#!/usr/bin/env bash


#----------------------------------------------------------------------------
# Versions + per-host policy for the CREDIT environment scripts -- the SINGLE
# SOURCE OF TRUTH for BOTH the DEFAULT versions (python/torch/CUDA/AWS plugin +
# the default backend) AND all per-host build policy (__CE_ENV_DIR, pip target, module
# set, NCCL/OFI flags, the config manifest + its SHA).  Keeping both here means
# every process derives identical values from the same code, with no fragile
# cross-process export list.
#
# This file is SOURCED (never executed) by config_env.sh (the dual-mode entry
# point), create_env.sh (the build subprocess), and build-aws-ofi-nccl-plugin.sh
# (which only needs the CREDIT_DEFAULT_AWS_OFI_NCCL_VERSION constant).  Sourcing
# it just assigns the CREDIT_DEFAULT_* constants and DEFINES the functions below;
# nothing runs, so it is safe to source even under `set -eu`.
#
# Bump a default = a one-line edit to the CREDIT_DEFAULT_* block below.
#
# Inputs to __ce_host_config (set by the sourcer BEFORE calling it): CREDIT_BACKEND
# and CREDIT_PYTHON_VERSION; it reads __ce_target_host too; CREDIT_TORCH_VERSION and
# CREDIT_CUDA_VERSION are optional (empty => host/global defaults apply).  SCRIPTDIR
# (the envs/ dir) need only be set before __ce_host_config is CALLED -- it is used
# for __CE_ENV_DIR -- not at source time (this file no longer sources a sibling).
#
# Like config_env.sh this must be portable to BOTH bash and zsh (no associative
# arrays; no reliance on word-splitting).
#----------------------------------------------------------------------------


# Central, single source of truth for the DEFAULT versions and the default
# backend.  THIS is the one place to bump them.  CREDIT_*-prefixed, so they are
# wiped by config_env.sh's glob cleanup when sourced into a long-lived shell; the
# create_env.sh / build-aws-ofi-nccl-plugin.sh subprocesses never clean up --
# they pollute nothing.
CREDIT_DEFAULT_BACKEND="conda"          # packaging backend when --uv is absent
CREDIT_DEFAULT_PYTHON_VERSION="3.11"    # --python-version default
CREDIT_MIN_PYTHON_VERSION="3.11"        # floor for the --venv backend (adopts the
                                        # PATH python); keep in sync with
                                        # pyproject.toml requires-python
CREDIT_DEFAULT_TORCH_VERSION="2.10.0"   # --torch-version default (CUDA hosts)
CREDIT_DEFAULT_CUDA_VERSION="12.6"      # global --cuda-version default; a host
                                        # may override it (see __ce_host_config,
                                        # e.g. derecho -> 12.9)
CREDIT_DEFAULT_AWS_OFI_NCCL_VERSION="v1.19.2"   # aws-ofi-nccl plugin tag


