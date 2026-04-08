#!/bin/bash
#SBATCH --job-name=amber
#SBATCH --partition=build
#SBATCH --nodes=1
#SBATCH --ntasks=16
#SBATCH --cpus-per-task=1
#SBATCH --gres=gpu:0
#SBATCH --output=amber_workflow_%j.out

# ==========================================================
#   Unified Amber CPU Workflow Script
# ==========================================================
# Usage:
#   sbatch [--partition=build] [--nodes=1] [--ntasks=N] \
#          amber.sbatch
#
# Optional environment variables:
#   INPUT_DIR=/path/to/pdbs          (default: ./input)
#   OUTPUT_BASE=/path/to/output      (default: ./output)
#   MDIN_DIR=/path/to/mdin_files     (default: ./mdin_files)
#   LEAPRC=/path/to/leaprc.input     (default: ./leaprc.input)
#
# Example:
#   INPUT_DIR=/scratch/pdbs OUTPUT_BASE=/scratch/results \
#   sbatch --partition=build --nodes=1 --ntasks=16 amber.sbatch
#
# This script mirrors gromacs.sbatch:
#   pdb2gmx + editconf + solvate → tleap
#   grompp (em)  + mdrun (em)    → sander (EM)
#   grompp (md)  + mdrun (md)    → sander.MPI (heat) + sander.MPI (prod)
# ==========================================================

# ----------------------------------------------------------
#  Environment setup
# ----------------------------------------------------------
module load amber ambertools 2>/dev/null || echo "⚠️  Warning: module load failed — ensure amber and ambertools are in PATH"

export GMX_MAXBACKUP=-1   # unused, kept for parity with gromacs.sbatch comment style

# ----------------------------------------------------------
#  Directory configuration (user-overridable)
# ----------------------------------------------------------
SCRIPT_DIR=$(pwd)
INPUT_DIR=${INPUT_DIR:-"${SCRIPT_DIR}/input"}
OUTPUT_BASE=${OUTPUT_BASE:-"${SCRIPT_DIR}/output"}
MDIN_DIR=${MDIN_DIR:-"${SCRIPT_DIR}/mdin_files"}
LEAPRC=${LEAPRC:-"${SCRIPT_DIR}/leaprc.input"}

mkdir -p "${OUTPUT_BASE}"

# ----------------------------------------------------------
#  Show SLURM job configuration summary
# ----------------------------------------------------------
echo "======================================"
echo "📋 SLURM Job Configuration"
echo "======================================"
echo "🧩 Partition      : ${SLURM_JOB_PARTITION}"
echo "🧮 Nodes          : ${SLURM_JOB_NUM_NODES}"
echo "🔢 MPI Ranks      : ${SLURM_NTASKS}"
echo "📊 Hostname       : $(hostname)"
echo ""
echo "======================================"
echo "📂 Workflow Directories"
echo "======================================"
echo "📥 Input Directory : ${INPUT_DIR}"
echo "📤 Output Base     : ${OUTPUT_BASE}"
echo "🧾 MDIN Directory  : ${MDIN_DIR}"
echo "🔧 tleap script    : ${LEAPRC}"
echo "======================================"
echo ""

# ----------------------------------------------------------
#  Validate inputs
# ----------------------------------------------------------
if ! compgen -G "${INPUT_DIR}/*.pdb" > /dev/null; then
    echo "❌ No PDB files found in: ${INPUT_DIR}"
    exit 1
fi

if [ ! -f "${LEAPRC}" ]; then
    echo "❌ tleap script not found: ${LEAPRC}"
    exit 1
fi

for mdin in em.mdin heat.mdin prod.mdin; do
    if [ ! -f "${MDIN_DIR}/${mdin}" ]; then
        echo "❌ Required mdin file not found: ${MDIN_DIR}/${mdin}"
        exit 1
    fi
done

