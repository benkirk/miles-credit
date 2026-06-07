# `envs/` — agent guide

Scope: the environment-installer scripts in this directory and their CI. This is
working guidance (invariants, gotchas, how to verify). User-facing docs live in
[`README.md`](README.md); don't duplicate them here — update the README when
behavior changes.

## What's here

| File | Role |
| --- | --- |
| `config_env.sh` | Dual-mode (source **or** execute) entry point. `bash`+`zsh`, conda (default) or `uv` (`--uv`), idempotent. Does modules, env vars, **activation**, and orchestration in the caller's shell. Shells out to `create_env.sh` to build. |
| `host_config.sh` | Per-host policy (`__ce_host_config`) — the **single source of truth**. SOURCED (never executed) by both `config_env.sh` and `create_env.sh`, so both derive identical `ENV_DIR`/pip-target/flags. Sources `default_versions.sh`. Owns its own cleanup (`__ce_host_config_cleanup`, which chains to `__ce_default_versions_cleanup`). |
| `default_versions.sh` | **Single source of truth for the DEFAULT versions** (`CREDIT_DEFAULT_{BACKEND,PYTHON_VERSION,TORCH_VERSION,CUDA_VERSION,AWS_OFI_NCCL_VERSION}`). SOURCED (never executed): by `host_config.sh` (→ reaches `config_env.sh` + `create_env.sh`) and directly by `build-aws-ofi-nccl-plugin.sh`. Owns its own cleanup (`__ce_default_versions_cleanup`). Bump a default = one-line edit here. |
| `create_env.sh` | The build recipe (conda create / `uv venv`, pip install, OFI plugin, probe). **EXECUTE-ONLY**: `config_env.sh` runs it as a SUBPROCESS when the env is absent, so it pollutes nothing. Mirrors `build-aws-ofi-nccl-plugin.sh`. |
| `build-aws-ofi-nccl-plugin.sh` | derecho-only. Builds the AWS OFI NCCL plugin + (if no system hwloc) a standalone hwloc into `<env>/dependencies/`. Owns **all** hwloc logic. Invoked by `create_env.sh`. |
| `activate-nccl-hpe-cxi.sh` / `deactivate-nccl-hpe-cxi.sh` | Runtime NCCL/Cray-Slingshot (CXI) env vars + plugin discovery (`NCCL_NET_PLUGIN`, `LD_LIBRARY_PATH`). |
| `probe_installed_env.py` | Post-install health check (torch/CUDA/NCCL, `import credit`); `--require-nccl`, `--verbose`. |
| `README.md` | User-facing documentation. |
| `../.github/workflows/ci-config-env.yml` | CI for all of the above. |

## How the three files fit together

`config_env.sh` is the only dual-mode file (it must `return`/`exit` correctly
when sourced). It sources `host_config.sh` for policy, and when the env is
absent it **executes** `create_env.sh` as a child process to build, then
re-activates the finished prefix in the caller's shell itself.

Inter-file contract (the part to hold in your head):
- `create_env.sh` is a **subprocess** → it inherits exported env vars and the
  **module environment** the parent loaded (modules are env vars), but **not**
  shell functions. So it re-sources `conda.sh` itself (the `conda activate`
  *function* isn't inherited) and re-derives host policy by sourcing
  `host_config.sh` + calling `__ce_host_config` (agreement with the parent by
  construction, not via a fragile export list). The parent passes only `BACKEND`,
  `VERBOSE`, `PYTHON_VERSION`, `TORCH_VERSION`, and `CUDA_VERSION`; `NCAR_HOST` is
  already in the environment.
- `create_env.sh`'s own `conda activate`/venv-activate during the build is local
  and discarded — that's why the parent **always** activates afterward (a single
  activation path for both build-vs-already-exists).
- `create_env.sh` does **not** use `set -eu` (it sources activate scripts that
  trip `-u`/`-e`); it relies on an explicit `|| { …; exit 1; }` per step.

## Non-negotiable invariants for `config_env.sh`

These are the contract CI enforces — break one and you break real users (this
script is sourced into interactive shells and PBS run scripts):

1. **Dual-mode.** Sourcing must `return`, executing must `exit`. Only the
   Section-3 top-level driver issues the single `return N || exit N`; functions
   only set status. Don't add `exit`/`return` inside helpers.
2. **`bash` AND `zsh`.** No associative arrays; no reliance on word-splitting.
   Build argv with `set --` positional lists and quote expansions. Keep
   "≤1 optional token" tricks (e.g. `${__CE_CUDA_MODULE}`) — they expand
   identically in both shells.
