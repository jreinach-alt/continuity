"""Spike T2.0 harness — donor-template bsnes ``.bst`` encoder (P2, G2/G3).

The design-doc encode strategy (spec H6): boot the pinned bsnes headless at
power-on, serialize -> a **donor** ``.bst`` carrying every emulator-internal
field in a self-consistent configuration from bsnes's own code path. Then
overwrite the *architectural* fields with the CMS values decoded from a Mesen2
``.mss`` capture and emit. Synthesis is written FROM the target's own load
path, so the loader accepts it (G2) and — with the register-file domains
transplanted — StateProbe's WAI resumes into a healthy NMI, the audit
re-runs, the beacon epoch ADVANCES, and the pass bitmap reaches 0x3F8F (G3).

Primitives (P1 convention — the oracles ARE the decode/layout tools; the C
formalization ``transmute_snes.c`` is the P2 follow-on):
  * cms_decode.MesenRecords : one-shot mss_dump decode of every keyed record
                              (byte-exact, validated against Mesen in C4a).
  * bst_dump -O             : positional offset map of the bsnes payload
                              (every field's byte offset + length), so we
                              overwrite in place without re-deriving the walk.
  * bst.py                  : payload unwrap/rewrap (RLE + 12-byte container).

Register-file transforms (Session 5 — the G3 body). Every field is pinned in
``cms/mapping_mesen2_bsnes.json``; bsnes decode semantics are transcribed from
the vendored ``sfc/{cpu,smp,ppu-fast,dsp}`` sources at the pin:

  * Raw byte arrays (identical semantics both emulators): WRAM, VRAM, CGRAM,
    SRAM, ARAM.
  * 65C816 register file: pc=(k<<16)|pc, PS flag unpack, StopState->wai/stp.
  * CPU I/O ($42xx) + timing: nmiEnable/hirq/virq/autoJoypadPoll (Mesen
    exposes these pre-unpacked), htime=(dot+1)<<2, vtime, ALU mul/div result
    registers, joypads, WRIO, WRAM port address, PPU counter vcounter/hcounter
    (the WAI-resume gate).
  * PPU register file: display + all ppufast.io.* + ppufast.latch.* — the
    VRAM prefetch (latch.vram) + address, CGRAM address/latch, mode7 A/B
    (M7-product), and H/V latch that C4 proved load-bearing.
  * Structured OAM: raw 544-byte OAM low/high tables -> ppufast.object[128]
    (readObject/writeObject bit-packing, object.y = raw+1).
  * SMP/SPC700: register file (ya=(y<<8)|a, PSW unpack), I/O ports
    (apu0-3<-port_to_cpu, cpu0-3<-port_from_cpu), TEST/$F0 bits, timers — the
    mailbox-continuity (domain 11) transplant.
  * DSP blob: the 640-byte SPC_DSP ``copy_state`` blob rebuilt from Mesen's
    ``spc.dsp.*`` records in blargg order (domain 5 is a v0 audit blind spot,
    so this is pipeline-completeness, not a G3 gate; env_mode enum + step-unit
    crosswalks are documented P2 residuals).

emulator-internal micro-op scratch (wdc.z/mar/u/v/w, thread frequencies,
sample buffers, DMA clock counters) is left at the donor's self-consistent
power-on value — quiescent-safe at an instruction boundary (H3).
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import bst  # noqa: E402
import cms_decode  # noqa: E402
from cms_decode import MesenRecords  # noqa: E402


# Architectural byte-array domains that are raw + same-semantics both sides.
# (cms record via mss_dump) -> (bsnes payload field name in the -O offset map).
# OAM is intentionally absent (structured in bsnes fastPPU — overwrite_oam).
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
    import subprocess
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


class _Writer:
    """Byte-exact field writer over the unwrapped donor payload.

    Every write is bounds- and width-checked against the offset map so a
    wrong field name or a width mismatch is a loud error, never a silent
    corrupt transplant. Records which bsnes fields were touched (for the G3
    report) and which mapping domains contributed.
    """

    def __init__(self, buf: bytearray, offs: dict):
        self.buf = buf
        self.offs = offs
        self.written = []

    def put(self, name: str, value: int):
        if name not in self.offs:
            raise EncodeError(f"donor offset map missing field {name!r}")
        off, length = self.offs[name]
        v = int(value) & ((1 << (8 * length)) - 1)
        self.buf[off:off + length] = v.to_bytes(length, "little")
        self.written.append(name)

    def put_bytes(self, name: str, data: bytes):
        if name not in self.offs:
            raise EncodeError(f"donor offset map missing field {name!r}")
        off, length = self.offs[name]
        if len(data) != length:
            raise EncodeError(
                f"{name}: field is {length} bytes but source is {len(data)}"
            )
        self.buf[off:off + length] = data
        self.written.append(name)


# ---------------------------------------------------------------------------
# CPU — 65C816 register file (§cpu wdc)
# ---------------------------------------------------------------------------
def overwrite_cpu(w: _Writer, m: MesenRecords) -> None:
    w.put("cpu.wdc.pc", (m.u("cpu.k") << 16) | m.u("cpu.pc"))
    w.put("cpu.wdc.a", m.u("cpu.a"))
    w.put("cpu.wdc.x", m.u("cpu.x"))
    w.put("cpu.wdc.y", m.u("cpu.y"))
    w.put("cpu.wdc.s", m.u("cpu.sp"))
    w.put("cpu.wdc.d", m.u("cpu.d"))
    w.put("cpu.wdc.b", m.u("cpu.dbr"))
    ps = m.u("cpu.ps")  # NVMXDIZC packed byte
    for i, flag in enumerate(["c", "z", "i", "d", "x", "m", "v", "n"]):
        w.put(f"cpu.wdc.p.{flag}", (ps >> i) & 1)
    w.put("cpu.wdc.e", m.u("cpu.emulationMode"))
    w.put("cpu.wdc.mdr", m.u("memoryManager.openBus"))
    # StopState enum {0 Running, 1 Stopped, 2 WaitingForIrq}
    stop = m.u("cpu.stopState")
    w.put("cpu.wdc.wai", 1 if stop == 2 else 0)
    w.put("cpu.wdc.stp", 1 if stop == 1 else 0)


# ---------------------------------------------------------------------------
# CPU — I/O registers ($42xx) + PPU counter (timing) + ALU (§cpu tail/io)
#
# THE WAI-RESUME GATE: the capture parks the CPU in WAI waiting for the vblank
# NMI, but the power-on donor has nmiEnable=0 -> no NMI fires -> the epoch
# freezes. Mesen serializes internalRegisters.enableNmi already unpacked, so
# nmiEnable/hirq/virq/autoJoypadPoll are direct copies (no $4200 bit-unpack).
# ---------------------------------------------------------------------------
def overwrite_cpu_io(w: _Writer, m: MesenRecords) -> None:
    # PPU counter (timing) — vcounter/hcounter carry; periods recompute at
    # steady state so the donor's are already correct for this region.
    w.put("cpu.counter.time.vcounter", m.u("ppu.scanline"))
    w.put("cpu.counter.time.hcounter", m.u("memoryManager.hClock"))
    w.put("cpu.counter.time.field", m.u("ppu.oddFrame"))

    # $4200 NMITIMEN — Mesen exposes the decoded enables directly.
    w.put("cpu.io.nmiEnable", m.u("internalRegisters.enableNmi"))
    w.put("cpu.io.hirqEnable", m.u("internalRegisters.enableHorizontalIrq"))
    w.put("cpu.io.virqEnable", m.u("internalRegisters.enableVerticalIrq"))
    w.put("cpu.io.irqEnable", 0)  # composite h|v; donor-checked 0 (P2 pin)
    w.put("cpu.io.autoJoypadPoll",
          m.u("internalRegisters.enableAutoJoypadRead"))
    w.put("cpu.status.autoJoypadCounter", 33)  # 33 = inactive (cpu.hpp:118)

    # $4207-420A HTIME/VTIME — bsnes stores (dot+1)<<2 master-clock comparator
    # (sfc/cpu/io.cpp:204-215); Mesen stores the raw dot.
    w.put("cpu.io.htime",
          ((m.u("internalRegisters.horizontalTimer") + 1) << 2) & 0xFFFF)
    w.put("cpu.io.vtime", m.u("internalRegisters.verticalTimer"))

    # $420D MEMSEL, $4201 WRIO
    w.put("cpu.io.fastROM", m.u("internalRegisters.enableFastRom"))
    w.put("cpu.io.pio", m.u("internalRegisters.ioPortOutput"))

    # $4202-4206 / $4214-4217 ALU multiply/divide register file (domain 8).
    w.put("cpu.io.wrmpya", m.u("internalRegisters.aluMulDiv.multOperand1"))
    w.put("cpu.io.wrmpyb", m.u("internalRegisters.aluMulDiv.multOperand2"))
    w.put("cpu.io.wrdiva", m.u("internalRegisters.aluMulDiv.dividend"))
    w.put("cpu.io.wrdivb", m.u("internalRegisters.aluMulDiv.divisor"))
    w.put("cpu.io.rddiv", m.u("internalRegisters.aluMulDiv.divResult"))
    w.put("cpu.io.rdmpy",
          m.u("internalRegisters.aluMulDiv.multOrRemainderResult"))

    # $4218-421F auto-read controller results.
    for i in range(4):
        w.put(f"cpu.io.joy{i + 1}",
              m.u(f"internalRegisters.controllerData[{i}]"))

    # $2181-83 WRAM data-port address (17-bit).
    w.put("cpu.io.wramAddress",
          m.u("memoryManager.registerHandlerB.wramPosition") & 0x1FFFF)


# ---------------------------------------------------------------------------
# PPU — fastPPU register file (§ppu_fastppu_true)
#
# bsnes stores DECODED register forms; Mesen exposes the same decoded forms
# under different names. Each field is mapped to its Mesen equivalent (or a
# small bit derivation) — verified value-for-value against the beacon capture.
# Gating for the pass bitmap: latch.vram + io.vram* (VRAM domain 1), io.cgram*
# (CGRAM domain 2), io.mode7.a/b (CPU_MATH domain 8), io.hcounter/vcounter +
# latch counters (HV_LATCH domain 10). The render-pipeline fields (bg tile
# bases, windows, colour math beyond mode7 A/B) feed the harness-side witness
# frame, not the CPU-readable bitmap, but are transplanted for faithfulness.
# ---------------------------------------------------------------------------
def overwrite_ppu(w: _Writer, m: MesenRecords) -> None:
    # display prefix (recompute from setini bits)
    w.put("ppu.display.interlace", m.u("ppu.screenInterlace"))
    w.put("ppu.display.overscan", m.u("ppu.overscanMode"))
    w.put("ppu.display.vdisp", 240 if m.u("ppu.overscanMode") else 225)

    # latch — VRAM prefetch (domain 1) + write buffers + counter latch phase
    w.put("ppufast.latch.vram", m.u("ppu.vramReadBuffer"))
    w.put("ppufast.latch.oam", m.u("ppu.oamWriteBuffer"))
    w.put("ppufast.latch.cgram", m.u("ppu.cgramWriteBuffer"))
    w.put("ppufast.latch.oamAddress", m.u("ppu.internalOamAddress"))
    w.put("ppufast.latch.cgramAddress", m.u("ppu.internalCgramAddress"))
    w.put("ppufast.latch.mode7", m.u("ppu.mode7.valueLatch"))
    w.put("ppufast.latch.counters", m.u("ppu.locationLatched"))
    w.put("ppufast.latch.hcounter", m.u("ppu.horizontalLocToggle"))
    w.put("ppufast.latch.vcounter", m.u("ppu.verticalLocationToggle"))
    w.put("ppufast.latch.ppu1.mdr", m.u("ppu.ppu1OpenBus"))
    w.put("ppufast.latch.ppu1.bgofs", m.u("ppu.hvScrollLatchValue"))
    w.put("ppufast.latch.ppu2.mdr", m.u("ppu.ppu2OpenBus"))
    w.put("ppufast.latch.ppu2.bgofs", m.u("ppu.hScrollLatchValue"))

    # io — display / OAM addressing
    w.put("ppufast.io.displayDisable", m.u("ppu.forcedBlank"))
    w.put("ppufast.io.displayBrightness", m.u("ppu.screenBrightness"))
    w.put("ppufast.io.oamBaseAddress", m.u("ppu.oamRamAddress") << 1)
    w.put("ppufast.io.oamAddress", m.u("ppu.internalOamAddress"))
    w.put("ppufast.io.oamPriority", m.u("ppu.enableOamPriority"))

    # io — BG mode / VRAM address (domain 1)
    w.put("ppufast.io.bgPriority", m.u("ppu.mode1Bg3Priority"))
    w.put("ppufast.io.bgMode", m.u("ppu.bgMode"))
    w.put("ppufast.io.vramIncrementMode",
          m.u("ppu.vramAddrIncrementOnSecondReg"))
    w.put("ppufast.io.vramMapping", m.u("ppu.vramAddressRemapping"))
    w.put("ppufast.io.vramIncrementSize", m.u("ppu.vramIncrementValue"))
    w.put("ppufast.io.vramAddress", m.u("ppu.vramAddress"))

    # io — CGRAM address (domain 2)
    w.put("ppufast.io.cgramAddress", m.u("ppu.cgramAddress"))
    w.put("ppufast.io.cgramAddressLatch", m.u("ppu.cgramAddressLatch"))

    # io — H/V counter latch (domain 10)
    w.put("ppufast.io.hcounter", m.u("ppu.horizontalLocation"))
    w.put("ppufast.io.vcounter", m.u("ppu.verticalLocation"))

    # io — SETINI screen mode bits
    w.put("ppufast.io.interlace", m.u("ppu.screenInterlace"))
    w.put("ppufast.io.overscan", m.u("ppu.overscanMode"))
    w.put("ppufast.io.pseudoHires", m.u("ppu.hiResMode"))
    w.put("ppufast.io.extbg", m.u("ppu.extBgEnabled"))

    # io — mosaic
    w.put("ppufast.io.mosaic.size", m.u("ppu.mosaicSize"))
    w.put("ppufast.io.mosaic.counter", 0)  # row phase; frame-edge recompute

    # io — mode7 matrix (a/b drive the $2134-36 product, domain 8)
    w.put("ppufast.io.mode7.hflip", m.u("ppu.mode7.horizontalMirroring"))
    w.put("ppufast.io.mode7.vflip", m.u("ppu.mode7.verticalMirroring"))
    w.put("ppufast.io.mode7.repeat",
          (m.u("ppu.mode7.largeMap") << 1) | m.u("ppu.mode7.fillWithTile0"))
    w.put("ppufast.io.mode7.a", m.u("ppu.mode7.matrix[0]"))
    w.put("ppufast.io.mode7.b", m.u("ppu.mode7.matrix[1]"))
    w.put("ppufast.io.mode7.c", m.u("ppu.mode7.matrix[2]"))
    w.put("ppufast.io.mode7.d", m.u("ppu.mode7.matrix[3]"))
    w.put("ppufast.io.mode7.x", m.u("ppu.mode7.centerX"))
    w.put("ppufast.io.mode7.y", m.u("ppu.mode7.centerY"))
    w.put("ppufast.io.mode7.hoffset", m.u("ppu.mode7.hscroll"))
    w.put("ppufast.io.mode7.voffset", m.u("ppu.mode7.vscroll"))

    # io — window position registers
    w.put("ppufast.io.window.oneLeft", m.u("ppu.window[0].left"))
    w.put("ppufast.io.window.oneRight", m.u("ppu.window[0].right"))
    w.put("ppufast.io.window.twoLeft", m.u("ppu.window[1].left"))
    w.put("ppufast.io.window.twoRight", m.u("ppu.window[1].right"))

    # io — per-BG render config (witness-frame only; transplanted for fidelity)
    _TILEMODE_BY_BGMODE = {  # (bg1,bg2,bg3,bg4) TileMode enum per BGMODE
        0: (0, 0, 0, 0), 1: (1, 1, 0, 4), 2: (1, 1, 4, 4),
        3: (2, 1, 4, 4), 4: (2, 0, 4, 4), 5: (1, 1, 4, 4),
        6: (1, 4, 4, 4), 7: (3, 4, 4, 4),
    }
    bgmode = m.u("ppu.bgMode")
    tilemodes = _TILEMODE_BY_BGMODE.get(bgmode, (4, 4, 4, 4))
    main = m.u("ppu.mainScreenLayers")
    sub = m.u("ppu.subScreenLayers")
    mos = m.u("ppu.mosaicEnabled")
    for idx, bg in enumerate(("bg1", "bg2", "bg3", "bg4")):
        p = f"ppufast.io.{bg}"
        w.put(f"{p}.window.oneEnable", m.u(f"ppu.window[0].activeLayers[{idx}]"))
        w.put(f"{p}.window.oneInvert",
              m.u(f"ppu.window[0].invertedLayers[{idx}]"))
        w.put(f"{p}.window.twoEnable", m.u(f"ppu.window[1].activeLayers[{idx}]"))
        w.put(f"{p}.window.twoInvert",
              m.u(f"ppu.window[1].invertedLayers[{idx}]"))
        w.put(f"{p}.window.mask", m.u(f"ppu.maskLogic[{idx}]"))
        w.put(f"{p}.window.aboveEnable", m.u(f"ppu.windowMaskMain[{idx}]"))
        w.put(f"{p}.window.belowEnable", m.u(f"ppu.windowMaskSub[{idx}]"))
        w.put(f"{p}.aboveEnable", (main >> idx) & 1)
        w.put(f"{p}.belowEnable", (sub >> idx) & 1)
        w.put(f"{p}.mosaicEnable", (mos >> idx) & 1)
        w.put(f"{p}.tiledataAddress", m.u(f"ppu.layers[{idx}].chrAddress"))
        w.put(f"{p}.screenAddress", m.u(f"ppu.layers[{idx}].tilemapAddress"))
        w.put(f"{p}.screenSize",
              m.u(f"ppu.layers[{idx}].doubleWidth")
              | (m.u(f"ppu.layers[{idx}].doubleHeight") << 1))
        w.put(f"{p}.tileSize", m.u(f"ppu.layers[{idx}].largeTiles"))
        w.put(f"{p}.hoffset", m.u(f"ppu.layers[{idx}].hscroll"))
        w.put(f"{p}.voffset", m.u(f"ppu.layers[{idx}].vscroll"))
        w.put(f"{p}.tileMode", tilemodes[idx])

    # io — OBJ render config (OBSEL); tile bases are witness-frame only.
    w.put("ppufast.io.obj.window.oneEnable", m.u("ppu.window[0].activeLayers[4]"))
    w.put("ppufast.io.obj.window.oneInvert",
          m.u("ppu.window[0].invertedLayers[4]"))
    w.put("ppufast.io.obj.window.twoEnable", m.u("ppu.window[1].activeLayers[4]"))
    w.put("ppufast.io.obj.window.twoInvert",
          m.u("ppu.window[1].invertedLayers[4]"))
    w.put("ppufast.io.obj.window.mask", m.u("ppu.maskLogic[4]"))
    w.put("ppufast.io.obj.window.aboveEnable", m.u("ppu.windowMaskMain[4]"))
    w.put("ppufast.io.obj.window.belowEnable", m.u("ppu.windowMaskSub[4]"))
    w.put("ppufast.io.obj.aboveEnable", (main >> 4) & 1)
    w.put("ppufast.io.obj.belowEnable", (sub >> 4) & 1)
    w.put("ppufast.io.obj.interlace", m.u("ppu.objInterlace"))
    w.put("ppufast.io.obj.baseSize", m.u("ppu.oamMode"))
    # nameselect: Mesen oamAddressOffset = (nameselect+1)<<13 bytes ->
    # (nameselect+1)<<12 words; recover nameselect (0 when offset==0x1000).
    offw = m.u("ppu.oamAddressOffset")
    w.put("ppufast.io.obj.nameselect", (offw >> 12) - 1 if offw else 0)
    w.put("ppufast.io.obj.tiledataAddress", m.u("ppu.oamBaseAddress"))
    w.put("ppufast.io.obj.rangeOver", m.u("ppu.rangeOver"))
    w.put("ppufast.io.obj.timeOver", m.u("ppu.timeOver"))

    # io — colour math (CGWSEL/CGADSUB/COLDATA); witness-frame only except
    # fixedColor carries the exact BGR555 backdrop.
    w.put("ppufast.io.col.window.oneEnable", m.u("ppu.window[0].activeLayers[5]"))
    w.put("ppufast.io.col.window.oneInvert",
          m.u("ppu.window[0].invertedLayers[5]"))
    w.put("ppufast.io.col.window.twoEnable", m.u("ppu.window[1].activeLayers[5]"))
    w.put("ppufast.io.col.window.twoInvert",
          m.u("ppu.window[1].invertedLayers[5]"))
    w.put("ppufast.io.col.window.mask", m.u("ppu.maskLogic[5]"))
    w.put("ppufast.io.col.window.aboveMask", m.u("ppu.colorMathClipMode"))
    w.put("ppufast.io.col.window.belowMask", m.u("ppu.colorMathPreventMode"))
    cme = m.u("ppu.colorMathEnabled")  # per-source bitmask
    # bsnes col.enable[] order: BG1,BG2,BG3,BG4,OBJ1,OBJ2,COL; OBJ1 always 0.
    for i, bitpos in enumerate((0, 1, 2, 3, None, 4, 5)):
        w.put(f"ppufast.io.col.enable[{i}]",
              0 if bitpos is None else (cme >> bitpos) & 1)
    w.put("ppufast.io.col.directColor", m.u("ppu.directColorMode"))
    w.put("ppufast.io.col.blendMode", m.u("ppu.colorMathAddSubscreen"))
    w.put("ppufast.io.col.halve", m.u("ppu.colorMathHalveResult"))
    w.put("ppufast.io.col.mathMode", m.u("ppu.colorMathSubtractMode"))
    w.put("ppufast.io.col.fixedColor", m.u("ppu.fixedColor"))


# ---------------------------------------------------------------------------
# OAM — raw 544 bytes -> ppufast.object[128] (domain 3)
#
# bit-packing pinned against sfc/ppu-fast/object.cpp readObject/writeObject:
#   low table 4 bytes/sprite: x-low, (y = raw+1), character,
#     attr = vflip<<7|hflip<<6|priority<<4|palette<<1|nameselect
#   high table 2 bits/sprite: bit (n%4)*2 = x bit8, bit (n%4)*2+1 = size
# ---------------------------------------------------------------------------
def overwrite_oam(w: _Writer, oam: bytes) -> None:
    if len(oam) != 544:
        raise EncodeError(f"OAM is {len(oam)} bytes, expected 544")
    for n in range(128):
        lo = oam[n * 4:n * 4 + 4]
        x_low, y_raw, character, attr = lo[0], lo[1], lo[2], lo[3]
        hbyte = oam[512 + (n >> 2)]
        shift = (n & 3) * 2
        x_bit8 = (hbyte >> shift) & 1
        size = (hbyte >> (shift + 1)) & 1
        p = f"ppufast.object[{n}]"
        w.put(f"{p}.x", x_low | (x_bit8 << 8))
        w.put(f"{p}.y", (y_raw + 1) & 0xFF)  # +1: rendering one scanline late
        w.put(f"{p}.character", character)
        w.put(f"{p}.nameselect", attr & 1)
        w.put(f"{p}.palette", (attr >> 1) & 7)
        w.put(f"{p}.priority", (attr >> 4) & 3)
        w.put(f"{p}.hflip", (attr >> 6) & 1)
        w.put(f"{p}.vflip", (attr >> 7) & 1)
        w.put(f"{p}.size", size)


# ---------------------------------------------------------------------------
# SMP / SPC700 — register file + I/O ports + timers (§smp; domain 11 mailbox)
# ---------------------------------------------------------------------------
def overwrite_smp(w: _Writer, m: MesenRecords) -> None:
    w.put("smp.spc700.pc", m.u("spc.pc"))
    w.put("smp.spc700.ya", (m.u("spc.y") << 8) | m.u("spc.a"))
    w.put("smp.spc700.x", m.u("spc.x"))
    w.put("smp.spc700.s", m.u("spc.sp"))
    psw = m.u("spc.ps")  # NVPBHIZC packed byte
    for i, flag in enumerate(["c", "z", "i", "h", "b", "p", "v", "n"]):
        w.put(f"smp.spc700.p.{flag}", (psw >> i) & 1)
    # Mesen 2.1.1 does not serialize spc.stopState; StateProbe's SPC runs an
    # echo loop (never SLEEP/STOP). Set both false (== donor, running).
    w.put("smp.spc700.wait", 0)
    w.put("smp.spc700.stop", 0)

    # I/O ports — the mailbox. bsnes names are cross-wired vs intuition
    # (sfc/smp/io.cpp): io.apu* is the CPU->SMP latch (CPU writes $2140-43 ->
    # io.apu; SPC reads $F4-F7 -> io.apu), io.cpu* is the SMP->CPU latch (SPC
    # writes -> io.cpu; CPU reads -> io.cpu). Mesen's cpuRegs = CPU->SMP,
    # outputReg = SMP->CPU. So the correct crosswalk is apu<-cpuRegs,
    # cpu<-outputReg (names lie, bits don't).
    for i in range(4):
        w.put(f"smp.io.apu{i}", m.u(f"spc.cpuRegs[{i}]"))    # CPU->SMP
        w.put(f"smp.io.cpu{i}", m.u(f"spc.outputReg[{i}]"))  # SMP->CPU
    w.put("smp.io.aux4", m.u("spc.ramReg[0]"))
    w.put("smp.io.aux5", m.u("spc.ramReg[1]"))
    w.put("smp.io.dspAddr", m.u("spc.dspReg"))
    w.put("smp.io.iplromEnable", m.u("spc.romEnabled"))

    # $F0 TEST decomposition (Mesen splits it into named fields).
    w.put("smp.io.timersDisable", m.u("spc.timersDisabled"))
    w.put("smp.io.ramWritable", m.u("spc.writeEnabled"))
    w.put("smp.io.timersEnable", m.u("spc.timersEnabled"))
    w.put("smp.io.externalWaitStates", m.u("spc.externalSpeed"))
    w.put("smp.io.internalWaitStates", m.u("spc.internalSpeed"))
    # ramDisable ($F0 bit2): Mesen does not expose it; leave donor (0).

    # timers — bsnes stream order stage0,stage1,stage2,stage3,line,enable,
    # target (smp/serialization.cpp:31-53). Mesen: stage0/stage1/stage2/output
    # /prevStage1(edge)/enabled/target. stage3 (4-bit read-to-clear output)
    # <- Mesen 'output'; bsnes 'line' <- Mesen 'prevStage1' (stage-1 edge
    # memory). Both model the same divider chain (open_p2_pin: stage crosswalk).
    for t in range(3):
        s = f"spc.timer{t}"
        d = f"smp.timer{t}"
        w.put(f"{d}.stage0", m.u(f"{s}.stage0"))
        w.put(f"{d}.stage1", m.u(f"{s}.stage1"))
        w.put(f"{d}.stage2", m.u(f"{s}.stage2"))
        w.put(f"{d}.stage3", m.u(f"{s}.output"))
        w.put(f"{d}.line", m.u(f"{s}.prevStage1"))
        w.put(f"{d}.enable", m.u(f"{s}.enabled"))
        w.put(f"{d}.target", m.u(f"{s}.target"))


# ---------------------------------------------------------------------------
# DMA — cpu.channel[0..7] register residue (§cpu channels; domain 12)
#
# $43x0 DMAP bit crosswalk (names lie, bits don't): Mesen 'invertDirection' =
# bsnes 'direction' (bit7), 'hdmaIndirectAddressing'='indirect' (bit6),
# 'unusedControlFlag'='unused' (bit5), 'decrement'='reverseTransfer' (bit4),
# 'fixedTransfer'='fixedTransfer' (bit3), 'transferMode'='transferMode'(0-2).
# ---------------------------------------------------------------------------
def overwrite_dma(w: _Writer, m: MesenRecords) -> None:
    hdmaen = m.u("dmaController.hdmaChannels")  # $420C HDMAEN bitmask
    for ch in range(8):
        s = f"dmaController.channel[{ch}]"
        d = f"cpu.channel[{ch}]"
        # $420B MDMAEN is transient (quiescent: 0); $420C HDMAEN carries.
        w.put(f"{d}.dmaEnable", 0)
        w.put(f"{d}.hdmaEnable", (hdmaen >> ch) & 1)
        w.put(f"{d}.direction", m.u(f"{s}.invertDirection"))
        w.put(f"{d}.indirect", m.u(f"{s}.hdmaIndirectAddressing"))
        w.put(f"{d}.unused", m.u(f"{s}.unusedControlFlag"))
        w.put(f"{d}.reverseTransfer", m.u(f"{s}.decrement"))
        w.put(f"{d}.fixedTransfer", m.u(f"{s}.fixedTransfer"))
        w.put(f"{d}.transferMode", m.u(f"{s}.transferMode"))
        w.put(f"{d}.targetAddress", m.u(f"{s}.destAddress"))
        w.put(f"{d}.sourceAddress", m.u(f"{s}.srcAddress"))
        w.put(f"{d}.sourceBank", m.u(f"{s}.srcBank"))
        w.put(f"{d}.transferSize", m.u(f"{s}.transferSize"))
        w.put(f"{d}.indirectBank", m.u(f"{s}.hdmaBank"))
        w.put(f"{d}.hdmaAddress", m.u(f"{s}.hdmaTableAddress"))
        w.put(f"{d}.lineCounter", m.u(f"{s}.hdmaLineCounterAndRepeat"))
        w.put(f"{d}.unknown", m.u(f"{s}.unusedRegister"))
        w.put(f"{d}.hdmaCompleted", m.u(f"{s}.hdmaFinished"))
        w.put(f"{d}.hdmaDoTransfer", m.u(f"{s}.doTransfer"))


def encode(mss_path: str, donor_bst: str, out_bst: str,
           mss_dump: str, bst_dump: str, sram_bytes: int = 8192,
           dsp_blob: bool = True) -> dict:
    """Rebuild a bsnes ``.bst`` from a Mesen ``.mss`` over a power-on donor.

    Returns a report of which domains were overwritten (for the G3 matrix).
    """
    with open(donor_bst, "rb") as fh:
        donor_raw = fh.read()
    payload = bytearray(bst.bst_unwrap(donor_raw))
    offs = payload_offsets(bst_dump, donor_bst, sram_bytes)
    m = MesenRecords(mss_dump, mss_path)
    w = _Writer(payload, offs)

    # 1. raw byte-array domains (identical semantics)
    raw_domains = []
    for mss_key, bsnes_name in _RAW_ARRAY_MAP:
        w.put_bytes(bsnes_name, m.array(mss_key))
        raw_domains.append(bsnes_name)

    # 2. register-file transforms
    overwrite_cpu(w, m)
    overwrite_cpu_io(w, m)
    overwrite_ppu(w, m)
    overwrite_oam(w, m.array("ppu.oamRam"))
    overwrite_smp(w, m)
    overwrite_dma(w, m)
    dsp_note = "skipped"
    if dsp_blob:
        import dsp_blob as _dsp  # local import: optional transform
        blob = _dsp.build_blob(m)
        w.put_bytes("dsp.spc_dsp_blob", blob)
        dsp_note = f"{len(blob)} bytes (blargg copy_state order)"

    rebuilt = bst.bst_wrap(bytes(payload))
    with open(out_bst, "wb") as fh:
        fh.write(rebuilt)

    return {
        "out": out_bst,
        "out_bytes": len(rebuilt),
        "raw_arrays": raw_domains,
        "register_files": ["cpu.wdc", "cpu.io+timing", "ppu", "oam(objects)",
                           "smp/spc700", "dma.channels"],
        "dsp_blob": dsp_note,
        "fields_written": len(w.written),
        "cpu_pc": (m.u("cpu.k") << 16) | m.u("cpu.pc"),
    }


def _cli(argv=None):
    import argparse
    import json
    p = argparse.ArgumentParser(description="Donor-encode a Mesen .mss -> bsnes .bst")
    p.add_argument("mss")
    p.add_argument("donor")
    p.add_argument("out")
    p.add_argument("--mss-dump", required=True)
    p.add_argument("--bst-dump", required=True)
    p.add_argument("--sram", type=int, default=8192)
    p.add_argument("--no-dsp-blob", action="store_true")
    a = p.parse_args(argv)
    rep = encode(a.mss, a.donor, a.out, a.mss_dump, a.bst_dump, a.sram,
                 dsp_blob=not a.no_dsp_blob)
    print(json.dumps(rep, indent=2))


if __name__ == "__main__":
    _cli()
