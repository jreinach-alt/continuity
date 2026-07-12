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


def _read(path):
    with open(path, "rb") as fh:
        return fh.read()


def control_c1(baseline_frames: int = 400, advance_frames: int = 150) -> dict:
    """C1 — bsnes native `.bst` round-trips through bsnes.

    Gold-standard state-transfer proof: a state saved by bsnes at frame N,
    reloaded into a FRESH bsnes core and advanced K frames, must reconstruct
    the exact architectural machine state of a native run straight to N+K —
    the only permitted divergence being bsnes's per-boot PRNG seed
    (`random.state`), which the CMS classifies emulator-internal and never
    translates. Plus: the state loads without rejection, the emulator is
    demonstrably live (A != B), and the load+advance path is deterministic.
    """
    import bst
    from bsnes_runner import BsnesRunner, RC_OK

    result = {
        "control": "C1",
        "description": "bsnes native .bst -> bsnes",
        "must": "pass",
        "evidence": {},
    }
    try:
        runner = BsnesRunner()
    except HarnessUnavailable:
        raise

    tmpdir = tempfile.mkdtemp(prefix="c1_", dir=os.environ.get("TMPDIR"))
    A = os.path.join(tmpdir, "A.bst")
    B = os.path.join(tmpdir, "B.bst")
    C = os.path.join(tmpdir, "C.bst")
    C2 = os.path.join(tmpdir, "C2.bst")
    try:
        n, k = baseline_frames, advance_frames
        runner.save(sp.ROM_PATH, A, n)
        runner.save(sp.ROM_PATH, B, n + k)
        rc_c = runner.reload(sp.ROM_PATH, A, C, k)
        rc_c2 = runner.reload(sp.ROM_PATH, A, C2, k)

        raw_a, raw_b, raw_c = _read(A), _read(B), _read(C)
        pay_a = bst.bst_unwrap(raw_a)
        pay_b = bst.bst_unwrap(raw_b)
        pay_c = bst.bst_unwrap(raw_c)
        arch = bst.architectural_diff(pay_b, pay_c)
        raw_bc = sum(
            1 for i in range(min(len(pay_b), len(pay_c))) if pay_b[i] != pay_c[i]
        )

        result["evidence"] = {
            "baseline_frames": n,
            "advance_frames": k,
            "saved_bytes": len(raw_a),
            "reload_accepted": rc_c == RC_OK,
            "raw_diffs_native_vs_reload": raw_bc,
            "architectural_diffs": len(arch),
            "internal_mask_window": bst.INTERNAL_MASK_WINDOWS,
            "reload_deterministic": rc_c2 == RC_OK and _read(C) == _read(C2),
        }
        checks = {
            "state_accepted_on_reload": rc_c == RC_OK,
            "emulation_live": raw_a != raw_b,
            "architectural_convergence": len(arch) == 0,
            "reload_path_deterministic":
                rc_c2 == RC_OK and _read(C) == _read(C2),
        }
        result["checks"] = checks
        result["passed"] = all(checks.values())
        return result
    finally:
        for p in (A, B, C, C2):
            try:
                os.remove(p)
            except OSError:
                pass
        try:
            os.rmdir(tmpdir)
        except OSError:
            pass


def control_c3(baseline_frames: int = 400) -> dict:
    """C3 — corrupted/truncated `.bst` is rejected loudly (no false-pass).

    Proves the bsnes oracle is not a rubber stamp: a valid state loads, and
    a battery of corruptions that hit real load-path gates (container
    signature, container size, serializer signature, version string,
    serializeSize) are each rejected. The both-directions check (valid
    accepted AND every corruption refused) is the actual acceptance bar —
    an oracle that rejects everything is as useless as one that accepts
    everything.
    """
    import bst
    from bsnes_runner import BsnesRunner, RC_OK, RC_REJECTED

    result = {
        "control": "C3",
        "description": "corrupted .bst -> bsnes (must reject)",
        "must": "fail-loudly",
        "evidence": {},
    }
    try:
        runner = BsnesRunner()
    except HarnessUnavailable:
        raise

    tmpdir = tempfile.mkdtemp(prefix="c3_", dir=os.environ.get("TMPDIR"))
    valid = os.path.join(tmpdir, "valid.bst")
    made = [valid]
    try:
        runner.save(sp.ROM_PATH, valid, baseline_frames)
        good = _read(valid)
        payload = bst.bst_unwrap(good)

        def corrupt_payload(mutate):
            b = bytearray(payload)
            mutate(b)
            return bst.bst_wrap(bytes(b))

        cases = {}
        cases["empty"] = b""
        bad_sig = bytearray(good)
        bad_sig[0] ^= 0xFF
        cases["bad_container_signature"] = bytes(bad_sig)
        cases["truncated"] = good[: len(good) - 1000]
        cases["inner_signature"] = corrupt_payload(
            lambda b: b.__setitem__(slice(0, 4), b"\x00\x00\x00\x00")
        )
        cases["version_string"] = corrupt_payload(
            lambda b: b.__setitem__(8, b[8] ^ 0xFF)
        )
        cases["serialize_size"] = corrupt_payload(
            lambda b: b.__setitem__(4, (b[4] + 1) & 0xFF)
        )

        rejects = {}
        for name, data in cases.items():
            path = os.path.join(tmpdir, f"corrupt_{name}.bst")
            with open(path, "wb") as fh:
                fh.write(data)
            made.append(path)
            rejects[name] = runner.check(sp.ROM_PATH, path) == RC_REJECTED

        valid_accepted = runner.check(sp.ROM_PATH, valid) == RC_OK

        result["evidence"] = {
            "valid_accepted": valid_accepted,
            "corruptions": rejects,
        }
        checks = {"valid_state_accepted": valid_accepted}
        for name, ok in rejects.items():
            checks[f"rejected_{name}"] = ok
        result["checks"] = checks
        result["passed"] = all(checks.values())
        return result
    finally:
        for p in made:
            try:
                os.remove(p)
            except OSError:
                pass
        try:
            os.rmdir(tmpdir)
        except OSError:
            pass


CONTROLS = {
    "c1": control_c1,
    "c2": control_c2,
    "c3": control_c3,
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
        else:
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
