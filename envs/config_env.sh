#!/usr/bin/env bash


#----------------------------------------------------------------------------
# Unified script to create and initialize a CREDIT Python environment
# (conda by default, or uv via --uv) across systems.
#
# This script is intended to be idempotent and both sourceable or runnable.
#
# Structure: this file is the dual-mode ENTRY POINT -- it does modules, env
# vars, and activation in the caller's shell, and orchestrates the rest.  Two
# concerns live in sibling files so this one stays small and the build can grow
# without touching the delicate dual-mode/no-pollution plumbing:
#   host_config.sh - per-host policy (single source of truth; SOURCED by both
#                    this file and create_env.sh)
#   create_env.sh  - the build recipe (EXECUTE-ONLY; invoked as a SUBPROCESS
#                    when the env is absent, so it pollutes nothing)
# The dual-mode return/exit must happen at the top level of a sourced file, so
# functions report status via return codes and a single thin driver (Section 3)
# issues the one `return N || exit N`.
#----------------------------------------------------------------------------


#============================================================================
# SECTION 1 - shell / SCRIPTDIR detection (must stay at top level: the
# BASH_SOURCE[0] / ${(%):-%x} expansions only resolve to THIS file when
# evaluated in the script body, not inside a function).
#============================================================================
if [ -n "${BASH_SOURCE[0]}" ]; then
    SCRIPT_PATH="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION}" ]; then
    SCRIPT_PATH="${(%):-%x}"
else
    echo "Unknown shell, falling back to \$0 for script path" >&2
    SCRIPT_PATH="$0"
fi
SCRIPTDIR="$(realpath "$(dirname "$(realpath "${SCRIPT_PATH}")")")"

# Per-host policy lives in a sibling file, SOURCED here (so the entry point and
# the build subprocess share ONE source of truth).  Must be sourced at top
# level: __ce_host_config sets scalars the caller's shell then activates from.
# host_config.sh in turn sources default_versions.sh, so the CREDIT_DEFAULT_*
# defaults (consumed by __ce_parse_args / __ce_usage below) are in scope after
# this line; its cleanup is reached via __ce_host_config_cleanup.
source "${SCRIPTDIR}/host_config.sh"


#============================================================================
# SECTION 2 - function definitions
#============================================================================

#----------------------------------------------------------------------------
__ce_usage() {
    cat <<USAGE
Usage: [source] config_env.sh [--conda | --uv] [--python-version X.Y]
                              [--torch-version X.Y.Z] [--cuda-version X.Y]
                              [--verbose] [--rebuild]
                              [--print-env-dir] [--list] [--help]

  --conda         Use conda for packaging (the default backend on every host).
                  Provided for symmetry with --uv so the backend can be pinned
                  explicitly rather than relying on the default.  If both --conda
                  and --uv are given, the last one wins.
  --uv            Use the 'uv' package installer and a uv-managed venv instead
                  of conda.  Supported on all hosts (default/casper/derecho).
                  uv must already be on PATH (or available as a module); it is
                  not bootstrapped for you.
  --python-version X.Y
                  Python version to build the environment with
                  (default ${CREDIT_DEFAULT_PYTHON_VERSION}).  Folded into the
                  env's config hash (so builds with different Python versions get
                  distinct SHA-named prefixes and coexist).  Accepts
                  '--python-version 3.12' or '--python-version=3.12'.
  --torch-version X.Y.Z
                  torch version to pin on the pip line for the CUDA-enabled
                  hosts (default ${CREDIT_DEFAULT_TORCH_VERSION}).  Combined with
                  --cuda-version into a 'torch==<ver>+cu<tag>' spec plus the
                  matching PyTorch --extra-index-url.  Accepts the '=' form too.
  --cuda-version X.Y
                  CUDA build of torch to install on the CUDA-enabled hosts,
                  e.g. '12.6' -> the cu126 PyTorch wheels.  Defaults per host
                  (casper ${CREDIT_DEFAULT_CUDA_VERSION}, derecho 12.9); override
                  for any host.  On the portable 'default' host, supplying this
                  opts into a CUDA build (otherwise plain torch from PyPI is used).
  --verbose, -v   Show module/backend setup output (quiet by default).
  --rebuild, -r   Rebuild the environment even if it already exists.
                  The existing env is moved aside and removed in the
                  background, then a fresh env is built.
  --print-env-dir Resolve and print the (SHA-named) env directory for the given
                  flags, then stop -- no build, no activation.  The prefix is a
                  content hash, so callers (CI, PBS scripts) ask the script for
                  the path rather than predicting it.
  --list          List the built CREDIT envs under ${SCRIPTDIR##*/}/ with their
                  config (backend/host/python/torch/cuda), read from each env's
                  credit-env.manifest, then stop.
  --help, -h      Show this help and stop.
USAGE
}

