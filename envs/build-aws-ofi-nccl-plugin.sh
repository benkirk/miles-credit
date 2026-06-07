#!/bin/bash -eu

# Pull in the central default versions (single source of truth) when present, so
# the standalone default matches what create_env.sh exports.  Guarded + with a
# literal last resort so this script still runs if the file is ever absent.
SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "${SCRIPTDIR}/default_versions.sh" ] && source "${SCRIPTDIR}/default_versions.sh"

# Set environment variables for dependencies
AWS_OFI_NCCL_VERSION="${AWS_OFI_NCCL_VERSION:-${CREDIT_DEFAULT_AWS_OFI_NCCL_VERSION:-v1.19.2}}"
OFI_HOME=${NCAR_ROOT_LIBFABRIC}

# Match the standalone hwloc to the CUDA the rest of the env uses.  create_env.sh
# exports the resolved (CLI>host>global) choice; standalone runs fall back to the
# central default.  Strip the dot for the conda build string (12.8 -> cuda128).
CUDA_VERSION="${CREDIT_CUDA_VERSION:-${CREDIT_DEFAULT_CUDA_VERSION:-12.9}}"
CUDA_CONDA_BUILD="cuda${CUDA_VERSION//./}"

# The plugin and its non-Python build dependencies (hwloc) install under a
# single per-environment "dependencies" prefix, INDEPENDENT of the Python
# packaging backend (conda or uv).  config_env.sh exports AWS_OFI_PLUGIN_HOME
# explicitly; the fallback derives <active-env>/dependencies for standalone use.
AWS_OFI_PLUGIN_HOME="${AWS_OFI_PLUGIN_HOME:-${VIRTUAL_ENV:-${CONDA_PREFIX:-}}/dependencies}"
mkdir -p "${AWS_OFI_PLUGIN_HOME}"

# hwloc supplies the build headers (and a runtime lib) for aws-ofi-nccl.  Prefer
# the system/module dev headers; otherwise provision a standalone CUDA-aware
# hwloc in its OWN conda env under the dependencies prefix.  When we build
# against that hwloc, bake an rpath to it so the plugin loads THAT hwloc at
# runtime (aws-ofi-nccl's configure adds -L but no -rpath).
HWLOC_CONFIGURE_ARG=""     # --with-hwloc=... or empty (let configure search)
HWLOC_RPATH_LDFLAGS=""     # -Wl,-rpath for the hwloc libdir, when used
if printf '#include <hwloc.h>\n' | ${CC:-gcc} -E -x c - >/dev/null 2>&1; then
    echo "==> using system/module hwloc (configure auto-detect; no rpath needed)"
else
    HWLOC_PREFIX="${AWS_OFI_PLUGIN_HOME}/hwloc-env"
    if [ ! -f "${HWLOC_PREFIX}/include/hwloc.h" ]; then
        echo "==> no system hwloc.h; provisioning a standalone CUDA-aware hwloc in ${HWLOC_PREFIX}"
        # We only need the `conda` BINARY here to create an isolated build-deps
        # env; we never ACTIVATE it, so this is fully independent of the uv/conda
        # Python packaging backend the caller is using.  Load the module only if
        # conda is not already on PATH (e.g. the uv backend).  conda and uv are
        # *conflicting* modules on NCAR HPC, so we must drop uv first -- safe
        # here in this child shell, where uv is not needed (the gcc/cuda modules
        # the build relies on are unaffected).
        if ! command -v conda >/dev/null 2>&1; then
            type module >/dev/null 2>&1 || source /etc/profile.d/z00_modules.sh 2>/dev/null || true
            module unload uv >/dev/null 2>&1 || true
            module load conda >/dev/null 2>&1 || module try-load conda >/dev/null 2>&1 || true
        fi
        command -v conda >/dev/null 2>&1 || {
            echo "ERROR: hwloc must be built but 'conda' is not available." >&2
            echo "       'module load conda' (or install conda) and retry." >&2
            exit 1
        }
        # CONDA_OVERRIDE_CUDA lets the cudaNNN build resolve on a driverless
        # login node, where conda's __cuda virtual package is otherwise absent.
        CONDA_OVERRIDE_CUDA="${CUDA_VERSION}" conda create --yes --prefix "${HWLOC_PREFIX}" \
              -c conda-forge "libhwloc=*=${CUDA_CONDA_BUILD}*" cuda-version="${CUDA_VERSION}" pkg-config
    else
        echo "==> reusing standalone hwloc at ${HWLOC_PREFIX}"
    fi
    HWLOC_CONFIGURE_ARG="--with-hwloc=${HWLOC_PREFIX}"
    HWLOC_RPATH_LDFLAGS="-Wl,-rpath,${HWLOC_PREFIX}/lib"
    export PKG_CONFIG_PATH="${HWLOC_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
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
