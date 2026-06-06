# Environment Installation (conda, or `uv` via `--uv`)

## `config_env.sh`

A unified script for installing and initializing a CREDIT Python environment
across machines. It is **runnable or sourceable**, works under both `bash` and
`zsh`, and is **idempotent**: the first invocation builds the environment, and
every subsequent invocation simply activates it.

Sourcing this script in your interactive shell or in a PBS run script is a
reliable, one-line way to initialize CREDIT on any supported platform.

The target machine is selected by the `NCAR_HOST` environment variable (NCAR
HPC sets this automatically on login). When `NCAR_HOST` is unset or empty the
script uses the portable `default` configuration. Each host installs into its
own prefix alongside this script: `credit-env`, `credit-env-casper`, or
`credit-env-derecho`.

### Supported hosts

- **`default`** — any host with `conda` already on `PATH` (or `uv`, with
  `--uv`). Creates a Python 3.11 environment and runs `pip install -e "."`
  from the repository root. No modules are loaded and no host-specific extras
  are installed.

- **`casper`** — loads `ncarenv/25.10`, `gcc/14.3.0`, and `conda`, then
  installs `.[ncar-hpc-casper]` against the CUDA 12.6 PyTorch index
  (`torch==2.10.0+cu126`). `mpi4py` is built from source with the host
  compilers (`PIP_NO_BINARY=mpi4py`).

