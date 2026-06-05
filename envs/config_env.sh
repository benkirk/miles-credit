#!/usr/bin/env bash


#----------------------------------------------------------------------------
# Unified script to create and initialize a CREDIT conda-based environment
# across systems.
#
# This script is intended to be idempotent and both sourceable or runnable.
#
# Structure: generic scaffolding + per-host policy + build recipe are split
# into functions (Section 2).  The dual-mode return/exit must happen at the
# top level of a sourced file, so functions report status via return codes and
# a single thin driver (Section 3) issues the one `return N || exit N`.
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


#============================================================================
# SECTION 2 - function definitions
#============================================================================

#----------------------------------------------------------------------------
__ce_usage() {
    cat <<USAGE
Usage: [source] config_env.sh [--verbose] [--rebuild] [--help]

  --verbose, -v   Show module/conda setup output (quiet by default).
  --rebuild, -r   Rebuild the environment even if it already exists.
                  The existing env is moved aside and removed in the
                  background, then a fresh env is built.
  --help, -h      Show this help and stop.
USAGE
}

#----------------------------------------------------------------------------
# Run a command quietly unless --verbose was given.
run_quiet() {
    if [ "${VERBOSE}" -eq 1 ]; then
        "$@"
    else
        "$@" >/dev/null 2>&1
    fi
}

#----------------------------------------------------------------------------
# Parse "$@" into VERBOSE / REBUILD / __ce_show_help / __ce_bad_arg.
# Called at top level so "$@" is the script's args.
# Works whether SOURCED or EXECUTED, under bash & zsh.  We read "$@" directly:
# verified correct in both shells when args are supplied to `source`.
# NOTE (zsh quirk): when this file is SOURCED with NO arguments, zsh does not
# reset positional parameters, so the caller's $@ is visible here.  Normal
# interactive use (empty $@) is unaffected.
__ce_parse_args() {
    VERBOSE=0
    REBUILD=0
    __ce_show_help=0
    __ce_bad_arg=""
    for __ce_arg in "$@"; do
        case "${__ce_arg}" in
            --verbose|-v) VERBOSE=1 ;;
            --rebuild|-r) REBUILD=1 ;;
            --help|-h)    __ce_show_help=1 ;;
            "")           : ;;
            *)            __ce_bad_arg="${__ce_arg}" ;;
        esac
    done
}

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
#
# ADDING A HOST = add ONE case arm here.  Both the module-setup phase and the
# pip/build phase read from this function, so nothing else needs editing.
# (If a future host needs a module set unlike gcc/conda[/cuda], branch in
# __ce_setup_modules -- the one other host-aware spot.)
__ce_host_config() {
    ENV_NAME="credit-env"
    PIP_EXTRA_URL=""
    PIP_TARGET_SPEC="."
    __CE_CUDA_MODULE=""
    __CE_USE_MODULES=0
    NEEDS_OFI_PLUGIN=0

    case "${TARGET_HOST}" in

        "default")
            # vanilla conda, nothing special; all defaults above apply
            ;;

        "casper")
            ENV_NAME="${ENV_NAME}-${NCAR_HOST}"
            __CE_USE_MODULES=1
            PIP_EXTRA_URL="https://download.pytorch.org/whl/cu126"
            PIP_TARGET_SPEC=".[ncar-hpc-${NCAR_HOST}]"
            ;;

        "derecho")
            ENV_NAME="${ENV_NAME}-${NCAR_HOST}"
            __CE_USE_MODULES=1
            __CE_CUDA_MODULE="cuda"
            PIP_EXTRA_URL="https://download.pytorch.org/whl/cu129"
            PIP_TARGET_SPEC=".[ncar-hpc-${NCAR_HOST}]"
            NEEDS_OFI_PLUGIN=1
            ;;

        *)
            echo "ERROR: unhandled ${TARGET_HOST}?!!" >&2
            ;;
    esac

    ENV_DIR="${SCRIPTDIR}/${ENV_NAME}"
}

