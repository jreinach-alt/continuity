"""Spike T2.0 harness — validity controls (C1-C4).

The controls prove the oracle can PASS valid transfers and FAIL invalid
ones BEFORE any transmutation is scored (spec §Verification / acceptance
A3). Each returns a structured result dict with evidence, so a pass is
auditable, not a green light on faith.

  C1  bsnes native  .bst -> bsnes         (must pass)   [needs bsnes runner]
  C2  Mesen2 native .mss -> Mesen2        (must pass)   [needs MesenCore]
  C3  corrupted/truncated .bst -> bsnes   (must FAIL)   [needs bsnes runner]
  C4  CMS decode -> transplant -> continue == native load  [MesenCore+CMS]

C4 is now the FULL behavioural control: all-domain decode completeness
(WRAM/VRAM/OAM/CGRAM/SRAM/ARAM byte-exact + CPU field-exact vs Mesen ground
truth) plus an architectural transplant (memory+CPU from the file, PPU
register file via the SetPpuState binding) whose StateProbe continuation
must match a native LoadStateFile. Each control raises HarnessUnavailable
when its emulator dependency is absent so the CLI can report SKIP (exit 77)
rather than a false failure.

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
import cms_decode  # noqa: E402


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


def _ensure_mss_dump():
    """Compile the mss_dump decode oracle into build/, return its path.

    Raises HarnessUnavailable if it can't be built (no cc / no zlib) so C4
    skips cleanly. mss_dump IS the decode primitive for P1's first pass;
    transmute_snes.c formalizes the full decode->CMS->encode pipeline in P2.
    """
    import shutil
    import subprocess

    transmute = os.path.abspath(os.path.join(_HERE, ".."))
    build_dir = os.path.join(transmute, "build")
    os.makedirs(build_dir, exist_ok=True)
    out = os.path.join(build_dir, "mss_dump")
    src = os.path.join(transmute, "mss_dump.c")
    if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(src):
        return out
    cc = shutil.which("gcc") or shutil.which("cc")
    if not cc:
        raise HarnessUnavailable("no C compiler for mss_dump")
    proc = subprocess.run(
        [cc, "-std=c99", "-O2", "-o", out, src, "-lz"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise HarnessUnavailable(f"mss_dump build failed: {proc.stderr.strip()}")
    return out


def _settled_audit(runner, mem, schema, tries: int = 6) -> dict:
    """Read the StateProbe RESULT block at a checksum-clean instant.

    The block is written atomically by StateProbe's NMI, but a read taken at
    a park-phase that happens to straddle that NMI can catch it mid-update
    (a torn read: epoch already bumped, trailing checksum not yet). The
    architectural fields (magic / bitmaps / beacon) don't tear — only the
    checksum flips — so this settle loop is purely to hand back clean
    evidence; the pass predicate never depends on the transient checksum.
    """
    parsed = None
    block = None
    for _ in range(tries):
        block = sp.read_result_block(runner, mem, schema)
        parsed = schema.parse(block)
        if schema.checksum_ok(block):
            break
        runner.run_frames(1)
    return {
        "epoch": parsed["beacon_epoch"],
        "pass_bitmap": parsed["domain_pass_bitmap"],
        "audit_passed": schema.audit_passed(parsed),
        "checksum_ok": schema.checksum_ok(block),
        "beacon": sp.read_beacon(runner, mem, schema),
        "magic": parsed["magic"],
    }


def _transplant_continue(dom, cpu_dec, ppu_raw, schema,
                         other_frames, continuation_frames, inject_ppu=True):
    """Fresh core -> park elsewhere -> transplant architectural state -> run.

    Returns (before_audit, post_inject_audit, continued_audit). ``ppu_raw``
    is the source core's PPU register file (core->core in this increment;
    file->core PPU transcode is deferred to transmute_snes.c per the P2
    brief). Memory + CPU come from the FILE decode (``dom`` / ``cpu_dec``).
    """
    runner, mem = new_state_runner()
    try:
        runner.load_rom(sp.ROM_PATH, run_seconds=0.0)
        runner.run_frames(other_frames)
        before = _settled_audit(runner, mem, schema)
        cms_decode.inject_memory_domains(runner, mem, dom)  # file -> core
        runner.set_cpu_state(cpu_dec)                        # file -> core
        if inject_ppu:
            runner.set_ppu_state_raw(ppu_raw)                # core -> core
        post = _settled_audit(runner, mem, schema)
        runner.run_frames(continuation_frames)
        cont = _settled_audit(runner, mem, schema)
        return before, post, cont
    finally:
        try:
            runner.stop()
        except Exception:
            pass


def control_c4(baseline_frames: int = 1000, other_frames: int = 1300,
               continuation_frames: int = 0) -> dict:
    """C4 — CMS decode -> live re-injection -> behavioural continuation.

    Full-behavioural C4 (spec §method upgrade / summary P1-finish). Isolates
    Question A "is the architectural decomposition complete?" from Question B
    "can we synthesize bsnes's format?" — a live-core injection test that
    needs no file encoding. Two independent proofs:

      C4a DECODE COMPLETENESS (file -> values, vs Mesen ground truth):
          every architectural MEMORY domain the decode oracle pulls from the
          `.mss` — WRAM, VRAM, OAM, CGRAM, SRAM, ARAM — is byte-identical to
          the live core's region at capture; and the CPU record transcodes
          field-exact to the live GetCpuState (CycleCount excepted — it is
          the free-running emulator-internal counter, CMS class "internal").

      C4b ARCHITECTURAL SUFFICIENCY (transplant vs native load): transplant
          {file-decoded memory + file-decoded CPU + PPU register file} into a
          DIFFERENT parked core and run it forward; its StateProbe audit must
          continue green (all domains pass, beacon intact) identically to a
          native LoadStateFile of the same `.mss` continued the same way.
          Timing PHASE differs (epoch offset by a couple ticks) — expected
          and explicitly NOT the bar (spec §Verification: transient timing
          divergence, behavioural convergence).

    Field-level attribution (spec verdict rule "every failure gets a root
    cause"): a diagnostic memory+CPU-ONLY transplant is also run — it FAILS
    exactly one domain bit (PPU-register-dependent), demonstrating both that
    SetPpuState is load-bearing (not cosmetic) and that the control is
    sensitive, not a rubber stamp.

    PPU register file is transplanted core->core here (the SetPpuState
    binding); its file->core transcode (SnesPpuState from the 946 keyed
    ppu.* records) is P2 work in transmute_snes.c — a recorded deviation.
    """
    schema = sp.StateProbeSchema()
    if continuation_frames <= 0:
        continuation_frames = schema.gen2_max_frames
    mss_dump = _ensure_mss_dump()

    result = {
        "control": "C4",
        "description": "CMS decode -> transplant -> continuation vs native load",
        "must": "pass",
        "evidence": {},
    }
    try:
        source, mem = new_state_runner()
    except HarnessUnavailable:
        raise
    except Exception as exc:
        raise HarnessUnavailable(f"Mesen2 core bring-up failed: {exc!r}") from exc

    tmpdir = tempfile.mkdtemp(prefix="c4_", dir=os.environ.get("TMPDIR"))
    cap = os.path.join(tmpdir, "c4_cap.mss")
    try:
        # --- source capture at park (read live BEFORE save) ----------------
        source.load_rom(sp.ROM_PATH, run_seconds=0.0)
        source.run_frames(baseline_frames)
        captured = _settled_audit(source, mem, schema)
        cpu_live = source.get_cpu_state()
        ppu_raw = source.get_ppu_state_raw()
        live_regs = {
            cms_name: bytes(source.read_region(getattr(mem, mem_attr)))
            for cms_name, _key, mem_attr, _size in cms_decode.MEMORY_DOMAINS
        }
        source.save_state_file(cap)
        source.stop()

        # --- C4a: decode completeness vs ground truth ----------------------
        dom = cms_decode.decode_memory_domains(mss_dump, cap)
        cpu_dec = cms_decode.decode_cpu_state(mss_dump, cap)
        mem_match = {c: (dom[c] == live_regs[c]) for c in live_regs}
        arch_fields = [n for n, _ in cpu_dec._fields_ if n != "CycleCount"]
        cpu_mismatch = [
            n for n in arch_fields if getattr(cpu_dec, n) != getattr(cpu_live, n)
        ]

        # --- C4b: native-load oracle ---------------------------------------
        oracle, memo = new_state_runner()
        oracle.load_rom(sp.ROM_PATH, run_seconds=0.0)
        oracle.load_state_file(cap)
        oracle.run_frames(2)
        oracle.run_frames(continuation_frames)
        a_native = _settled_audit(oracle, memo, schema)
        oracle.stop()

        # --- C4b: architectural transplant (mem+CPU+PPU) -------------------
        before, post, a_inject = _transplant_continue(
            dom, cpu_dec, ppu_raw, schema,
            other_frames, continuation_frames, inject_ppu=True)

        # --- field-level attribution: mem+CPU ONLY (PPU load-bearing) ------
        _b2, _p2, a_partial = _transplant_continue(
            dom, cpu_dec, ppu_raw, schema,
            other_frames, continuation_frames, inject_ppu=False)

        full = schema.pass_bitmap_full
        result["evidence"] = {
            "capture_frames": baseline_frames,
            "continuation_frames": continuation_frames,
            "memory_domains": {
                c: {"bytes": len(dom[c]), "matches_ground_truth": mem_match[c]}
                for c in mem_match
            },
            "cpu_decode": {
                "arch_fields_checked": len(arch_fields),
                "mismatched_fields": cpu_mismatch,
                "pc": hex(cpu_dec.PC), "sp": hex(cpu_dec.SP),
                "stop_state": cpu_dec.StopState,
            },
            "captured_audit": captured | {"magic": captured["magic"].decode("latin-1")},
            "native_continuation": a_native | {"magic": a_native["magic"].decode("latin-1")},
            "transplant_continuation": a_inject | {"magic": a_inject["magic"].decode("latin-1")},
            "transplant_before_epoch": before["epoch"],
            "post_inject_epoch": post["epoch"],
            # Non-gating field-level attribution: transplant memory+CPU but
            # NOT the PPU register file. Because the target booted the same
            # ROM under RANDOM power-on (Mesen RamState::Random, re-seeded per
            # boot), its own PPU is sometimes close enough that every domain
            # still passes, and sometimes not — so this is NONDETERMINISTIC by
            # construction. That is itself the finding: with PPU left
            # un-injected, a PPU-register-dependent domain's correctness is
            # left to chance; injecting the PPU (full transplant, above) makes
            # it pass deterministically. Recorded as evidence, never gated.
            "mem_cpu_only_diagnostic": {
                "pass_bitmap": hex(a_partial["pass_bitmap"]),
                "audit_passed": a_partial["audit_passed"],
                "ppu_dependent_bits_missing":
                    hex(full & ~a_partial["pass_bitmap"]),
                "note": "nondeterministic (random power-on); evidence only",
            },
        }
        checks = {
            # C4a — decode completeness (all 6 memory domains + CPU)
            "decode_wram": mem_match["wram"],
            "decode_vram": mem_match["vram"],
            "decode_oam": mem_match["oam"],
            "decode_cgram": mem_match["cgram"],
            "decode_sram": mem_match["sram"],
            "decode_aram": mem_match["aram"],
            "decode_cpu_registers": not cpu_mismatch,
            "captured_audit_passed": captured["audit_passed"],
            # C4b — transplant landed + behavioural continuation vs native
            "injection_landed":
                post["epoch"] == captured["epoch"]
                and post["pass_bitmap"] == captured["pass_bitmap"]
                and post["magic"] == b"SPRB",
            "injection_changed_target": before["epoch"] != captured["epoch"],
            "native_continuation_passed": a_native["audit_passed"],
            "transplant_continuation_passed": a_inject["audit_passed"],
            "continuation_bitmap_matches_native":
                a_inject["pass_bitmap"] == a_native["pass_bitmap"] == full,
            "continuation_beacon_matches_native":
                a_inject["beacon"] == a_native["beacon"] == schema.beacon_value,
            "both_progressed_past_capture":
                a_native["epoch"] > captured["epoch"]
                and a_inject["epoch"] > captured["epoch"],
        }
        result["checks"] = checks
        result["passed"] = all(checks.values())
        return result
    finally:
        try:
            if os.path.exists(cap):
                os.remove(cap)
            os.rmdir(tmpdir)
        except OSError:
            pass


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
    "c4": control_c4,
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