3. **Zero shell-state pollution when sourced.** `__ce_cleanup` must `unset` every
   variable and `unset -f` every function the sourced path defines. **If you add a
   helper function or a variable, add its name to the matching list in the same
   edit.** Cleanup is now split by ownership: `config_env.sh`'s own
   vars/functions go in its `__ce_cleanup`; the host-policy vars/functions go in
   `host_config.sh`'s `__ce_host_config_cleanup` (which `__ce_cleanup` invokes);
   the `CREDIT_DEFAULT_*` constants go in `default_versions.sh`'s
   `__ce_default_versions_cleanup` (which `__ce_host_config_cleanup` chains to).
   Add a name to the list **in the file that defines it**. (`create_env.sh` and
   `build-aws-ofi-nccl-plugin.sh` are subprocesses and need no cleanup.) This is
   the #1 regression here, and CI's
   "no shell pollution" step will catch it — but check it yourself.
4. **Host policy is one source of truth.** All per-host differences live in
   `__ce_host_config` **in `host_config.sh`** (one `case` arm per host). Adding a
   host = add one arm; nothing else should grow host-awareness except
   `__ce_setup_modules` (in `config_env.sh`) if its module set genuinely differs.
5. **Idempotent.** First run builds; later runs just `Activating …`. `--rebuild`
   moves the old prefix aside and `rm`s it in the background. Don't make the
   activate path do build work.
6. **Fail loudly.** Every build/install step must `return 1` on failure — never
   let a failure fall through to the "successfully installed" message.

## Backend specifics

- **Prefix encodes backend AND Python version** so independent builds coexist and
  existence tests never cross-detect: `credit-env[-host]-py<X.Y>[-uv]` (e.g.
  `credit-env-py3.11`, `credit-env-derecho-py3.12-uv`). The version is **always**
  present, even the default 3.11. `__ce_host_config` builds this from
  `CREDIT_BACKEND` + `CREDIT_PYTHON_VERSION` (a `config_env.sh`-owned input,
  default `CREDIT_DEFAULT_PYTHON_VERSION` from `default_versions.sh`, threaded to
  the `create_env.sh` subprocess and used for `conda
  create python=…` / `uv venv --python …`). Add the `-py…` segment in exactly one
  place (`__ce_host_config`).
- **Input vars are `CREDIT_*`-namespaced — do not rename them back to bare names.**
  The cross-process inputs (`CREDIT_BACKEND`, `CREDIT_VERBOSE`,
  `CREDIT_PYTHON_VERSION`, `CREDIT_TORCH_VERSION`, `CREDIT_CUDA_VERSION`) carry a
  `CREDIT_` prefix specifically so a loaded module can't shadow them. The original
  bare `CUDA_VERSION` collided with the env var the **`cuda/12.9.0` module exports**
  (`CUDA_VERSION=12.9.0`): `__ce_host_config` read it instead of the intended host
  default `12.9`, producing the bogus wheel tag `cu1290` and an unresolvable
  `torch==…+cu1290` pin — derecho-only, so CI (default host, no `cuda` module)
  never saw it. When you add a new input, give it a `CREDIT_` prefix and thread it
  through all three files (parse in `config_env.sh`, pass at the subprocess call,
  read in `create_env.sh`/`host_config.sh`).
- **uv must provision its own interpreter:** the `uv venv` call uses
  `--managed-python` so it never adopts whatever `python<X.Y>` the caller's shell
  exposes (an active conda env, a system python). Without it the venv symlinks an
  external interpreter and dangles when that is rebuilt/removed. Don't drop this flag.
- `mpi4py` is always a source build: conda path via `PIP_NO_BINARY=mpi4py`; uv
  path via uv's own `--no-binary mpi4py` (uv ignores `PIP_NO_BINARY`).
