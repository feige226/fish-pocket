#!/usr/bin/env bash
# Run scripts/smoke-sim.sh on several simulators at once, so an engine upgrade is
# checked on every iOS version this machine has: one iPhone and one iPad per
# runtime, plus iPhone Duo when it exists. Each device runs in its own process on
# its own engine port; screenshots and logs land under app/build/smoke/matrix-*/.
#
#   scripts/smoke-matrix.sh [UDID ...]     (default: newest iOS runtime only)
#   SMOKE_SCREENS=full runs every screen on every device; the default `key` set
#   keeps a matrix run to the screens that differ per device.
#
# Old runtimes go stale on a machine (boot fails, or the device never gets a
# display) and `simctl` still lists them, so the default stays on the newest iOS
# runtime: pass UDIDs to cover older ones once they are healthy.
#
# Needs one build: run scripts/run-sim.sh once; each device gets the same app.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/app/build/smoke/matrix-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"

devices=("$@")
if [ ${#devices[@]} -eq 0 ]; then
  # Every available runtime gets its first iPhone and first iPad; Duo is its own
  # layout and worth a row. `watch` simulators cannot run the app.
  while IFS= read -r udid; do
    [ -n "$udid" ] && devices+=("$udid")
  done < <(xcrun simctl list devices available --json | node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      const devices = JSON.parse(s).devices;
      const byRuntime = new Map();
      for (const [runtime, list] of Object.entries(devices)) {
        const version = /iOS-(\d+)/.exec(runtime)?.[1];
        if (!version) continue;
        for (const device of list) {
          if (!device.isAvailable || /watch/i.test(device.name)) continue;
          if (!byRuntime.has(Number(version))) byRuntime.set(Number(version), { iphone: null, ipad: null, duo: null });
          const row = byRuntime.get(Number(version));
          if (/duo/i.test(device.name) && !row.duo) row.duo = device.udid;
          else if (/iphone|se /i.test(device.name) && !row.iphone) row.iphone = device.udid;
          else if (/ipad/i.test(device.name) && !row.ipad) row.ipad = device.udid;
        }
      }
      const newest = Math.max(...byRuntime.keys());
      const row = byRuntime.get(newest);
      console.log([row.iphone, row.ipad, row.duo].filter(Boolean).join("\n"));
    });')
fi
[ ${#devices[@]} -gt 0 ] || { echo "no iPhone or iPad simulators found" >&2; exit 1; }
printf 'devices: %s\n' "${#devices[@]}"

port=3090
for device in "${devices[@]}"; do
  name="$(xcrun simctl list devices | sed -nE "s/^ +(.+) \($device\) (\(Booted\)|\(Shutdown\)).*/\1 \2/p" | head -1)"
  label="$(printf '%s' "$name" | sed -E 's/ \((Booted|Shutdown)\)$//' | tr ' ' '-' | tr -cd 'A-Za-z0-9.-')"
  printf '  %s  %s  port %s\n' "$label" "$device" "$port"
  (
    xcrun simctl boot "$device" >/dev/null 2>&1 || true
    # A cold iOS 18 runtime can take a minute; bootstatus -b hangs on it, so poll.
    for _ in $(seq 60); do
      xcrun simctl list devices | grep -q "$device) (Booted)" && break
      sleep 3
    done
    SIM_DEVICE="$device" SMOKE_PORT="$port" SMOKE_SCREENS="${SMOKE_SCREENS:-key}" \
      "$root/scripts/smoke-sim.sh" "$out/$label" >"$out/$label.log" 2>&1
    echo "$?" >"$out/$label.status"
  ) &
  port=$((port + 1))
done
wait

fail=0
for device in "${devices[@]}"; do
  label="$(xcrun simctl list devices | sed -nE "s/^ +(.+) \($device\) (\(Booted\)|\(Shutdown\)).*/\1 \2/p" | head -1 | sed -E 's/ \((Booted|Shutdown)\)$//' | tr ' ' '-' | tr -cd 'A-Za-z0-9.-')"
  status="$(cat "$out/$label.status" 2>/dev/null || echo 1)"
  if [ "$status" = 0 ]; then
    printf 'PASS %s\n' "$label"
  else
    printf 'FAIL %s  (see %s.log)\n' "$label" "$out/$label"
    tail -5 "$out/$label.log" | sed 's/^/     /'
    fail=1
  fi
done
[ "$fail" -eq 0 ] || { echo "matrix: FAILED"; exit 1; }
echo "matrix: passed — screenshots in $out"
