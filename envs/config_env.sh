#!/usr/bin/env bash


#----------------------------------------------------------------------------
# Unified script to create and initialize a CREDIT conda-based environment
# across systems.
#
# This script is intended to be idempotent and both sourceable or runnable.
#----------------------------------------------------------------------------


#----------------------------------------------------------------------------
# Determine the directory containing this script, compatible with bash and zsh
if [ -n "${BASH_SOURCE[0]}" ]; then
    SCRIPT_PATH="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION}" ]; then
    SCRIPT_PATH="${(%):-%x}"
else
    echo "Unknown shell, falling back to \$0 for script path" >&2
    SCRIPT_PATH="$0"
fi
SCRIPTDIR="$(realpath "$(dirname "$(realpath "${SCRIPT_PATH}")")")"
#----------------------------------------------------------------------------


#----------------------------------------------------------------------------
# Command-line options. Works whether SOURCED or EXECUTED, under bash & zsh.
# We read "$@" directly: verified correct in both shells when args are supplied
# to `source`.  NOTE (zsh quirk): when this file is SOURCED with NO arguments,
# zsh does not reset positional parameters, so the caller's $@ is visible here.
# Normal interactive use (empty $@) is unaffected.
VERBOSE=0
REBUILD=0
__ce_show_help=0
__ce_bad_arg=""

for __ce_arg in "$@"; do
    case "${__ce_arg}" in
        --verbose|-v) VERBOSE=1 ;;
        --rebuild|-r) REBUILD=1 ;;
        --help|-h)    __ce_show_help=1 ;;
        "")           : ;;
        *)            __ce_bad_arg="${__ce_arg}" ;;
    esac
done

__ce_usage() {
    cat <<USAGE
Usage: [source] config_env.sh [--verbose] [--rebuild] [--help]

  --verbose, -v   Show module/conda setup output (quiet by default).
  --rebuild, -r   Rebuild the environment even if it already exists.
                  The existing env is moved aside and removed in the
                  background, then a fresh env is built.
  --help, -h      Show this help and stop.
USAGE
}

if [ -n "${__ce_bad_arg}" ]; then
    echo "config_env.sh: unknown argument '${__ce_bad_arg}'" >&2
    __ce_usage >&2
    __ce_show_help=1
fi

if [ "${__ce_show_help}" -eq 1 ]; then
    [ -n "${__ce_bad_arg}" ] || __ce_usage
    unset VERBOSE REBUILD __ce_show_help __ce_bad_arg __ce_arg 2>/dev/null
    unset -f __ce_usage 2>/dev/null
    return 0 2>/dev/null || exit 0
fi

# Verbosity helper: run a command quietly unless --verbose was given.
run_quiet() {
    if [ "${VERBOSE}" -eq 1 ]; then
        "$@"
    else
        "$@" >/dev/null 2>&1
    fi
}
#----------------------------------------------------------------------------

ENV_NAME=credit-env

#----------------------------------------------------------------------------
# special configuration for special machines:
# default: vanilla conda with nothing special
# NCAR_HOST: casper/derecho, load default modules and perform host-specific conf
TARGET_HOST=${NCAR_HOST:-"default"}

# pre-build host specific choices.
case "${TARGET_HOST}" in

    "default")
        # no-op
        ;;

    "casper")
        ENV_NAME=${ENV_NAME}-${NCAR_HOST}

        # setup preferred module environment
        type module >/dev/null 2>&1 || source /etc/profile.d/z00_modules.sh
        run_quiet module --force purge
        run_quiet module load ncarenv/25.10
        run_quiet module reset
        run_quiet module load gcc/14.3.0 conda
        run_quiet module list

        pip_extra_args="--extra-index-url https://download.pytorch.org/whl/cu126"

        ;;

    "derecho")
        ENV_NAME=${ENV_NAME}-${NCAR_HOST}

        # setup preferred module environment
        type module >/dev/null 2>&1 || source /etc/profile.d/z00_modules.sh
        run_quiet module --force purge
        run_quiet module load ncarenv/25.10
        run_quiet module reset
        run_quiet module load gcc/14.3.0 conda cuda
        run_quiet module list

        pip_extra_args="--extra-index-url https://download.pytorch.org/whl/cu129"
        ;;

    *)
        echo "ERROR: unhandled ${TARGET_HOST}?!!"
        ;;
esac

ENV_DIR=${SCRIPTDIR}/${ENV_NAME}



#----------------------------------------------------------------------------
# Conda - via various methods.
# If a conda module exists, load it.
# Initialize if needed.
run_quiet module try-load conda
conda --version >/dev/null 2>&1 || {
    echo "config_env.sh: cannot locate conda." >&2
    unset VERBOSE REBUILD __ce_show_help __ce_bad_arg __ce_arg 2>/dev/null
    unset -f __ce_usage run_quiet 2>/dev/null
    return 1 2>/dev/null || exit 1
}