# ----------------------------------------------------------
#  Loop over input PDB files  (mirrors gromacs.sbatch per-PDB loop)
# ----------------------------------------------------------
for INPUT_PDB in "${INPUT_DIR}"/*.pdb; do
    BASENAME=$(basename "${INPUT_PDB}" .pdb)
    OUTDIR="${OUTPUT_BASE}/${BASENAME}"
    time_stamp=$(date +%Y-%m-%d-%H%M%S)

    # Backup old runs safely (mirrors gromacs.sbatch backup logic)
    [ -d "${OUTDIR}" ] && mv "${OUTDIR}" "${OUTDIR}_${time_stamp}"
    mkdir -p "${OUTDIR}"

    echo "======================================"
    echo "🚀 Starting Amber Workflow for: ${BASENAME}"
    echo "Working Dir: ${OUTDIR}"
    echo "Input File : ${INPUT_PDB}"
    echo "======================================"

    # Copy input PDB and mdin files into working directory
    cp "${INPUT_PDB}" "${OUTDIR}/"
    cp "${MDIN_DIR}"/*.mdin "${OUTDIR}/" 2>/dev/null || echo "⚠️  No mdin files copied"

    # Write a per-run tleap script pointing at the copied PDB
    cat > "${OUTDIR}/leaprc_run.input" << LEAPEOF
source leaprc.protein.ff99SBildn
source leaprc.water.spce
mol = loadpdb ${BASENAME}.pdb
check mol
solvateBox mol SPCBOX 10.0
addions mol Na+ 0
saveamberparm mol system.prmtop system.inpcrd
savepdb mol system.pdb
quit
LEAPEOF

    cd "${OUTDIR}" || exit 3

    # ----------------------------------------------------------
    #  Stage 0: System preparation  (mirrors pdb2gmx + editconf + solvate + grompp)
    # ----------------------------------------------------------
    echo "--------------------------------------"
    echo "👉 Stage 0: tleap — system preparation"
    echo "--------------------------------------"
    START=$(date +%s)
    tleap -f leaprc_run.input
    STATUS=$?; END=$(date +%s)
    [ $STATUS -ne 0 ] && echo "❌ tleap failed (${BASENAME})" && exit 1
    echo "✅ tleap complete  ⏱️ $((END - START))s"
    echo ""

    # ----------------------------------------------------------
    #  Stage 1: Energy minimization  (mirrors gromacs EM mdrun)
    # ----------------------------------------------------------
    echo "--------------------------------------"
    echo "👉 Stage 1: sander — energy minimization"
    echo "--------------------------------------"
    START=$(date +%s)
    sander -O \
        -i em.mdin    -o em.mdout \
        -p system.prmtop -c system.inpcrd -r em.rst7
    STATUS=$?; END=$(date +%s)
    [ $STATUS -ne 0 ] && echo "❌ sander (EM) failed (${BASENAME})" && exit 1
    echo "✅ Energy minimization complete  ⏱️ $((END - START))s"
    echo ""

    # ----------------------------------------------------------
    #  Stage 2: NVT heating 0 → 300 K  (Amber-specific pre-production stage)
    # ----------------------------------------------------------
    echo "--------------------------------------"
    echo "👉 Stage 2: sander.MPI — NVT heating 0→300 K"
    echo "--------------------------------------"
    START=$(date +%s)
    mpirun -np "${SLURM_NTASKS}" sander.MPI -O \
        -i heat.mdin   -o heat.mdout \
        -p system.prmtop -c em.rst7 -r heat.rst7 -x heat.nc
    STATUS=$?; END=$(date +%s)
    [ $STATUS -ne 0 ] && echo "❌ sander.MPI (heat) failed (${BASENAME})" && exit 1
    echo "✅ NVT heating complete  ⏱️ $((END - START))s"
    echo ""

    # ----------------------------------------------------------
    #  Stage 3: NPT production MD  (mirrors gromacs production mdrun)
    # ----------------------------------------------------------
    echo "--------------------------------------"
    echo "👉 Stage 3: sander.MPI — NPT production MD"
    echo "--------------------------------------"
    START=$(date +%s)
    mpirun -np "${SLURM_NTASKS}" sander.MPI -O \
        -i prod.mdin   -o prod.mdout \
        -p system.prmtop -c heat.rst7 -r prod.rst7 -x prod.nc \
        -inf prod.mdinfo
    STATUS=$?; END=$(date +%s)
    [ $STATUS -ne 0 ] && echo "❌ sander.MPI (prod) failed (${BASENAME})" && exit 1
    echo "✅ Production MD complete  ⏱️ $((END - START))s"
    echo ""

    echo "🎯 Finished processing: ${BASENAME}"
    echo "📂 Results stored in: ${OUTDIR}"
    echo ""
    cd "${SCRIPT_DIR}"
done

echo "🎉 All Amber CPU workflow jobs completed successfully!"
