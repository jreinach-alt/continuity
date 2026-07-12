"""Spike T2.0 harness — Mesen2 save-state bindings (spike-local).

This is the P1 "MesenRunner state-binding extension" from the spec file
table. It stays SPIKE-LOCAL (open question 4, owner's call): rather than
mutate SuperForge's shipped ``mesen_runner.py``, we subclass the runner
that ships there and add the two save-state methods the spike needs.

The binding logic is faithful to the verified upstream implementation on
SuperForge branch ``claude/stateprobe-diagnostic-rom-em6jh2`` (commit
``de79be4``) — the same code that captured ``beacon_gen2.mss``. Keeping
it spike-local means Continuity's P1 harness has no hard dependency on a
particular SuperForge branch: it rides whatever ``MesenRunner`` is on the
SuperForge checkout and layers the state API on top.

Desktop-tier x86_64 tooling only (spec toolchain note): needs
``MesenCore.so`` (SuperForge's committed core) and its SDL2/ALSA runtime
deps. Never shipped to a device; ``src/**`` is untouched.
"""

import ctypes
import os
import sys
import time
from typing import Optional


# --- SuperForge locator -----------------------------------------------------
#
# The Mesen2 harness (MesenRunner + MesenCore.so) lives in the SuperForge
# repo, which P1 sessions have in scope (spec §SuperForge assets). Find it
# without hardcoding a single path so the harness works whether SuperForge
# is a sibling checkout, at /home/user/SuperForge (this platform), or at
# an operator-supplied location.

def _candidate_superforge_roots():
    env = os.environ.get("SUPERFORGE_ROOT") or os.environ.get(
        "CONTINUITY_SUPERFORGE"
    )
    if env:
        yield env
    here = os.path.dirname(os.path.abspath(__file__))
    # Continuity repo root is three levels up from tools/transmute/harness/.
    repo_root = os.path.abspath(os.path.join(here, "..", "..", ".."))
    yield os.path.join(os.path.dirname(repo_root), "SuperForge")
    yield os.path.join(os.path.dirname(repo_root), "superforge")
    yield "/home/user/SuperForge"
    yield "/workspace/superforge"
    yield "/workspace/SuperForge"


def find_superforge() -> Optional[str]:
    """Return the SuperForge repo root, or None if it can't be located.

    A root qualifies only if it carries the harness module we import, so a
    stray empty directory named ``SuperForge`` never shadows the real one.
    """
    rel = os.path.join("infrastructure", "test_harness", "mesen_runner.py")
    for root in _candidate_superforge_roots():
        if root and os.path.isfile(os.path.join(root, rel)):
            return os.path.abspath(root)
    return None


class HarnessUnavailable(RuntimeError):
    """Raised when the Mesen2 harness cannot be brought up.

    Control drivers catch this to SKIP (not FAIL) in environments without
    the emulator core — e.g. the mainline gate, which has neither
    SuperForge nor SDL2. A missing core is "not testable here", never a
    red test.
    """


def import_mesen_runner():
    """Import SuperForge's MesenRunner + MemoryType, or raise HarnessUnavailable.

    Wraps every failure mode (SuperForge absent, SDL2 missing, core
    unloadable) in HarnessUnavailable so callers get one thing to catch.
    """
    root = find_superforge()
    if root is None:
        raise HarnessUnavailable(
            "SuperForge checkout not found (set SUPERFORGE_ROOT). The Mesen2 "
            "half of the harness needs infrastructure/test_harness/"
            "mesen_runner.py + tools/Mesen/MesenCore.so."
        )
    if root not in sys.path:
        sys.path.insert(0, root)
    try:
        from infrastructure.test_harness.mesen_runner import (  # noqa: E402
            MesenRunner,
            MemoryType,
        )
    except Exception as exc:  # pragma: no cover - env-dependent
        raise HarnessUnavailable(
            f"could not import MesenRunner from {root}: {exc!r}"
        ) from exc
    return MesenRunner, MemoryType


def _make_state_runner_class():
    """Build the StateMesenRunner subclass bound to SuperForge's MesenRunner.

    Done as a factory (not a module-level ``class ... (MesenRunner)``) so
    importing this module never forces the SuperForge import — a caller
    that only wants ``find_superforge`` / ``parse_*`` pays nothing, and the
    gate can import the module to shellcheck-adjacent-lint it without a core.
    """
    MesenRunner, MemoryType = import_mesen_runner()

    class StateMesenRunner(MesenRunner):
        """MesenRunner + .mss save/load over the InteropDLL exports.

        ``self._lib`` is bound lazily by the base class inside ``load_rom``
        (issue #123 process-global core), so we bind the two ctypes
        prototypes on first use rather than in ``__init__``.
        """

        _state_api_bound = False

        def _bind_state_api(self) -> None:
            lib = self._lib
            if lib is None:
                raise RuntimeError(
                    "load a ROM before using the save-state API "
                    "(MesenCore binds on load_rom)."
                )
            if not (hasattr(lib, "SaveStateFile") and hasattr(lib, "LoadStateFile")):
                raise HarnessUnavailable(
                    "MesenCore.so lacks SaveStateFile/LoadStateFile exports — "
                    "rebuild from a recent SourMesen/Mesen2 checkout."
                )
            if not self._state_api_bound:
                lib.SaveStateFile.restype = None
                lib.SaveStateFile.argtypes = [ctypes.c_char_p]
                lib.LoadStateFile.restype = ctypes.c_bool
                lib.LoadStateFile.argtypes = [ctypes.c_char_p]
                self._state_api_bound = True

        def save_state_file(self, path: str, wait: bool = True,
                            timeout: float = 5.0) -> str:
            """Save a full-system ``.mss`` state to ``path``.

            The core writes asynchronously on the emulation thread, so by
            default we poll until the file exists and is non-empty (the
            StateProbe capture did the same). Returns the absolute path.
            """
            self._bind_state_api()
            abs_path = os.path.abspath(path)
            os.makedirs(os.path.dirname(abs_path), exist_ok=True)
            if os.path.exists(abs_path):
                os.remove(abs_path)
            self._lib.SaveStateFile(abs_path.encode("utf-8"))
            if wait:
                self._wait_for_file(abs_path, timeout)
            return abs_path

        def load_state_file(self, path: str) -> bool:
            """Load a ``.mss`` produced by ``save_state_file``.

            The returned bool is the core's synchronous acknowledgement and
            is NOT a reliable success signal (apply happens on the emulation
            thread). Verify by observing emulated state rewind — e.g. the
            StateProbe beacon epoch counter — not this value.
            """
            self._bind_state_api()
            abs_path = os.path.abspath(path)
            if not os.path.exists(abs_path):
                raise FileNotFoundError(f"save state not found: {abs_path}")
            return bool(self._lib.LoadStateFile(abs_path.encode("utf-8")))

        def _wait_for_file(self, path: str, timeout: float) -> None:
            deadline = time.time() + timeout
            while time.time() < deadline:
                if os.path.exists(path) and os.path.getsize(path) > 0:
                    return
                # Nudge the emulation thread so the async write lands.
                try:
                    self.run_frames(1)
                except Exception:
                    time.sleep(0.02)
            raise TimeoutError(
                f"save state {path} did not appear within {timeout}s"
            )

    return StateMesenRunner, MemoryType


def new_state_runner():
    """Construct a ready StateMesenRunner instance (+ MemoryType).

    Raises HarnessUnavailable if the Mesen2 core can't be brought up.
    """
    StateMesenRunner, MemoryType = _make_state_runner_class()
    return StateMesenRunner(), MemoryType
