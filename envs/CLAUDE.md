# `envs/` — agent guide

Scope: the environment-installer scripts in this directory and their CI. This is
working guidance (invariants, gotchas, how to verify). User-facing docs live in
[`README.md`](README.md); don't duplicate them here — update the README when
behavior changes.

## What's here

| File | Role |
| --- | --- |
| `config_env.sh` | Dual-mode (source **or** execute) entry point. `bash`+`zsh`, conda (default), `uv` (`--uv`), or a plain `python -m venv` (`--venv`), idempotent. Does modules, env vars, **activation**, and orchestration in the caller's shell. Shells out to `create_env.sh` to build. |
| `versions_config.sh` | **Single source of truth for BOTH the DEFAULT versions** (`CREDIT_DEFAULT_{BACKEND,PYTHON_VERSION,TORCH_VERSION,CUDA_VERSION,AWS_OFI_NCCL_VERSION}`) **and the per-host policy** (`__ce_host_config`, `__ce_sha`). SOURCED (never executed) by `config_env.sh` + `create_env.sh` (both derive identical `ENV_DIR`/pip-target/flags) and by `build-aws-ofi-nccl-plugin.sh` (just for the AWS plugin default). Sourcing only assigns constants + defines functions (nothing runs → safe under `set -eu`). Owns one cleanup, `__ce_host_config_cleanup` (unsets the host-policy scalars AND the `CREDIT_DEFAULT_*` constants). Bump a default = one-line edit here. |
| `create_env.sh` | The build recipe (conda create / `uv venv`, pip install, OFI plugin, probe, then writes `<ENV_DIR>/credit-env.manifest`). **EXECUTE-ONLY**: `config_env.sh` runs it as a SUBPROCESS when the env is absent, so it pollutes nothing. Mirrors `build-aws-ofi-nccl-plugin.sh`. |
| `build-aws-ofi-nccl-plugin.sh` | derecho-only. Builds the AWS OFI NCCL plugin + (if no system hwloc) a standalone hwloc into `<env>/dependencies/`. Owns **all** hwloc logic. Invoked by `create_env.sh`. |
| `activate-nccl-hpe-cxi.sh` / `deactivate-nccl-hpe-cxi.sh` | Runtime NCCL/Cray-Slingshot (CXI) env vars + plugin discovery (`NCCL_NET_PLUGIN`, `LD_LIBRARY_PATH`). |
| `probe_installed_env.py` | Post-install health check (torch/CUDA/NCCL, `import credit`); `--require-nccl`, `--verbose`. |
| `README.md` | User-facing documentation. |
| `../.github/workflows/ci-config-env.yml` | CI for all of the above. |

## How the three files fit together

`config_env.sh` is the only dual-mode file (it must `return`/`exit` correctly
when sourced). It sources `versions_config.sh` for policy, and when the env is
absent it **executes** `create_env.sh` as a child process to build, then
re-activates the finished prefix in the caller's shell itself.

