#!/usr/bin/env bash


#----------------------------------------------------------------------------
# Central, single source of truth for the DEFAULT versions used to build a
# CREDIT environment (and the default packaging backend).  THIS is the one
# place to bump them: a version bump is a one-line edit here, so the entry
# point, the build subprocess, and the standalone OFI plugin builder can never
# disagree.
#
# SOURCED (never executed): host_config.sh sources it (which in turn reaches
# config_env.sh and create_env.sh, both of which source host_config.sh at top
# level before they need a default), and build-aws-ofi-nccl-plugin.sh sources
# it directly (it is outside the host_config.sh chain).
#
# Like the other env scripts this must be portable to BOTH bash and zsh: it is
# only plain scalar assignments plus one cleanup function (no associative
# arrays, no word-splitting).
#----------------------------------------------------------------------------

CREDIT_DEFAULT_BACKEND="conda"          # packaging backend when --uv is absent
CREDIT_DEFAULT_PYTHON_VERSION="3.11"    # --python-version default
CREDIT_DEFAULT_TORCH_VERSION="2.10.0"   # --torch-version default (CUDA hosts)
CREDIT_DEFAULT_CUDA_VERSION="12.6"      # global --cuda-version default; a host
                                        # may override it (see host_config.sh,
                                        # e.g. derecho -> 12.9)
CREDIT_DEFAULT_AWS_OFI_NCCL_VERSION="v1.19.2"   # aws-ofi-nccl plugin tag

#----------------------------------------------------------------------------
# Tidy up the shell state THIS file defines (only meaningful when sourced into
# a long-lived shell via config_env.sh).  Co-located with the definitions above
# so adding a default here means updating the cleanup in the SAME file.
# host_config.sh's __ce_host_config_cleanup chains to this; the create_env.sh
# and build-aws-ofi-nccl-plugin.sh subprocesses never call it (they pollute
# nothing).
__ce_default_versions_cleanup() {
    unset CREDIT_DEFAULT_BACKEND CREDIT_DEFAULT_PYTHON_VERSION \
          CREDIT_DEFAULT_TORCH_VERSION CREDIT_DEFAULT_CUDA_VERSION \
          CREDIT_DEFAULT_AWS_OFI_NCCL_VERSION 2>/dev/null
    unset -f __ce_default_versions_cleanup 2>/dev/null   # self-unset LAST
}