#----------------------------------------------------------------------------
# Set up the preferred module environment (host-driven).
__ce_setup_modules() {
    [ "${__CE_USE_MODULES}" -eq 1 ] || return 0

    type module >/dev/null 2>&1 || source /etc/profile.d/z00_modules.sh
    run_quiet module --force purge
    run_quiet module load ncarenv/25.10
    run_quiet module reset
    run_quiet module load gcc/14.3.0 conda ${__CE_CUDA_MODULE}   # <=1 token: portable
    run_quiet module list
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
# Activate the environment if it already exists.  Returns 0 (activated) so the
# caller can short-circuit, or 1 if there is nothing to activate.
__ce_activate_if_exists() {
    [ -d "${ENV_DIR}" ] || return 1
    echo "Activating ${ENV_DIR}"
    conda activate "${ENV_DIR}"   # side effect propagates to the caller's shell
}

#----------------------------------------------------------------------------
# Build the environment from scratch (we only get here when ENV_DIR is absent).
__ce_build_env() {
    #-------------------------------------------------------
    # create minimal conda environment
    conda create \
          --yes \
          --prefix "${ENV_DIR}" \
          python=3.11

    conda activate "${ENV_DIR}"

    #-------------------------------------------------------
    # install via pip, forcing a source build of mpi4py with host compilers.
    # PIP_EXTRA_URL is passed as two explicit args only when set, so this is
    # correct under both bash and zsh (no word-splitting reliance).
    export PIP_NO_BINARY="mpi4py"
    if [ -n "${PIP_EXTRA_URL}" ]; then
        pip install -e "${PIP_TARGET_SPEC}" --extra-index-url "${PIP_EXTRA_URL}"
    else
        pip install -e "${PIP_TARGET_SPEC}"
    fi

    #-------------------------------------------------------
    # host-specific post-install steps
    if [ "${NEEDS_OFI_PLUGIN}" -eq 1 ]; then

        # hwloc supplies the build headers for aws-ofi-nccl.  Install it (plus
        # pkg-config, so build-aws-ofi-nccl-plugin.sh can find it via the conda
        # lib/pkgconfig/hwloc.pc) ONLY when the system/module environment lacks
        # the dev headers; otherwise we build/link against the system hwloc.
        # The probe runs HERE, after modules are loaded, in the real build env.
        if { command -v pkg-config >/dev/null 2>&1 && pkg-config --exists hwloc 2>/dev/null; } \
           || printf '#include <hwloc.h>\n' | ${CC:-cc} -E -x c - >/dev/null 2>&1; then
            echo "config_env.sh: system/module hwloc dev found; not installing conda hwloc."
        else
            echo "config_env.sh: no system hwloc.h; installing CUDA-aware hwloc + pkg-config from conda-forge."
            # CONDA_OVERRIDE_CUDA lets the cuda129 build resolve on a driverless
            # login node, where conda's __cuda virtual package is otherwise absent.
            CONDA_OVERRIDE_CUDA="12.9" conda install \
                  --yes \
                  -c conda-forge \
                  "libhwloc=*=cuda129*" cuda-version=12.9 pkg-config || {
                echo "config_env.sh: hwloc/pkg-config install failed." >&2
                return 1
            }
        fi

        # Build the OFI Plugin (it makes its own hwloc prefix/rpath decision).
        # Fail loudly: a broken plugin must NOT report success.
        export AWS_OFI_NCCL_VERSION="v1.19.2"
        ${SCRIPTDIR}/build-aws-ofi-nccl-plugin.sh || {
            echo "config_env.sh: aws-ofi-nccl plugin build failed." >&2
            return 1
        }

        # install the env var hooks (the deactivate.d dir may not exist yet):
        mkdir -p ${CONDA_PREFIX}/etc/conda/activate.d ${CONDA_PREFIX}/etc/conda/deactivate.d \
            && cp ${SCRIPTDIR}/activate-nccl-hpe-cxi.sh ${CONDA_PREFIX}/etc/conda/activate.d/nccl-hpe-cxi.sh \
            && cp ${SCRIPTDIR}/deactivate-nccl-hpe-cxi.sh ${CONDA_PREFIX}/etc/conda/deactivate.d/nccl-hpe-cxi.sh || {
            echo "config_env.sh: failed to install NCCL activate/deactivate hooks." >&2
            return 1
        }
    fi

    #-------------------------------------------------------
    # query installed packages
    python -c "import torch; print('torch version:', torch.__version__); print('CUDA available:', torch.cuda.is_available()); print(torch.__config__.show())"
    python -c "import torch; print('nccl version:', torch.cuda.nccl.version())"
    python -c "import credit"

    #-------------------------------------------------------
    # report success
    echo
    echo "\"${ENV_NAME}\" conda environment for ${TARGET_HOST} successfully installed into ${CONDA_PREFIX}"
    echo "use \"conda activate ${ENV_DIR}\" to activate"
}

#----------------------------------------------------------------------------
# Tidy up all shell state (important when SOURCED -- functions and vars defined
# here would otherwise persist in the caller's interactive shell).
# NOTE: when adding a new function/var above, add its name here too.
__ce_cleanup() {
    unset VERBOSE REBUILD TARGET_HOST ENV_NAME ENV_DIR PIP_EXTRA_URL PIP_TARGET_SPEC \
          __CE_USE_MODULES __CE_CUDA_MODULE NEEDS_OFI_PLUGIN CONDA_ROOT \
          __ce_show_help __ce_bad_arg __ce_arg __ce_status 2>/dev/null
    unset -f __ce_usage run_quiet __ce_parse_args __ce_host_config __ce_setup_modules \
             __ce_ensure_conda __ce_maybe_rebuild __ce_activate_if_exists __ce_build_env \
             __ce_run 2>/dev/null
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

    TARGET_HOST="${NCAR_HOST:-default}"
    __ce_host_config
    __ce_setup_modules

    __ce_ensure_conda  || return 1
    __ce_maybe_rebuild || return 1

    # Activate if it exists (and we did not just remove it for rebuild).
    if __ce_activate_if_exists; then
        return 0
    fi

    # OK - from here on out we are building the environment.
    __ce_build_env || return 1
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
