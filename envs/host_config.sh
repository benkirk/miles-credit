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
# The sourcer MUST set SCRIPTDIR (the envs/ dir) BEFORE sourcing this file (it
# is used immediately, below, to pull in default_versions.sh) and set
# CREDIT_BACKEND and CREDIT_PYTHON_VERSION before calling __ce_host_config; it
# reads TARGET_HOST too.  CREDIT_TORCH_VERSION and CREDIT_CUDA_VERSION are
# optional inputs (empty => host/global defaults apply).
#
# Like config_env.sh this must be portable to BOTH bash and zsh (no associative
# arrays; no reliance on word-splitting).
#----------------------------------------------------------------------------


# Central, single source of truth for the DEFAULT versions (python/torch/CUDA/
# AWS plugin) and the default backend.  Sourcing it here is the one hop that
# delivers the CREDIT_DEFAULT_* constants to BOTH config_env.sh and
# create_env.sh, since both source this file at top level before they need a
# default.  __ce_host_config_cleanup chains to its cleanup.
source "${SCRIPTDIR}/default_versions.sh"


#----------------------------------------------------------------------------
# Single source of truth for ALL per-host policy.  Sets plain scalars
# (portable to bash AND zsh; no associative arrays):
#   __CE_MANIFEST    - canonical config manifest (every build-affecting input,
#                      fixed field order); hashed for the prefix and written
#                      verbatim into the built env as credit-env.manifest.
#   __CE_SHA         - 8-hex content hash of __CE_MANIFEST (via __ce_sha).
#   ENV_NAME         - <backend>-credit-env[-<host>]-<__CE_SHA>
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
#   __CE_CUDA_VER    - the RESOLVED CUDA version (e.g. 12.8), or "" on non-CUDA
#                      installs.  Computed once here so consumers (e.g. the
#                      aws-ofi-nccl plugin build) need not re-derive the
#                      precedence.
#   global defaults  - torch + CUDA defaults come from default_versions.sh
#                      (CREDIT_DEFAULT_TORCH_VERSION / CREDIT_DEFAULT_CUDA_VERSION)
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
    __CE_CUDA_VER=""

    case "${TARGET_HOST}" in

        "default")
            # vanilla conda, nothing special; all defaults above apply.
            # (A CUDA torch build is opt-in here via --cuda-version.)
            ;;

        "casper")
            __CE_USE_MODULES=1
            PIP_TARGET_SPEC=".[distributed]"
            __CE_EXPECT_NCCL=1
            __CE_WANT_CUDA=1          # default CUDA -> CREDIT_DEFAULT_CUDA_VERSION
            ;;

        "derecho")
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
        __CE_TORCH_VER="${CREDIT_TORCH_VERSION:-${CREDIT_DEFAULT_TORCH_VERSION}}"
        __CE_CUDA_VER="${CREDIT_CUDA_VERSION:-${__CE_DEFAULT_CUDA:-${CREDIT_DEFAULT_CUDA_VERSION}}}"
        __CE_CUDA_TAG="cu${__CE_CUDA_VER//./}"
        PIP_EXTRA_URL="https://download.pytorch.org/whl/${__CE_CUDA_TAG}"
        __CE_TORCH_SPEC="torch==${__CE_TORCH_VER}+${__CE_CUDA_TAG}"
        unset __CE_TORCH_VER __CE_CUDA_TAG   # keep __CE_CUDA_VER (a documented output)
    elif [ -n "${CREDIT_TORCH_VERSION}" ]; then
        # No CUDA build requested, but the user pinned a torch version with
        # --torch-version: pin the CPU build of torch from PyPI.  PIP_EXTRA_URL
        # stays empty (set above), so the default index serves the CPU wheel --
        # no +cu<tag> suffix, no --extra-index-url.  When NEITHER a CUDA build
        # nor --torch-version is requested, both arms are skipped and torch
        # stays unpinned (pyproject's bare 'torch' resolves it) -- the original
        # 'default' host behavior, preserved.
        __CE_TORCH_SPEC="torch==${CREDIT_TORCH_VERSION}"
    fi

    # ----- content-addressed prefix -------------------------------------------
    # Assemble a CANONICAL config manifest from every input that affects the
    # build, in a FIXED field order; empty fields mean "does not apply".  Hashing
    # this (not the raw CLI args) is what makes the prefix unique across every
    # axis AND idempotent: flag spelling/order is irrelevant because the manifest
    # is the already-resolved config.  Fields record build INTENT, not resolved
    # package versions (so unpinned torch keeps a stable SHA -- not a lockfile).
    #   schema       - recipe version; bump to deliberately invalidate ALL envs
    #                  when the build recipe changes in a way no field captures.
    #   aws_ofi_nccl - included ONLY when the plugin is actually built (derecho),
    #                  so bumping its default never invalidates default/casper.
    # printf with NO trailing newline: the bytes hashed here are byte-for-byte the
    # bytes create_env.sh writes to credit-env.manifest, so the file always
    # re-hashes to the SHA in the dir name (a free integrity check).
    __CE_MANIFEST="$(printf '%s' \
"schema=1
backend=${CREDIT_BACKEND}
host=${TARGET_HOST}
python=${CREDIT_PYTHON_VERSION}
torch=${CREDIT_TORCH_VERSION}
cuda=${CREDIT_CUDA_VERSION}
torch_spec=${__CE_TORCH_SPEC}
pip_extra_url=${PIP_EXTRA_URL}
pip_target=${PIP_TARGET_SPEC}
aws_ofi_nccl=$([ "${NEEDS_OFI_PLUGIN}" -eq 1 ] && printf '%s' "${CREDIT_DEFAULT_AWS_OFI_NCCL_VERSION}")
ofi_plugin=${NEEDS_OFI_PLUGIN}")"

    # Name = <backend>-credit-env[-<host>]-<short-sha>.  backend leads (covers
    # conda AND uv explicitly, replacing the old -uv suffix / bare-conda
    # asymmetry); the host segment appears only for non-default hosts; python +
    # everything else live in the manifest + SHA, not the name.  8 hex chars:
    # inputs are config-derived (non-adversarial) and the manifest-match guard in
    # config_env.sh is the backstop, so collision risk is negligible.
    __CE_SHA="$(printf '%s' "${__CE_MANIFEST}" | __ce_sha | cut -c1-8)"
    ENV_NAME="${CREDIT_BACKEND}-credit-env"
    [ "${TARGET_HOST}" != "default" ] && ENV_NAME="${ENV_NAME}-${TARGET_HOST}"
    ENV_NAME="${ENV_NAME}-${__CE_SHA}"

    ENV_DIR="${SCRIPTDIR}/${ENV_NAME}"
}

