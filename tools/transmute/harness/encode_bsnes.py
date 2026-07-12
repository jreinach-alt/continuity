"""Spike T2.0 harness — donor-template bsnes ``.bst`` encoder (P2, G2/G3).

The design-doc encode strategy (spec H6): boot the pinned bsnes headless at
power-on, serialize -> a **donor** ``.bst`` carrying every emulator-internal
field in a self-consistent configuration from bsnes's own code path. Then
overwrite the *architectural* fields with the CMS values decoded from a Mesen2
``.mss`` capture and emit. Synthesis is written FROM the target's own load
path, so the loader accepts it (G2) and — for the domains fully carried —
StateProbe continues and audits green (G3).

Primitives (P1 convention — the oracles ARE the decode/layout tools; the C
formalization ``transmute_snes.c`` is the P2 follow-on):
  * mss_dump -x KEY  : byte-exact Mesen decode of each keyed record.
  * bst_dump -O      : positional offset map of the bsnes payload (every
                       field's byte offset + length), so we overwrite in
                       place without re-deriving the serialize walk here.
  * bst.py           : payload unwrap/rewrap (RLE + 12-byte container).

Scope of THIS pass (recorded deviations, honest about the G3 boundary):
  * Overwritten (raw byte arrays, identical semantics both emulators):
    WRAM, VRAM, CGRAM, SRAM, ARAM — plus the 65C816 register file
    (small pinned transform: pc=(pbr<<16)|pc, PS flag unpack, stopState).
  * NOT yet overwritten (deferred, each a named G3 gap):
    - OAM: bsnes fastPPU stores it STRUCTURED (ppufast.object[N].{x,y,...}),
      not as Mesen's raw 544-byte table — needs an OAM-table->object
      transform.
    - PPU register file, SMP/SPC700 regs, DSP blob: large register-file
      transforms (the mapping JSON pins them; C4 already proved the PPU
      register file is load-bearing). These are the transmute_snes.c body.
  Consequence: G2 (loads) is fully in scope; G3 is reported PER DOMAIN with
  field-level attribution — the spike's evidence model ("every failure gets a
  root cause"), not a single pass/fail.
"""

import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import bst  # noqa: E402
import cms_decode  # noqa: E402


# Architectural byte-array domains that are raw + same-semantics both sides.
# (cms record via mss_dump) -> (bsnes payload field name in the -O offset map).
# OAM is intentionally absent (structured in bsnes fastPPU — see module docs).
_RAW_ARRAY_MAP = [
    ("memoryManager.workRam", "cpu.wram"),
    ("ppu.vram",              "ppufast.vram"),
    ("ppu.cgram",             "ppufast.cgram"),
    ("cart.saveRam",          "cartridge.ram"),
    ("spc.ram",               "dsp.apuram"),
]


class EncodeError(RuntimeError):
    pass


