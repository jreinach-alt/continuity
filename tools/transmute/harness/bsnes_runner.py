"""Spike T2.0 harness — Python wrapper over the compiled bsnes host.

Locates the pinned bsnes libretro core + the compiled bsnes_host driver
(both under tools/transmute/build/, produced by build_bsnes_host.sh) and
exposes save / reload / check primitives. Raises HarnessUnavailable when
the core or host isn't built so controls SKIP rather than FAIL on hosts
without the (heavy) bsnes build — same discipline as the Mesen2 side.
"""

import os
import subprocess

from mesen_state import HarnessUnavailable  # reuse the one skip signal


_HERE = os.path.dirname(os.path.abspath(__file__))
_TRANSMUTE = os.path.abspath(os.path.join(_HERE, ".."))
BUILD_DIR = os.path.join(_TRANSMUTE, "build")
HOST_BIN = os.path.join(BUILD_DIR, "bsnes_host")
CORE_SO = os.path.join(BUILD_DIR, "bsnes_libretro.so")
# Fallback: the core as the vendored makefile emits it.
_VENDOR_CORE = os.path.join(
    _TRANSMUTE, "vendor", "bsnes", "bsnes", "out", "bsnes_libretro.so"
)

# Exit codes from bsnes_host.
RC_OK = 0
RC_ERROR = 1
RC_REJECTED = 3


class BsnesRunner:
    def __init__(self):
        core = CORE_SO if os.path.exists(CORE_SO) else _VENDOR_CORE
        if not os.path.exists(HOST_BIN) or not os.path.exists(core):
            raise HarnessUnavailable(
                "bsnes host/core not built — run "
                "tools/transmute/harness/build_bsnes_host.sh "
                f"(host={os.path.exists(HOST_BIN)}, core={os.path.exists(core)})"
            )
        self.core = core

    def _run(self, args, timeout=120):
        proc = subprocess.run(
            [HOST_BIN, args[0], self.core, *args[1:]],
            capture_output=True, text=True, timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr

    def save(self, rom: str, out_bst: str, frames: int) -> None:
        rc, _, err = self._run(["save", rom, out_bst, "--frames", str(frames)])
        if rc != RC_OK:
            raise RuntimeError(f"bsnes save failed (rc={rc}): {err.strip()}")

    def reload(self, rom: str, in_bst: str, out_bst: str, frames: int) -> int:
        """Load in_bst into a fresh core, run `frames`, re-save to out_bst.

        Returns the host exit code (RC_OK / RC_REJECTED / RC_ERROR).
        """
        rc, _, _ = self._run(
            ["reload", rom, in_bst, out_bst, "--frames", str(frames)]
        )
        return rc

    def check(self, rom: str, in_bst: str) -> int:
        """Try to load in_bst; return RC_OK if accepted, RC_REJECTED if not."""
        rc, _, _ = self._run(["check", rom, in_bst])
        return rc
