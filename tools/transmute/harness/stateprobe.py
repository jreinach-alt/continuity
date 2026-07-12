"""Spike T2.0 harness — StateProbe RESULT_SCHEMA reader + audit helpers.

StateProbe is the self-auditing diagnostic ROM (spec §Primary instrument).
It writes a 40-byte RESULT_SCHEMA v1 block to WRAM ``$7EF000`` (mirrored to
SRAM) recording a per-domain pass/fail bitmap. This module parses that
block and provides the audit-verification predicate the harness controls
score against.

Everything authoritative — the block layout, the beacon address, the
expected pass bitmap, the frame budgets — is read from the committed
fixture manifest (``tests/fixtures/transmute/stateprobe/
stateprobe_manifest.json``), never hardcoded, so the harness can never
drift from the ROM it is auditing.
"""

import json
import os
import struct
from typing import Optional


_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.abspath(os.path.join(_HERE, "..", "..", ".."))
FIXTURE_DIR = os.path.join(
    _REPO_ROOT, "tests", "fixtures", "transmute", "stateprobe"
)
MANIFEST_PATH = os.path.join(FIXTURE_DIR, "stateprobe_manifest.json")
ROM_PATH = os.path.join(FIXTURE_DIR, "stateprobe.sfc")
BEACON_CAPTURE_PATH = os.path.join(FIXTURE_DIR, "beacon_gen2.mss")


def load_manifest(path: str = MANIFEST_PATH) -> dict:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _wram_offset(addr_hex: str) -> int:
    """Map a ``$7Exxxx`` bank-address string to a WRAM-region offset.

    MemoryType.SnesWorkRam is the 128 KiB block $7E0000-$7FFFFF, so the
    offset is the 24-bit address minus $7E0000.
    """
    return int(addr_hex, 16) - 0x7E0000


class StateProbeSchema:
    """RESULT_SCHEMA v1 layout + expectations, driven by the manifest."""

    def __init__(self, manifest: Optional[dict] = None):
        self.manifest = manifest or load_manifest()
        self.fields = self.manifest["result_schema_v1"]
        self.block_len = max(f["offset"] + f["size"] for f in self.fields)
        addrs = self.manifest["addresses"]
        self.result_offset = _wram_offset(addrs["result_block"])
        self.beacon_offset = _wram_offset(addrs["beacon"])
        self.beacon_value = int(addrs["beacon_value"], 16)
        exp = self.manifest["expected"]
        self.pass_bitmap_full = exp["ran_pass_bitmap_full"]
        self.beacon_max_frames = exp["beacon_max_frames"]
        self.gen2_max_frames = exp["gen2_max_frames"]
        self.build_id = self.manifest["build_id"]

    def parse(self, block: bytes) -> dict:
        """Decode a RESULT_SCHEMA block into a field dict."""
        if len(block) < self.block_len:
            raise ValueError(
                f"block too short: {len(block)} < {self.block_len}"
            )
        out = {}
        for f in self.fields:
            raw = block[f["offset"]:f["offset"] + f["size"]]
            if f["field"] == "magic":
                out["magic"] = raw
            elif f["size"] == 1:
                out[f["field"]] = raw[0]
            elif f["size"] == 2:
                out[f["field"]] = struct.unpack("<H", raw)[0]
            elif f["size"] == 3:
                out[f["field"]] = int.from_bytes(raw, "little")
            elif f["size"] == 4:
                out[f["field"]] = struct.unpack("<I", raw)[0]
            else:
                out[f["field"]] = raw
        return out

    def checksum_ok(self, block: bytes) -> bool:
        """Verify the trailing 32-bit LE sum of bytes [0..36)."""
        body = block[:36]
        stored = struct.unpack("<I", block[36:40])[0]
        return (sum(body) & 0xFFFFFFFF) == stored

    def audit_passed(self, parsed: dict) -> bool:
        """True iff this is a valid, fully-passing StateProbe result.

        The bar (spec §Verification): magic present, the correct build,
        the beacon reached, and every domain that ran passed with the full
        expected bitmap and no first-failure recorded.
        """
        return (
            parsed.get("magic") == b"SPRB"
            and parsed.get("schema_version") == 1
            and parsed.get("build_id") == self.build_id
            and parsed.get("domain_pass_bitmap") == self.pass_bitmap_full
            and parsed.get("domain_ran_bitmap") == self.pass_bitmap_full
            and parsed.get("first_fail_domain") == 255
        )


def read_result_block(runner, mem_type, schema: StateProbeSchema) -> bytes:
    """Read the RESULT_SCHEMA block out of a live runner's WRAM."""
    return bytes(
        runner.read_bytes(
            mem_type.SnesWorkRam, schema.result_offset, schema.block_len
        )
    )


def read_beacon(runner, mem_type, schema: StateProbeSchema) -> int:
    return runner.read_bytes(
        mem_type.SnesWorkRam, schema.beacon_offset, 1
    )[0]