#----------------------------------------------------------------------------
# Inventory the built CREDIT envs from their on-disk manifests -- the "status
# regardless of CLI arguments" capability: it reads each env's credit-env.manifest
# rather than re-deriving anything from flags.  Needs no backend/modules.
__ce_list() {
    # zsh aborts on an unmatched glob (nomatch is on by default); disable it
    # locally so an empty envs/ dir is handled by the per-iteration guard below.
    # bash never reaches this line (the guard is false), so its lack of `setopt`
    # is irrelevant.
    [ -n "${ZSH_VERSION}" ] && setopt local_options no_nomatch 2>/dev/null

    __ce_list_any=0
    printf '%-40s %-7s %-8s %-7s %-9s %s\n' DIR BACKEND HOST PYTHON TORCH CUDA
    for __ce_d in "${SCRIPTDIR}"/*-credit-env-*/; do
        [ -d "${__ce_d}" ] || continue                 # literal pattern => no envs
        __ce_m="${__ce_d}credit-env.manifest"
        [ -f "${__ce_m}" ] || continue                 # skip half-built / foreign
        __ce_list_any=1
        # grep matches a final line even without a trailing newline (the manifest
        # has none); cut -f2- keeps values that contain '='.
        __ce_b="$(grep  '^backend=' "${__ce_m}" | cut -d= -f2-)"
        __ce_h="$(grep  '^host='    "${__ce_m}" | cut -d= -f2-)"
        __ce_py="$(grep '^python='  "${__ce_m}" | cut -d= -f2-)"
        __ce_t="$(grep  '^torch='   "${__ce_m}" | cut -d= -f2-)"
        __ce_c="$(grep  '^cuda='    "${__ce_m}" | cut -d= -f2-)"
        printf '%-40s %-7s %-8s %-7s %-9s %s\n' \
            "$(basename "${__ce_d%/}")" \
            "${__ce_b:--}" "${__ce_h:--}" "${__ce_py:--}" "${__ce_t:--}" "${__ce_c:--}"
    done
    [ "${__ce_list_any}" -eq 1 ] || echo "(no built CREDIT environments found under ${SCRIPTDIR})"
    unset __ce_d __ce_m __ce_b __ce_h __ce_py __ce_t __ce_c __ce_list_any
}

#----------------------------------------------------------------------------
# Run a command quietly unless --verbose was given.
run_quiet() {
    if [ "${CREDIT_VERBOSE}" -eq 1 ]; then
        "$@"
    else
        "$@" >/dev/null 2>&1
    fi
}

