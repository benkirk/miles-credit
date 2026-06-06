unset NCCL_NET
unset NCCL_NET_PLUGIN

# Drop <env>/dependencies/lib from LD_LIBRARY_PATH (mirror of the activate hook).
# Pad with colons so end matches work, remove all occurrences, strip padding.
# Only reachable via conda's deactivate.d (uv has no deactivate cleanup).
_credit_env="${CONDA_PREFIX:-${VIRTUAL_ENV:-}}"
if [ -n "${_credit_env}" ] && [ -n "${LD_LIBRARY_PATH:-}" ]; then
    # Quote the needle (a variable) so the slashes in the path are NOT parsed as
    # the //pattern/replacement delimiters.
    _credit_pat=":${_credit_env}/dependencies/lib:"
    _credit_tmp=":${LD_LIBRARY_PATH}:"
    _credit_tmp="${_credit_tmp//"$_credit_pat"/:}"
    _credit_tmp="${_credit_tmp#:}"
    _credit_tmp="${_credit_tmp%:}"
    export LD_LIBRARY_PATH="${_credit_tmp}"
    unset _credit_tmp _credit_pat
fi
unset _credit_env
