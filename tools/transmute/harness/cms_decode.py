"""Spike T2.0 harness — CMS decode from a Mesen2 ``.mss`` (P1 primitive).

Decode = pull architectural machine state out of a captured ``.mss`` and hand
it back as (a) raw region bytes for the memory domains and (b) a populated
``SnesCpuState`` for the 65C816 register file. The extraction primitive is the
P0 ``mss_dump -x <key>`` oracle (byte-exact, validated against Mesen itself in
control C4a); this module is the thin structural layer over it that the
full-behavioural C4 and the P2 encoder consume.

The keyed record names are ground-truth from the real beacon capture
(``mss_dump beacon_gen2.mss``) — they are NOT guessed from the serializer
source. Memory domains are byte arrays; the CPU record is 17 scalar
sub-records (``cpu.a`` … ``cpu.stopState``) that pack 1:1 into SnesCpuState.

Deliberately kept in Python over ``mss_dump`` rather than reimplementing the
container/zlib/record walk — that walk already lives, tested, in the C oracle;
``transmute_snes.c`` formalizes the same decode for the shipping pipeline (P2).
"""

import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from mesen_state import SnesCpuState  # noqa: E402


# --- Architectural memory domains ------------------------------------------
#
# (cms_name, mss record key, MesenRunner MemoryType attribute, byte size).
# The MemoryType is named, not imported, so this module loads without the
# SuperForge core present (the gate can lint it); callers resolve the attr
# against the `mem` object new_state_runner() hands back.
#
# spc.ram (ARAM) is included: it is a CMS architectural domain (APU RAM) and
# a plain byte array Mesen exposes as SpcRam. The DSP register file / SPC700
# CPU registers are NOT here — Mesen exports no Set for them, and StateProbe
# v0 leaves the APU-internal domains (bits 4/5/6) as documented blind spots.
MEMORY_DOMAINS = [
    ("wram",  "memoryManager.workRam", "SnesWorkRam",   131072),
    ("vram",  "ppu.vram",              "SnesVideoRam",  65536),
    ("oam",   "ppu.oamRam",            "SnesSpriteRam", 544),
    ("cgram", "ppu.cgram",             "SnesCgRam",     512),
    ("sram",  "cart.saveRam",          "SnesSaveRam",   8192),
    ("aram",  "spc.ram",               "SpcRam",        65536),
]


# --- CPU record -> SnesCpuState field map ----------------------------------
#
# struct field name -> (mss record key, byte width). Widths match
# SnesCpuTypes.h. Order is irrelevant here (we setattr by name); it mirrors
# the struct for readability. cpu.waiOver is intentionally absent — it is not
# a SnesCpuState member (see mesen_state.SnesCpuState docstring).
_CPU_FIELD_MAP = [
    ("CycleCount",     "cpu.cycleCount",    8),
    ("A",              "cpu.a",             2),
    ("X",              "cpu.x",             2),
    ("Y",              "cpu.y",             2),
    ("SP",             "cpu.sp",            2),
    ("D",              "cpu.d",             2),
    ("PC",             "cpu.pc",            2),
    ("K",              "cpu.k",             1),
    ("DBR",            "cpu.dbr",           1),
    ("PS",             "cpu.ps",            1),
    ("EmulationMode",  "cpu.emulationMode", 1),
    ("NmiFlagCounter", "cpu.nmiFlagCounter",1),
    ("IrqLock",        "cpu.irqLock",       1),
    ("NeedNmi",        "cpu.needNmi",       1),
    ("IrqSource",      "cpu.irqSource",     1),
    ("PrevIrqSource",  "cpu.prevIrqSource", 1),
    ("StopState",      "cpu.stopState",     1),
]


class DecodeError(RuntimeError):
    """A keyed record could not be extracted or had the wrong length."""


def extract_domain(mss_dump: str, mss_path: str, key: str) -> bytes:
    """Return the raw little-endian bytes of one keyed record via mss_dump -x.

    Raises DecodeError on any non-zero exit (malformed / refused / key
    missing) so a decode failure is loud, never a silent empty transplant.
    """
    proc = subprocess.run(
        [mss_dump, "-x", key, mss_path], capture_output=True,
    )
    if proc.returncode != 0:
        raise DecodeError(
            f"extract {key!r} failed (rc={proc.returncode}): "
            f"{proc.stderr.decode('latin-1', 'replace').strip()}"
        )
    return proc.stdout


