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


# --- Mesen2 SnesCpuState (register-injection struct) ------------------------
#
# Layout transcribed field-for-field from the pinned vendored source
# (tools/transmute/vendor/mesen2 @ b9fa69d):
#   Core/SNES/SnesCpuTypes.h:12   struct SnesCpuState : BaseState { ... }
#   Core/Shared/BaseState.h:3     struct BaseState {};   (empty — no vtable,
#                                 no members, so the struct begins at
#                                 CycleCount @ offset 0)
# InteropDLL exports Get/SetCpuState(BaseState&, CpuType); the debugger
# does `memcpy(&dstState, &srcState, sizeof(SnesCpuState))` for CpuType::Snes
# (Core/Debugger/Debugger.cpp:858) — a full whole-struct write-back, so
# injecting this struct sets every architectural CPU field at once.
#
# NOTE: the CPU's `_waiOver` bool is serialized alongside these fields in the
# .mss (key `cpu.waiOver`) but is NOT a member of SnesCpuState, so it is not
# reachable through Set/GetCpuState. Frame-edge (quiescent) captures land
# waiOver=0, so this is immaterial for the pilot; recorded as a known gap.
_CPU_TYPE_SNES = 0


class SnesCpuState(ctypes.Structure):
    """ctypes mirror of Mesen2 ``SnesCpuState`` (SnesCpuTypes.h @ pin).

    Field order and widths are exact; ``_pack_`` is left at natural
    alignment so ``CycleCount`` (u64) forces 8-byte alignment and the whole
    struct pads to 32 bytes — matching the C++ ``sizeof(SnesCpuState)`` the
    debugger memcpy's.
    """

    _fields_ = [
        ("CycleCount", ctypes.c_uint64),   # off 0
        ("A", ctypes.c_uint16),            # off 8
        ("X", ctypes.c_uint16),            # off 10
        ("Y", ctypes.c_uint16),            # off 12
        ("SP", ctypes.c_uint16),           # off 14
        ("D", ctypes.c_uint16),            # off 16
        ("PC", ctypes.c_uint16),           # off 18
        ("K", ctypes.c_uint8),             # off 20
        ("DBR", ctypes.c_uint8),           # off 21
        ("PS", ctypes.c_uint8),            # off 22
        ("EmulationMode", ctypes.c_uint8), # off 23 (bool)
        ("NmiFlagCounter", ctypes.c_uint8),# off 24
        ("IrqLock", ctypes.c_uint8),       # off 25 (bool)
        ("NeedNmi", ctypes.c_uint8),       # off 26 (bool)
        ("IrqSource", ctypes.c_uint8),     # off 27
        ("PrevIrqSource", ctypes.c_uint8), # off 28
        ("StopState", ctypes.c_uint8),     # off 29 (SnesCpuStopState)
    ]

    def as_dict(self) -> dict:
        return {name: getattr(self, name) for name, _ in self._fields_}


# GetPpuState fills a caller-provided scratch buffer with the SnesPpuState
# struct (a few hundred bytes); SetPpuState memcpy's sizeof(SnesPpuState)
# back out of the buffer. We never need to know the exact size: Get then Set
# with the SAME buffer transplants the whole PPU register file byte-for-byte.
# 16 KB of headroom guards against a future core with a larger struct.
_PPU_STATE_BUF_SIZE = 16384


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
        _reg_api_bound = False

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

        # --- register-state API (CPU/PPU injection) --------------------
        #
        # Get/SetCpuState + Get/SetPpuState are exported by MesenCore.so but
        # were never bound in SuperForge's MesenRunner (spike summary
        # finding 6). They are the primitive full-behavioural C4 needs: the
        # memory API transplants RAM domains, these transplant the register
        # files (65C816 regs + the PPU register file).

        def _bind_reg_api(self) -> None:
            lib = self._lib
            if lib is None:
                raise RuntimeError(
                    "load a ROM before using the register-state API "
                    "(MesenCore binds on load_rom)."
                )
            needed = ("GetCpuState", "SetCpuState", "GetPpuState", "SetPpuState")
            missing = [n for n in needed if not hasattr(lib, n)]
            if missing:
                raise HarnessUnavailable(
                    "MesenCore.so lacks register-state exports "
                    f"{missing} — rebuild from a recent SourMesen/Mesen2 checkout."
                )
            if not self._reg_api_bound:
                # All four take (BaseState& state, CpuType cpuType); the
                # state pointer is a plain buffer/struct pointer.
                lib.GetCpuState.restype = None
                lib.GetCpuState.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
                lib.SetCpuState.restype = None
                lib.SetCpuState.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
                lib.GetPpuState.restype = None
                lib.GetPpuState.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
                lib.SetPpuState.restype = None
                lib.SetPpuState.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
                self._reg_api_bound = True

        def get_cpu_state(self) -> SnesCpuState:
            """Read the live 65C816 register file into a SnesCpuState."""
            self._bind_reg_api()
            st = SnesCpuState()
            self._lib.GetCpuState(ctypes.byref(st), _CPU_TYPE_SNES)
            return st

        def set_cpu_state(self, state: SnesCpuState) -> None:
            """Overwrite the live 65C816 register file (whole-struct memcpy)."""
            self._bind_reg_api()
            self._lib.SetCpuState(ctypes.byref(state), _CPU_TYPE_SNES)

        def get_ppu_state_raw(self) -> bytes:
            """Snapshot the PPU register file as an opaque buffer.

            Returns the full ``_PPU_STATE_BUF_SIZE`` buffer; only the first
            ``sizeof(SnesPpuState)`` bytes are meaningful, but SetPpuState
            reads exactly that prefix, so a Get→Set round-trip of the whole
            buffer transplants the register file faithfully without the
            harness needing the struct's exact size.
            """
            self._bind_reg_api()
            buf = (ctypes.c_uint8 * _PPU_STATE_BUF_SIZE)()
            self._lib.GetPpuState(buf, _CPU_TYPE_SNES)
            return bytes(buf)

        def set_ppu_state_raw(self, data: bytes) -> None:
            """Overwrite the PPU register file from a ``get_ppu_state_raw``
            buffer (whole-struct memcpy of its meaningful prefix)."""
            self._bind_reg_api()
            if len(data) < _PPU_STATE_BUF_SIZE:
                data = data + b"\x00" * (_PPU_STATE_BUF_SIZE - len(data))
            buf = (ctypes.c_uint8 * _PPU_STATE_BUF_SIZE).from_buffer_copy(
                data[:_PPU_STATE_BUF_SIZE]
            )
            self._lib.SetPpuState(buf, _CPU_TYPE_SNES)

        def write_region(self, mem_type, data: bytes) -> None:
            """Overwrite an entire memory region from offset 0.

            Thin wrapper over the base ``write_bytes`` for readability at
            transplant call sites (WRAM/VRAM/OAM/CGRAM/SRAM/ARAM).
            """
            self.write_bytes(mem_type, 0, data)

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