#----------------------------------------------------------------------------
# Portable SHA-256 of stdin -> bare lowercase hex digest on stdout.
#
# Used by __ce_host_config to hash the config manifest at config-resolution time
# -- BEFORE the env is built and (on the 'default' host) potentially before any
# module puts a Python on PATH.  So the hasher MUST NOT depend on the very
# interpreter these scripts exist to provision: try the coreutils/openssl
# binaries present on bare login nodes + macOS + Linux runners first, and keep
# `python3 -c hashlib` strictly as a last resort.  Each tool's output is
# normalized to just the digest:
#   sha256sum / shasum -a 256 -> "<hash>  -"            (take field 1)
#   openssl dgst -sha256      -> "(stdin)= <hash>"  or
#                                "SHA2-256(stdin)= <hash>" (openssl 3) (take last)
# bash + zsh safe (no associative arrays, no word-splitting reliance).
__ce_sha() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 | awk '{print $NF}'
    else
        python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
    fi
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
          __CE_WANT_CUDA __CE_DEFAULT_CUDA __CE_CUDA_VER __CE_MANIFEST __CE_SHA 2>/dev/null
    unset -f __ce_host_config __ce_sha 2>/dev/null
    # Clean up the default_versions.sh state we sourced in (defensive: it may be
    # absent if sourcing failed).  Self-unsets the CREDIT_DEFAULT_* constants.
    command -v __ce_default_versions_cleanup >/dev/null 2>&1 && __ce_default_versions_cleanup
    unset -f __ce_host_config_cleanup 2>/dev/null   # self-unset LAST
}