def payload_offsets(bst_dump: str, donor_bst: str, sram_bytes: int) -> dict:
    """Parse ``bst_dump -O`` into {field_name: (offset, length)}.

    The offsets index the UNWRAPPED payload (same coordinate space as
    bst.bst_unwrap output), so an overwrite writes straight into the
    unwrapped donor bytes.
    """
    proc = subprocess.run(
        [bst_dump, "-O", "-s", str(sram_bytes), donor_bst],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise EncodeError(f"bst_dump -O failed: {proc.stderr.strip()}")
    offs = {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        off, length, name = int(parts[0]), int(parts[1]), parts[2]
        offs[name] = (off, length)
    return offs


def _put(buf: bytearray, off: int, length: int, data: bytes, name: str):
    if len(data) != length:
        raise EncodeError(
            f"{name}: field is {length} bytes but source is {len(data)}"
        )
    buf[off:off + length] = data


def _put_scalar(buf: bytearray, offs: dict, name: str, value: int):
    off, length = offs[name]
    buf[off:off + length] = int(value).to_bytes(length, "little")


def overwrite_cpu(buf: bytearray, offs: dict, cpu) -> None:
    """Overwrite the bsnes wdc register file from a decoded SnesCpuState.

    Transforms pinned in cms/mapping_mesen2_bsnes.json §cpu:
      wdc.pc = (K<<16)|PC ; wdc.b = DBR ; wdc.p.* = PS bits ;
      wdc.wai = (StopState==2) ; wdc.stp = (StopState==1).
    bsnes-internal micro-op scratch (wdc.z/irq/vector/mar/mdr/u/v/w) is left
    at the donor's self-consistent power-on value (quiescent-safe at an
    instruction boundary — H3).
    """
    _put_scalar(buf, offs, "cpu.wdc.pc", (cpu.K << 16) | cpu.PC)
    _put_scalar(buf, offs, "cpu.wdc.a", cpu.A)
    _put_scalar(buf, offs, "cpu.wdc.x", cpu.X)
    _put_scalar(buf, offs, "cpu.wdc.y", cpu.Y)
    _put_scalar(buf, offs, "cpu.wdc.s", cpu.SP)
    _put_scalar(buf, offs, "cpu.wdc.d", cpu.D)
    _put_scalar(buf, offs, "cpu.wdc.b", cpu.DBR)
    ps = cpu.PS
    for i, flag in enumerate(["c", "z", "i", "d", "x", "m", "v", "n"]):
        _put_scalar(buf, offs, f"cpu.wdc.p.{flag}", (ps >> i) & 1)
    _put_scalar(buf, offs, "cpu.wdc.e", cpu.EmulationMode)
    _put_scalar(buf, offs, "cpu.wdc.wai", 1 if cpu.StopState == 2 else 0)
    _put_scalar(buf, offs, "cpu.wdc.stp", 1 if cpu.StopState == 1 else 0)


def encode(mss_path: str, donor_bst: str, out_bst: str,
           mss_dump: str, bst_dump: str, sram_bytes: int = 8192) -> dict:
    """Rebuild a bsnes ``.bst`` from a Mesen ``.mss`` over a power-on donor.

    Returns a report of which domains were overwritten (for the G3 matrix).
    """
    with open(donor_bst, "rb") as fh:
        donor_raw = fh.read()
    payload = bytearray(bst.bst_unwrap(donor_raw))
    offs = payload_offsets(bst_dump, donor_bst, sram_bytes)

    overwritten = []
    for mss_key, bsnes_name in _RAW_ARRAY_MAP:
        if bsnes_name not in offs:
            raise EncodeError(f"donor offset map missing {bsnes_name!r}")
        off, length = offs[bsnes_name]
        data = cms_decode.extract_domain(mss_dump, mss_path, mss_key)
        _put(payload, off, length, data, bsnes_name)
        overwritten.append(bsnes_name)

    cpu = cms_decode.decode_cpu_state(mss_dump, mss_path)
    overwrite_cpu(payload, offs, cpu)
    overwritten.append("cpu.wdc.*")

    rebuilt = bst.bst_wrap(bytes(payload))
    with open(out_bst, "wb") as fh:
        fh.write(rebuilt)

    return {
        "out": out_bst,
        "out_bytes": len(rebuilt),
        "overwritten": overwritten,
        "deferred": ["ppufast.oam (structured)", "ppu register file",
                     "smp/spc700 regs", "dsp blob"],
        "cpu_pc": (cpu.K << 16) | cpu.PC,
    }


def _cli(argv=None):
    import argparse
    p = argparse.ArgumentParser(description="Donor-encode a Mesen .mss -> bsnes .bst")
    p.add_argument("mss")
    p.add_argument("donor")
    p.add_argument("out")
    p.add_argument("--mss-dump", required=True)
    p.add_argument("--bst-dump", required=True)
    p.add_argument("--sram", type=int, default=8192)
    a = p.parse_args(argv)
    rep = encode(a.mss, a.donor, a.out, a.mss_dump, a.bst_dump, a.sram)
    import json
    print(json.dumps(rep, indent=2))


if __name__ == "__main__":
    _cli()
