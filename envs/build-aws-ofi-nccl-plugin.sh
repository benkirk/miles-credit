#!/bin/bash -eu

# Set environment variables for dependencies
AWS_OFI_NCCL_VERSION=${AWS_OFI_NCCL_VERSION:-"v1.19.2"}
OFI_HOME=${NCAR_ROOT_LIBFABRIC}
AWS_OFI_PLUGIN_HOME=${CONDA_PREFIX}
HWLOC_PREFIX=${CONDA_PREFIX}

# Build the OFI Plugin

build_dir=$(mktemp -d)
pushd ${build_dir}

git clone https://github.com/aws/aws-ofi-nccl.git && git -C aws-ofi-nccl fetch --tags --quiet && git -C aws-ofi-nccl checkout ${AWS_OFI_NCCL_VERSION}
cd aws-ofi-nccl

echo "==> Building aws-ofi-nccl plugin in $(pwd)"
./autogen.sh
CC=gcc CXX=g++ ./configure \
       --with-libfabric="${OFI_HOME}" \
       --with-cuda="${CUDA_HOME}" \
       --with-hwloc="${HWLOC_PREFIX}" \
       --prefix="${AWS_OFI_PLUGIN_HOME}" \
       --disable-picky-compiler
make --no-print-directory -j 8 && make --no-print-directory install
popd

rm -rf ${build_dir}
