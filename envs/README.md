# Environment Installation (conda, or `uv` via `--uv`)

## `config_env.sh`

A unified script for installing and initializing a CREDIT Python environment
across machines. It is **runnable or sourceable**, works under both `bash` and
`zsh`, and is **idempotent**: the first invocation builds the environment, and
every subsequent invocation simply activates it.

Sourcing this script in your interactive shell or in a PBS run script is a
reliable, one-line way to initialize CREDIT on any supported platform.

`config_env.sh` is the only file you invoke; the build itself lives in a sibling
`create_env.sh` (run automatically when the environment is missing) and per-host
policy in `host_config.sh`. You never call those directly.

The target machine is selected by the `NCAR_HOST` environment variable (NCAR
HPC sets this automatically on login). When `NCAR_HOST` is unset or empty the
script uses the portable `default` configuration. Each host installs into its
own prefix alongside this script, with the Python version always encoded in the
name: `credit-env-py3.11`, `credit-env-casper-py3.11`, or
`credit-env-derecho-py3.11` (and e.g. `credit-env-py3.12` with
`--python-version 3.12`). Different versions — and the `--uv` backend
(`…-uv`) — coexist in distinct prefixes.

### Supported hosts

- **`default`** — any host with `conda` already on `PATH` (or `uv`, with
  `--uv`). Creates a Python environment (3.11 by default; see
  `--python-version`) and runs `pip install -e "."` from the repository root.
  No modules are loaded and no host-specific extras are installed.

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
| `--uv`            | Use the [`uv`](https://docs.astral.sh/uv/) installer and a uv-managed venv instead of conda (see [below](#alternative-the-uv-backend---uv)). Supported on all hosts (`default`/`casper`/`derecho`). |
| `--python-version X.Y` | Python version to build with (default `3.11`). Always encoded into the prefix (e.g. `credit-env-py3.12`), so versions coexist. Accepts `--python-version 3.12` or `--python-version=3.12`. |
| `--verbose`, `-v` | Show module/backend setup output (suppressed by default).              |
| `--rebuild`, `-r` | Rebuild even if the environment exists. The old prefix is moved aside and removed in the background, then a fresh environment is built. |
| `--help`, `-h`    | Print usage and stop.                                                  |

### Alternative: the `uv` backend (`--uv`)

By default the script uses **conda** purely to provide an isolated environment
with a controlled Python (3.11 by default; see `--python-version`); everything
else is installed with `pip`. The `--uv` flag swaps that backend for
[`uv`](https://docs.astral.sh/uv/): it creates a uv-managed venv (`uv venv
--python <version>`, fetching a managed CPython if needed) and installs the same
stack with `uv pip install`. Everything else —
dual-mode source/execute, `bash`/`zsh`, idempotency, `--rebuild`, the
post-install health check, and the zero-shell-pollution contract — is
unchanged.

- **uv must already be on `PATH`** (or loadable as a module — on Casper `uv`
  and `conda` are *conflicting* modules, so only the one for the selected
  backend is loaded). The script does **not** bootstrap uv for you; install it
  per the [uv docs](https://docs.astral.sh/uv/getting-started/installation/)
  or `module load uv` first.
- The uv env gets its **own prefix** (`credit-env-uv`, `credit-env-casper-uv`,
  `credit-env-derecho-uv`) so a uv build and a conda build can coexist. Activate
  it the standard venv way: `source envs/credit-env-uv/bin/activate`.
- `mpi4py` is still forced to a source build, via uv's `--no-binary mpi4py`
  (uv does not honor pip's `PIP_NO_BINARY`).
- **`derecho` is supported under `--uv`.** Its one *non-Python* build dependency
  (`libhwloc`) is no longer installed into the Python env: the plugin build
  script provisions it in a **standalone conda env** under
  `<env>/dependencies/hwloc-env` (using only the `conda` binary, never
  activated), so the choice of Python backend is irrelevant. The NCCL/CXI
  runtime variables are applied by **`config_env.sh` itself sourcing the hook**
  after activation (conda additionally keeps its `activate.d`/`deactivate.d`
  hooks). One caveat under uv: a bare `deactivate` does **not** unset those
  variables — re-`source config_env.sh` or start a fresh shell.

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
and CUDA in the loaded modules. The plugin and its non-Python build
dependencies live under a single per-env **`<env>/dependencies/`** prefix
(independent of whether the Python env is conda- or uv-managed):

```
<env>/dependencies/
├── lib/libnccl-net-ofi.so        ← the plugin (configure --prefix)
└── hwloc-env/lib/libhwloc.so.15  ← standalone conda env, rpath'd by the plugin
```

`hwloc` is a build-time dependency of the plugin. The build script uses the
system/module copy when its development headers are present; otherwise (the
case on Derecho) it provisions a CUDA-aware `libhwloc` + `pkg-config` in the
**standalone `hwloc-env` conda env** above — created with the `conda` *binary*
only (never activated), so it is decoupled from the Python packaging backend —
and links the plugin against it via rpath so it is used at runtime.

Because the plugin no longer sits in the environment's default `lib/`, and a uv
venv never auto-exposes a lib directory, the runtime hook points NCCL straight
at it: it exports `NCCL_NET_PLUGIN` to the full `.so` path and prepends
`<env>/dependencies/lib` to `LD_LIBRARY_PATH`.

To select and tune the plugin at runtime, `config_env.sh` **sources the NCCL
activation hook into your shell** after activation, on every invocation (so a
plain `source config_env.sh` is enough). The hooks derive from HPE's
[`shs-ccl-docs`](https://github.com/HewlettPackard/shs-ccl-docs):

- `activate-nccl-hpe-cxi.sh` sets `NCCL_NET="AWS Libfabric"` (which selects the
  plugin) plus the recommended `FI_CXI_*`/`NCCL_*` tunables and the
  `NCCL_NET_PLUGIN`/`LD_LIBRARY_PATH` discovery vars above.
- `deactivate-nccl-hpe-cxi.sh` reverses them.

For the **conda** backend the installer additionally copies these into
`etc/conda/{activate,deactivate}.d/` so a bare `conda activate <prefix>` is
self-sufficient. The **uv** backend has no `activate.d` equivalent, so it relies
on `config_env.sh` sourcing the hook; note a bare `deactivate` will not unset
the variables under uv.

> **WARNING:** Do **not** set `NCCL_NET` for single-node runs — forcing the
> network transport when all ranks share a node causes unnecessary VNI
> allocation and degraded performance. For multi-node PBS jobs the RDZV
> settings additionally require the `--disable_rdzv_get` launch flag (see the
> hook and `shs-ccl-docs`).
