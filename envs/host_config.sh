#!/usr/bin/env bash


#----------------------------------------------------------------------------
# Per-host policy for the CREDIT environment scripts.
#
# This file is SOURCED (never executed) by BOTH config_env.sh (the dual-mode
# entry point) and create_env.sh (the build subprocess).  Keeping it here means
# host policy stays a SINGLE SOURCE OF TRUTH: both processes derive the same
# ENV_DIR / pip target / module set from the same code given the same
# TARGET_HOST + CREDIT_BACKEND, with no fragile cross-process export list.
#
# The sourcer MUST set SCRIPTDIR (the envs/ dir), CREDIT_BACKEND, and CREDIT_PYTHON_VERSION
# before calling __ce_host_config; it reads TARGET_HOST too.  CREDIT_TORCH_VERSION and
# CREDIT_CUDA_VERSION are optional inputs (empty => host/global defaults apply).
#
# Like config_env.sh this must be portable to BOTH bash and zsh (no associative
# arrays; no reliance on word-splitting).
#----------------------------------------------------------------------------


#----------------------------------------------------------------------------
# Single source of truth for ALL per-host policy.  Sets plain scalars
# (portable to bash AND zsh; no associative arrays):
#   ENV_NAME         - base name + optional host suffix
#   ENV_DIR          - derived here, once
#   PIP_EXTRA_URL    - bare extra-index URL, or "" (kept as a URL, not a
#                      "--extra-index-url <url>" string, so we never depend
#                      on word-splitting -- which differs between bash & zsh).
#                      Derived from the resolved CUDA version on CUDA hosts.
#   PIP_TARGET_SPEC  - "."  or  ".[distributed]"  (the single MPI extra; the
#                      torch/CUDA pin is NOT in pyproject -- see __CE_TORCH_SPEC)
#   __CE_TORCH_SPEC  - "" or "torch==<ver>+cu<tag>": explicit torch pin appended
#                      to the pip line on CUDA hosts.  Replaces the former
#                      per-host ncar-hpc-{casper,derecho} torch pins so the
#                      version/CUDA build are chosen at install time, not baked
#                      into pyproject.toml.
#   __CE_CUDA_MODULE - ""  or  "cuda"  (<= 1 token, so unquoted expansion is
#                      identical in bash and zsh)
#   __CE_USE_MODULES - 0/1 (run the module dance?)
#   NEEDS_OFI_PLUGIN - 0/1 (derecho-only post-build steps)
#   __CE_EXPECT_NCCL - 0/1 (is NCCL expected here? -> health check requires it.
#                      NCCL is optional in general but expected on the GPU/HPC
#                      hosts we cannot exercise on free CI: casper, derecho)
#
# CUDA/torch selection (resolution order: CLI flag > per-host default > global):
#   __CE_WANT_CUDA   - 0/1 (does this host install a CUDA torch build?)
#   __CE_DEFAULT_CUDA- per-host default CUDA version, or "" to use the global one
#   global defaults  - torch 2.10.0, CUDA 12.6 (the constants below)
# The 'default' host installs a CUDA build only if the user passes --cuda-version.
#
# ADDING A HOST = add ONE case arm here.  Both config_env.sh's module-setup
# phase and create_env.sh's pip/build phase read from this function, so nothing
# else needs editing.  (If a future host needs a module set unlike
# "gcc + <backend> [+ cuda]", branch in __ce_setup_modules in config_env.sh --
# the one other host-aware spot.)
__ce_host_config() {
    ENV_NAME="credit-env"
    PIP_EXTRA_URL=""
    PIP_TARGET_SPEC="."
    __CE_TORCH_SPEC=""
    __CE_CUDA_MODULE=""
    __CE_USE_MODULES=0
    NEEDS_OFI_PLUGIN=0
    __CE_EXPECT_NCCL=0
    __CE_WANT_CUDA=0
    __CE_DEFAULT_CUDA=""

    case "${TARGET_HOST}" in

        "default")
            # vanilla conda, nothing special; all defaults above apply.
            # (A CUDA torch build is opt-in here via --cuda-version.)
            ;;

        "casper")
            ENV_NAME="${ENV_NAME}-${NCAR_HOST}"
            __CE_USE_MODULES=1
            PIP_TARGET_SPEC=".[distributed]"
            __CE_EXPECT_NCCL=1
            __CE_WANT_CUDA=1          # default CUDA -> global default (12.6)
            ;;

        "derecho")
            ENV_NAME="${ENV_NAME}-${NCAR_HOST}"
            __CE_USE_MODULES=1
            __CE_CUDA_MODULE="cuda"
            PIP_TARGET_SPEC=".[distributed]"
            NEEDS_OFI_PLUGIN=1
            __CE_EXPECT_NCCL=1
            __CE_WANT_CUDA=1
            __CE_DEFAULT_CUDA="12.9"  # derecho ships a newer CUDA than the global default
            ;;

        *)
            echo "ERROR: unhandled ${TARGET_HOST}?!!" >&2
            ;;
    esac

    # Build the torch pin + matching PyTorch extra-index-url when this host wants
    # a CUDA build (or the user explicitly asked for one with --cuda-version).
    # Resolve the CUDA version CLI > per-host default > global default; the torch
    # version is a single global default overridable by --torch-version.  Strip
    # the dot for the wheel tag (12.6 -> cu126; ${//} works in bash AND zsh).
    if [ "${__CE_WANT_CUDA}" -eq 1 ] || [ -n "${CREDIT_CUDA_VERSION}" ]; then
        __CE_TORCH_VER="${CREDIT_TORCH_VERSION:-2.10.0}"
        __CE_CUDA_VER="${CREDIT_CUDA_VERSION:-${__CE_DEFAULT_CUDA:-12.6}}"
        __CE_CUDA_TAG="cu${__CE_CUDA_VER//./}"
        PIP_EXTRA_URL="https://download.pytorch.org/whl/${__CE_CUDA_TAG}"
        __CE_TORCH_SPEC="torch==${__CE_TORCH_VER}+${__CE_CUDA_TAG}"
        unset __CE_TORCH_VER __CE_CUDA_VER __CE_CUDA_TAG
    fi

    # Encode the Python version into the prefix (always, even the default) so
    # envs built with different Python versions coexist and never cross-detect.
    ENV_NAME="${ENV_NAME}-py${CREDIT_PYTHON_VERSION}"

    # Give the uv env its own prefix so a uv build and a conda build can coexist
    # and the per-backend existence tests never cross-detect one another.
    [ "${CREDIT_BACKEND}" = "uv" ] && ENV_NAME="${ENV_NAME}-uv"

    ENV_DIR="${SCRIPTDIR}/${ENV_NAME}"
}

#----------------------------------------------------------------------------
# Tidy up the shell state THIS file defines.  Co-located with the definitions
# above so adding a var/function here means updating the cleanup in the SAME
# file (config_env.sh's __ce_cleanup just invokes this).  Only meaningful when
# sourced into a long-lived shell (i.e. config_env.sh sourced); harmless in the
# create_env.sh subprocess, which never calls it.
__ce_host_config_cleanup() {
    unset ENV_NAME ENV_DIR PIP_EXTRA_URL PIP_TARGET_SPEC __CE_TORCH_SPEC \
          __CE_CUDA_MODULE __CE_USE_MODULES NEEDS_OFI_PLUGIN __CE_EXPECT_NCCL \
          __CE_WANT_CUDA __CE_DEFAULT_CUDA 2>/dev/null
    unset -f __ce_host_config 2>/dev/null
    unset -f __ce_host_config_cleanup 2>/dev/null   # self-unset LAST
}
