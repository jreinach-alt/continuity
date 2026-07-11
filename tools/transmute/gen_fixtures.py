#!/usr/bin/env python3
"""gen_fixtures.py — synthetic container fixtures for the T2.0 dumpers.

Generates structurally-faithful .mss / .bst files into
tests/fixtures/transmute/ plus a fixtures.sha256 manifest. These are
CONTAINER fixtures: they exercise every framing, gate, and refuse path of
mss_dump/bst_dump (magic, zlib payload, keyed records, RLE codec, stream
header gates, exact positional walk, chip firewall) with planted scalar
values the unit test asserts. They are NOT emulator-produced states —
semantic oracle fixtures (StateProbe beacon captures) arrive with the
SuperForge import and P1 runner work, and supersede nothing here: both
kinds stay.

Layouts transcribe the same pinned sources as the dumpers:
  mesen2 @ b9fa69dd (SaveStateManager.cpp, Serializer.{h,cpp})
  bsnes  @ 7d5aa1e6 (states.cpp, nall rle.hpp, system/serialization.cpp,
                     per-chip serialization.cpp files)
The .bst walk widths here are written FROM cms/mapping_mesen2_bsnes.json;
bst_dump's tables were written FROM the vendored serialize functions —
the unit test cross-checks the two transcriptions against each other.

Deterministic content (fixed values, zeros for arrays). Committed
fixtures are canonical; the manifest pins their hashes. Regenerating on
a different zlib may alter .mss bytes (compression), which is fine —
recommit fixtures + manifest together if you regenerate.

Usage: python3 tools/transmute/gen_fixtures.py
"""

import hashlib
import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "tests" / "fixtures" / "transmute"


# ---------------------------------------------------------------- mss ----

def mss_record(key: str, value: bytes) -> bytes:
    return key.encode() + b"\x00" + struct.pack("<I", len(value)) + value


def mss_container(payload_records: bytes, console_type: int = 0) -> bytes:
    out = bytearray()
    out += b"MSS"
    out += struct.pack("<I", 20000)          # emu_version (arbitrary)
    out += struct.pack("<I", 4)              # format_version
    out += struct.pack("<I", console_type)   # Snes = 0
    fb = bytes(64)                           # tiny fake framebuffer
    fbz = zlib.compress(fb, 6)
    out += struct.pack("<IIII", len(fb), 4, 4, 100)
    out += struct.pack("<I", len(fbz)) + fbz
    name = b"stateprobe.sfc"
    out += struct.pack("<I", len(name)) + name
    # payload framing: compressed variant (Serializer::SaveTo)
    pz = zlib.compress(payload_records, 1)
    out += b"\x01"
    out += struct.pack("<I", len(payload_records))
    out += struct.pack("<I", len(pz))
    out += pz
    return bytes(out)


def build_mss_v0() -> bytes:
    recs = bytearray()
    recs += mss_record("cpu.a", struct.pack("<H", 0x1234))
    recs += mss_record("cpu.pc", struct.pack("<H", 0x8000))
    recs += mss_record("cpu.k", b"\x80")
    recs += mss_record("cpu.emulationMode", b"\x00")
    recs += mss_record("memoryManager.openBus", b"\x42")
    recs += mss_record("memoryManager.workRam", bytes(64))
    recs += mss_record("ppu.vram", bytes(128))
    recs += mss_record("internalRegisters.horizontalTimer",
                       struct.pack("<H", 0x1FF))
    recs += mss_record("spc.pc", struct.pack("<H", 0xFFC0))
    recs += mss_record("spc.dsp.regs", bytes(128))
    recs += mss_record("cart.saveRam", bytes(32))
    recs += mss_record("controlManager.pollCounter", struct.pack("<I", 7))
    return mss_container(bytes(recs))


def build_mss_chipcart() -> bytes:
    recs = bytearray()
    recs += mss_record("cpu.a", struct.pack("<H", 0x1234))
    recs += mss_record("cart.saveRam", bytes(32))
    recs += mss_record("cart.coprocessor.sa1.r", struct.pack("<H", 0xBEEF))
    return mss_container(bytes(recs))


# ---------------------------------------------------------------- bst ----

