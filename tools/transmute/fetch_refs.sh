#!/bin/sh
# fetch_refs.sh — pin and fetch Spike T2.0's emulator reference sources.
#
# Every byte-format claim the spike makes cites file:line in THESE trees
# at THESE commits (project rule: format truth from vendored source, never
# from docs or memory). Trees land in tools/transmute/vendor/ (gitignored,
# never committed — ~70 MB).
#
# Desktop-tier tool (x86_64 dev/CI hosts only): NOT BusyBox-constrained,
# never ships to a device.
#
# Usage: sh tools/transmute/fetch_refs.sh
# Idempotent: verified-at-pin trees are left untouched; a tree at the
# wrong commit is an error (delete it yourself — this script never rm's).

set -eu

readonly MESEN2_REPO="https://github.com/SourMesen/Mesen2"
# Final commit of the archived (2026-06-04) upstream — permanent by archival.
readonly MESEN2_PIN="b9fa69ddc6d0a331fb103fdb5eef6904305703c2"

readonly BSNES_REPO="https://github.com/bsnes-emu/bsnes"
# bsnes-emu/bsnes master as pinned at spike start (SerializerVersion "115.1").
readonly BSNES_PIN="7d5aa1e656b9171524d01b1b22917197d8121cb4"

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
vendor="$here/vendor"
mkdir -p "$vendor"

fetch_one() {
    _name=$1
    _repo=$2
    _pin=$3
    _dest="$vendor/$_name"

    if [ -d "$_dest/.git" ]; then
        _head=$(git -C "$_dest" rev-parse HEAD)
        if [ "$_head" = "$_pin" ]; then
            printf '%s: already at pin %s\n' "$_name" "$_pin"
            return 0
        fi
        printf '%s: exists at %s but pin is %s — refusing to touch it.\n' \
            "$_name" "$_head" "$_pin" >&2
        printf 'Delete %s and re-run to re-fetch.\n' "$_dest" >&2
        return 1
    fi

    printf '%s: fetching %s @ %s\n' "$_name" "$_repo" "$_pin"
    git init -q "$_dest"
    git -C "$_dest" remote add origin "$_repo"
    # GitHub serves unadvertised commits by SHA (allowReachableSHA1InWant).
    git -C "$_dest" fetch --depth 1 origin "$_pin"
    git -C "$_dest" checkout -q --detach FETCH_HEAD

    _head=$(git -C "$_dest" rev-parse HEAD)
    if [ "$_head" != "$_pin" ]; then
        printf '%s: fetched %s, expected %s — aborting.\n' \
            "$_name" "$_head" "$_pin" >&2
        return 1
    fi
    printf '%s: pinned OK\n' "$_name"
}

fetch_one mesen2 "$MESEN2_REPO" "$MESEN2_PIN"
fetch_one bsnes  "$BSNES_REPO"  "$BSNES_PIN"

printf 'vendor trees ready under %s\n' "$vendor"
