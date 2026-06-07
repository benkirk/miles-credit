# Design: content-addressed environment prefixes

**Status:** proposal (no code yet)
**Scope:** `envs/` installer scripts + their CI; user docs updated on adoption.

## Problem

The env prefix is built in one place — `__ce_host_config` in
[`host_config.sh`](host_config.sh) — as:

```
credit-env[-<host>]-py<X.Y>[-uv]
```

It is unique only on **host × backend × python**. The **torch** and **CUDA**
versions are *not* in the name, so two builds that differ only in those (same
host/py/backend) resolve to the **same directory and clobber each other**.
`CLAUDE.md` documents this as a known limitation:

> Neither version is encoded in the prefix — two CUDA variants share a prefix;
> use `--rebuild` to switch an existing env.

As more axes are added (`--torch-version`, `--cuda-version`, future knobs), the
naming scheme cannot represent the permutations, and the only escape is a
destructive `--rebuild`.

## Goals

1. A prefix that is unique across **every** input that affects the build, so all
   permutations coexist on disk and none clobber another.
2. Idempotent lookup: the same logical config resolves to the same directory
   regardless of how the CLI flags were spelled or ordered.
3. The status/identity of an env is **knowable from the directory itself**,
   without re-deriving it from a CLI invocation.
4. Short, collision-resistant directory names.

## Approach: a config manifest + content hash

### 1. Canonical config manifest (single source of truth for identity)

Inside `__ce_host_config`, *after* all resolution already done today (torch
spec, resolved CUDA version, pip target, OFI-plugin flag), assemble a
**canonical manifest string** with a fixed field order. Every input that changes
the build appears; fields that do not apply are empty (or `0`):

```
schema=1
backend=conda
host=casper
python=3.11
torch=2.10.0
cuda=12.6
torch_spec=torch==2.10.0+cu126
pip_extra_url=https://download.pytorch.org/whl/cu126
pip_target=.[distributed]
aws_ofi_nccl=v1.19.2
ofi_plugin=1
```

Notes:
- **`schema=`** is a manifest/recipe version. Bump it to deliberately invalidate
  *all* envs when the build recipe changes in a way no other field captures
  (e.g. how `mpi4py` is forced to a source build).
- The manifest records build **intent/config**, not resolved package versions.
  On the `default` host with no torch pin, `torch=`/`torch_spec=` are empty
  (torch stays unpinned, exactly as today); two such builds at different times
  share a SHA even if PyPI later resolves a newer torch. This matches current
  semantics — the manifest is not a lockfile.
- Computed in `__ce_host_config` so the **parent (`config_env.sh`) and the
  subprocess (`create_env.sh`) agree by construction** — same as the existing
  `ENV_DIR` contract.

### 2. Hash → directory name

The SHA is computed from the **resolved canonical string**, never from raw CLI
args. This is what delivers goals (1) and (2):

- `--cuda-version 12.6` on casper and the casper default resolve to the *same*
  manifest → *same* SHA → *same* dir. Flag spelling/order is irrelevant.
- Bumping a default in `default_versions.sh` changes the manifest → new SHA →
  new dir (correct: it is a different environment).

```
<backend>-credit-env[-<host>]-<short-sha>

conda-credit-env-a1b2c3d4e5f6        # default host
conda-credit-env-casper-7f3e91c0a2b1
uv-credit-env-derecho-22ab90ff7c3d
```