def rle1_encode(data: bytes) -> bytes:
    """nall Encode::RLE<1> (M=4): 8-byte LE size, then packets."""
    out = bytearray(struct.pack("<Q", len(data)))
    base = 0
    skip = 0

    def flush():
        nonlocal base, skip
        out.append(skip - 1)
        out.extend(data[base:base + skip])
        base += skip
        skip = 0

    n = len(data)
    while base + skip < n:
        same = 1
        off = base + skip + 1
        while off < n and data[off] == data[base + skip] and same < 127 + 4:
            same += 1
            off += 1
        if same < 4:
            skip += 1
            if skip == 128:
                flush()
        else:
            if skip:
                flush()
            out.append(0x80 | (same - 4))
            out.append(data[base])
            base += same
    if skip:
        flush()
    return bytes(out)


class Stream:
    def __init__(self):
        self.buf = bytearray()

    def u(self, value: int, width: int):
        self.buf += int(value).to_bytes(width, "little")

    def arr(self, data: bytes):
        self.buf += data


def bst_stream(sram: int = 8192, synchronize: int = 1,
               fastppu: int = 1, chip_extra: int = 0) -> bytes:
    """Plain-cart fastPPU stream per the mapping's width tables."""
    s = Stream()
    body = Stream()

    def thread():
        body.u(21477272, 4)   # frequency
        body.u(0, 8)          # clock

    def ppucounter():
        for w in (1, 1, 4, 4, 4, 4, 4, 4):
            body.u(0, w)

    # random
    body.u(1, 4)              # entropy Low
    body.u(0x0123456789ABCDEF, 8)
    body.u(1, 8)
    # cartridge
    body.arr(bytes(sram))
    # cpu: wdc
    body.u(0x808000, 4)       # pc.d
    body.u(0x1234, 2)         # a  (planted)
    for _ in range(5):        # x y z s d
        body.u(0, 2)
    body.u(0x80, 1)           # b
    for _ in range(8):        # p flags
        body.u(0, 1)
    for _ in range(4):        # e irq wai stp
        body.u(0, 1)
    body.u(0xFFEA, 2)         # vector
    body.u(0, 4)              # mar
    body.u(0x42, 1)           # mdr
    for _ in range(3):        # u v w
        body.u(0, 4)
    thread()
    ppucounter()
    body.arr(bytes(128 * 1024))          # wram
    body.u(2, 4)                          # version
    body.u(0, 4)
    body.u(0, 4)                          # counter.cpu/dma
    # status: 4,1,4,4,4,1,4,1 then 10x1, 2x1, 4x1, 4, 1,1, 1,1
    for w in (4, 1, 4, 4, 4, 1, 4, 1):
        body.u(0, w)
    for _ in range(10):
        body.u(0, 1)
    for _ in range(2):
        body.u(0, 1)
    for _ in range(4):
        body.u(0, 1)
    body.u(33, 4)                         # autoJoypadCounter inactive
    body.u(0, 1)
    body.u(0, 1)
    body.u(0, 1)
    body.u(0, 1)
    # io
    body.u(0, 4)                          # wramAddress
    for _ in range(5):
        body.u(0, 1)
    body.u(0xFF, 1)                       # pio
    body.u(0xFF, 1)
    body.u(0xFF, 1)                       # wrmpya/b
    body.u(0xFFFF, 2)
    body.u(0xFF, 1)                       # wrdiva/b
    body.u(0x0800, 2)                     # htime (planted: (0x1ff+1)<<2)
    body.u(0x1FF, 2)                      # vtime
    body.u(0, 1)                          # fastROM
    body.u(0, 2)
    body.u(0, 2)                          # rddiv rdmpy
    for _ in range(4):                    # joy1-4
        body.u(0, 2)
    for _ in range(3):                    # alu
        body.u(0, 4)
    for _ in range(8):                    # channels
        for w in (1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 2, 1, 2, 1, 1, 1, 1):
            body.u(0, w)
    # smp
    body.u(0xFFC0, 2)                     # spc700.pc
    body.u(0, 2)                          # ya
    body.u(0, 1)
    body.u(0xEF, 1)                       # x, s
    for _ in range(8):                    # p flags
        body.u(0, 1)
    body.u(0, 1)
    body.u(0, 1)                          # wait stop
    thread()
    body.u(0, 4)
    body.u(0, 4)                          # clockCounter dspCounter
    body.u(0xAA, 1)                       # apu0 (planted)
    for _ in range(3):
        body.u(0, 1)
    for _ in range(6):                    # $F0 fields
        body.u(0, 1)
    body.u(1, 1)                          # iplromEnable
    body.u(0, 1)                          # dspAddr
    for _ in range(4):
        body.u(0, 1)
    body.u(0, 1)
    body.u(0, 1)                          # aux4 aux5
    for _ in range(3):                    # timers
        for w in (1, 1, 1, 1, 1, 1, 1):
            body.u(0, w)
    # ppu (fast layout)
    body.u(0, 1)
    body.u(0, 1)
    body.u(225, 4)                        # display
    thread()
    ppucounter()
    for w in (1, 1, 1, 1, 1, 2, 1, 1, 2, 1, 1, 1, 1, 1,
              1, 1, 1, 1):                # latch (+ ppu1/ppu2 mdr,bgofs)
        body.u(0, w)
    for w in (1, 1, 2, 2, 1, 1, 1, 1, 1, 1, 2, 1, 1, 2, 2,
              1, 1, 1, 1):                # io scalars
        body.u(0, w)
    body.u(1, 1)
    body.u(0, 1)                          # mosaic size/counter
    for w in (1, 1, 4, 2, 2, 2, 2, 2, 2, 2, 2):   # mode7
        body.u(0, w)
    for _ in range(4):                    # window positions
        body.u(0, 1)
    for _ in range(4):                    # bg1..bg4
        for w in (1, 1, 1, 1, 4, 1, 1):   # WindowLayer
            body.u(0, w)
        for w in (1, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 1):  # bg fields
            body.u(0, w)
    for w in (1, 1, 1, 1, 4, 1, 1):       # obj WindowLayer
        body.u(0, w)
    for w in (1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1):   # obj fields
        body.u(0, w)
    for w in (1, 1, 1, 1, 4, 4, 4):       # col WindowColor
        body.u(0, w)
    for w in (1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2):      # col fields
        body.u(0, w)
    body.arr(bytes(64 * 1024))            # vram
    body.arr(bytes(512))                  # cgram
    for _ in range(128):                  # objects
        for w in (2, 1, 1, 1, 1, 1, 1, 1, 1):
            body.u(0, w)
    # dsp
    body.arr(bytes(64 * 1024))            # apuram
    body.arr(bytes(8192 * 2))             # samplebuffer
    body.u(0x77, 8)                       # clock (planted)
    body.arr(bytes(640))                  # spc_dsp blob
    # simulated coprocessor residue (chip firewall exerciser)
    body.arr(b"\x5A" * chip_extra)

    total = 538 + len(body.buf)
    s.u(0x31545342, 4)
    s.u(total, 4)
    ver = b"115.1"
    s.arr(ver + bytes(16 - len(ver)))
    s.arr(bytes(512))                     # description
    s.u(synchronize, 1)
    s.u(fastppu, 1)
    s.arr(bytes(body.buf))
    assert len(s.buf) == total
    return bytes(s.buf)


def bst_container(stream: bytes) -> bytes:
    rle = rle1_encode(stream)
    out = struct.pack("<III", 0x5A220000, len(rle), 0)
    return out + rle


# ---------------------------------------------------------------- main ---

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    files = {
        "synthetic_v0.mss": build_mss_v0(),
        "synthetic_chipcart.mss": build_mss_chipcart(),
        "synthetic_truncated.mss": build_mss_v0()[:-3],
        "synthetic_v0.bst": bst_container(bst_stream()),
        "synthetic_sync0.bst": bst_container(bst_stream(synchronize=0)),
        "synthetic_chipresidual.bst":
            bst_container(bst_stream(chip_extra=32)),
    }
    manifest = []
    for name, data in sorted(files.items()):
        (OUT / name).write_bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        manifest.append(f"{digest}  {name}")
        print(f"{name}: {len(data)} bytes sha256={digest[:16]}...")
    (OUT / "fixtures.sha256").write_text("\n".join(manifest) + "\n")
    print(f"wrote {len(files)} fixtures + manifest to {OUT}")


if __name__ == "__main__":
    main()
