#!/usr/bin/env bash


#----------------------------------------------------------------------------
# Per-host policy for the CREDIT environment scripts.
#
# This file is SOURCED (never executed) by BOTH config_env.sh (the dual-mode
# entry point) and create_env.sh (the build subprocess).  Keeping it here means
# host policy stays a SINGLE SOURCE OF TRUTH: both processes derive the same
# ENV_DIR / pip target / module set from the same code given the same
# TARGET_HOST + BACKEND, with no fragile cross-process export list.
#
# The sourcer MUST set SCRIPTDIR (the envs/ dir), BACKEND, and PYTHON_VERSION
# before calling __ce_host_config; it reads TARGET_HOST too.
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
#                      on word-splitting -- which differs between bash & zsh)
#   PIP_TARGET_SPEC  - "."  or  ".[ncar-hpc-<host>]"
#   __CE_CUDA_MODULE - ""  or  "cuda"  (<= 1 token, so unquoted expansion is
#                      identical in bash and zsh)
#   __CE_USE_MODULES - 0/1 (run the module dance?)
#   NEEDS_OFI_PLUGIN - 0/1 (derecho-only post-build steps)
#   __CE_EXPECT_NCCL - 0/1 (is NCCL expected here? -> health check requires it.
#                      NCCL is optional in general but expected on the GPU/HPC
#                      hosts we cannot exercise on free CI: casper, derecho)
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
    __CE_CUDA_MODULE=""
    __CE_USE_MODULES=0
    NEEDS_OFI_PLUGIN=0
    __CE_EXPECT_NCCL=0

    case "${TARGET_HOST}" in

        "default")
            # vanilla conda, nothing special; all defaults above apply
            ;;

        "casper")
            ENV_NAME="${ENV_NAME}-${NCAR_HOST}"
            __CE_USE_MODULES=1
            PIP_EXTRA_URL="https://download.pytorch.org/whl/cu126"
            PIP_TARGET_SPEC=".[ncar-hpc-${NCAR_HOST}]"
            __CE_EXPECT_NCCL=1
            ;;

        "derecho")
            ENV_NAME="${ENV_NAME}-${NCAR_HOST}"
            __CE_USE_MODULES=1
            __CE_CUDA_MODULE="cuda"
            PIP_EXTRA_URL="https://download.pytorch.org/whl/cu129"
            PIP_TARGET_SPEC=".[ncar-hpc-${NCAR_HOST}]"
            NEEDS_OFI_PLUGIN=1
            __CE_EXPECT_NCCL=1
            ;;

        *)
            echo "ERROR: unhandled ${TARGET_HOST}?!!" >&2
            ;;
    esac

    # Encode the Python version into the prefix (always, even the default) so
    # envs built with different Python versions coexist and never cross-detect.
    ENV_NAME="${ENV_NAME}-py${PYTHON_VERSION}"

    # Give the uv env its own prefix so a uv build and a conda build can coexist
    # and the per-backend existence tests never cross-detect one another.
    [ "${BACKEND}" = "uv" ] && ENV_NAME="${ENV_NAME}-uv"

    ENV_DIR="${SCRIPTDIR}/${ENV_NAME}"
}

#----------------------------------------------------------------------------
# Tidy up the shell state THIS file defines.  Co-located with the definitions
# above so adding a var/function here means updating the cleanup in the SAME
# file (config_env.sh's __ce_cleanup just invokes this).  Only meaningful when
# sourced into a long-lived shell (i.e. config_env.sh sourced); harmless in the
# create_env.sh subprocess, which never calls it.
__ce_host_config_cleanup() {
    unset ENV_NAME ENV_DIR PIP_EXTRA_URL PIP_TARGET_SPEC \
          __CE_CUDA_MODULE __CE_USE_MODULES NEEDS_OFI_PLUGIN __CE_EXPECT_NCCL 2>/dev/null
    unset -f __ce_host_config 2>/dev/null
    unset -f __ce_host_config_cleanup 2>/dev/null   # self-unset LAST
}
