#!/usr/bin/env bash


#----------------------------------------------------------------------------
# Build a CREDIT Python environment from scratch (conda by default, or uv when
# BACKEND=uv).  EXECUTE-ONLY: config_env.sh invokes this as a SUBPROCESS when
# the target env does not yet exist, then re-activates the finished prefix in
# the caller's shell itself.  Because this is a child process it pollutes
# nothing -- no dual-mode driver, no sourced-detection, no __ce_cleanup needed.
# Like build-aws-ofi-nccl-plugin.sh it receives its inputs via the environment
# and reports via exit code.  Unlike that script it does NOT use `set -eu`: it
# sources conda.sh / `conda activate` / the venv `activate` (which reference
# unbound vars and return nonzero internally, tripping -u/-e), so it relies on
# an explicit `|| { ...; exit 1; }` on every step instead -- exactly as the
# original __ce_build_env did.  Fail loudly: no step may fall through to
# "success".
#
# Inputs (from the environment the parent exports / inherits):
#   BACKEND    - "conda" (default) or "uv"
#   VERBOSE    - 0/1 (forwarded to the probe)
#   NCAR_HOST  - host id (-> TARGET_HOST); already in the HPC environment
#   plus the module environment the parent loaded (PATH/CC/CUDA_HOME/...),
#   which IS inherited by this subprocess.
#
# Host policy (ENV_DIR, pip target, NCCL/OFI flags) is recomputed HERE from the
# shared host_config.sh given the same TARGET_HOST/BACKEND, so parent and child
# agree by construction rather than via a fragile export list.
#----------------------------------------------------------------------------


SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPTDIR}/host_config.sh"

BACKEND="${BACKEND:-conda}"
VERBOSE="${VERBOSE:-0}"
TARGET_HOST="${NCAR_HOST:-default}"
__ce_host_config

# `conda activate` is a SHELL FUNCTION defined by conda.sh -- not the `conda`
# PATH binary -- and it is NOT inherited by this EXECUTED (non-sourced) child,
# even though the parent already ran it.  conda is already on PATH (the parent
# loaded its module, inherited here), so re-source conda.sh in THIS process to
# make `conda activate` work below.  (The uv path activates a venv FILE we are
# about to create, so it has no such inheritance issue.)
if [ "${BACKEND}" != "uv" ]; then
    CONDA_ROOT=$(conda info --base 2>/dev/null)
    if [ -n "${CONDA_ROOT}" ] && [ -f "${CONDA_ROOT}/etc/profile.d/conda.sh" ]; then
        source "${CONDA_ROOT}/etc/profile.d/conda.sh"
    fi
fi


#-------------------------------------------------------
# create a minimal isolated environment with a controlled Python (3.11)
if [ "${BACKEND}" = "uv" ]; then
    # Force a uv-managed standalone CPython (--managed-python) so the venv
    # never adopts an interpreter the caller's shell merely happens to
    # expose -- e.g. an active conda env (CONDA_PREFIX) or a system
    # python3.11 on PATH -- whose lifecycle we do not control.  Without it,
    # uv symlinks the venv's python at that external interpreter, which then
    # dangles if it is later rebuilt or removed (breaking the uv env and the
    # conda/uv "coexistence" guarantee).
    uv venv --managed-python --python 3.11 "${ENV_DIR}" || {
        echo "create_env.sh: 'uv venv' failed." >&2
        exit 1
    }
    source "${ENV_DIR}/bin/activate" || {
        echo "create_env.sh: activating uv venv '${ENV_DIR}' failed." >&2
        exit 1
    }
else
    conda create \
          --yes \
          --prefix "${ENV_DIR}" \
          python=3.11 || {
        echo "create_env.sh: 'conda create' failed." >&2
        exit 1
    }

    conda activate "${ENV_DIR}" || {
        echo "create_env.sh: 'conda activate ${ENV_DIR}' failed." >&2
        exit 1
    }
fi

