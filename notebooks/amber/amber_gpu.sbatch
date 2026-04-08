#!/bin/bash
#SBATCH --job-name=amber_gpu
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --gres=gpu:1
#SBATCH --output=amber_gpu_%j.out

# ==========================================================
#   Amber GPU Workflow Script  (pmemd.cuda)
# ==========================================================
# Usage:
#   sbatch [--partition=gpu] [--gres=gpu:1] \
#          amber_gpu.sbatch <prmtop_path> <inpcrd_path> <output_dir>
#
# Optional environment variables:
#   MDIN_DIR=/path/to/mdin_files     (default: ./mdin_files)
#
# Example:
#   sbatch --partition=gpu --gres=gpu:1 \
#          amber_gpu.sbatch system.prmtop system.inpcrd output_gpu
#
# Mirrors gromacs_mpi.sbatch (GPU path):
#   gmx_mpi mdrun -nb gpu -pme gpu  →  sander (EM) + pmemd.cuda (heat + prod)
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
    echo "Usage: sbatch amber_gpu.sbatch <prmtop> <inpcrd> <output_dir>"
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

# --- Load environment ---
module load amber ambertools 2>/dev/null || echo "⚠️  Warning: module load failed"

# --- Detect GPU  (mirrors gromacs_mpi.sbatch GPU detection) ---
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
echo "======================================"
echo "📁 Working directory : $(pwd)"
echo "📄 Topology          : ${PRMTOP}"
echo "📄 Coordinates       : ${INPCRD}"
echo "🧩 Partition         : ${SLURM_JOB_PARTITION}"
echo "🧮 Nodes             : ${SLURM_JOB_NUM_NODES}"
echo "🔢 CPU threads       : ${SLURM_CPUS_PER_TASK}"
echo "🎮 GPUs detected     : ${GPU_COUNT}"
echo "======================================"

if [[ "${GPU_COUNT}" -eq 0 ]]; then
    echo "❌ ERROR: No GPU detected. Submit to --partition=gpu --gres=gpu:1"
    exit 3
fi

export CUDA_VISIBLE_DEVICES=0
echo ""
echo "GPU status:"
nvidia-smi --query-gpu=index,name,memory.total,memory.free --format=csv,noheader
echo ""

# ----------------------------------------------------------
#  Stage 1: Energy minimization  (CPU — sander is more robust for EM)
# ----------------------------------------------------------
echo "--------------------------------------"
echo "👉 Stage 1: sander — energy minimization (CPU)"
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
#  Stage 2: NVT heating  (GPU — pmemd.cuda)
# ----------------------------------------------------------
echo "--------------------------------------"
echo "👉 Stage 2: pmemd.cuda — NVT heating 0→300 K (GPU)"
echo "--------------------------------------"
START=$(date +%s)
pmemd.cuda -O \
    -i heat.mdin   -o heat.mdout \
    -p "${PRMTOP}" -c em.rst7 -r heat.rst7 -x heat.nc
STATUS=$?; END=$(date +%s)
[ $STATUS -ne 0 ] && echo "❌ pmemd.cuda (heat) failed" && exit 1
echo "✅ NVT heating complete  ⏱️ $((END - START))s"
echo ""

# ----------------------------------------------------------
#  Stage 3: NPT production MD  (GPU — pmemd.cuda, timed)
# ----------------------------------------------------------
echo "--------------------------------------"
echo "👉 Stage 3: pmemd.cuda — NPT production MD (GPU)"
echo "--------------------------------------"
START=$(date +%s)
time pmemd.cuda -O \
    -i prod.mdin   -o prod.mdout \
    -p "${PRMTOP}" -c heat.rst7 -r prod.rst7 -x prod.nc \
    -inf prod.mdinfo
STATUS=$?; END=$(date +%s)
[ $STATUS -ne 0 ] && echo "❌ pmemd.cuda (prod) failed" && exit 1
echo "✅ Production MD complete  ⏱️ $((END - START))s"

echo ""
echo "✅ Job completed successfully at: $(date)"
echo "📂 Results saved in: ${OUTDIR}"
