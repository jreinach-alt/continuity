"""Spike T2.0 harness — bsnes `.bst` container + RLE codec (Python side).

Mirror of the C++ host's container logic (bsnes_host.cpp) for the harness
to unwrap/compare states without spawning the core. The RLE<1> (S=1, M=4)
and 12-byte container framing are transcribed from the same pinned source
(nall/encode/rle.hpp + target-bsnes/program/states.cpp). Cross-checked
against the C++ host and `bst_dump` in the control tests.

Also carries the payload layout constants the controls need — notably the
`random.state` field, the one emulator-INTERNAL byte range that legitimately
differs between two independent boots (bsnes seeds its PRNG per power-on
regardless of the entropy hack). Architectural-equivalence comparisons mask
exactly this window.
"""

import struct

BST_SIGNATURE = 0x5A220000  # Program::State::Signature

# --- Serializer payload header layout (System::serialize, plain cart) -------
# signature(4) + serializeSize(4) + version[16] + description[512]
# + synchronize(1) + fastPPU(1) = 538, then serializeAll() begins with the
# `random` block: entropy(4) + state(8) + increment(8).
PAYLOAD_HEADER_LEN = 4 + 4 + 16 + 512 + 1 + 1  # 538
RANDOM_STATE_OFF = PAYLOAD_HEADER_LEN + 4        # 542
RANDOM_STATE_LEN = 8                             # [542, 550)

# The single field that varies between two independent power-ons; masked in
# architectural-equivalence checks (empirically verified: it is the only
# difference between two fresh deterministic-entropy boots).
INTERNAL_MASK_WINDOWS = [(RANDOM_STATE_OFF, RANDOM_STATE_OFF + RANDOM_STATE_LEN)]


def rle_encode(data: bytes) -> bytes:
    out = bytearray()
    n = len(data)
    for byte in range(8):
        out.append((n >> (byte * 8)) & 0xFF)
    base = 0
    skip = 0

    def flush():
        nonlocal base, skip
        out.append((skip - 1) & 0xFF)
        while skip:
            out.append(data[base])
            base += 1
            skip -= 1

    while base + skip < n:
        same = 1
        off = base + skip + 1
        while off < n:
            if data[off] != data[base + skip]:
                break
            same += 1
            if same == 127 + 4:
                break
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


def rle_decode(data: bytes) -> bytes:
    pos = 0

    def load():
        nonlocal pos
        v = data[pos] if pos < len(data) else 0
        pos += 1
        return v

    size = 0
    for byte in range(8):
        size |= load() << (byte * 8)
    out = bytearray(size)
    base = 0

    def write(v):
        nonlocal base
        if base < size:
            out[base] = v
            base += 1

    while base < size:
        byte = load()
        if byte < 128:
            for _ in range(byte + 1):
                write(load())
        else:
            value = load()
            for _ in range((byte & 127) + 4):
                write(value)
    return bytes(out)


def bst_wrap(payload: bytes) -> bytes:
    rle = rle_encode(payload)
    return struct.pack("<III", BST_SIGNATURE, len(rle), 0) + rle


def bst_unwrap(file_bytes: bytes) -> bytes:
    if len(file_bytes) < 12:
        raise ValueError("bst too short")
    sig, rle_state, rle_preview = struct.unpack("<III", file_bytes[:12])
    if sig != BST_SIGNATURE:
        raise ValueError(f"bad signature {sig:#x}")
    if 12 + rle_state + rle_preview != len(file_bytes):
        raise ValueError("container size mismatch")
    return rle_decode(file_bytes[12:12 + rle_state])


def _mask_internal(payload: bytes) -> bytes:
    b = bytearray(payload)
    for lo, hi in INTERNAL_MASK_WINDOWS:
        for i in range(lo, min(hi, len(b))):
            b[i] = 0
    return bytes(b)


def architectural_diff(payload_a: bytes, payload_b: bytes) -> list:
    """Return offsets where two payloads differ, ignoring internal fields.

    Empty list => architecturally identical (differences, if any, are only
    in the masked emulator-internal windows).
    """
    a = _mask_internal(payload_a)
    b = _mask_internal(payload_b)
    n = min(len(a), len(b))
    diffs = [i for i in range(n) if a[i] != b[i]]
    if len(a) != len(b):
        diffs.extend(range(n, max(len(a), len(b))))
    return diffs
