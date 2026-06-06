# ref: https://github.com/HewlettPackard/shs-ccl-docs/blob/main/ccl_env.sh

# SPDX-FileCopyrightText: Copyright Hewlett Packard Enterprise Development LP
# SPDX-License-Identifier: MIT

# Source this file to include recommended NCCL or RCCL environment variables.
#
# RCCL, NCCL, aws-ofi-nccl  and fabric environment variables for all_reduce_perf
# Note: When running with slurm, the flag --network=disable_rdzv_get is required
# and must be added to the srun command.  When running with PBS, the flag
# --disable_rdzv_get is required for the RDZV settings

export HSA_FORCE_FINE_GRAIN_PCIE=1
export FI_MR_CACHE_MONITOR=userfaultfd
export FI_CXI_DISABLE_HOST_REGISTER=1
export FI_CXI_DEFAULT_CQ_SIZE=131072
#export FI_CXI_RDZV_PROTO=alt_read
#export FI_CXI_RDZV_EAGER_SIZE=0
#export FI_CXI_RDZV_THRESHOLD=0
#export FI_CXI_RDZV_GET_MIN=0
export FI_CXI_DEFAULT_TX_SIZE=2048
export NCCL_CROSS_NIC=1
export NCCL_NET_GDR_LEVEL=PHB
export NCCL_SOCKET_IFNAME=hsn0,hsn1,hsn2,hsn3

# WARNING: Do not set NCCL_NET on single-node runs. Setting this variable
# forces NCCL to use the network transport even when all ranks share the same
# node, causing unnecessary VNI allocation and degraded performance.
export NCCL_NET="AWS Libfabric"
export FI_CXI_RX_MATCH_MODE=hybrid

# --- CREDIT-specific: locate the relocated aws-ofi-nccl plugin ----------------
# The plugin and its hwloc dependency install under <env>/dependencies (NOT the
# environment's default lib/, and uv never auto-exposes a lib dir), so point
# NCCL straight at the plugin and add its libdir to the loader path.  Works for
# both conda (CONDA_PREFIX) and uv (VIRTUAL_ENV); we pick whichever holds the
# built plugin.  Quoted list items -> no word-splitting (bash & zsh safe).
for _credit_env in "${VIRTUAL_ENV:-}" "${CONDA_PREFIX:-}"; do
    if [ -n "${_credit_env}" ] && [ -f "${_credit_env}/dependencies/lib/libnccl-net-ofi.so" ]; then
        export NCCL_NET_PLUGIN="${_credit_env}/dependencies/lib/libnccl-net-ofi.so"
        # prepend the plugin libdir only if it is not already present
        case ":${LD_LIBRARY_PATH:-}:" in
            *":${_credit_env}/dependencies/lib:"*) : ;;
            *) export LD_LIBRARY_PATH="${_credit_env}/dependencies/lib:${LD_LIBRARY_PATH:-}" ;;
        esac
        break
    fi
done
unset _credit_env