# Initialize conda if not already initialized
if [ -z "$CONDA_SHLVL" ]; then
    # Try to source conda's setup script
    CONDA_ROOT=$(conda info --base 2>/dev/null)
    if [ -n "$CONDA_ROOT" ] && [ -f "$CONDA_ROOT/etc/profile.d/conda.sh" ]; then
        source "$CONDA_ROOT/etc/profile.d/conda.sh"
    fi
fi



#----------------------------------------------------------------------------
# Activate environment if exist, build if necessary or requested

# Smart rebuild: if the env exists and --rebuild was requested, move it aside
# (fast) and delete it in the background (slow rm on the parallel filesystem),
# then fall through to the build path below.
if [ -d "${ENV_DIR}" ] && [ "${REBUILD}" -eq 1 ]; then
    __ce_old="${ENV_DIR}.old.$$"
    echo "Rebuild requested; moving existing env aside: ${__ce_old}"
    if mv "${ENV_DIR}" "${__ce_old}"; then
        echo "Removing ${__ce_old} in the background..."
        nohup rm -rf "${__ce_old}" >/dev/null 2>&1 &
        disown 2>/dev/null || true
    else
        echo "config_env.sh: failed to move ${ENV_DIR} aside; aborting rebuild." >&2
        unset VERBOSE REBUILD __ce_old __ce_show_help __ce_bad_arg __ce_arg 2>/dev/null
        unset -f __ce_usage run_quiet 2>/dev/null
        return 1 2>/dev/null || exit 1
    fi
    unset __ce_old
fi

# Activate environment if it exists (and we did not just remove it for rebuild).
if [ -d "${ENV_DIR}" ]; then
    echo "Activating ${ENV_DIR}"
    conda activate "${ENV_DIR}"

    # quick return mechanism; works when sourcing or executing
    unset VERBOSE REBUILD __ce_show_help __ce_bad_arg __ce_arg 2>/dev/null
    unset -f __ce_usage run_quiet 2>/dev/null
    return 0 2>/dev/null || exit 0
fi


# OK - from here on out we are building then environment

#-----------------------------------------------------------
# create minimal conda environment
conda create \
      --yes \
      --prefix ${ENV_DIR} \
      python=3.11

conda activate ${ENV_DIR}

#-----------------------------------------------------------
# install via pip,
# forcing a source build of mpi4py with host compilers
# with special per-machine additional configuration
export PIP_NO_BINARY="mpi4py"
case "${TARGET_HOST}" in

    "default")
        pip install -e ".[]" ${pip_extra_args}
        ;;

    "casper")
        pip install -e ".[ncar-hpc-${NCAR_HOST}]" ${pip_extra_args}
        # nothing else special for Casper
        ;;

    "derecho")
        pip install -e ".[ncar-hpc-${NCAR_HOST}]" ${pip_extra_args}

        # install hwloc via conda; it is a dependency for aws-ofi-nccl
        conda install \
              --yes \
              -c conda-forge \
              libhwloc=*=*cuda* cuda-version=12.9

        # Set environment variables for dependencies
        OFI_HOME=/opt/cray/libfabric/1.22.0
        AWS_OFI_PLUGIN_HOME=${CONDA_PREFIX}
        HWLOC_PREFIX=${CONDA_PREFIX}
        AWS_OFI_NCCL_VERSION="v1.19.2"

        # Build the OFI Plugin
        ${SCRIPTDIR}/build-aws-ofi-nccl-plugin.sh

        # install the env var hooks:
        cp -r ${SCRIPTDIR}/activate-nccl-hpe-cxi.sh ${CONDA_PREFIX}/etc/conda/activate.d/nccl-hpe-cxi.sh
        cp -r ${SCRIPTDIR}/deactivate-nccl-hpe-cxi.sh ${CONDA_PREFIX}/etc/conda/deactivate.d/nccl-hpe-cxi.sh
        ;;
esac



#-----------------------------------------------------------
# query installed packages
python -c "import torch; print('torch version:', torch.__version__); print('CUDA available:', torch.cuda.is_available()); print(torch.__config__.show())"
python -c "import torch; print('nccl version:', torch.cuda.nccl.version())"
python -c "import credit"

#-----------------------------------------------------------
# report success
echo
echo "\"${ENV_NAME}\" conda environment for ${TARGET_HOST} successfully installed into ${CONDA_PREFIX}"
echo "use \"conda activate ${ENV_DIR}\" to activate"

#-----------------------------------------------------------
# tidy up shell state (important when SOURCED)
unset VERBOSE REBUILD __ce_show_help __ce_bad_arg __ce_arg 2>/dev/null
unset -f __ce_usage run_quiet 2>/dev/null
return 0 2>/dev/null || exit 0