Inter-file contract (the part to hold in your head):
- `create_env.sh` is a **subprocess** → it inherits exported env vars and the
  **module environment** the parent loaded (modules are env vars), but **not**
  shell functions. So it re-sources `conda.sh` itself (the `conda activate`
  *function* isn't inherited) and re-derives host policy by sourcing
  `versions_config.sh` + calling `__ce_host_config` (agreement with the parent by
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
   edit.** Cleanup is split by ownership: `config_env.sh`'s own vars/functions go
   in its `__ce_cleanup`; the host-policy vars/functions AND the `CREDIT_DEFAULT_*`
   constants go in `versions_config.sh`'s `__ce_host_config_cleanup` (which
   `__ce_cleanup` invokes). Add a name to the list **in the file that defines it**.
   (`create_env.sh` and `build-aws-ofi-nccl-plugin.sh` are subprocesses and need
   no cleanup.) This is the #1 regression here, and CI's "no shell pollution" step
   will catch it — but check it yourself.
4. **Host policy is one source of truth.** All per-host differences live in
   `__ce_host_config` **in `versions_config.sh`** (one `case` arm per host). Adding a
   host = add one arm; nothing else should grow host-awareness except
   `__ce_setup_modules` (in `config_env.sh`) if its module set genuinely differs.
5. **Idempotent.** First run builds; later runs just `Activating …`. `--rebuild`
   moves the old prefix aside and `rm`s it in the background. Don't make the
   activate path do build work.
6. **Fail loudly.** Every build/install step must `return 1` on failure — never
   let a failure fall through to the "successfully installed" message.

## Backend specifics

- **Prefix is content-addressed** so independent builds coexist and existence
  tests never cross-detect: `<backend>-credit-env[-host]-<sha>` (e.g.
  `conda-credit-env-6dbcaf4e`, `uv-credit-env-derecho-22ab90ff`). `__ce_host_config`
  assembles `__CE_MANIFEST` — a canonical, fixed-field-order string of **every**
  build-affecting input (schema/backend/host/python/torch/cuda/torch_spec/
  pip_extra_url/pip_target/aws_ofi_nccl/ofi_plugin) — *after* all resolution, then
  `__CE_SHA="$(printf '%s' "$__CE_MANIFEST" | __ce_sha | cut -c1-8)"`. Hashing the
  **resolved** config (not raw CLI) is what makes lookup idempotent (flag
  spelling/order is irrelevant) and unique across every axis. The manifest records
  build **intent**, not resolved package versions (unpinned torch keeps a stable
  SHA — it is not a lockfile). `schema=1` is a recipe version: bump it to
  deliberately invalidate ALL envs when the recipe changes in a way no field
  captures. `aws_ofi_nccl` is in the manifest **only when `ofi_plugin=1`**
  (derecho), so bumping its default never needlessly invalidates default/casper.
  `__ce_sha` is portable (sha256sum → shasum → openssl → python3 last-resort) so it
  works before any module puts Python on PATH. Build the name in exactly one place
  (`__ce_host_config`); python/torch/cuda are NOT in the name (they live in the
  manifest + SHA).
- **The manifest is written into the env and re-checked on activate.** After a
  successful build `create_env.sh` writes the byte-for-byte hashed string to
  `<ENV_DIR>/credit-env.manifest` (so re-hashing the file reproduces the dir's
  SHA). On the activate path `config_env.sh`'s `__ce_check_manifest` requires that
  file to exist and `cmp`-match `__CE_MANIFEST`; a missing manifest (interrupted
  build) or mismatch (collision/stale) is **fatal** with a `--rebuild` hint —
  never silently activate the wrong/half-built env. Parent and child agree by
  construction (both recompute `__CE_MANIFEST` via `__ce_host_config`), so the
  manifest is **not** added to the subprocess export list.
- **Resolve-only / inventory modes.** `--print-env-dir` runs `__ce_host_config`
  then echoes `ENV_DIR` and stops (no build/activate) — CI and PBS can no longer
  predict the SHA, so they ask the script. `--list` (`__ce_list`) scans
  `*-credit-env-*/`, reads each `credit-env.manifest`, and prints a table — the
  "status regardless of CLI args" capability. Both terminate via the rc-2 path
  (like `--help`).
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
  read in `create_env.sh`/`versions_config.sh`).
- **uv must provision its own interpreter:** the `uv venv` call uses
  `--managed-python` so it never adopts whatever `python<X.Y>` the caller's shell
  exposes (an active conda env, a system python). Without it the venv symlinks an
  external interpreter and dangles when that is rebuilt/removed. Don't drop this flag.