#-------------------------------------------------------
# install the Python stack, forcing a source build of mpi4py with the host
# compilers.  Build the command via `set --` (a function-local positional
# list) so expansion is identical under bash and zsh -- no unquoted
# word-splitting -- and the extra-index URL is appended as two explicit
# args only when set.  uv has its OWN no-binary flag; it does NOT honor
# pip's PIP_NO_BINARY.  Fail loudly: a failed install must NOT fall through
# to "success".
if [ "${BACKEND}" = "uv" ]; then
    set -- uv pip install --no-binary mpi4py -e "${PIP_TARGET_SPEC}"
else
    export PIP_NO_BINARY="mpi4py"
    set -- pip install -e "${PIP_TARGET_SPEC}"
fi
[ -n "${PIP_EXTRA_URL}" ] && set -- "$@" --extra-index-url "${PIP_EXTRA_URL}"
"$@" || {
    echo "create_env.sh: package install failed." >&2
    exit 1
}

#-------------------------------------------------------
# host-specific post-install steps
if [ "${NEEDS_OFI_PLUGIN}" -eq 1 ]; then

    # Build the AWS OFI NCCL plugin and its non-Python build dependency
    # (hwloc) under a single per-env "dependencies" prefix, independent of
    # the packaging backend.  The build script provisions a standalone
    # CUDA-aware hwloc there when the system lacks the dev headers, and makes
    # its own hwloc prefix/rpath decision.  Fail loudly: a broken plugin must
    # NOT report success.
    export AWS_OFI_NCCL_VERSION="v1.19.2"
    export AWS_OFI_PLUGIN_HOME="${ENV_DIR}/dependencies"
    ${SCRIPTDIR}/build-aws-ofi-nccl-plugin.sh || {
        echo "create_env.sh: aws-ofi-nccl plugin build failed." >&2
        exit 1
    }

    # For the conda backend, also install activate.d/deactivate.d hooks so a
    # bare `conda activate <prefix>` sets the NCCL/CXI runtime env on its own
    # (the deactivate.d dir may not exist yet).  Both backends additionally
    # get the hook sourced into the caller's shell by config_env.sh's
    # __ce_source_runtime_hooks.
    if [ "${BACKEND}" = "conda" ]; then
        mkdir -p ${CONDA_PREFIX}/etc/conda/activate.d ${CONDA_PREFIX}/etc/conda/deactivate.d \
            && cp ${SCRIPTDIR}/activate-nccl-hpe-cxi.sh ${CONDA_PREFIX}/etc/conda/activate.d/nccl-hpe-cxi.sh \
            && cp ${SCRIPTDIR}/deactivate-nccl-hpe-cxi.sh ${CONDA_PREFIX}/etc/conda/deactivate.d/nccl-hpe-cxi.sh || {
            echo "create_env.sh: failed to install NCCL activate/deactivate hooks." >&2
            exit 1
        }
    fi
fi

#-------------------------------------------------------
# post-install health check: queries the torch build (version/CUDA/NCCL),
# reports NCCL only when present, and confirms `import credit` works.
# NCCL is required only where we expect it (casper/derecho).  Build the
# arg list via `set --` (a function-local positional list) so expansion is
# identical under bash and zsh -- no unquoted word-splitting.
set -- "${SCRIPTDIR}/probe_installed_env.py"
[ "${__CE_EXPECT_NCCL}" -eq 1 ] && set -- "$@" "--require-nccl"
[ "${VERBOSE}" -eq 1 ]          && set -- "$@" "--verbose"
python "$@" || {
    echo "create_env.sh: environment health check failed." >&2
    exit 1
}

#-------------------------------------------------------
# report success
echo
if [ "${BACKEND}" = "uv" ]; then
    echo "\"${ENV_NAME}\" uv environment for ${TARGET_HOST} successfully installed into ${VIRTUAL_ENV}"
    echo "use \"source ${ENV_DIR}/bin/activate\" to activate"
else
    echo "\"${ENV_NAME}\" conda environment for ${TARGET_HOST} successfully installed into ${CONDA_PREFIX}"
    echo "use \"conda activate ${ENV_DIR}\" to activate"
fi
