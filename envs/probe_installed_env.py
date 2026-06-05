#!/usr/bin/env python
"""Post-install health check for a CREDIT conda environment.

Run by ``envs/config_env.sh`` immediately after ``pip install`` to confirm the
environment actually works, and to report a short diagnostic on the torch build
(version, CUDA, NCCL, devices).  Also useful standalone::

    python envs/probe_installed_env.py [--require-nccl] [--verbose]

Exit status:
  0  every REQUIRED check passed
  1  a required check failed

REQUIRED checks are: ``import torch`` and ``import credit`` (the package must
load).  NCCL is *not* required in general -- CPU/MPS builds (e.g. macOS) ship
without it -- so a missing NCCL is reported and tolerated.  On GPU/HPC hosts
where NCCL is expected (Casper, Derecho), pass ``--require-nccl`` so a missing
or unqueryable NCCL becomes a hard failure.
"""

import argparse
import sys


def _ok(msg):
    print(f"  [ ok ] {msg}")


def _info(msg):
    print(f"  [info] {msg}")


def _fail(msg):
    print(f"  [FAIL] {msg}")


def main():
    parser = argparse.ArgumentParser(description="CREDIT environment health check")
    parser.add_argument(
        "--require-nccl",
        action="store_true",
        help="treat a missing/unqueryable NCCL as a failure (GPU/HPC hosts)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="also dump torch.__config__.show()",
    )
    args = parser.parse_args()

    failures = []

    print("CREDIT environment health check")
    print(f"  python: {sys.version.split()[0]} ({sys.executable})")

    # --- torch (required) ----------------------------------------------------
    try:
        import torch
    except Exception as exc:  # noqa: BLE001 - report any import error verbatim
        _fail(f"import torch: {exc!r}")
        print("\nHealth check FAILED: torch could not be imported.")
        return 1
    _ok(f"torch {torch.__version__}")

    try:
        cuda_avail = torch.cuda.is_available()
        _info(f"CUDA available: {cuda_avail}")
        if cuda_avail:
            _info(f"CUDA runtime: {torch.version.cuda}; devices: {torch.cuda.device_count()}")
            for i in range(torch.cuda.device_count()):
                _info(f"  device {i}: {torch.cuda.get_device_name(i)}")
    except Exception as exc:  # noqa: BLE001
        _info(f"could not query CUDA: {exc!r}")

    # --- NCCL (optional unless --require-nccl) -------------------------------
    nccl_version = None
    nccl_err = None
    try:
        # Raises AttributeError on a torch built without NCCL (e.g. macOS CPU/MPS).
        nccl_version = torch.cuda.nccl.version()
    except Exception as exc:  # noqa: BLE001
        nccl_err = exc
    if nccl_version is not None:
        _ok(f"NCCL version: {nccl_version}")
    elif args.require_nccl:
        _fail(f"NCCL required on this host but not available: {nccl_err!r}")
        failures.append("nccl")
    else:
        _info("NCCL not available (expected on CPU/MPS builds)")

    # --- mpi4py (optional, report only) -------------------------------------
    try:
        import mpi4py  # noqa: F401 - imported only to read its version

        _info(f"mpi4py {mpi4py.__version__}")
    except Exception:  # noqa: BLE001
        _info("mpi4py not installed (ok unless using the HPC MPI extras)")

    if args.verbose:
        print("\n--- torch.__config__.show() ---")
        print(torch.__config__.show())

    # --- credit (required) ---------------------------------------------------
    try:
        import credit

        _ok(f"import credit ({getattr(credit, '__version__', 'version unknown')})")
    except Exception as exc:  # noqa: BLE001
        _fail(f"import credit: {exc!r}")
        failures.append("credit")

    print()
    if failures:
        print(f"Health check FAILED: {', '.join(failures)}")
        return 1
    print("Health check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
