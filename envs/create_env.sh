#!/usr/bin/env bash


#----------------------------------------------------------------------------
# Build a CREDIT Python environment from scratch (conda by default, or uv when
# CREDIT_BACKEND=uv).  EXECUTE-ONLY: config_env.sh invokes this as a SUBPROCESS when
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
#   CREDIT_BACKEND        - "conda" or "uv" (default from versions_config.sh)
#   CREDIT_VERBOSE        - 0/1 (forwarded to the probe; also echoes the pip command)
#   CREDIT_PYTHON_VERSION - Python to build with (default from versions_config.sh)
#   CREDIT_TORCH_VERSION  - optional torch version pin (empty -> versions_config.sh default)
#   CREDIT_CUDA_VERSION   - optional CUDA build of torch (empty -> host/global default)
#   NCAR_HOST      - host id (-> __ce_target_host); already in the HPC environment
#   plus the module environment the parent loaded (PATH/CC/CUDA_HOME/...),
#   which IS inherited by this subprocess.
#
# Host policy (__CE_ENV_DIR, pip target, NCCL/OFI flags) is recomputed HERE from the
# shared versions_config.sh given the same __ce_target_host/CREDIT_BACKEND, so parent and
# child agree by construction rather than via a fragile export list.
#----------------------------------------------------------------------------


SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPTDIR}/versions_config.sh"

CREDIT_BACKEND="${CREDIT_BACKEND:-${CREDIT_DEFAULT_BACKEND}}"          # versions_config.sh
CREDIT_VERBOSE="${CREDIT_VERBOSE:-0}"
CREDIT_PYTHON_VERSION="${CREDIT_PYTHON_VERSION:-${CREDIT_DEFAULT_PYTHON_VERSION}}"  # versions_config.sh
CREDIT_TORCH_VERSION="${CREDIT_TORCH_VERSION:-}"
CREDIT_CUDA_VERSION="${CREDIT_CUDA_VERSION:-}"
CREDIT_VENV_PYTHON="${CREDIT_VENV_PYTHON:-python3}"   # --venv interpreter (parent-resolved)
__ce_target_host="${NCAR_HOST:-default}"
__ce_host_config

# `conda activate` is a SHELL FUNCTION defined by conda.sh -- not the `conda`
# PATH binary -- and it is NOT inherited by this EXECUTED (non-sourced) child,
# even though the parent already ran it.  conda is already on PATH (the parent
# loaded its module, inherited here), so re-source conda.sh in THIS process to
# make `conda activate` work below.  (The uv and venv paths activate a venv FILE
# we are about to create, so they have no such inheritance issue.)
if [ "${CREDIT_BACKEND}" = "conda" ]; then
    __ce_conda_root=$(conda info --base 2>/dev/null)
    if [ -n "${__ce_conda_root}" ] && [ -f "${__ce_conda_root}/etc/profile.d/conda.sh" ]; then
        source "${__ce_conda_root}/etc/profile.d/conda.sh"
    fi
fi


#-------------------------------------------------------
# create a minimal isolated environment with a controlled Python (the default
# lives in versions_config.sh; set by --python-version, passed in as
# CREDIT_PYTHON_VERSION)
case "${CREDIT_BACKEND}" in
    uv)
        # Force a uv-managed standalone CPython (--managed-python) so the venv
        # never adopts an interpreter the caller's shell merely happens to
        # expose -- e.g. an active conda env (CONDA_PREFIX) or a system
        # python3.11 on PATH -- whose lifecycle we do not control.  Without it,
        # uv symlinks the venv's python at that external interpreter, which then
        # dangles if it is later rebuilt or removed (breaking the uv env and the
        # conda/uv "coexistence" guarantee).
        uv venv --managed-python --python "${CREDIT_PYTHON_VERSION}" "${__CE_ENV_DIR}" || {
            echo "create_env.sh: 'uv venv' failed." >&2
            exit 1
        }
        source "${__CE_ENV_DIR}/bin/activate" || {
            echo "create_env.sh: activating uv venv '${__CE_ENV_DIR}' failed." >&2
            exit 1
        }
        ;;
    venv)
        # Plain stdlib venv against the PATH interpreter the parent resolved and
        # validated (CREDIT_VENV_PYTHON; its version == CREDIT_PYTHON_VERSION).
        # Unlike uv we deliberately ADOPT that interpreter -- that is the point
        # of this backend (independent of conda and uv).
        "${CREDIT_VENV_PYTHON}" -m venv "${__CE_ENV_DIR}" || {
            echo "create_env.sh: '${CREDIT_VENV_PYTHON} -m venv' failed." >&2
            exit 1
        }
        source "${__CE_ENV_DIR}/bin/activate" || {
            echo "create_env.sh: activating venv '${__CE_ENV_DIR}' failed." >&2
            exit 1
        }
        ;;
    conda)
        conda create \
              --yes \
              --prefix "${__CE_ENV_DIR}" \
              python="${CREDIT_PYTHON_VERSION}" || {
            echo "create_env.sh: 'conda create' failed." >&2
            exit 1
        }

        conda activate "${__CE_ENV_DIR}" || {
            echo "create_env.sh: 'conda activate ${__CE_ENV_DIR}' failed." >&2
            exit 1
        }
        ;;
