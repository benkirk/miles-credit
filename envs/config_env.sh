#!/usr/bin/env bash -e


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
    echo "Unknown shell!"
fi
SCRIPTDIR="$(realpath "$(dirname "$(realpath "${SCRIPT_PATH}")")")"
#----------------------------------------------------------------------------

ROOT_DIR=$(realpath ${CONFDIR}/..)

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
        module --force purge >/dev/null 2>&1
        module load ncarenv/25.10 >/dev/null 2>&1
        module reset >/dev/null 2>&1
        module load gcc/14.3.0 conda >/dev/null 2>&1
        module list

        pip_extra_args="--extra-index-url https://download.pytorch.org/whl/cu126"

        ;;

    "derecho")
        ENV_NAME=${ENV_NAME}-${NCAR_HOST}

        # setup preferred module environment
        type module >/dev/null 2>&1 || source /etc/profile.d/z00_modules.sh
        module --force purge >/dev/null 2>&1
        module load ncarenv/25.10 >/dev/null 2>&1
        module reset >/dev/null 2>&1
        module load gcc/14.3.0 conda cuda >/dev/null 2>&1
        module list

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
module try-load conda > /dev/null 2>&1
conda --version > /dev/null 2>&1 || {
    echo "Cannot locate conda?"
    exit 1
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
if [[ -d "{ENV_DIR}" ]]; then
    echo "Activating ${ENV_DIR}"
    conda activate ${ENV_DIR}

    # quick return mechanism; works whens sourcing or executing
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
        pip install -e ".[ncar-hpc-${NCAR_HOST}]" ${pip_extra_args}\

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
echo "\"${ENV_NAME}\" conda environment for Derecho successfully installed into ${CONDA_PREFIX}"
echo "use \"conda activate ${ENV_DIR}\" to activate"