#----------------------------------------------------------------------------
# Parse "$@" into CREDIT_VERBOSE / REBUILD / __ce_show_help / __ce_bad_arg.
# Called at top level so "$@" is the script's args.
# Works whether SOURCED or EXECUTED, under bash & zsh.  We read "$@" directly:
# verified correct in both shells when args are supplied to `source`.
# NOTE (zsh quirk): when this file is SOURCED with NO arguments, zsh does not
# reset positional parameters, so the caller's $@ is visible here.  Normal
# interactive use (empty $@) is unaffected.
__ce_parse_args() {
    CREDIT_VERBOSE=0
    REBUILD=0
    CREDIT_BACKEND="${CREDIT_DEFAULT_BACKEND}"          # default_versions.sh
    CREDIT_PYTHON_VERSION="${CREDIT_DEFAULT_PYTHON_VERSION}"  # default_versions.sh
    CREDIT_TORCH_VERSION=""          # empty = use default_versions.sh default
    CREDIT_CUDA_VERSION=""           # empty = use host/global default
    __ce_show_help=0
    __ce_print_dir=0          # --print-env-dir: resolve ENV_DIR and stop
    __ce_list=0               # --list: inventory built envs from their manifests
    __ce_bad_arg=""
    __ce_expect_val=""        # name of the option whose value the NEXT token is
    for __ce_arg in "$@"; do
        # Consume the value of a space-separated option (e.g. --python-version X).
        # Guard: a token starting with '-' is a flag, not a value -> missing value.
        if [ -n "${__ce_expect_val}" ]; then
            case "${__ce_arg}" in
                -*) __ce_bad_arg="--${__ce_expect_val} (missing value)" ;;
                *)  case "${__ce_expect_val}" in
                        python-version) CREDIT_PYTHON_VERSION="${__ce_arg}" ;;
                        torch-version)  CREDIT_TORCH_VERSION="${__ce_arg}" ;;
                        cuda-version)   CREDIT_CUDA_VERSION="${__ce_arg}" ;;
                    esac ;;
            esac
            __ce_expect_val=""
            continue
        fi
        case "${__ce_arg}" in
            --conda)              CREDIT_BACKEND="conda" ;;
            --uv)                 CREDIT_BACKEND="uv" ;;
            --python-version)     __ce_expect_val="python-version" ;;
            --python-version=*)   CREDIT_PYTHON_VERSION="${__ce_arg#*=}" ;;
            --torch-version)      __ce_expect_val="torch-version" ;;
            --torch-version=*)    CREDIT_TORCH_VERSION="${__ce_arg#*=}" ;;
            --cuda-version)       __ce_expect_val="cuda-version" ;;
            --cuda-version=*)     CREDIT_CUDA_VERSION="${__ce_arg#*=}" ;;
            --verbose|-v)         CREDIT_VERBOSE=1 ;;
            --rebuild|-r)         REBUILD=1 ;;
            --print-env-dir)      __ce_print_dir=1 ;;
            --list)               __ce_list=1 ;;
            --help|-h)            __ce_show_help=1 ;;
            "")                   : ;;
            *)                    __ce_bad_arg="${__ce_arg}" ;;
        esac
    done
    # A trailing value-option with no following token (e.g. "--python-version"
    # last) is reported here.  NOTE: empty CREDIT_TORCH_VERSION/CREDIT_CUDA_VERSION are VALID
    # (they mean "use the host default"), so only --python-version gets the
    # extra non-empty check below.
    [ -n "${__ce_expect_val}" ] && __ce_bad_arg="--${__ce_expect_val} (missing value)"
    [ -n "${CREDIT_PYTHON_VERSION}" ]  || __ce_bad_arg="--python-version (missing value)"
}

#----------------------------------------------------------------------------
# Set up the preferred module environment (host-driven).
__ce_setup_modules() {
    [ "${__CE_USE_MODULES}" -eq 1 ] || return 0

    type module >/dev/null 2>&1 || source /etc/profile.d/z00_modules.sh
    run_quiet module --force purge
    run_quiet module load ncarenv/25.10
    run_quiet module reset
    run_quiet module load gcc/14.3.0 ${__CE_CUDA_MODULE}   # <=1 extra token: portable
    # Load ONLY the backend tool's module.  On Casper the conda and uv modules
    # conflict, so we never load both; ${CREDIT_BACKEND} is "conda" or "uv".
    run_quiet module load "${CREDIT_BACKEND}"
    run_quiet module list
}

