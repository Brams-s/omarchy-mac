#!/bin/bash

set -euo pipefail
source "$(dirname "$0")/base-test.sh"

recovery="$ROOT/fix-arm-packages.sh"

[[ -x $recovery ]] || fail 'recovery script is executable'
bash -n "$recovery" || fail 'recovery script parses'
pass 'recovery script is present, executable, and parses'

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

conf="$test_tmp/pacman.conf"
printf '%s\n' '[options]' 'Architecture = aarch64' '[extra]' 'Server = https://regular.example/$arch' '[omarchy-aarch64]' 'Server = https://mac.example' > "$conf"
cp "$conf" "$test_tmp/original"

run_recovery() {
  OMARCHY_ARM_PACMAN_CONF="$conf" bash "$recovery" "$@" 2>&1
}

output=$(run_recovery --dry-run) || fail 'dry run succeeds' "$output"

cmp -s "$test_tmp/original" "$conf" || fail 'dry run leaves the configuration untouched'
[[ ! -e "$conf.bak" ]] || fail 'dry run writes no backup'
pass 'dry run changes nothing on the machine'

grep -q '^+\[omarchy\]$' <<<"$output" || fail 'dry run adds the edge section' "$output"
grep -q '^+Usage = Sync$' <<<"$output" || fail 'dry run keeps edge out of automatic selection' "$output"
grep -q '^+SigLevel = Required DatabaseOptional$' <<<"$output" || fail 'dry run requires signed packages' "$output"
grep -q 'would run: sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syu omarchy/hyprland omarchy/hyprtoolkit omarchy/hyprland-guiutils' <<<"$output" ||
  fail 'dry run reports the selected packages' "$output"
grep -q 'would run: sudo pacman-key' <<<"$output" || fail 'dry run reports the key import' "$output"
pass 'dry run reports the restricted signed edge section and the transaction'

# The update guard hook aborts any direct -Syu that does not identify itself,
# so a recovery that forgets this never reaches the packages it exists to
# install. The reported command must be the one that runs, or the dry run
# hides the failure instead of predicting it.
guard="$ROOT/bin/omarchy-update-pacman-guard"
if [[ -f $guard ]]; then
  grep -q 'OMARCHY_UPDATE_PACMAN' "$guard" || fail 'the guard still reads OMARCHY_UPDATE_PACMAN'
fi
transaction=$(grep -n 'pacman -Syu "\${targets\[@\]}"' "$recovery") || fail 'recovery runs the selection'
[[ $transaction == *'sudo env OMARCHY_UPDATE_PACMAN=1 pacman'* ]] ||
  fail 'the transaction identifies itself to the update guard' "$transaction"
reported=$(grep -o 'would run: sudo env [^"]*pacman -Syu' <<<"$output")
[[ $reported == "would run: sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syu" ]] ||
  fail 'the reported transaction matches the one that runs' "$reported"
pass 'the transaction identifies itself to the update guard'

grep -q 'Server = https://regular.example' <<<"$(cat "$conf")" || fail 'regular mirrors kept'
! grep -q '^-' <<<"$(grep -v '^---' <<<"$output")" || fail 'dry run removes nothing from a configuration without an edge section' "$output"
pass 'recovery only adds to a configuration that has no edge section'

# This script exists for machines whose installed package predates the helper,
# so a checkout must never be the only place it can find one. Point every local
# candidate at an empty directory and let it fall back to the published copy,
# served from a file here so the test needs no network.
cp "$ROOT/install/helpers/arm-package-sources.sh" "$test_tmp/published-helper.sh"
mkdir -p "$test_tmp/empty"
cp "$recovery" "$test_tmp/empty/fix-arm-packages.sh"
cp "$test_tmp/original" "$conf"

output=$(
  OMARCHY_ARM_PACMAN_CONF="$conf" \
    OMARCHY_PATH="$test_tmp/empty" \
    OMARCHY_ARM_HELPER_URL="file://$test_tmp/published-helper.sh" \
    bash "$test_tmp/empty/fix-arm-packages.sh" --dry-run 2>&1
) || fail 'dry run without a local helper succeeds' "$output"
grep -q 'omarchy/hyprland omarchy/hyprtoolkit omarchy/hyprland-guiutils' <<<"$output" ||
  fail 'fetched helper supplies the selected packages' "$output"
pass 'recovery falls back to the published helper when no checkout is installed'

output=$(run_recovery --unknown-option && echo UNEXPECTED) || true
grep -q 'Unknown option' <<<"$output" || fail 'unknown options are rejected' "$output"
! grep -q UNEXPECTED <<<"$output" || fail 'unknown options do not run the recovery' "$output"
cmp -s "$test_tmp/original" "$conf" || fail 'a rejected invocation changes nothing'
pass 'unknown options are rejected before anything runs'
