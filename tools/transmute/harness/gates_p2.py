"""Spike T2.0 harness — P2 donor-encode gates G2 / G3.

Executes the pre-registered P2 gates (spec §Phases):
  G2  the rebuilt bsnes state LOADS (format accepted by bsnes unserialize).
  G3  StateProbe v0 all-domain pass on quiescent transfer — the rebuilt
      state, run forward in bsnes, audits itself green.

Flow (needs only the bsnes host + mss_dump + the committed StateProbe beacon
fixture — NO Mesen core, so it runs anywhere the bsnes build exists):

  1. bsnes save --frames 0        -> power-on DONOR .bst (H6 template).
  2. encode_bsnes.encode(beacon_gen2.mss, donor) -> rebuilt .bst
     (overwrite architectural domains from the CMS decode of the committed
      quiescent Mesen capture).
  3. G2: bsnes check(rebuilt)     -> RC_OK (loads) or RC_REJECTED (fails).
  4. G3: bsnes reload(rebuilt, K) -> re-save; unwrap; slice StateProbe's
     RESULT block out of WRAM; parse per-domain pass bitmap.

TAUTOLOGY GUARD (critical): the RESULT block lives in WRAM, which the
encoder OVERWRITES from the capture — so reading a "passing" bitmap straight
back proves nothing (it is the value we injected). G3 therefore requires the
beacon EPOCH to ADVANCE past the injected epoch after running: only a live,
continuing StateProbe re-audit ticks the epoch. Verified two-sided — a native
Mesen load of the same beacon advances the epoch (552 -> 1453 over 900
frames); a transplant that merely loads but hangs leaves it frozen. Epoch
frozen == audit did not re-run == G3 NOT demonstrated, regardless of the
bitmap value.

Exit: 0 = G2 met (G3 reported, advance-gated) / 1 = G2 failed / 77 = deps.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import bst  # noqa: E402
import cms_decode  # noqa: E402
import encode_bsnes  # noqa: E402
import stateprobe as sp  # noqa: E402
from mesen_state import HarnessUnavailable  # noqa: E402

EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_SKIP = 77

_TRANSMUTE = os.path.abspath(os.path.join(_HERE, ".."))
_BUILD = os.path.join(_TRANSMUTE, "build")


def _ensure_oracle(name: str, src: str, libs) -> str:
    out = os.path.join(_BUILD, name)
    os.makedirs(_BUILD, exist_ok=True)
    srcp = os.path.join(_TRANSMUTE, src)
    if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(srcp):
        return out
    cc = shutil.which("gcc") or shutil.which("cc")
    if not cc:
        raise HarnessUnavailable(f"no C compiler for {name}")
    proc = subprocess.run(
        [cc, "-std=c99", "-O2", "-o", out, srcp, *libs],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise HarnessUnavailable(f"{name} build failed: {proc.stderr.strip()}")
    return out


def _read_bsnes_result(out_bst: str, cpu_wram_off: int, schema) -> dict:
    """Slice StateProbe's RESULT block out of a re-saved bsnes .bst WRAM."""
    with open(out_bst, "rb") as fh:
        payload = bst.bst_unwrap(fh.read())
    base = cpu_wram_off + schema.result_offset
    block = payload[base:base + schema.block_len]
    parsed = schema.parse(block)
    beacon = payload[cpu_wram_off + schema.beacon_offset]
    return {
        "epoch": parsed["beacon_epoch"],
        "pass_bitmap": parsed["domain_pass_bitmap"],
        "ran_bitmap": parsed["domain_ran_bitmap"],
        "first_fail_domain": parsed["first_fail_domain"],
        "audit_passed": schema.audit_passed(parsed),
        "checksum_ok": schema.checksum_ok(block),
        "magic": parsed["magic"].decode("latin-1"),
        "beacon": beacon,
    }