- **backend** becomes a leading segment (covers both conda and uv explicitly,
  replacing today's `-uv` suffix / bare-conda asymmetry).
- **host** segment only for non-default hosts.
- **python** drops out of the name entirely (it lives in the manifest + SHA).
- **short-sha**: 12 hex chars. Inputs are non-adversarial (config-derived), so
  collision risk is negligible; the manifest-match guard below is the backstop.

### 3. Manifest written into the env = integrity + status

After a successful build, `create_env.sh` writes the **exact hashed string** to:

```
<ENV_DIR>/credit-env.manifest
```

Because it is byte-for-byte what was hashed, re-hashing the file reproduces the
SHA embedded in the directory name — a free integrity check and the mechanism
behind goal (3): you can read any env's manifest to learn its full config
without reconstructing a CLI invocation.

On every invocation, if the target dir already exists, read its manifest and
confirm it matches the intended manifest before activating. A mismatch implies
an (astronomically unlikely) hash collision → **fail loudly** rather than
activate the wrong environment.

## New surface

### `--list` (inventory)

Scan `envs/*-credit-env-*/`, read each `credit-env.manifest`, and print a table:

```
DIR                              BACKEND  HOST     PYTHON  TORCH    CUDA
conda-credit-env-a1b2c3d4e5f6    conda    default  3.11    -        -
conda-credit-env-casper-7f3e91c0 conda    casper   3.11    2.10.0   12.6
uv-credit-env-derecho-22ab90ff   uv       derecho  3.12    2.10.0   12.9
```

This is the "status regardless of CLI arguments" capability — it reads the
on-disk manifests, independent of any flags.

### `--print-env-dir` (resolve-only)

Run `__ce_host_config` and echo the resolved `ENV_DIR`, then stop — no build, no
activation. Needed because CI (and PBS scripts) can no longer predict the
SHA-named directory; this lets them ask the script for the path. Also handy
interactively to locate a prefix.

## Implementation notes / non-obvious issues

- **Portable hashing.** The hash is computed in `__ce_host_config` at
  config-resolution time — *before* the target env is built, and (on the
  `default` host) potentially before any module puts a Python on `PATH`. So the
  hasher must not depend on the very interpreter these scripts exist to
  provision. Add a `__ce_sha` helper that tries `sha256sum` →
  `shasum -a 256` (macOS has no `sha256sum`) → `openssl dgst -sha256`, all of
  which are coreutils/openssl-level and present on bare login nodes and both
  macOS and Linux runners. Normalize to field 1 (`sha256sum`/`shasum` emit
  `<hash>  -`; openssl emits `(stdin)= <hash>` / `SHA2-256(stdin)= <hash>` on v3
  — strip accordingly). bash+zsh safe; the helper and any new vars go in the
  relevant `__ce_*_cleanup` lists (invariant #3, "zero shell-state pollution").
  - **Why not `python -c 'hashlib...'` as the primary?** It's tempting because
    its output is already bare (`<hash>`, no column/prefix to strip) and the
    digest is interpreter-independent, so parent/child agreement is never at
    risk. But it reintroduces a bootstrap dependency on a `python3` that may not
    be on `PATH` yet — exactly the chicken-and-egg the binary tools avoid. Keep
    Python as a *last-resort* fallback only, not the entry point; the cleaner
    output isn't worth the dependency given the chain already normalizes.
- **CI must stop hardcoding the name.** `.github/actions/build-credit-env/action.yml`
  currently recomputes `CE_ENV=credit-env-py<X.Y>[-uv]` to assert
  `test -d envs/$CE_ENV`. With a SHA name it must capture
  `ENV_DIR=$(<shell> envs/config_env.sh $CE_ARGS --print-env-dir)` once, then use
  that for the `test -d` and the source-activate marker check.
- **`.gitignore`** → add `envs/*-credit-env-*/` (the manifest lives inside the
  ignored dir, so nothing new is tracked).
- **Docs** (`README.md`, `CLAUDE.md`): the prefix description and the
  manual-activation examples (`source envs/credit-env-uv/bin/activate`) change —
  steer users to `source envs/config_env.sh [--uv]` or `--print-env-dir`.
- **Migration:** out of scope. Old-scheme dirs (`credit-env-*-py*`) are inert and
  will be removed manually; the new scheme simply builds fresh SHA-named envs.

## Files touched on adoption

| File | Change |
| --- | --- |
| `host_config.sh` | Build manifest string + `__ce_sha` helper; set `ENV_NAME`/`ENV_DIR` from `<backend>-credit-env[-host]-<sha>`; export the manifest for the writer; extend cleanup. |
| `create_env.sh` | Write `<ENV_DIR>/credit-env.manifest`; success messages use the new name. |
| `config_env.sh` | `--print-env-dir` (resolve-only) and `--list` (inventory) modes; manifest-match guard on the activate path; arg parsing + cleanup + usage. |
| `.github/actions/build-credit-env/action.yml` | Replace hardcoded `CE_ENV` with `--print-env-dir` capture. |
| `.gitignore` | Add `envs/*-credit-env-*/`. |
| `README.md`, `CLAUDE.md` | Update prefix description, activation examples, the "prefix encodes…" invariant. |

## Open questions for review

1. **Manifest filename** — `credit-env.manifest` (visible) vs `.credit-env-manifest`
   (hidden). Visible is friendlier for `cat`/`--list`; proposing visible.
2. **Short-SHA length** — 12 hex proposed; 8 is git-like and shorter, 16 is
   belt-and-suspenders. The collision guard makes this low-stakes.
3. **`--list` output** — fixed columns (above) vs a `--list --verbose` that dumps
   the full manifest per env. Proposing the table by default.