class MesenRecords:
    """One-shot decode of every keyed record in a ``.mss`` capture.

    ``mss_dump`` (no ``-x``) prints one line per record — ``key\\tsize\\tvalue``
    for scalars (value as ``0xhex\\tdecimal``), ``key\\tsize\\tcrc32=..`` for
    byte arrays >8 bytes. Parsing that single dump once gives O(1) access to
    all ~1300 architectural scalars without a subprocess per field; the six
    large memory arrays are still pulled via ``mss_dump -x`` on demand (and
    cached). This is the decode-side surface the P2 register-file encoder
    consumes; ``transmute_snes.c`` formalizes the same walk for shipping.

    The chip-firewall exit (rc==2) is honoured: a coprocessor capture raises
    DecodeError here rather than silently transplanting a plain-cart subset.
    """

    def __init__(self, mss_dump: str, mss_path: str):
        self.mss_dump = mss_dump
        self.mss_path = mss_path
        self._scalars: dict = {}
        self._arrays: dict = {}
        proc = subprocess.run(
            [mss_dump, mss_path], capture_output=True, text=True,
        )
        if proc.returncode == 2:
            raise DecodeError(
                f"REFUSE: {mss_path} tripped the chip firewall "
                "(coprocessor/enhancement keys present)"
            )
        if proc.returncode != 0:
            raise DecodeError(
                f"mss_dump {mss_path} failed (rc={proc.returncode}): "
                f"{proc.stderr.strip()}"
            )
        for line in proc.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) < 3 or not parts[1].isdigit():
                continue  # header lines ("mss.* = ..") — not records
            key, size = parts[0], int(parts[1])
            if parts[2].startswith("0x"):
                self._scalars[key] = (size, int(parts[3]))
            # arrays (crc32=..) are pulled by name via .array()

    def has(self, key: str) -> bool:
        return key in self._scalars

    def u(self, key: str) -> int:
        """Unsigned integer value of a scalar record (raises if absent)."""
        rec = self._scalars.get(key)
        if rec is None:
            raise DecodeError(f"record not found (or not scalar): {key!r}")
        return rec[1]

    def size(self, key: str) -> int:
        rec = self._scalars.get(key)
        if rec is None:
            raise DecodeError(f"record not found: {key!r}")
        return rec[0]

    def array(self, key: str) -> bytes:
        """Raw bytes of a byte-array record (cached; via mss_dump -x)."""
        if key not in self._arrays:
            self._arrays[key] = extract_domain(
                self.mss_dump, self.mss_path, key)
        return self._arrays[key]


def decode_cpu_state(mss_dump: str, mss_path: str) -> SnesCpuState:
    """Transcode the ``cpu.*`` records of a ``.mss`` into a SnesCpuState.

    Each field is an independently-keyed scalar record; we extract, verify the
    width, and int-decode little-endian. The result is ready for
    ``StateMesenRunner.set_cpu_state`` (whole-struct memcpy into the live CPU).
    """
    st = SnesCpuState()
    for field, key, width in _CPU_FIELD_MAP:
        raw = extract_domain(mss_dump, mss_path, key)
        if len(raw) != width:
            raise DecodeError(
                f"{key!r}: expected {width} bytes, got {len(raw)}"
            )
        setattr(st, field, int.from_bytes(raw, "little"))
    return st


def decode_memory_domains(mss_dump: str, mss_path: str) -> dict:
    """Extract every architectural memory domain -> {cms_name: bytes}.

    Verifies each domain's byte length against MEMORY_DOMAINS so a
    short/over-long read (wrong record, format drift) is caught here rather
    than corrupting a downstream transplant.
    """
    out = {}
    for cms_name, key, _mem_attr, size in MEMORY_DOMAINS:
        raw = extract_domain(mss_dump, mss_path, key)
        if len(raw) != size:
            raise DecodeError(
                f"{cms_name} ({key!r}): expected {size} bytes, got {len(raw)}"
            )
        out[cms_name] = raw
    return out


def inject_memory_domains(runner, mem, domains: dict) -> None:
    """Write each decoded memory domain into a live core via the memory API.

    ``domains`` is the dict decode_memory_domains returns. MemoryType attrs
    are resolved lazily against the caller's ``mem`` enum.
    """
    for cms_name, _key, mem_attr, _size in MEMORY_DOMAINS:
        data = domains.get(cms_name)
        if data is None:
            continue
        runner.write_region(getattr(mem, mem_attr), data)
