# `envs/` — agent guide

Scope: the environment-installer scripts in this directory and their CI. This is
working guidance (invariants, gotchas, how to verify). User-facing docs live in
[`README.md`](README.md); don't duplicate them here — update the README when
behavior changes.

## What's here

| File | Role |
| --- | --- |
| `config_env.sh` | Dual-mode (source **or** execute) entry point. `bash`+`zsh`, conda (default) or `uv` (`--uv`), idempotent. Does modules, env vars, **activation**, and orchestration in the caller's shell. Shells out to `create_env.sh` to build. |
| `host_config.sh` | Per-host policy (`__ce_host_config`) — the **single source of truth**. SOURCED (never executed) by both `config_env.sh` and `create_env.sh`, so both derive identical `ENV_DIR`/pip-target/flags. Owns its own cleanup (`__ce_host_config_cleanup`). |
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
  `VERBOSE`, and `PYTHON_VERSION`; `NCAR_HOST` is already in the environment.
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
   `host_config.sh`'s `__ce_host_config_cleanup` (which `__ce_cleanup` invokes).
   Add a name to the list **in the file that defines it**. (`create_env.sh` is a
   subprocess and needs no cleanup.) This is the #1 regression here, and CI's
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
  present, even the default 3.11. `__ce_host_config` builds this from `BACKEND` +
  `PYTHON_VERSION` (a `config_env.sh`-owned input, default 3.11, threaded to the
  `create_env.sh` subprocess and used for `conda create python=…` / `uv venv
  --python …`). Add the `-py…` segment in exactly one place (`__ce_host_config`).
- **uv must provision its own interpreter:** the `uv venv` call uses
  `--managed-python` so it never adopts whatever `python<X.Y>` the caller's shell
  exposes (an active conda env, a system python). Without it the venv symlinks an
  external interpreter and dangles when that is rebuilt/removed. Don't drop this flag.
- `mpi4py` is always a source build: conda path via `PIP_NO_BINARY=mpi4py`; uv
  path via uv's own `--no-binary mpi4py` (uv ignores `PIP_NO_BINARY`).

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

- Syntax: `bash -n` + `zsh -n` on `config_env.sh` and `host_config.sh`;
  `bash -n envs/create_env.sh` (execute-only → bash only).
- Fast contract (no build): `--help`, `--uv --help`, `--bogus` (maps to rc 0),
  and sourced `--help` leaving no `__ce_*`/`BACKEND`/host-policy residue under
  bash & zsh.
- **HPC behavior is not covered by CI** — the heavy `casper`/`derecho` builds
  (CUDA wheels, NCCL, Cray libfabric, the OFI plugin) can't run on free runners.
  Validate those **manually on a casper/derecho login node**, both backends, full
  matrix: fresh build → idempotent activate → source+hooks+no-pollution →
  `--rebuild` → `pipdeptree`/`pytest`, plus (derecho) `ldd`/`readelf` that the
  plugin resolves `libhwloc.so.15` into `dependencies/hwloc-env/lib`.

## CI notes (`ci-config-env.yml`)

- Triggers on PRs to `staging`/`main` touching `envs/**`, `pyproject.toml`, or the
  workflow; plus `workflow_dispatch`. Matrix: {ubuntu-x86_64, ubuntu-arm64,
  macos-arm64} × {bash, zsh}; `full-build` adds × {conda, uv}.
- `matrix` is **not** allowed in a step's `shell:` field — every step runs under
  `shell: bash` and invokes the shell-under-test inside the run block.
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
