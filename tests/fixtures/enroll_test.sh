#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Test Enrollment Helper — creates a complete enrollment environment for CI
# Provides a bare git remote, pre-seeded saves, and scripted enrollment.
# Source pal_test.sh before this file. Set TEST_TMPDIR before sourcing pal_test.sh.

# Variables set by et_setup for tests to use
ET_REMOTE_DIR=""
ET_REPO_DIR=""

# et_setup — create bare remote, seed saves, run enrollment
# Usage: et_setup <test_tmpdir>
# Returns: 0 success, 1 failure
et_setup() {
    local test_tmpdir
    test_tmpdir="$1"

    ET_REMOTE_DIR="$test_tmpdir/remote.git"
    ET_REPO_DIR="$CONTINUITY_REPO_DIR"

    # Create bare remote
    "$CONTINUITY_GIT_BIN" init --bare "$ET_REMOTE_DIR" >/dev/null 2>&1 || return 1

    # Ensure the bare repo default branch is main
    "$CONTINUITY_GIT_BIN" -C "$ET_REMOTE_DIR" symbolic-ref HEAD refs/heads/main 2>/dev/null || true

    # Seed the bare remote with initial saves via a temp working clone
    local seed_dir
    seed_dir="$test_tmpdir/seed_clone"
    "$CONTINUITY_GIT_BIN" clone "$ET_REMOTE_DIR" "$seed_dir" >/dev/null 2>&1 || return 1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" checkout -b main 2>/dev/null || true
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" config user.email "test@seed" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" config user.name "Seed" >/dev/null 2>&1

    # Create pre-seeded save files
    mkdir -p "$seed_dir/snes" "$seed_dir/gba" "$seed_dir/gb"
    printf 'testdata' > "$seed_dir/snes/super_metroid.srm"
    printf 'testdata' > "$seed_dir/gba/minish_cap.srm"
    printf 'testdata' > "$seed_dir/gb/links_awakening.srm"

    "$CONTINUITY_GIT_BIN" -C "$seed_dir" add snes/super_metroid.srm gba/minish_cap.srm gb/links_awakening.srm >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" commit -m "seed: initial saves" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" push origin main >/dev/null 2>&1 || return 1

    # Clean up seed clone
    rm -rf "$seed_dir"

    # Initialize PAL directories (parent of repo dir)
    pal_init

    # Source core modules
    local script_dir
    script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    # Walk up to find project root (tests/fixtures -> tests -> project root,
    # or tests/unit/core -> tests/unit -> tests -> project root, etc.)
    local project_root
    project_root="$script_dir"
    while [ ! -f "$project_root/CLAUDE.md" ] && [ "$project_root" != "/" ]; do
        project_root="$(dirname "$project_root")"
    done

    . "$project_root/src/core/pal.sh"
    . "$project_root/src/core/sync_engine.sh"
    . "$project_root/src/core/enrollment.sh"

    pal_validate || return 1

    # Run enrollment using file:// URL
    local repo_url
    repo_url="file://$ET_REMOTE_DIR"

    enroll_run "$repo_url" "$CONTINUITY_DEVICE_NAME" "test-pat-token" || return 1

    return 0
}

# et_add_remote_save — add a save file to the bare remote
# Usage: et_add_remote_save <system> <filename> <content>
# Returns: 0 success, 1 failure
et_add_remote_save() {
    local system filename content
    system="$1"
    filename="$2"
    content="$3"

    # Clone bare remote into a temp working copy
    local work_dir
    work_dir="$(mktemp -d)"
    "$CONTINUITY_GIT_BIN" clone "$ET_REMOTE_DIR" "$work_dir/clone" >/dev/null 2>&1 || return 1
    "$CONTINUITY_GIT_BIN" -C "$work_dir/clone" config user.email "test@remote" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$work_dir/clone" config user.name "Remote" >/dev/null 2>&1

    mkdir -p "$work_dir/clone/$system"
    printf '%s' "$content" > "$work_dir/clone/$system/$filename"

    "$CONTINUITY_GIT_BIN" -C "$work_dir/clone" add "$system/$filename" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$work_dir/clone" commit -m "remote: add $system/$filename" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$work_dir/clone" push origin main >/dev/null 2>&1 || return 1

    rm -rf "$work_dir"
    return 0
}

# et_teardown — remove all temp directories
# Usage: et_teardown
et_teardown() {
    if [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ]; then
        rm -rf "$TEST_TMPDIR"
    fi
}