def run_g2g3(continuation_frames: int = 900) -> dict:
    from bsnes_runner import BsnesRunner, RC_OK

    schema = sp.StateProbeSchema()
    mss_dump = _ensure_oracle("mss_dump", "mss_dump.c", ["-lz"])
    bst_dump = _ensure_oracle("bst_dump", "bst_dump.c", ["-lz"])
    try:
        runner = BsnesRunner()
    except HarnessUnavailable:
        raise

    result = {"gate": "G2/G3", "description": "donor-encode -> bsnes load + audit",
              "evidence": {}}
    tmp = tempfile.mkdtemp(prefix="g2g3_", dir=os.environ.get("TMPDIR"))
    donor = os.path.join(tmp, "donor.bst")
    rebuilt = os.path.join(tmp, "rebuilt.bst")
    out = os.path.join(tmp, "out.bst")
    try:
        # 1. power-on donor
        runner.save(sp.ROM_PATH, donor, 0)
        # 2. donor-encode from the committed quiescent Mesen capture
        rep = encode_bsnes.encode(
            sp.BEACON_CAPTURE_PATH, donor, rebuilt, mss_dump, bst_dump,
            sram_bytes=8192)
        # offset of cpu.wram (for slicing the re-saved result later)
        offs = encode_bsnes.payload_offsets(bst_dump, donor, 8192)
        cpu_wram_off = offs["cpu.wram"][0]

        # The epoch we INJECT (StateProbe RESULT block lives in WRAM, which the
        # encoder overwrites) — the tautology-guard baseline: G3 requires the
        # post-run epoch to exceed this, else the audit never re-ran.
        inj_wram = cms_decode.extract_domain(
            mss_dump, sp.BEACON_CAPTURE_PATH, "memoryManager.workRam")
        injected_epoch = schema.parse(
            inj_wram[schema.result_offset:
                     schema.result_offset + schema.block_len])["beacon_epoch"]

        # 3. G2 — does the rebuilt state LOAD?
        g2_rc = runner.check(sp.ROM_PATH, rebuilt)
        g2 = g2_rc == RC_OK

        # sanity: a byte-mangled rebuilt must be REJECTED (gate not a rubber
        # stamp) — flip the inner serializer signature.
        raw = open(rebuilt, "rb").read()
        pay = bytearray(bst.bst_unwrap(raw))
        pay[0] ^= 0xFF
        bad = os.path.join(tmp, "bad.bst")
        with open(bad, "wb") as fh:
            fh.write(bst.bst_wrap(bytes(pay)))
        bad_rejected = runner.check(sp.ROM_PATH, bad) != RC_OK

        result["evidence"]["encode"] = rep
        result["evidence"]["g2_rc"] = g2_rc
        result["evidence"]["bad_state_rejected"] = bad_rejected

        # 4. G3 — run the rebuilt state forward; read StateProbe's audit.
        #    Advance-gated: only a LIVE re-audit (epoch > injected) counts.
        g3 = None
        if g2:
            rc = runner.reload(sp.ROM_PATH, rebuilt, out, continuation_frames)
            if rc == RC_OK and os.path.exists(out):
                audit = _read_bsnes_result(out, cpu_wram_off, schema)
                full = schema.pass_bitmap_full
                advanced = audit["epoch"] > injected_epoch
                g3 = {
                    "reload_rc": rc,
                    "injected_epoch": injected_epoch,
                    "post_run_epoch": audit["epoch"],
                    "audit_advanced": advanced,
                    "audit": audit,
                    "expected_full_bitmap": hex(full),
                    "pass_bitmap": hex(audit["pass_bitmap"]),
                    "domains_missing": hex(full & ~audit["pass_bitmap"]),
                    # A passing bitmap only counts if the audit actually re-ran.
                    "all_domains_passed_live":
                        advanced and audit["audit_passed"]
                        and audit["pass_bitmap"] == full,
                    "note": ("epoch frozen at the injected value => StateProbe "
                             "did not continue executing => reading the block "
                             "back is a tautology, NOT a demonstrated audit")
                            if not advanced else "live re-audit observed",
                }
            else:
                g3 = {"reload_rc": rc, "error": "reload produced no state"}
        result["evidence"]["g3"] = g3

        result["checks"] = {
            "G2_rebuilt_state_loads": g2,
            "G2_gate_rejects_mangled": bad_rejected,
        }
        # G2 is the gated milestone this pass; G3 is reported (advance-gated).
        result["g2_met"] = g2 and bad_rejected
        result["g3_all_domains_live"] = bool(
            g3 and g3.get("all_domains_passed_live"))
        result["g3_audit_advanced"] = bool(g3 and g3.get("audit_advanced"))
        result["passed"] = result["g2_met"]
        return result
    finally:
        for p in (donor, rebuilt, out, os.path.join(tmp, "bad.bst")):
            try:
                os.remove(p)
            except OSError:
                pass
        try:
            os.rmdir(tmp)
        except OSError:
            pass


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Spike T2.0 P2 gates G2/G3")
    ap.add_argument("--frames", type=int, default=900,
                    help="frames to run the rebuilt state before reading audit")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    try:
        res = run_g2g3(continuation_frames=args.frames)
    except HarnessUnavailable as exc:
        print(f"SKIP G2/G3: {exc}", file=sys.stderr)
        return EXIT_SKIP

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        print(f"G2/G3  ({res['description']})")
        for k, v in res["checks"].items():
            print(f"  [{'ok' if v else 'XX'}] {k}")
        g3 = res["evidence"].get("g3")
        if g3 and "audit" in g3:
            print(f"  G3 audit: injected_epoch={g3['injected_epoch']} "
                  f"post_run_epoch={g3['post_run_epoch']} "
                  f"advanced={g3['audit_advanced']}")
            print(f"            pass_bitmap={g3['pass_bitmap']} "
                  f"expected={g3['expected_full_bitmap']} "
                  f"missing={g3['domains_missing']}")
            print(f"            {g3['note']}")
        print(f"  => G2 met: {res['g2_met']}   "
              f"G3 audit advanced: {res['g3_audit_advanced']}   "
              f"G3 all-domains live: {res['g3_all_domains_live']}")
    return EXIT_PASS if res["passed"] else EXIT_FAIL


if __name__ == "__main__":
    raise SystemExit(main())
