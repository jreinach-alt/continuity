"""Spike T2.0 harness — SPC_DSP ``copy_state`` blob builder (P2, domain 5).

bsnes serializes the DSP as a fixed 640-byte blob produced by blargg's
``SPC_DSP::copy_state`` (sfc/dsp/SPC_DSP.cpp:949-1016 @ pin) — 514 meaningful
bytes zero-padded to ``state_size``. This module rebuilds those exact bytes
from Mesen2's structured ``spc.dsp.*`` records (Core/SNES/DSP/Dsp.cpp +
DspVoice.cpp), so the bsnes ``dsp.spc_dsp_blob`` field carries the captured
DSP state rather than the donor's power-on silence.

Encoding rule (SPC_DSP.h SPC_COPY + SPC_State_Copier::copy_int): every scalar
is emitted little-endian at ``sizeof(type)``; ``copier.extra()`` emits a single
zero byte; the u8-array fields (regs, per-voice BRR buffer, echo history) are
copied verbatim — both emulators hold them as LE int16 / raw u8, same order.

DSP is domain 5, a v0 audit BLIND SPOT (not in the 0x3F8F pass bitmap), so the
blob is pipeline-completeness rather than a G3 gate. Two crosswalks remain P2
residuals (mapping open_p2_pins), immaterial to a quiescent tone-loop capture:
  * ``env_mode`` enum values (Mesen envMode vs blargg env_mode_t) — copied low
    byte; both use 0=release,1=attack,2=decay,3=sustain in practice.
  * ``step`` <-> ``phase`` sample-cycle unit — copied verbatim (both count the
    32-clock sample cadence).
"""

import struct


def _le(value: int, width: int) -> bytes:
    return (int(value) & ((1 << (8 * width)) - 1)).to_bytes(width, "little")


def build_blob(m) -> bytes:
    """Return the 640-byte SPC_DSP blob for the bsnes ``dsp.spc_dsp_blob``."""
    out = bytearray()

    # DSP registers ($00-$7F), raw copy.
    regs = m.array("spc.dsp.regs")
    if len(regs) != 128:
        raise ValueError(f"spc.dsp.regs is {len(regs)} bytes, expected 128")
    out += regs

    # 8 voices — blargg per-voice order.
    for i in range(8):
        v = f"spc.dsp.voices[{i}]"
        buf = m.array(f"{v}.sampleBuffer")  # 12 x int16 = 24 bytes, verbatim
        if len(buf) != 24:
            raise ValueError(f"{v}.sampleBuffer is {len(buf)} bytes, expected 24")
        out += buf
        out += _le(m.u(f"{v}.interpolationPos"), 2)
        out += _le(m.u(f"{v}.brrAddress"), 2)
        out += _le(m.u(f"{v}.envVolume"), 2)
        out += _le(m.u(f"{v}.prevCalculatedEnv"), 2)   # hidden_env (int16)
        out += _le(m.u(f"{v}.bufferPos"), 1)
        out += _le(m.u(f"{v}.brrOffset"), 1)
        out += _le(m.u(f"{v}.keyOnDelay"), 1)
        out += _le(m.u(f"{v}.envMode"), 1)             # enum crosswalk (P2 pin)
        out += _le(m.u(f"{v}.envOut"), 1)              # t_envx_out
        out += b"\x00"                                 # copier.extra()

    # Echo history — 8 x 2 x int16 = 32 bytes, verbatim.
    echo_hist = m.array("spc.dsp.echoHistory")
    if len(echo_hist) != 32:
        raise ValueError(f"echoHistory is {len(echo_hist)} bytes, expected 32")
    out += echo_hist

    # Misc globals (blargg order).
    out += _le(m.u("spc.dsp.everyOtherSample"), 1)
    out += _le(m.u("spc.dsp.keyOn"), 1)
    out += _le(m.u("spc.dsp.noiseLfsr"), 2)
    out += _le(m.u("spc.dsp.counter"), 2)
    out += _le(m.u("spc.dsp.echoOffset"), 2)
    out += _le(m.u("spc.dsp.echoLength"), 2)
    out += _le(m.u("spc.dsp.step"), 1)                 # phase (step<->phase pin)
    out += _le(m.u("spc.dsp.newKeyOn"), 1)
    out += _le(m.u("spc.dsp.voiceEndBuffer"), 1)       # endx_buf
    out += _le(m.u("spc.dsp.envRegBuffer"), 1)         # envx_buf
    out += _le(m.u("spc.dsp.outRegBuffer"), 1)         # outx_buf
    out += _le(m.u("spc.dsp.pitchModulationOn"), 1)    # t_pmon
    out += _le(m.u("spc.dsp.noiseOn"), 1)              # t_non
    out += _le(m.u("spc.dsp.echoOn"), 1)               # t_eon
    out += _le(m.u("spc.dsp.dirSampleTableAddress"), 1)  # t_dir
    out += _le(m.u("spc.dsp.keyOff"), 1)               # t_koff
    out += _le(m.u("spc.dsp.brrNextAddress"), 2)       # t_brr_next_addr
    out += _le(m.u("spc.dsp.adsr1"), 1)                # t_adsr0
    out += _le(m.u("spc.dsp.brrHeader"), 1)            # t_brr_header
    out += _le(m.u("spc.dsp.brrData"), 1)              # t_brr_byte
    out += _le(m.u("spc.dsp.sourceNumber"), 1)         # t_srcn
    out += _le(m.u("spc.dsp.echoRingBufferAddress"), 1)  # t_esa
    out += _le(m.u("spc.dsp.echoEnabled"), 1)          # t_echo_enabled

    # t_main_out[2], t_echo_out[2], t_echo_in[2] (int16 each).
    # Mesen packs outSamples (8B) = main_out pair; echoOut/echoIn (8B each).
    main = m.array("spc.dsp.outSamples")               # 8 bytes
    eout = m.array("spc.dsp.echoOut")
    ein = m.array("spc.dsp.echoIn")
    out += main[0:2] + main[2:4]                        # t_main_out[0], [1]
    out += eout[0:2] + eout[2:4]                        # t_echo_out[0], [1]
    out += ein[0:2] + ein[2:4]                          # t_echo_in[0], [1]

    out += _le(_dir_addr(m), 2)                         # t_dir_addr
    out += _le(m.u("spc.dsp.pitch"), 2)                 # t_pitch
    out += (m.array("spc.dsp.voiceOutput")[0:2])        # t_output (int16)
    out += _le(m.u("spc.dsp.echoPointer"), 2)           # t_echo_ptr
    out += _le(m.u("spc.dsp.looped"), 1)                # t_looped
    out += b"\x00"                                      # copier.extra()

    if len(out) > 640:
        raise ValueError(f"blob overran: {len(out)} > 640")
    out += b"\x00" * (640 - len(out))                   # zero-pad to state_size
    return bytes(out)


def _dir_addr(m):
    # blargg t_dir_addr is the computed sample-table entry address; Mesen holds
    # sampleAddress (the current voice's BRR start). Non-gating pipeline reg.
    return m.u("spc.dsp.sampleAddress")
