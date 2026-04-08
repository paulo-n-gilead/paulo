#!/bin/bash
#SBATCH --job-name=amber_mpi
#SBATCH --partition=build
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --gres=gpu:0
#SBATCH --output=amber_mpi_%j.out

# ==========================================================
#   Amber Multi-Node MPI Workflow Script  (sander.MPI)
# ==========================================================
# Usage:
#   sbatch [--partition=build] [--nodes=N] [--ntasks-per-node=M] \
#          amber_mpi.sbatch <prmtop_path> <inpcrd_path> <output_dir>
#
# Optional environment variables:
#   MDIN_DIR=/path/to/mdin_files     (default: ./mdin_files)
#
# Examples:
#   # 4 nodes × 8 ranks = 32 MPI processes
#   sbatch --partition=build --nodes=4 --ntasks-per-node=8 \
#          amber_mpi.sbatch system.prmtop system.inpcrd output_mpi
#
#   # Single node, 16 ranks
#   sbatch --partition=build --nodes=1 --ntasks=16 \
#          amber_mpi.sbatch system.prmtop system.inpcrd output_mpi_1n
#
# Mirrors gromacs_mpi.sbatch (CPU/multi-node path):
#   mpirun -np N gmx_mpi mdrun  →  mpirun -np N sander.MPI
#   --mca pml_ucx_tls any       →  --mca btl_openib_allow_ib true (InfiniBand)
#
# Pre-requisite: system.prmtop + system.inpcrd must already exist.
#   Run tleap manually or via amber.sbatch first.
# ==========================================================

# --- Parse CLI arguments ---
INPUT_PRMTOP=$1
INPUT_INPCRD=$2
OUTDIR=$3

if [[ -z "${INPUT_PRMTOP}" || -z "${INPUT_INPCRD}" || -z "${OUTDIR}" ]]; then
    echo "❌ ERROR: Missing arguments."
    echo "Usage: sbatch amber_mpi.sbatch <prmtop> <inpcrd> <output_dir>"
    exit 1
fi

# --- Validate input files ---
if [[ ! -f "${INPUT_PRMTOP}" ]]; then
    echo "❌ ERROR: Topology file not found: ${INPUT_PRMTOP}"
    exit 2
fi
if [[ ! -f "${INPUT_INPCRD}" ]]; then
    echo "❌ ERROR: Coordinate file not found: ${INPUT_INPCRD}"
    exit 2
fi

# --- Directory configuration ---
SCRIPT_DIR=$(pwd)
MDIN_DIR=${MDIN_DIR:-"${SCRIPT_DIR}/mdin_files"}

for mdin in em.mdin heat.mdin prod.mdin; do
    if [ ! -f "${MDIN_DIR}/${mdin}" ]; then
        echo "❌ Required mdin file not found: ${MDIN_DIR}/${mdin}"
        exit 1
    fi
done

# --- Handle output directory safely  (mirrors gromacs_mpi.sbatch backup logic) ---
time_stamp=$(date +%Y-%m-%d-%H%M%S)
if [[ -d "${OUTDIR}" ]]; then
    echo "⚠️  Output directory already exists: ${OUTDIR}"
    echo "📦 Renaming to: ${OUTDIR}_${time_stamp}"
    mv "${OUTDIR}" "${OUTDIR}_${time_stamp}"
fi
mkdir -p "${OUTDIR}"
cp "${INPUT_PRMTOP}" "${INPUT_INPCRD}" "${OUTDIR}/"
cp "${MDIN_DIR}"/*.mdin "${OUTDIR}/"
cd "${OUTDIR}" || exit 3

PRMTOP=$(basename "${INPUT_PRMTOP}")
INPCRD=$(basename "${INPUT_INPCRD}")
TOTAL_RANKS=${SLURM_NTASKS}

# --- Load environment ---
module load amber ambertools 2>/dev/null || echo "⚠️  Warning: module load failed"

# --- Info summary  (mirrors gromacs_mpi.sbatch info block) ---
echo "======================================"
echo "📁 Working directory : $(pwd)"
echo "📄 Topology          : ${PRMTOP}"
echo "📄 Coordinates       : ${INPCRD}"
echo "🧩 Partition         : ${SLURM_JOB_PARTITION}"
echo "🧮 Nodes             : ${SLURM_JOB_NUM_NODES:-${SLURM_NNODES}}"
echo "🔢 MPI ranks         : ${TOTAL_RANKS}"
echo "🧵 Ranks per node    : ${SLURM_NTASKS_PER_NODE:-auto}"
echo "======================================"
echo ""

# Show node distribution
echo "🧩 Node distribution:"
srun -n "${TOTAL_RANKS}" hostname 2>/dev/null | sort | uniq -c || echo "  (srun not available)"
echo ""

# ----------------------------------------------------------
#  Stage 1: Energy minimization  (serial — sander is safest for EM)
# ----------------------------------------------------------
echo "--------------------------------------"
echo "👉 Stage 1: sander — energy minimization (serial)"
echo "--------------------------------------"
START=$(date +%s)
sander -O \
    -i em.mdin    -o em.mdout \
    -p "${PRMTOP}" -c "${INPCRD}" -r em.rst7
STATUS=$?; END=$(date +%s)
[ $STATUS -ne 0 ] && echo "❌ sander (EM) failed" && exit 1
echo "✅ Energy minimization complete  ⏱️ $((END - START))s"
echo ""

# ----------------------------------------------------------
#  Stage 2: NVT heating  (multi-node MPI)
# ----------------------------------------------------------
echo "--------------------------------------"
echo "👉 Stage 2: sander.MPI — NVT heating 0→300 K (${TOTAL_RANKS} ranks)"
echo "--------------------------------------"
START=$(date +%s)
mpirun -np "${TOTAL_RANKS}" \
    --mca btl_openib_allow_ib true \
    sander.MPI -O \
    -i heat.mdin   -o heat.mdout \
    -p "${PRMTOP}" -c em.rst7 -r heat.rst7 -x heat.nc
STATUS=$?; END=$(date +%s)
[ $STATUS -ne 0 ] && echo "❌ sander.MPI (heat) failed" && exit 1
echo "✅ NVT heating complete  ⏱️ $((END - START))s"
echo ""

# ----------------------------------------------------------
#  Stage 3: NPT production MD  (multi-node MPI, timed)
# ----------------------------------------------------------
echo "--------------------------------------"
echo "👉 Stage 3: sander.MPI — NPT production MD (${TOTAL_RANKS} ranks)"
echo "--------------------------------------"
START=$(date +%s)
time mpirun -np "${TOTAL_RANKS}" \
    --mca btl_openib_allow_ib true \
    sander.MPI -O \
    -i prod.mdin   -o prod.mdout \
    -p "${PRMTOP}" -c heat.rst7 -r prod.rst7 -x prod.nc \
    -inf prod.mdinfo
STATUS=$?; END=$(date +%s)
[ $STATUS -ne 0 ] && echo "❌ sander.MPI (prod) failed" && exit 1
echo "✅ Production MD complete  ⏱️ $((END - START))s"

echo ""
echo "✅ Job completed successfully at: $(date)"
echo "📂 Results saved in: ${OUTDIR}"