- **`--venv` is the opposite of uv: it deliberately ADOPTS the PATH `python3`.**
  It is `python -m venv`, independent of conda and uv, and does **no module
  manipulation** on any host (`__ce_setup_modules` skips the backend-module load
  for it). Because it cannot *choose* the interpreter it can only *check* it:
  `__ce_resolve_venv_python` (in `config_env.sh`) finds `python3`/`python`,
  enforces `>= CREDIT_MIN_PYTHON_VERSION` (a constant in `versions_config.sh`,
  kept in sync with pyproject's `requires-python`), and treats `--python-version`
  as an **assertion** — a mismatch with the PATH python is fatal; omitting it
  *adopts* the detected version. This resolution MUST run **before
  `__ce_host_config`** (it sets `CREDIT_PYTHON_VERSION`, which feeds the
  manifest/SHA and `--print-env-dir`), so it is a dedicated early step in
  `__ce_run`, not folded into `__ce_ensure_backend`. The resolved interpreter is
  threaded to the build subprocess as `CREDIT_VENV_PYTHON` (a `CREDIT_*` input,
  so parent and child use the *exact* same python). `__ce_py_explicit` tracks
  whether `--python-version` was actually passed (the default 3.11 is set
  unconditionally, so adopt-on-omit needs this flag to avoid a spurious mismatch).
- **Backend dispatch is ONE case, not per-backend helpers.** `__ce_ensure_backend`
  is a single `case "${CREDIT_BACKEND}"` with a `conda`/`uv`/`venv` arm (the old
  `__ce_ensure_uv`/`__ce_ensure_conda` helpers were removed). `__ce_activate_if_exists`
  is likewise a `case` where `uv|venv)` share the `source <env>/bin/activate` arm
  (both are standard venvs) and `conda)` uses `conda activate`; `create_env.sh`
  mirrors this with `case` arms for creation and the success message. When adding
  a backend, add an arm in each — and remember the cleanup/CI leak lists.
- `mpi4py` is always a source build: conda **and venv** via `PIP_NO_BINARY=mpi4py`
  (both drive the active env's plain `pip`); uv via uv's own `--no-binary mpi4py`
  (uv ignores `PIP_NO_BINARY`).
- **torch/CUDA is pinned at install time, not in `pyproject.toml`.** The CUDA
  hosts install the single `.[distributed]` extra (just `mpi4py`); the torch
  build is appended to the pip line as `__CE_TORCH_SPEC` (`torch==<ver>+cu<tag>`)
  with a matching `PIP_EXTRA_URL`, both built in `__ce_host_config` from
  `--torch-version`/`--cuda-version`. CUDA version resolves CLI > per-host default
  (`__CE_DEFAULT_CUDA`, e.g. derecho 12.9) > global default
  (`CREDIT_DEFAULT_CUDA_VERSION`); torch defaults to `CREDIT_DEFAULT_TORCH_VERSION`
  — both global defaults live in `versions_config.sh`. The `default` host gets a
  CUDA build only if the
  user passes `--cuda-version`. This is what let the old per-host
  `ncar-hpc-{casper,derecho}` extras collapse into one. `--verbose` echoes the
  fully expanded pip command (the line is assembled dynamically). Both versions
  ARE in the config hash now (via `__CE_MANIFEST`), so two CUDA/torch variants get
  **distinct** SHA prefixes and coexist — `--rebuild` is no longer required to
  switch between them (it remains for forcing a clean rebuild of the *same*
  config).
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

- Syntax: `bash -n` + `zsh -n` on `config_env.sh` and `versions_config.sh`;
  `bash -n envs/create_env.sh` (execute-only → bash only).
- Fast contract (no build): `--help`, `--uv --help`, `--venv --help`, `--bogus`
  (maps to rc 0), and sourced `--help` leaving no
  `__ce_*`/`CREDIT_*`/host-policy/`CREDIT_DEFAULT_*` residue (incl.
  `__ce_host_config_cleanup`, `__ce_sha`, `__ce_list`, `__ce_check_manifest`,
  `__ce_resolve_venv_python`, `__CE_MANIFEST`, `__CE_SHA`, `CREDIT_VENV_PYTHON`,
  `__ce_py_explicit`, `CREDIT_MIN_PYTHON_VERSION`) under bash & zsh.
- venv resolution (no full build, needs a `python3` on PATH): `--venv
  --print-env-dir` adopts the PATH python's `X.Y` into the SHA;
  `--venv --python-version <matches>` gives the SAME SHA; `--venv --python-version
  <differs>` and a `python3 < CREDIT_MIN_PYTHON_VERSION` BOTH fail loudly (rc 1).
- Content-addressing (no build): `--print-env-dir` is deterministic and matches
  across bash/zsh and across the three `__ce_sha` backends; same config via
  `--python-version=3.12` vs `--python-version 3.12` → identical SHA; `--uv` /
  `--venv` / `--torch-version` / `--cuda-version` each shift the SHA. `--list` reads
  manifests and tolerates an empty `envs/` (zsh `nomatch` is disabled locally).
  The integrity invariant: `printf '%s' "$__CE_MANIFEST" | __ce_sha | cut -c1-8`
  equals the suffix of `ENV_DIR` (= what `create_env.sh` writes to the manifest).
- **HPC behavior is not covered by CI** — the heavy `casper`/`derecho` builds
  (CUDA wheels, NCCL, Cray libfabric, the OFI plugin) can't run on free runners.
  Validate those **manually on a casper/derecho login node**, all backends
  (conda/uv/venv), full matrix: fresh build → idempotent activate →
  source+hooks+no-pollution →
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
  The action's "Derive backend / arg vars" step captures
  `CE_ENV=$(basename "$(bash envs/config_env.sh $ARGS --print-env-dir)")` — it can
  no longer hardcode the prefix now that the name is a content hash; all later
  `envs/$CE_ENV` references are unchanged.
- `ci-config-env.yml` triggers on PRs to `staging`/`main` touching `envs/**`,
  `pyproject.toml`, or the workflow; plus `workflow_dispatch`. Matrix:
  {ubuntu-x86_64, ubuntu-arm64, macos-arm64} × {bash, zsh}; `full-build` adds
  × {conda, uv, venv} and calls the action at defaults (py3.11, no torch pin, all
  legs on). The `venv` leg is special-cased in the action: it does NOT pass
  `--python-version` (venv would hard-fail a mismatch with the runner's `python3`)
  and its in_env helpers use the venv's own `bin/python`+`bin/pip`. The `contract`
  job stays inline (it tests arg-parsing/pollution, not the build).
- `ci-matrix.yml` triggers on **any** PR to `main`/`staging` (no paths filter) +
  `workflow_dispatch`. Matrix: {3.11, 3.12, 3.13} × {2.10.0, 2.11.0} × {conda, uv}
  on linux-amd64/bash; `rebuild`+`introspect` off, pytest + verify-torch on. Each
  leg passes `--torch-version` only → the CPU torch-pin `elif` arm. **venv is
  excluded here on purpose** — a forced `--python-version` sweep is incompatible
  with venv's adopt-or-match rule (it is covered by ci-config-env's full-build).
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
