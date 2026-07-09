# Sprint Spec Template

Copy this template to `docs/sprints/sprint-X.Y.md` when detailing a new sprint.

---

# Sprint X.Y — [Title]

## Phase

Phase X — [Phase Name]

## Approved

<!-- The orchestrator or user sets this date when the spec is approved. -->
<!-- Agents MUST NOT begin implementation until this field contains a date. -->
**Not yet approved**

## Status

`not-started` | `approved` | `in-progress` | `qa-review` | `complete`

Status definitions:
- `not-started` — Spec is being drafted or under review. No implementation allowed.
- `approved` — Spec is locked and approved for implementation. Set the Approved date above.
- `in-progress` — Coding agent is actively implementing.
- `qa-review` — Implementation complete. QA agent is validating.
- `complete` — All acceptance criteria met, QA passed, merged.

## Goal

One sentence describing what this sprint achieves and why it matters.

## Reference Specs

- List the design documents this sprint implements from
- e.g., `docs/architecture/ideal_os_session_manager_technical_architecture_spec.md`, sections X-Y

## Scope

### In Scope

- [ ] Specific deliverable 1
- [ ] Specific deliverable 2
- [ ] Specific deliverable 3
- [ ] Tests for all of the above

### Out of Scope

- Thing that might be confused as in-scope but is explicitly deferred
- Another boundary clarification

## Files to Create or Modify

| Action | Path | Description |
|--------|------|-------------|
| Create | `src/module/file.sh` | Brief purpose |
| Create | `tests/unit/module/test_file.sh` | Tests for file.sh |
| Modify | `config/module/config.json` | Add new field |

## Acceptance Criteria

All must pass for the sprint to be considered complete.

1. **[Criterion name]:** Specific, testable statement of what "done" looks like.
2. **[Criterion name]:** Another specific, testable statement.
3. **[Criterion name]:** All new code has corresponding tests.
4. **[Criterion name]:** `scripts/test.sh` passes with zero failures.
5. **[Criterion name]:** ShellCheck reports no errors on new `.sh` files (after Sprint 0.3).

## Test Plan

### Automated Tests

| Test | Type | Location | Validates |
|------|------|----------|-----------|
| `test_name` | unit | `tests/unit/module/` | What it proves |

### Manual Validation (if device-dependent)

- [ ] Step to perform on device
- [ ] Expected result

## Dependencies

- List sprints that must be complete before this one
- e.g., Sprint 0.1 (test harness must exist)

## QA Checklist

The QA agent validates these after implementation:

- [ ] All acceptance criteria met
- [ ] All automated tests pass
- [ ] No files created outside specified paths
- [ ] No unrelated changes included
- [ ] Commit messages follow format in CLAUDE.md
- [ ] Code follows coding standards in CLAUDE.md

## Defects

QA agent appends defects here using this format. One section per defect.

```markdown
### Defect: [short title]

- **Criterion violated:** AC [number]
- **File:** `path/to/file`
- **Observed:** What actually happened
- **Expected:** What should have happened
- **Repro:** Command or steps to reproduce
- **Severity:** `blocking` | `major` | `minor`
- **Status:** `open` | `fix-in-progress` | `verified`
```

Severity definitions:
- `blocking` — Acceptance criterion cannot pass. Sprint cannot complete.
- `major` — Functionality is wrong but a workaround exists. Must fix before merge.
- `minor` — Cosmetic or non-functional issue. May defer with orchestrator approval.

## Notes

Any implementation hints, open questions, or decisions made during sprint planning.