- **`derecho`** — as `casper`, plus the `cuda` module and the CUDA 12.9 PyTorch
  index (`torch==2.10.0+cu129`). Additionally builds the **AWS OFI NCCL
  plugin** and installs NCCL/Slingshot activation hooks — see
  [NOTES](#derecho--nccl-cray-slingshot-and-the-aws-ofi-plugin).

The `ncar-hpc-*` extras are defined under `[project.optional-dependencies]` in
the repository `pyproject.toml`.

### Options

These work identically whether the script is sourced or executed:

| Option            | Effect                                                                 |
| ----------------- | ---------------------------------------------------------------------- |
| `--uv`            | Use the [`uv`](https://docs.astral.sh/uv/) installer and a uv-managed venv instead of conda (see [below](#alternative-the-uv-backend---uv)). Supported on `default`/`casper`; `derecho` is conda-only. |
| `--verbose`, `-v` | Show module/backend setup output (suppressed by default).              |
| `--rebuild`, `-r` | Rebuild even if the environment exists. The old prefix is moved aside and removed in the background, then a fresh environment is built. |
| `--help`, `-h`    | Print usage and stop.                                                  |

### Alternative: the `uv` backend (`--uv`)

By default the script uses **conda** purely to provide an isolated environment
with a controlled Python (3.11); everything else is installed with `pip`. The
`--uv` flag swaps that backend for [`uv`](https://docs.astral.sh/uv/): it
creates a uv-managed venv (`uv venv --python 3.11`, fetching a managed CPython
if needed) and installs the same stack with `uv pip install`. Everything else —
dual-mode source/execute, `bash`/`zsh`, idempotency, `--rebuild`, the
post-install health check, and the zero-shell-pollution contract — is
unchanged.

- **uv must already be on `PATH`** (or loadable as a module — on Casper `uv`
  and `conda` are *conflicting* modules, so only the one for the selected
  backend is loaded). The script does **not** bootstrap uv for you; install it
  per the [uv docs](https://docs.astral.sh/uv/getting-started/installation/)
  or `module load uv` first.
- The uv env gets its **own prefix** (`credit-env-uv`, `credit-env-casper-uv`)
  so a uv build and a conda build can coexist. Activate it the standard venv
  way: `source envs/credit-env-uv/bin/activate`.
- `mpi4py` is still forced to a source build, via uv's `--no-binary mpi4py`
  (uv does not honor pip's `PIP_NO_BINARY`).
- **`derecho` is conda-only.** Its path needs a *non-Python* build dependency
  (`libhwloc` + `pkg-config` from conda-forge) for the AWS OFI NCCL plugin and
  conda `activate.d` hooks — neither of which uv can provide — so `--uv` on
  `derecho` stops with an error.

```bash
# build (first time) or activate a uv-backed env into your current shell:
source envs/config_env.sh --uv

# one-shot build under uv:
./envs/config_env.sh --uv --rebuild
```

## Examples

Activate (or build, the first time) into your **current** shell — the normal
interactive use:

```bash
source envs/config_env.sh
```

Run it as an executable instead (build/activate happens in a subshell — useful
for a one-shot build, not for activating your login shell):

```bash
NCAR_HOST=derecho ./envs/config_env.sh
```

Inside a PBS run script, source it to initialize CREDIT before launching:

```bash
#PBS ...
source /glade/work/<user>/.../envs/config_env.sh
python -m credit.train ...
```

Force a clean rebuild, or watch the setup in detail:

```bash
./envs/config_env.sh --rebuild
./envs/config_env.sh --verbose
```

Re-running is cheap: if the environment already exists the script just
activates it and returns immediately.

## Continuous integration

`config_env.sh` is exercised in CI by
[`.github/workflows/ci-config-env.yml`](../.github/workflows/ci-config-env.yml),
which runs on pull requests into `staging`/`main` that touch `envs/**` or
`pyproject.toml` (and on manual dispatch). The matrix covers Linux x86_64,
Linux arm64, and macOS arm64, each under **both `bash` and `zsh`**:

- **contract** (fast, no conda): `bash -n`/`zsh -n`, `--help`, unknown-argument
  handling, and the sourceable dual-mode + **no-shell-pollution** guarantee.
- **full build**: a real `--rebuild`, then idempotent activate and
  source-activate, plus a post-install health check (`probe_installed_env.py`)
  that imports `torch`/`credit` and reports the CUDA/NCCL state.

**Rule — keep the environment minimal.** The environment is the runtime users
source on laptops and HPC, so CI/diagnostic tooling must **not** be added to
`config_env.sh` or `pyproject.toml`. Any such tooling is installed *in the
workflow* against the already-built env (e.g. `pipdeptree` via
`conda run -p <prefix> pip install pipdeptree`). NCCL follows the same spirit:
optional in general (CPU/macOS builds have none), but **required on the GPU/HPC
hosts that cannot run on free CI** (Casper, Derecho) via the probe's
`--require-nccl`.

## NOTES

### `derecho` — NCCL, Cray Slingshot, and the AWS OFI Plugin

Derecho's interconnect is **HPE Cray Slingshot**, exposed through libfabric's
**CXI** provider. NCCL's built-in network transports (sockets / IB verbs) do
not speak CXI, so out of the box NCCL collectives will not use the Slingshot
fabric between nodes. The working path is layered:

```
NCCL  →  aws-ofi-nccl  →  libfabric  →  CXI provider (Slingshot)
```

The **AWS OFI NCCL plugin** (`aws-ofi-nccl`) is the network backend that lets
NCCL issue its sends/receives over libfabric. On the `derecho` path the
installer builds it (`build-aws-ofi-nccl-plugin.sh`) against the Cray libfabric
and CUDA in the loaded modules, installing it into the conda environment.

To actually select and tune it at runtime, the installer also copies two conda
activation hooks into the environment (derived from HPE's
[`shs-ccl-docs`](https://github.com/HewlettPackard/shs-ccl-docs)):

- `etc/conda/activate.d/nccl-hpe-cxi.sh` sets `NCCL_NET="AWS Libfabric"` (which
  selects the plugin) along with the recommended `FI_CXI_*` and `NCCL_*`
  fabric tunables.
- `etc/conda/deactivate.d/nccl-hpe-cxi.sh` unsets `NCCL_NET` again.

`hwloc` is a build-time dependency of the plugin. The installer pulls it from
conda-forge **only when the system lacks the development headers** (the case on
Derecho), and links the plugin (via rpath) against that copy so it is used at
runtime; `pkg-config` is installed alongside it for detection.

> **WARNING:** Do **not** set `NCCL_NET` for single-node runs — forcing the
> network transport when all ranks share a node causes unnecessary VNI
> allocation and degraded performance. For multi-node PBS jobs the RDZV
> settings additionally require the `--disable_rdzv_get` launch flag (see the
> hook and `shs-ccl-docs`).
