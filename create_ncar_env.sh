#!/bin/bash

set -e

#-----------------------------------------------------------
# set up an initial conda environment at ${CREDIT_ENV_PATH}
# containing Derecho-specific torch & MPI bits.
module load ncarenv/25.10 >/dev/null 2>&1
module reset >/dev/null 2>&1
module load gcc/14.3.0 conda >/dev/null 2>&1
module list

#export ESMFMKFILE="/glade/work/dgagne/esmf-8.9.1/lib/libO/Linux.gfortran.64.mpiuni.default/esmf.mk"
topdir=$(git rev-parse --show-toplevel)
CREDIT_ENV_NAME=${CREDIT_ENV_NAME:-"credit-${NCAR_HOST}-env"}

# force recreate
[ -d ./${CREDIT_ENV_NAME} ] && ~/bin/purge.sh -f ./${CREDIT_ENV_NAME} || true

#-----------------------------------------------------------
# create minimal conda environment
conda create \
      --yes \
      --prefix ./${CREDIT_ENV_NAME} \
      python=3.11

conda activate ./${CREDIT_ENV_NAME}

#-----------------------------------------------------------
# install via pip,
# forcing a source build of mpi4py with host compilers
# with special per-machine additional configuration
export PIP_NO_BINARY="mpi4py"
case "${NCAR_HOST}" in
    "casper")
        pip install -e ".[ncar-hpc-${NCAR_HOST}]" \
            --extra-index-url https://download.pytorch.org/whl/cu126
        ;;

    "derecho")
        pip install -e ".[ncar-hpc-${NCAR_HOST}]" \
            --extra-index-url https://download.pytorch.org/whl/cu129

        # install hwloc via conda; it is a dependency for aws-ofi-nccl
        conda install \
              --yes \
              -c conda-forge \
              libhwloc=*=*cuda* cuda-version=12.9

        # need CUDA to compile aws-ofi-nccl
        module load cuda

        # Set environment variables for dependencies
        OFI_HOME=/opt/cray/libfabric/1.22.0
        AWS_OFI_PLUGIN_HOME=${CONDA_PREFIX}
        HWLOC_PREFIX=${CONDA_PREFIX}
        AWS_OFI_NCCL_VERSION="v1.19.2"

        # Build the OFI Plugin
        echo "==> Building aws-ofi-nccl plugin"
        rm -rf ./aws-ofi-nccl/
        git clone https://github.com/aws/aws-ofi-nccl.git && git -C aws-ofi-nccl fetch --tags --quiet && git -C aws-ofi-nccl checkout ${AWS_OFI_NCCL_VERSION}
        pushd aws-ofi-nccl
        ./autogen.sh
        CC=gcc CXX=g++ ./configure \
              --with-libfabric="${OFI_HOME}" \
              --with-cuda="${CUDA_HOME}" \
              --with-hwloc="${HWLOC_PREFIX}" \
              --prefix="${AWS_OFI_PLUGIN_HOME}" \
              --disable-picky-compiler
        make -j 8 && make install
        popd

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
echo "\"${CREDIT_ENV_NAME}\" conda environment for Derecho successfully installed into CONDA_PREFIX"
echo "use \"conda activate ${CREDIT_ENV_NAME}\" to activate"
