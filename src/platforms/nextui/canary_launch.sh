#!/bin/sh
# Continuity canary — minimal diagnostic launch.sh.
#
# Temporarily replaces the real Continuity.pak launch.sh on the SD card to
# answer one question: does NextUI execute our launch.sh at all?
#
# It writes proof of execution to the SD card root (a location macOS Finder
# does not hide), records the environment facts the next debugging step
# needs, then shows the NextUI logo for 5 seconds via show2.elf.
#
# Deliberately failure-tolerant: no set -e, every step independent, and
# evidence is flushed with sync after each write so it survives even if a
# later step hangs or the device powers off.
#
# CONTINUITY_CANARY_ROOT overrides the SD card root for off-device testing.

SDROOT="${CONTINUITY_CANARY_ROOT:-/mnt/SDCARD}"
PROOF="$SDROOT/CONTINUITY_CANARY.txt"

# Step 1: simplest possible proof of execution, before anything else runs.
printf 'canary ran\n' > "$PROOF"
sync

# Step 2: mirror the real launch.sh's first action and record the result.
if cd "$(dirname "$0")"; then
    cd_result="ok"
else
    cd_result="FAILED"
fi

# Step 3: can we write inside the PAK directory? (Earlier debug attempts
# logged here; this tells us whether those logs could ever have appeared.)
pakdir_write="skipped (cd failed)"
if [ "$cd_result" = "ok" ]; then
    if printf 'canary pak-dir write ok\n' > ./canary_pakdir_write.txt 2>/dev/null; then
        pakdir_write="ok"
    else
        pakdir_write="FAILED"
    fi
fi

# Step 4: record environment facts.
{
    printf 'date: %s\n' "$(date)"
    printf 'script: %s\n' "$0"
    printf 'cd_to_pak_dir: %s\n' "$cd_result"
    printf 'cwd: %s\n' "$(pwd)"
    printf 'pakdir_write: %s\n' "$pakdir_write"
    printf 'platform: %s\n' "${PLATFORM:-unset}"
    printf 'device: %s\n' "${DEVICE:-unset}"
    printf 'userdata_path: %s\n' "${USERDATA_PATH:-unset}"
    printf 'show2_path: %s\n' "$(command -v show2.elf || printf 'NOT-ON-PATH')"
} >> "$PROOF" 2>&1
sync

# Step 5: visible feedback — NextUI logo + text for 5 seconds.
show2.elf --mode=simple --image="$SDROOT/.system/res/logo.png" \
    --text="Continuity canary OK" --timeout=5
show2_rc=$?

printf 'show2_exit_code: %s\n' "$show2_rc" >> "$PROOF"
sync

# If show2 failed instantly, still hold the black screen briefly so a
# canary that ran is distinguishable from one that never launched.
if [ "$show2_rc" -ne 0 ]; then
    sleep 3
fi

exit 0