#----------------------------------------------------------------------------
# Locate the selected backend (conda or uv) and initialize it if needed.
# Returns 1 if the backend tool cannot be found.
__ce_ensure_backend() {
    if [ "${CREDIT_BACKEND}" = "uv" ]; then
        __ce_ensure_uv
    else
        __ce_ensure_conda
    fi
}

#----------------------------------------------------------------------------
# Locate uv (it comes from a module on Casper, or is already on PATH on a
# default host).  Per project policy uv is NOT bootstrapped here; if it cannot
# be found we stop with guidance.  Returns 1 if uv is unavailable.
__ce_ensure_uv() {
    run_quiet module try-load uv
    uv --version >/dev/null 2>&1 || {
        echo "config_env.sh: cannot locate uv." >&2
        echo "                Install it (https://docs.astral.sh/uv/) or 'module load uv', then re-run." >&2
        return 1
    }
}

#----------------------------------------------------------------------------
# Locate conda (loading a module if available) and initialize it if needed.
# Returns 1 if conda cannot be found.
__ce_ensure_conda() {
    run_quiet module try-load conda
    conda --version >/dev/null 2>&1 || {
        echo "config_env.sh: cannot locate conda." >&2
        return 1
    }

    # `conda activate` is a SHELL FUNCTION defined by conda.sh -- not the
    # `conda` PATH binary -- and it is NOT inherited by an EXECUTED (non-sourced)
    # script, even though CONDA_SHLVL may be exported (e.g. "0") from the parent.
    # So we cannot gate on CONDA_SHLVL; source conda.sh unconditionally (it is
    # idempotent) to make `conda activate` work in THIS process.
    CONDA_ROOT=$(conda info --base 2>/dev/null)
    if [ -n "${CONDA_ROOT}" ] && [ -f "${CONDA_ROOT}/etc/profile.d/conda.sh" ]; then
        source "${CONDA_ROOT}/etc/profile.d/conda.sh"
    fi
}

#----------------------------------------------------------------------------
# Smart rebuild: if the env exists and --rebuild was requested, move it aside
# (fast) and delete it in the background (slow rm on the parallel filesystem),
# so the subsequent existence test falls through to the build path.
# Returns 1 if the move fails.
__ce_maybe_rebuild() {
    [ -d "${ENV_DIR}" ] && [ "${REBUILD}" -eq 1 ] || return 0

    __ce_old="${ENV_DIR}.old.$$"
    echo "Rebuild requested; moving existing env aside: ${__ce_old}"
    if mv "${ENV_DIR}" "${__ce_old}"; then
        echo "Removing ${__ce_old} in the background..."
        nohup rm -rf "${__ce_old}" >/dev/null 2>&1 &
        disown 2>/dev/null || true
    else
        echo "config_env.sh: failed to move ${ENV_DIR} aside; aborting rebuild." >&2
        unset __ce_old
        return 1
    fi
    unset __ce_old
}

#----------------------------------------------------------------------------
# Integrity/identity guard before activation.  ENV_DIR is expected to exist here
# (just built, or pre-existing).  Its credit-env.manifest must be byte-for-byte
# the string __ce_host_config hashed into the dir name, so re-checking it
# confirms the env on disk really is the requested config.  A missing manifest
# (interrupted build) or a mismatch (astronomically unlikely hash collision, or
# a stale env) is fatal -- fail loudly with a --rebuild hint rather than activate
# the wrong / half-built environment.  Returns 1 on mismatch.
__ce_check_manifest() {
    [ -d "${ENV_DIR}" ] || return 0   # nothing on disk -> activate step reports it
    if [ ! -f "${ENV_DIR}/credit-env.manifest" ]; then
        echo "config_env.sh: ${ENV_DIR} has no credit-env.manifest" >&2
        echo "                (interrupted build?); re-run with --rebuild." >&2
        return 1
    fi
    printf '%s' "${__CE_MANIFEST}" | cmp -s - "${ENV_DIR}/credit-env.manifest" || {
        echo "config_env.sh: ${ENV_DIR} does not match the requested config" >&2
        echo "                (stale env or hash collision); re-run with --rebuild." >&2
        return 1
    }
}