- **torch/CUDA is pinned at install time, not in `pyproject.toml`.** The CUDA
  hosts install the single `.[distributed]` extra (just `mpi4py`); the torch
  build is appended to the pip line as `__CE_TORCH_SPEC` (`torch==<ver>+cu<tag>`)
  with a matching `PIP_EXTRA_URL`, both built in `__ce_host_config` from
  `--torch-version`/`--cuda-version`. CUDA version resolves CLI > per-host default
  (`__CE_DEFAULT_CUDA`, e.g. derecho 12.9) > global default
  (`CREDIT_DEFAULT_CUDA_VERSION`); torch defaults to `CREDIT_DEFAULT_TORCH_VERSION`
  — both global defaults live in `default_versions.sh`. The `default` host gets a
  CUDA build only if the
  user passes `--cuda-version`. This is what let the old per-host
  `ncar-hpc-{casper,derecho}` extras collapse into one. `--verbose` echoes the
  fully expanded pip command (the line is assembled dynamically). Neither version
  is encoded in the prefix — two CUDA variants share a prefix; use `--rebuild` to
  switch an existing env.
  - **`--torch-version` also pins a plain CPU build.** When no CUDA build is
    requested (no `--cuda-version`, non-CUDA host) but `--torch-version` is given,
    `__ce_host_config` sets `__CE_TORCH_SPEC=torch==<ver>` with an empty
    `PIP_EXTRA_URL` → the CPU wheel from PyPI (no `+cu` tag, no extra index). With
    NEITHER flag, torch stays unpinned (pyproject's bare `torch`). This `elif` arm
    is what lets `ci-matrix.yml` vary torch on linux-amd64 CPU runners.

## derecho / OFI plugin (the `NEEDS_OFI_PLUGIN` path)

- All non-Python build artifacts live under **`<env>/dependencies/`**, backend-independent:
  `dependencies/lib/libnccl-net-ofi.so` (plugin) and, when there's no system hwloc,
  `dependencies/hwloc-env/` (a **standalone conda env** built with the `conda`
  *binary only, never activated* — so it's independent of conda-vs-uv). The plugin
  is rpath'd to the hwloc-env libdir.
- **Keep `libhwloc`/`pkg-config` out of the Python env** — that conda-only coupling
  is exactly what made derecho conda-only before. `build-aws-ofi-nccl-plugin.sh`
  owns this; don't move hwloc logic back into `config_env.sh`.
- Runtime vars are applied by `__ce_source_runtime_hooks` sourcing
  `activate-nccl-hpe-cxi.sh` into the caller **on every invocation** (so `source
  config_env.sh` is self-sufficient under uv, which has no `activate.d`). conda
  *additionally* gets `etc/conda/{activate,deactivate}.d/` copies.
- The hook's `LD_LIBRARY_PATH` prepend is **dedup-guarded** — keep it idempotent
  (re-sourcing must not duplicate the entry), and keep `activate`/`deactivate`
  mirror images, both `bash`/`zsh` safe.

## How to verify a change

- Syntax: `bash -n` + `zsh -n` on `config_env.sh`, `host_config.sh`, and
  `default_versions.sh`; `bash -n envs/create_env.sh` (execute-only → bash only).
- Fast contract (no build): `--help`, `--uv --help`, `--bogus` (maps to rc 0),
  and sourced `--help` leaving no `__ce_*`/`CREDIT_*`/host-policy/`CREDIT_DEFAULT_*`
  residue (incl. `__ce_default_versions_cleanup`) under bash & zsh.
- **HPC behavior is not covered by CI** — the heavy `casper`/`derecho` builds
  (CUDA wheels, NCCL, Cray libfabric, the OFI plugin) can't run on free runners.
  Validate those **manually on a casper/derecho login node**, both backends, full
  matrix: fresh build → idempotent activate → source+hooks+no-pollution →
  `--rebuild` → `pipdeptree`/`pytest`, plus (derecho) `ldd`/`readelf` that the
  plugin resolves `libhwloc.so.15` into `dependencies/hwloc-env/lib`.

## CI notes (`ci-config-env.yml`, `ci-matrix.yml`)

- **`ci-config-env.yml` tests the SCRIPT**; **`ci-matrix.yml` tests the credit
  SOURCE** across a `python × torch × backend` matrix. Both share the composite
  action **`.github/actions/build-credit-env`** (the extracted `full-build` body:
  fresh build → idempotent activate → source-activate+no-pollution → optional
  `--rebuild` / verify-torch / pipdeptree / pytest, gated by `rebuild` /
  `introspect` / `run-tests` inputs). `cuda-version` uses the sentinel `disabled`
  (= don't pass `--cuda-version`); a real value is reserved for a future GPU leg.
- `ci-config-env.yml` triggers on PRs to `staging`/`main` touching `envs/**`,
  `pyproject.toml`, or the workflow; plus `workflow_dispatch`. Matrix:
  {ubuntu-x86_64, ubuntu-arm64, macos-arm64} × {bash, zsh}; `full-build` adds
  × {conda, uv} and calls the action at defaults (py3.11, no torch pin, all legs
  on) — behavior identical to before the extraction. The `contract` job stays
  inline (it tests arg-parsing/pollution, not the build).
- `ci-matrix.yml` triggers on **any** PR to `main`/`staging` (no paths filter) +
  `workflow_dispatch`. Matrix: {3.11, 3.12, 3.13} × {2.10.0, 2.11.0} × {conda, uv}
  on linux-amd64/bash; `rebuild`+`introspect` off, pytest + verify-torch on. Each
  leg passes `--torch-version` only → the CPU torch-pin `elif` arm.
- `matrix` is **not** allowed in a step's `shell:` field (and is invisible inside
  a composite action) — steps run under `shell: bash`/`inputs.shell` and invoke
  the shell-under-test inside the run block. Every `run:` in the composite action
  must declare an explicit `shell:`.
- Temp source-mode scripts run **without `set -e`** on purpose (the script is meant
  to be sourced into a normal shell; e.g. `module try-load` returns 127 off-HPC).
- **Honest-by-design:** heavy legs may go red where the scientific stack or
  GPU-only checks can't complete on a CPU runner. derecho's Cray/GPU steps can't
  run on free CI, so the portable leg uses the `default` host.
- **Keep the environment minimal.** Never add CI/diagnostic tooling (`pipdeptree`,
  `pytest`, …) to `config_env.sh` or `pyproject.toml`; install it *in the workflow*
  against the already-built env. NCCL is required only on casper/derecho via the
  probe's `--require-nccl`.
- Build dirs are git-ignored (`envs/credit-env*/`) — never commit a built env.
