#!/bin/bash
#SBATCH --job-name=boltz-smoke-srun
#SBATCH --partition=gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --gres=gpu:a10g:1
#SBATCH --time=00:15:00
#SBATCH --output=slurm-%x-%j.out

set -euo pipefail
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK}"
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export NCCL_DEBUG=INFO
export PYTHONUNBUFFERED=1

source "${HOME}/spack/share/spack/setup-env.sh"
spack env activate boltz

echo "=== MPI runtime sanity (CPU ranks) ==="
srun -n 2 --overcommit python - <<'PY'
from mpi4py import MPI
import socket
c = MPI.COMM_WORLD
print(f"[mpi] rank={c.rank}/{c.size} host={socket.gethostname()}")
PY

echo "=== CUDA availability + matmul sanity ==="
srun -n 1 python - <<'PY'
import torch
assert torch.cuda.is_available(), "CUDA not available"
torch.cuda.set_device(0)
a = torch.randn(4096, 4096, device="cuda", dtype=torch.float16)
b = torch.randn(4096, 4096, device="cuda", dtype=torch.float16)
c = a @ b
torch.cuda.synchronize()
print("[cuda] device:", torch.cuda.get_device_name(0), "checksum:", float(c.mean()))
PY

echo "=== Boltz CLI check ==="
srun -n 1 boltz predict --help | head -n 30

