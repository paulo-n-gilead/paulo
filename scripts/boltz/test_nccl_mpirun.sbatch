#!/bin/bash
#SBATCH --job-name=boltz-nccl-mpirun
#SBATCH --partition=gpu
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --gres=gpu:a10g:1
#SBATCH --time=00:20:00
#SBATCH --output=slurm-%x-%j.out

set -euo pipefail
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK}"
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export NCCL_DEBUG=INFO
export PYTHONUNBUFFERED=1

source "${HOME}/spack/share/spack/setup-env.sh"
spack env activate boltz

export MASTER_ADDR="$(scontrol show hostnames "${SLURM_JOB_NODELIST}" | head -n 1)"
export MASTER_PORT=29501

mpirun -np "${SLURM_NTASKS}" --map-by ppr:1:node \
    -x MASTER_ADDR -x MASTER_PORT -x NCCL_DEBUG -x CUDA_DEVICE_ORDER \
    python - <<'PY'
import os
import torch
import torch.distributed as dist

# OpenMPI rank env
rank = int(os.environ.get("OMPI_COMM_WORLD_RANK", "0"))
world = int(os.environ.get("OMPI_COMM_WORLD_SIZE", "1"))
local_rank = int(os.environ.get("OMPI_COMM_WORLD_LOCAL_RANK", "0"))

assert torch.cuda.is_available(), "CUDA not available"
torch.cuda.set_device(local_rank)

dist.init_process_group(
    backend="nccl",
    init_method="tcp://{}:{}".format(os.environ["MASTER_ADDR"], os.environ["MASTER_PORT"]),
    rank=rank,
    world_size=world
)

x = torch.tensor([rank + 1.0], device="cuda")
dist.all_reduce(x, op=dist.ReduceOp.SUM)
expected = world * (world + 1) / 2
ok = abs(x.item() - expected) < 1e-3
print(f"[rank={rank}] all_reduce={x.item()} expected={expected} ok={ok}")
dist.destroy_process_group()

if not ok:
    raise SystemExit(3)
PY