#----------------------------------------------------------------------------
# Activate the environment if it already exists.  Returns 0 (activated) so the
# caller can short-circuit, or 1 if there is nothing to activate.
__ce_activate_if_exists() {
    if [ "${CREDIT_BACKEND}" = "uv" ]; then
        [ -f "${ENV_DIR}/bin/activate" ] || return 1
        echo "Activating ${ENV_DIR}"
        source "${ENV_DIR}/bin/activate"   # side effect propagates to the caller
    else
        [ -d "${ENV_DIR}" ] || return 1
        echo "Activating ${ENV_DIR}"
        conda activate "${ENV_DIR}"   # side effect propagates to the caller's shell
    fi
}

#----------------------------------------------------------------------------
# Source the NCCL/CXI runtime hook into the CALLER's shell (only meaningful when
# this file is itself sourced).  Runs after activation on EVERY invocation --
# both the fresh-build and the already-exists paths -- so `source config_env.sh`
# always sets NCCL_NET / NCCL_NET_PLUGIN / LD_LIBRARY_PATH for the relocated
# plugin.  The hook derives the env prefix from VIRTUAL_ENV/CONDA_PREFIX and is a
# no-op (no plugin file) on hosts that do not build it.  For conda this overlaps
# the activate.d hook -- a harmless, idempotent double-source.
__ce_source_runtime_hooks() {
    [ "${NEEDS_OFI_PLUGIN}" -eq 1 ] || return 0
    [ -f "${SCRIPTDIR}/activate-nccl-hpe-cxi.sh" ] && \
        source "${SCRIPTDIR}/activate-nccl-hpe-cxi.sh"
    return 0
}

#----------------------------------------------------------------------------
# Tidy up all shell state (important when SOURCED -- functions and vars defined
# here would otherwise persist in the caller's interactive shell).
# NOTE: when adding a new function/var above, add its name here too.  The
# host-policy vars/functions are owned by host_config.sh and cleaned up by its
# __ce_host_config_cleanup (invoked below), so they are NOT listed here.
__ce_cleanup() {
    unset CREDIT_VERBOSE REBUILD CREDIT_BACKEND CREDIT_PYTHON_VERSION CREDIT_TORCH_VERSION CREDIT_CUDA_VERSION \
          TARGET_HOST CONDA_ROOT \
          __ce_show_help __ce_print_dir __ce_list __ce_bad_arg __ce_arg __ce_expect_val __ce_status 2>/dev/null
    unset -f __ce_usage __ce_list run_quiet __ce_parse_args __ce_setup_modules \
             __ce_ensure_backend __ce_ensure_uv __ce_ensure_conda __ce_maybe_rebuild \
             __ce_check_manifest __ce_activate_if_exists __ce_source_runtime_hooks __ce_run 2>/dev/null
    # Clean up the host_config.sh state we sourced in (defensive: it may be
    # absent if sourcing failed).  Self-unsets __ce_host_config[_cleanup].
    command -v __ce_host_config_cleanup >/dev/null 2>&1 && __ce_host_config_cleanup
    unset -f __ce_cleanup 2>/dev/null   # self-unset LAST
    return "${1:-0}"                    # propagate the status passed in
}

