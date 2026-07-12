"""Spike T2.0 harness — validity controls (C1-C4).

The controls prove the oracle can PASS valid transfers and FAIL invalid
ones BEFORE any transmutation is scored (spec §Verification / acceptance
A3). Each returns a structured result dict with evidence, so a pass is
auditable, not a green light on faith.

  C1  bsnes native  .bst -> bsnes         (must pass)   [needs bsnes runner]
  C2  Mesen2 native .mss -> Mesen2        (must pass)   [needs MesenCore]
  C3  corrupted/truncated .bst -> bsnes   (must FAIL)   [needs bsnes runner]
  C4  CMS decode -> live re-inject Mesen2 (must match)  [needs MesenCore+CMS]

This file currently implements the Mesen2-side control (C2). The
bsnes-side controls (C1/C3) land with the bsnes headless runner; C4 lands
with the first transmute_snes.c decode pass. Each control raises
HarnessUnavailable when its emulator dependency is absent so the CLI can
report SKIP (exit 77) rather than a false failure.

CLI:  python3 controls.py c2 [--frames N] [--json]
Exit: 0 pass / 1 fail / 77 skip (dependency unavailable).
"""

import argparse
import json
import os
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from mesen_state import HarnessUnavailable, new_state_runner  # noqa: E402
import stateprobe as sp  # noqa: E402


EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_SKIP = 77


def control_c2(advance_frames: int = 600, run_seconds: float = 0.0) -> dict:
    """C2 — Mesen2 native save state round-trips through Mesen2.

    Sequence: boot StateProbe -> run to gen2 audit -> confirm audit PASS ->
    save .mss -> advance and confirm the epoch ticks (emulation live) ->
    load the .mss -> confirm the epoch REWINDS (load took effect) -> re-run
    to audit -> confirm audit PASS again and the beacon survives.

    The beacon epoch counter is the load oracle: LoadStateFile's return
    bool is unreliable (async apply), so we require an observed rewind.
    """
    schema = sp.StateProbeSchema()
    result = {
        "control": "C2",
        "description": "Mesen2 native .mss -> Mesen2",
        "must": "pass",
        "evidence": {},
    }
    # Core bring-up: any failure here (SDL2 missing, core unreadable, ROM
    # load rejected) means "not testable in this environment" -> SKIP, not
    # FAIL. Everything AFTER a live, booted ROM is a scored assertion.
    try:
        runner, mem = new_state_runner()
        runner.load_rom(sp.ROM_PATH, run_seconds=run_seconds)
    except HarnessUnavailable:
        raise
    except Exception as exc:
        raise HarnessUnavailable(f"Mesen2 core bring-up failed: {exc!r}") from exc

    tmpdir = tempfile.mkdtemp(prefix="c2_", dir=os.environ.get("TMPDIR"))
    save_path = os.path.join(tmpdir, "c2_capture.mss")
    try:
        runner.run_frames(schema.gen2_max_frames)

        base = schema.parse(sp.read_result_block(runner, mem, schema))
        base_beacon = sp.read_beacon(runner, mem, schema)
        result["evidence"]["baseline"] = {
            "magic": base["magic"].decode("latin-1"),
            "epoch": base["beacon_epoch"],
            "pass_bitmap": hex(base["domain_pass_bitmap"]),
            "beacon": hex(base_beacon),
            "audit_passed": schema.audit_passed(base),
            "checksum_ok": schema.checksum_ok(
                sp.read_result_block(runner, mem, schema)
            ),
        }

        runner.save_state_file(save_path)
        result["evidence"]["saved_bytes"] = os.path.getsize(save_path)

        runner.run_frames(advance_frames)
        advanced = schema.parse(sp.read_result_block(runner, mem, schema))
        result["evidence"]["advanced_epoch"] = advanced["beacon_epoch"]

        runner.load_state_file(save_path)
        runner.run_frames(2)
        reloaded = schema.parse(sp.read_result_block(runner, mem, schema))
        result["evidence"]["reloaded_epoch"] = reloaded["beacon_epoch"]

        runner.run_frames(schema.gen2_max_frames)
        final = schema.parse(sp.read_result_block(runner, mem, schema))
        final_block = sp.read_result_block(runner, mem, schema)
        final_beacon = sp.read_beacon(runner, mem, schema)
        result["evidence"]["final"] = {
            "epoch": final["beacon_epoch"],
            "pass_bitmap": hex(final["domain_pass_bitmap"]),
            "beacon": hex(final_beacon),
            "audit_passed": schema.audit_passed(final),
            "checksum_ok": schema.checksum_ok(final_block),
        }

        checks = {
            "baseline_audit_passed": schema.audit_passed(base),
            "state_file_nonempty": os.path.getsize(save_path) > 0,
            "epoch_advanced_before_load":
                advanced["beacon_epoch"] > base["beacon_epoch"],
            "epoch_rewound_on_load":
                reloaded["beacon_epoch"] < advanced["beacon_epoch"],
            "final_audit_passed": schema.audit_passed(final),
            "beacon_survived": final_beacon == schema.beacon_value,
        }
        result["checks"] = checks
        result["passed"] = all(checks.values())
        return result
    finally:
        try:
            runner.stop()
        except Exception:
            pass
        try:
            if os.path.exists(save_path):
                os.remove(save_path)
            os.rmdir(tmpdir)
        except OSError:
            pass


CONTROLS = {
    "c2": control_c2,
}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Spike T2.0 validity controls")
    parser.add_argument("control", choices=sorted(CONTROLS), help="control id")
    parser.add_argument("--frames", type=int, default=600,
                        help="frames to advance between save and load (C2)")
    parser.add_argument("--json", action="store_true",
                        help="emit the full result dict as JSON")
    args = parser.parse_args(argv)

    fn = CONTROLS[args.control]
    try:
        if args.control == "c2":
            result = fn(advance_frames=args.frames)
        else:  # pragma: no cover - future controls
            result = fn()
    except HarnessUnavailable as exc:
        print(f"SKIP {args.control.upper()}: {exc}", file=sys.stderr)
        return EXIT_SKIP

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        verdict = "PASS" if result.get("passed") else "FAIL"
        print(f"{result['control']} {verdict}  ({result['description']})")
        for name, ok in result.get("checks", {}).items():
            print(f"  [{'ok' if ok else 'XX'}] {name}")
    return EXIT_PASS if result.get("passed") else EXIT_FAIL


if __name__ == "__main__":
    raise SystemExit(main())
