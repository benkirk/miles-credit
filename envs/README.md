# Environment Installation (conda, `uv` via `--uv`, or a plain venv via `--venv`)

## `config_env.sh`

A unified script for installing and initializing a CREDIT Python environment
across machines. It is **runnable or sourceable**, works under both `bash` and
`zsh`, and is **idempotent**: the first invocation builds the environment, and
every subsequent invocation simply activates it.

Sourcing this script in your interactive shell or in a PBS run script is a
reliable, one-line way to initialize CREDIT on any supported platform.

`config_env.sh` is the only file you invoke; the build itself lives in a sibling
`create_env.sh` (run automatically when the environment is missing), and the
per-host policy plus the **default versions** (Python, torch, CUDA, the AWS OFI
NCCL plugin, and the default backend) live together in `versions_config.sh`. You
never call those directly. To change a default version, edit the single
corresponding line in `versions_config.sh`; the defaults shown by `--help` and
in the table below are read from there.

The target machine is selected by the `NCAR_HOST` environment variable (NCAR
HPC sets this automatically on login). When `NCAR_HOST` is unset or empty the
script uses the portable `default` configuration. Each environment installs
into a **content-addressed** prefix alongside this script, named
`<backend>-credit-env[-<host>]-<sha>` — e.g. `conda-credit-env-6dbcaf4e`,
`conda-credit-env-casper-7f3e91c0`, or `uv-credit-env-derecho-22ab90ff`. The
`<sha>` is a short hash of a canonical manifest of **every** input that affects
the build (backend, host, Python, torch, CUDA, pip target, …), so any
permutation gets its own prefix and they all coexist — change any of them and
you get a new directory rather than clobbering an existing one. The same logical
config always resolves to the same prefix regardless of how the flags were
spelled or ordered. Ask the script for a prefix with `--print-env-dir`, and list
what is built with `--list` (both read the on-disk manifest, not your flags).

### Supported hosts

- **`default`** — any host with `conda` already on `PATH` (or `uv`, with `--uv`;
  or just a `python3 >= 3.11` on `PATH`, with `--venv`). Creates a Python
  environment (3.11 by default; see `--python-version`) and runs `pip install -e
  "."` from the repository root. No modules are loaded and no host-specific
  extras are installed.

- **`casper`** — loads `ncarenv/25.10`, `gcc/14.3.0`, and `conda`, then
  installs `.[distributed]` (the `mpi4py` extra) with `torch==2.10.0+cu126`
  pinned on the pip line against the CUDA 12.6 PyTorch index (the default CUDA
  for this host; override with `--cuda-version`). `mpi4py` is built from source
  with the host compilers (`PIP_NO_BINARY=mpi4py`).

