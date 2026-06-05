#!/bin/bash -eu

# Set environment variables for dependencies
AWS_OFI_NCCL_VERSION=${AWS_OFI_NCCL_VERSION:-"v1.19.2"}
OFI_HOME=${NCAR_ROOT_LIBFABRIC}
AWS_OFI_PLUGIN_HOME=${CONDA_PREFIX}

# Make a conda-provided hwloc.pc visible to pkg-config when present.
export PKG_CONFIG_PATH="${CONDA_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# hwloc: prefer the system/module dev headers; fall back to the conda copy.
# When we build against the conda hwloc, bake an rpath to it so the plugin
# loads THAT hwloc at runtime (aws-ofi-nccl's configure adds -L but no -rpath).
# This probe must agree with config_env.sh, so it runs in the same env.
HWLOC_CONFIGURE_ARG=""     # --with-hwloc=... or empty (let configure search)
HWLOC_RPATH_LDFLAGS=""     # -Wl,-rpath for the conda libdir, when used
if printf '#include <hwloc.h>\n' | ${CC:-gcc} -E -x c - >/dev/null 2>&1; then
    echo "==> using system/module hwloc (configure auto-detect; no rpath needed)"
elif [ -f "${CONDA_PREFIX}/include/hwloc.h" ] \
     || { command -v pkg-config >/dev/null 2>&1 && pkg-config --exists hwloc 2>/dev/null; }; then
    echo "==> using conda hwloc at ${CONDA_PREFIX}"
    HWLOC_CONFIGURE_ARG="--with-hwloc=${CONDA_PREFIX}"
    HWLOC_RPATH_LDFLAGS="-Wl,-rpath,${CONDA_PREFIX}/lib"
else
    echo "ERROR: no hwloc.h on system path and none in ${CONDA_PREFIX}." >&2
    echo "       install one (conda install -c conda-forge libhwloc) and retry." >&2
    exit 1
fi

# Build the OFI Plugin

build_dir=$(mktemp -d)
pushd ${build_dir}

git clone https://github.com/aws/aws-ofi-nccl.git && git -C aws-ofi-nccl fetch --tags --quiet && git -C aws-ofi-nccl checkout ${AWS_OFI_NCCL_VERSION}
cd aws-ofi-nccl

echo "==> Building aws-ofi-nccl plugin in $(pwd)"
./autogen.sh
CC=gcc CXX=g++ LDFLAGS="${HWLOC_RPATH_LDFLAGS} ${LDFLAGS:-}" ./configure \
       --with-libfabric="${OFI_HOME}" \
       --with-cuda="${CUDA_HOME}" \
       ${HWLOC_CONFIGURE_ARG} \
       --prefix="${AWS_OFI_PLUGIN_HOME}" \
       --disable-picky-compiler
make --no-print-directory -j 8 && make --no-print-directory install
popd

rm -rf ${build_dir}