#----------------------------------------------------------------------------
# Orchestrator: does the work and reports status; NEVER exits/returns the
# script itself (that is the top-level driver's job).
#   rc 0 = env activated or built OK
#   rc 1 = fatal (conda missing / mv failed)
#   rc 2 = help / bad arg already printed -> terminate cleanly
__ce_run() {
    if [ -n "${__ce_bad_arg}" ]; then
        echo "config_env.sh: unknown argument '${__ce_bad_arg}'" >&2
        __ce_usage >&2
        __ce_show_help=1
    fi
    if [ "${__ce_show_help}" -eq 1 ]; then
        [ -n "${__ce_bad_arg}" ] || __ce_usage
        return 2
    fi

    # --list reads on-disk manifests only; no host policy / modules / backend.
    if [ "${__ce_list}" -eq 1 ]; then
        __ce_list
        return 2
    fi

    TARGET_HOST="${NCAR_HOST:-default}"

    __ce_host_config

    # --print-env-dir: emit the resolved (SHA-named) prefix and stop.  Needs host
    # config for the hash, but no modules/backend/build/activate.
    if [ "${__ce_print_dir}" -eq 1 ]; then
        echo "${ENV_DIR}"
        return 2
    fi

    __ce_setup_modules

    __ce_ensure_backend || return 1
    __ce_maybe_rebuild  || return 1

    # Build it from scratch if absent (and we did not just keep it after a
    # rebuild move-aside).  The build runs in create_env.sh as a SUBPROCESS:
    # it inherits the module environment we loaded above and re-derives host
    # policy itself, but its own activation is local and discarded -- so we
    # ALWAYS activate the now-existing prefix here, in the caller's shell,
    # regardless of build-vs-already-exists.  __ce_activate_if_exists then
    # doubles as the post-build success gate.  Finally source any runtime hooks
    # so every `source config_env.sh` sets the NCCL/CXI + plugin-discovery env.
    if [ ! -d "${ENV_DIR}" ]; then
        CREDIT_BACKEND="${CREDIT_BACKEND}" CREDIT_VERBOSE="${CREDIT_VERBOSE}" CREDIT_PYTHON_VERSION="${CREDIT_PYTHON_VERSION}" \
            CREDIT_TORCH_VERSION="${CREDIT_TORCH_VERSION}" CREDIT_CUDA_VERSION="${CREDIT_CUDA_VERSION}" \
            "${SCRIPTDIR}/create_env.sh" || {
                echo "config_env.sh: environment build failed." >&2
                return 1
            }
    fi

    __ce_check_manifest || return 1

    __ce_activate_if_exists || {
        echo "config_env.sh: env expected after build but not activatable: ${ENV_DIR}" >&2
        return 1
    }

    __ce_source_runtime_hooks
    return 0
}


#============================================================================
# SECTION 3 - top-level driver (the ONLY site that returns/exits the script,
# which is required for correct dual-mode source/execute behavior).
#============================================================================
# Are we being sourced or executed?  We must know, because `return` is only
# valid (and only desirable) when sourced; an executed invocation must `exit`.
__ce_sourced=0
if [ -n "${ZSH_VERSION}" ]; then
    case "${ZSH_EVAL_CONTEXT}" in *:file*) __ce_sourced=1 ;; esac
elif [ -n "${BASH_SOURCE[0]}" ]; then
    [ "${BASH_SOURCE[0]}" != "$0" ] && __ce_sourced=1
fi

__ce_parse_args "$@"
__ce_run
__ce_status=$?
# Map the orchestrator's status to a process/return code:
#   0 -> 0 (ok), 1 -> 1 (fatal), 2 (help/bad-arg, already reported) -> 0
[ "${__ce_status}" -eq 1 ] || __ce_status=0

# __ce_cleanup unsets ALL state (including __ce_status) and, as its final act,
# returns the code we pass in -- so `$?` right after is the desired code with
# NO surviving variable.  Sourced -> return that code to the caller; executed
# -> exit the process with it.
if [ "${__ce_sourced}" -eq 1 ]; then
    unset __ce_sourced
    __ce_cleanup "${__ce_status}"
    return $?
else
    __ce_cleanup "${__ce_status}"
    exit $?
fi