- **`derecho`** — as `casper`, plus the `cuda` module and the CUDA 12.9 PyTorch
  index (`torch==2.10.0+cu129`, the default CUDA for this host). Additionally
  builds the **AWS OFI NCCL plugin** and installs NCCL/Slingshot activation
  hooks — see [NOTES](#derecho--nccl-cray-slingshot-and-the-aws-ofi-plugin).

The single `distributed` extra is defined under `[project.optional-dependencies]`
in the repository `pyproject.toml`; it carries only `mpi4py`. The torch version
and its CUDA build are **not** pinned in `pyproject.toml` — they are selected at
install time via `--torch-version`/`--cuda-version` (which is why one extra now
serves both `casper` and `derecho`).

### Options

These work identically whether the script is sourced or executed:

| Option            | Effect                                                                 |
| ----------------- | ---------------------------------------------------------------------- |
| `--uv`            | Use the [`uv`](https://docs.astral.sh/uv/) installer and a uv-managed venv instead of conda (see [below](#alternative-the-uv-backend---uv)). Supported on all hosts (`default`/`casper`/`derecho`). |
| `--venv`          | Use a plain `python -m venv` against the `python3` already on `PATH` — independent of conda and uv, no module manipulation (see [below](#alternative-the-venv-backend---venv)). The interpreter is *adopted*, so it must be `>= 3.11` and `--python-version` (if given) must match it. |
| `--python-version X.Y` | Python version to build with (default `3.11`). Folded into the prefix's config hash, so different versions get distinct prefixes and coexist. Accepts `--python-version 3.12` or `--python-version=3.12`. Under `--venv` this *asserts* (rather than selects) the version. |
| `--torch-version X.Y.Z` | Pin the torch version on the pip line. On a CUDA build (CUDA host or `--cuda-version`) it becomes `torch==<ver>+cu<tag>` (default `2.10.0`); on a plain CPU build it pins `torch==<ver>` from PyPI. Omitted → torch is left unpinned (CPU) or defaults to `2.10.0` (CUDA). Accepts the `=` form too. |
| `--cuda-version X.Y` | CUDA build of torch, e.g. `12.6` → the `cu126` PyTorch wheels + matching `--extra-index-url`. Defaults per host (`casper` 12.6, `derecho` 12.9); on `default` it opts into a CUDA build (otherwise plain torch from PyPI). |
| `--verbose`, `-v` | Show module/backend setup output (suppressed by default). Also echoes the assembled `pip install` command. |
| `--rebuild`, `-r` | Rebuild even if the environment exists. The old prefix is moved aside and removed in the background, then a fresh environment is built. |
| `--print-env-dir` | Resolve and print the (SHA-named) env prefix for the given flags, then stop — no build, no activation. Lets CI/PBS scripts ask for the path instead of predicting it. |
| `--list`          | List the built environments (backend/host/python/torch/CUDA) read from each prefix's `credit-env.manifest`, then stop. |
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
- The uv env gets its **own prefix** (`uv-credit-env[-<host>]-<sha>`, the
  `backend` field of the manifest differs from conda) so a uv build and a conda
  build coexist. Re-activate it idempotently with `source envs/config_env.sh
  --uv` (or `source "$(envs/config_env.sh --uv --print-env-dir)/bin/activate"`
  for the bare venv path).
- `mpi4py` is still forced to a source build, via uv's `--no-binary mpi4py`
  (uv does not honor pip's `PIP_NO_BINARY`).
- `derecho`'s one *non-Python* build dependency
  (`libhwloc`) is provisioned in a **standalone conda env** under
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

### Alternative: the `venv` backend (`--venv`)

The `--venv` flag uses the Python standard library's `python -m venv` against the
**`python3` already on your `PATH`** — no conda, no uv, and **no module
manipulation** on any host. Unlike conda/uv (which *provision* an interpreter),
venv *adopts* the ambient one, so it can only **check** the version, not choose
it:

- The interpreter must be **`>= 3.11`** (`CREDIT_MIN_PYTHON_VERSION` in
  `versions_config.sh`, matching `pyproject.toml`'s `requires-python`); an older
  `python3` is a hard error.
- **`--python-version` becomes an assertion.** Omit it to *adopt* whatever
  `python3` resolves to; if you pass it, it must **match** that version exactly —
  a mismatch fails loudly (venv cannot install a different one). To build with a
  specific version, put that interpreter first on your `PATH` (e.g. `module load`
  it, or a `pyenv`/`asdf` shim) and re-run.
- The env gets its **own prefix** (`venv-credit-env[-<host>]-<sha>`; the
  `backend` field of the manifest differs from conda/uv) so all three backends
  coexist. The adopted version *is* folded into the SHA, so the prefix changes
  when the ambient `python3` does.
- `mpi4py` is forced to a source build via pip's `PIP_NO_BINARY=mpi4py` (the venv
  uses plain `pip`, exactly like the conda backend). Activation is the standard
  `source <prefix>/bin/activate` (sets `VIRTUAL_ENV`), like uv.

```bash
# build (first time) or activate a venv-backed env into your current shell
# (adopts the python3 on PATH):
source envs/config_env.sh --venv

# assert a specific version is the one on PATH (fails if it is not):
source envs/config_env.sh --venv --python-version 3.12
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
  that imports `torch`/`credit` and reports the CUDA/NCCL state. Runs across all
  three backends (`conda`/`uv`/`venv`); the venv leg adopts the runner's
  `python3` (no `--python-version` pin).

The heavy **full build** legs live in the reusable composite action
[`.github/actions/build-credit-env`](../.github/actions/build-credit-env/action.yml),
which a second workflow,
[`.github/workflows/ci-matrix.yml`](../.github/workflows/ci-matrix.yml), reuses to
test the **credit source** across a `python {3.11,3.12,3.13} × torch {2.10.0,2.11.0}
× backend {conda,uv}` matrix on linux-amd64/bash. It runs on **any** PR to
`main`/`staging` (no paths filter) and pins each torch via `--torch-version` (CPU
wheels), asserting the pin took before running `pytest`.

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