#----------------------------------------------------------------------------
# Single source of truth for ALL per-host policy.  Sets plain scalars
# (portable to bash AND zsh; no associative arrays):
#   __CE_MANIFEST    - canonical config manifest (every build-affecting input,
#                      fixed field order); hashed for the prefix and written
#                      verbatim into the built env as credit-env.manifest.
#   __CE_SHA         - 8-hex content hash of __CE_MANIFEST (via __ce_sha).
#   __CE_ENV_NAME         - <backend>-credit-env[-<host>]-<__CE_SHA>
#   __CE_ENV_DIR          - derived here, once
#   __CE_PIP_EXTRA_URL    - bare extra-index URL, or "" (kept as a URL, not a
#                      "--extra-index-url <url>" string, so we never depend
#                      on word-splitting -- which differs between bash & zsh).
#                      Derived from the resolved CUDA version on CUDA hosts.
#   __CE_PIP_TARGET_SPEC  - "."  or  ".[distributed]"  (the single MPI extra; the
#                      torch/CUDA pin is NOT in pyproject -- see __CE_TORCH_SPEC)
#   __CE_TORCH_SPEC  - "" or "torch==<ver>+cu<tag>": explicit torch pin appended
#                      to the pip line on CUDA hosts.  Replaces the former
#                      per-host ncar-hpc-{casper,derecho} torch pins so the
#                      version/CUDA build are chosen at install time, not baked
#                      into pyproject.toml.
#   __CE_CUDA_MODULE - ""  or  "cuda"  (<= 1 token, so unquoted expansion is
#                      identical in bash and zsh)
#   __CE_USE_MODULES - 0/1 (run the module dance?)
#   __CE_NEEDS_OFI_PLUGIN - 0/1 (derecho-only post-build steps)
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
#   global defaults  - torch + CUDA defaults come from the CREDIT_DEFAULT_* block
#                      above (CREDIT_DEFAULT_TORCH_VERSION / CREDIT_DEFAULT_CUDA_VERSION)
# The 'default' host installs a CUDA build only if the user passes --cuda-version.
#
# ADDING A HOST = add ONE case arm here.  Both config_env.sh's module-setup
# phase and create_env.sh's pip/build phase read from this function, so nothing
# else needs editing.  (If a future host needs a module set unlike
# "gcc + <backend> [+ cuda]", branch in __ce_setup_modules in config_env.sh --
# the one other host-aware spot.)
__ce_host_config() {
    __CE_ENV_NAME="credit-env"
    __CE_PIP_EXTRA_URL=""
    __CE_PIP_TARGET_SPEC="."
    __CE_TORCH_SPEC=""
    __CE_CUDA_MODULE=""
    __CE_USE_MODULES=0
    __CE_NEEDS_OFI_PLUGIN=0
    __CE_EXPECT_NCCL=0
    __CE_WANT_CUDA=0
    __CE_DEFAULT_CUDA=""
    __CE_CUDA_VER=""

    case "${__ce_target_host}" in

        "default")
            # vanilla conda, nothing special; all defaults above apply.
            # (A CUDA torch build is opt-in here via --cuda-version.)
            ;;

        "casper")
            __CE_USE_MODULES=1
            __CE_PIP_TARGET_SPEC=".[distributed]"
            __CE_EXPECT_NCCL=1
            __CE_WANT_CUDA=1          # default CUDA -> CREDIT_DEFAULT_CUDA_VERSION
            ;;

        "derecho")
            __CE_USE_MODULES=1
            __CE_CUDA_MODULE="cuda"
            __CE_PIP_TARGET_SPEC=".[distributed]"
            __CE_NEEDS_OFI_PLUGIN=1
            __CE_EXPECT_NCCL=1
            __CE_WANT_CUDA=1
            __CE_DEFAULT_CUDA="12.9"  # derecho ships a newer CUDA than the global default
            ;;

        *)
            echo "ERROR: unhandled ${__ce_target_host}?!!" >&2
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
        __CE_PIP_EXTRA_URL="https://download.pytorch.org/whl/${__CE_CUDA_TAG}"
        __CE_TORCH_SPEC="torch==${__CE_TORCH_VER}+${__CE_CUDA_TAG}"
        unset __CE_TORCH_VER __CE_CUDA_TAG   # keep __CE_CUDA_VER (a documented output)
    elif [ -n "${CREDIT_TORCH_VERSION}" ]; then
        # No CUDA build requested, but the user pinned a torch version with
        # --torch-version: pin the CPU build of torch from PyPI.  __CE_PIP_EXTRA_URL
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
host=${__ce_target_host}
python=${CREDIT_PYTHON_VERSION}
torch=${CREDIT_TORCH_VERSION}
cuda=${CREDIT_CUDA_VERSION}
torch_spec=${__CE_TORCH_SPEC}
pip_extra_url=${__CE_PIP_EXTRA_URL}
pip_target=${__CE_PIP_TARGET_SPEC}
aws_ofi_nccl=$([ "${__CE_NEEDS_OFI_PLUGIN}" -eq 1 ] && printf '%s' "${CREDIT_DEFAULT_AWS_OFI_NCCL_VERSION}")
ofi_plugin=${__CE_NEEDS_OFI_PLUGIN}")"

    # Name = <backend>-credit-env[-<host>]-<short-sha>.  backend leads (covers
    # conda AND uv explicitly, replacing the old -uv suffix / bare-conda
    # asymmetry); the host segment appears only for non-default hosts; python +
    # everything else live in the manifest + SHA, not the name.  8 hex chars:
    # inputs are config-derived (non-adversarial) and the manifest-match guard in
    # config_env.sh is the backstop, so collision risk is negligible.
    __CE_SHA="$(printf '%s' "${__CE_MANIFEST}" | __ce_sha | cut -c1-8)"
    __CE_ENV_NAME="${CREDIT_BACKEND}-credit-env"
    [ "${__ce_target_host}" != "default" ] && __CE_ENV_NAME="${__CE_ENV_NAME}-${__ce_target_host}"
    __CE_ENV_NAME="${__CE_ENV_NAME}-${__CE_SHA}"

    __CE_ENV_DIR="${SCRIPTDIR}/${__CE_ENV_NAME}"
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
# NOTE: this file defines NO cleanup of its own.  Everything it defines carries
# an owned prefix (vars __CE_*/ENV_*-renamed-to-__CE_*/CREDIT_*; funcs __ce_*),
# so config_env.sh's __ce_cleanup wipes it by a single glob over those prefixes.
# (The create_env.sh / build-aws-ofi-nccl-plugin.sh subprocesses source this file
# but never clean up -- they exit, polluting nothing.)
