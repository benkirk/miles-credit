# Conda-based Installation

## `config_env.sh`

A unified runnable, sourceable script for installing and initializing a CREDIT python environment on various types of machines:

FIXME: brief desciption of these cases
- `default` independent host with `conda` in the path...
- NCAR HPC Resources
  - `casper` ...
  - `derecho` ...

The script works under `bash` and `zsh`, can be executed or sourced, and is idempotent.

Sourcing this script within e.g. your shell or PBS run scripts should be a reliable way to initialze CREDIT across a variety of platforms.

## Examples
TODO


## NOTES
### `derecho` - NCCL, Cray Slingshot, and the AWS OFI Plugin