esac

#-------------------------------------------------------
# install the Python stack, forcing a source build of mpi4py with the host
# compilers.  Build the command via `set --` (a function-local positional
# list) so expansion is identical under bash and zsh -- no unquoted
# word-splitting -- and the extra-index URL is appended as two explicit
# args only when set.  uv has its OWN no-binary flag; it does NOT honor
# pip's PIP_NO_BINARY.  Fail loudly: a failed install must NOT fall through
# to "success".  conda and venv both drive the now-active env's plain `pip`
# (PIP_NO_BINARY forces the mpi4py source build); only uv differs.
if [ "${CREDIT_BACKEND}" = "uv" ]; then
    set -- uv pip install --no-binary mpi4py -e "${__CE_PIP_TARGET_SPEC}"
else
    export PIP_NO_BINARY="mpi4py"
    set -- pip install -e "${__CE_PIP_TARGET_SPEC}"
fi
# Pin torch (version + CUDA build) on the command line on CUDA hosts, with the
# matching PyTorch index appended right after.  Both come from versions_config.sh
# (driven by --torch-version/--cuda-version) -- empty on non-CUDA installs.
[ -n "${__CE_TORCH_SPEC}" ] && set -- "$@" "${__CE_TORCH_SPEC}"
[ -n "${__CE_PIP_EXTRA_URL}" ]   && set -- "$@" --extra-index-url "${__CE_PIP_EXTRA_URL}"
# The command is assembled dynamically (backend, extra, torch pin, index); echo
# the fully expanded form under --verbose so it is reproducible.  %q quotes each
# arg safely and is supported by both bash and zsh.
[ "${CREDIT_VERBOSE}" -eq 1 ] && { printf '+'; printf ' %q' "$@"; printf '\n'; }
"$@" || {
    echo "create_env.sh: package install failed." >&2
    exit 1
}

#-------------------------------------------------------
# host-specific post-install steps
if [ "${__CE_NEEDS_OFI_PLUGIN}" -eq 1 ]; then

    # Build the AWS OFI NCCL plugin and its non-Python build dependency
    # (hwloc) under a single per-env "dependencies" prefix, independent of
    # the packaging backend.  The build script provisions a standalone
    # CUDA-aware hwloc there when the system lacks the dev headers, and makes
    # its own hwloc prefix/rpath decision.  Fail loudly: a broken plugin must
    # NOT report success.
    export AWS_OFI_NCCL_VERSION="${CREDIT_DEFAULT_AWS_OFI_NCCL_VERSION}"   # versions_config.sh
    export AWS_OFI_PLUGIN_HOME="${__CE_ENV_DIR}/dependencies"
    export CREDIT_CUDA_VERSION="${__CE_CUDA_VER}"   # resolved CLI>host>global; for hwloc's conda build
    ${SCRIPTDIR}/build-aws-ofi-nccl-plugin.sh || {
        echo "create_env.sh: aws-ofi-nccl plugin build failed." >&2
        exit 1
    }

    # For the conda backend, also install activate.d/deactivate.d hooks so a
    # bare `conda activate <prefix>` sets the NCCL/CXI runtime env on its own
    # (the deactivate.d dir may not exist yet).  Both backends additionally
    # get the hook sourced into the caller's shell by config_env.sh's
    # __ce_source_runtime_hooks.
    if [ "${CREDIT_BACKEND}" = "conda" ]; then
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
[ "${CREDIT_VERBOSE}" -eq 1 ]          && set -- "$@" "--verbose"
python "$@" || {
    echo "create_env.sh: environment health check failed." >&2
    exit 1
}

#-------------------------------------------------------
# Record the env's identity: write the EXACT manifest string that __ce_host_config
# hashed into __CE_ENV_DIR's name (recomputed here, identical by construction).  It is
# byte-for-byte what was hashed, so re-hashing the file reproduces the dir's SHA
# (integrity), and config_env.sh's activate-path guard compares against it.  Only
# after the health check passes, so an incomplete build never leaves a manifest.
printf '%s' "${__CE_MANIFEST}" > "${__CE_ENV_DIR}/credit-env.manifest" || {
    echo "create_env.sh: failed to write ${__CE_ENV_DIR}/credit-env.manifest." >&2
    exit 1
}

#-------------------------------------------------------
# report success
echo
case "${CREDIT_BACKEND}" in
    uv)
        echo "\"${__CE_ENV_NAME}\" uv environment for ${__ce_target_host} successfully installed into ${VIRTUAL_ENV}"
        echo "use \"source ${__CE_ENV_DIR}/bin/activate\" to activate"
        ;;
    venv)
        echo "\"${__CE_ENV_NAME}\" venv environment for ${__ce_target_host} successfully installed into ${VIRTUAL_ENV}"
        echo "use \"source ${__CE_ENV_DIR}/bin/activate\" to activate"
        ;;
    conda)
        echo "\"${__CE_ENV_NAME}\" conda environment for ${__ce_target_host} successfully installed into ${CONDA_PREFIX}"
        echo "use \"conda activate ${__CE_ENV_DIR}\" to activate"
        ;;
esac
