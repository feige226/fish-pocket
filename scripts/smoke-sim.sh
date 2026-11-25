#!/usr/bin/env bash
# Smoke-test a built app on a booted simulator, for the check every engine or
# plugin upgrade owes: screenshot every screen `-dshOpen` reaches, then assert
# through the engine's HTTP API that the versions and backends the app ships
# actually run. Screens are for the reviewer's eyes; the assertions fail the run.
#
#   scripts/smoke-sim.sh [output dir]        (default: app/build/smoke/<time>-<device>)
#   SIM_DEVICE picks the simulator (default: the first booted one).
#   SMOKE_SCREENS=key limits the sweep to the screens a matrix run needs.
#   SMOKE_PORT (default 3080) keeps parallel simulators off one another's port.
#
# Installs app/build/DerivedData's build when the simulator has none, so a matrix
# run after one build needs no manual step.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
device="${SIM_DEVICE:-$(xcrun simctl list devices booted | sed -nE 's/.*\(([0-9A-F-]{36})\) \(Booted\).*/\1/p' | head -1)}"
[ -n "$device" ] || { echo "no booted simulator; boot one or set SIM_DEVICE" >&2; exit 1; }
bundle="${DSH_BUNDLE_ID:-com.wsw.dsh-ios}"
port="${SMOKE_PORT:-3080}"
out="${1:-$root/app/build/smoke/$(date +%Y%m%d-%H%M%S)-$(printf '%s' "$device" | tr -d '-' | cut -c1-8)}"
mkdir -p "$out"

built="$root/app/build/DerivedData/Build/Products/Debug-iphonesimulator/DshIOS.app"
# Install the build under test over whatever the simulator has: a stale install
# from an earlier run would pass while testing the old engine.
if [ -d "$built" ]; then
  xcrun simctl install "$device" "$built"
  app_dir="$(xcrun simctl get_app_container "$device" "$bundle" app)"
elif ! app_dir="$(xcrun simctl get_app_container "$device" "$bundle" app 2>/dev/null)"; then
  echo "no build in $built and none installed; run scripts/run-sim.sh first" >&2
  exit 1
fi
engine="$app_dir/nodejs-project"
[ -d "$engine" ] || { echo "no engine in $app_dir; install the app first" >&2; exit 1; }

# The versions the bundle actually carries, against the ones the repo pins.
dsh="$(node -p "require('$engine/node_modules/@deepseek-ai/dsh/package.json').version")"
bot="$(node -p "require('$engine/node_modules/ds-bot/package.json').version")"
imagegen="$(node -p "require('$engine/node_modules/dsh-image-gen/package.json').version")"
pinned_dsh="$(node -p "require('$root/engine/package.json').dependencies['@deepseek-ai/dsh']")"
pinned_bot="$(node -p "require('$root/engine/plugins/ios-host/pins.json')['ds-bot'].version")"
pinned_imagegen="$(node -p "require('$root/engine/plugins/ios-host/pins.json')['dsh-image-gen'].version")"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_dir/Info.plist")"
printf 'app %s (%s) · engine dsh %s · ds-bot %s · dsh-image-gen %s\n' "$app_version" "$app_build" "$dsh" "$bot" "$imagegen"

# Every screen the Debug build routes by launch argument (MainView.openForChecks,
# ConversationView). Each is terminated first so the launch argument is re-read.
if [ "${SMOKE_SCREENS:-full}" = key ]; then
  screens=(home settings imagegen plugins store schedules connectors capabilities miniapps whatsnew)
else
  screens=(home drawer settings imagegen plugins store schedules signin support share watch connectors
           whatsnew capabilities phonecontrol remote start fishpocket topup miniapps workbench
           filesearch approval question timeline)
fi
# The engine prints its URL with the launch token into the app's data container;
# every launch has a new token, so a 303 means this launch's engine is up.
data_dir() { xcrun simctl get_app_container "$device" "$bundle" data; }
engine_up() {
  local url
  url="$(cat "$(data_dir)/Library/Application Support/dsh-ios/root/home/dsh/.ios/web-url" 2>/dev/null)" || return 1
  [ "$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$url")" = 303 ]
}
# iPhone Duo has more than one screen and `simctl io` wants to be told which:
# display 1 is its primary one. The posture is set in Device Hub by hand; this
# captures the one the simulator is in and does not open or close it.
shot() {
  xcrun simctl io "$device" screenshot "$1" >/dev/null 2>&1 ||
    xcrun simctl io "$device" screenshot --display=1 "$1" >/dev/null 2>&1
}
missed=0
for name in "${screens[@]}"; do
  xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || true
  args=()
  [ "$name" = home ] || args+=(-dshOpen "$name")
  # These two are a tab and a page of a tab: the conversation the app would
  # restore on top of the tabs hides them, so it starts on the session list.
  case "$name" in store|miniapps) args+=(-dsh.lastPlace sessions) ;; esac
  # The first launch after a cold boot of an older runtime can fail with "the
  # system shell probably crashed"; the next attempt finds it up.
  for attempt in 1 2 3; do
    SIMCTL_CHILD_DSH_IOS_PORT="$port" xcrun simctl launch "$device" "$bundle" ${args[@]+"${args[@]}"} >/dev/null 2>&1 && break
    sleep 6
  done
  # A page drawn before the engine answers is a skeleton: wait for the engine,
  # then for the page to settle.
  for _ in $(seq 45); do engine_up && break; sleep 1; done
  sleep 10
  shot "$out/$name.png" || { echo "no screenshot of $name" >&2; missed=$((missed + 1)); }
done
echo "screens: $out"

web_url="$(cat "$(data_dir)/Library/Application Support/dsh-ios/root/home/dsh/.ios/web-url")"
jar="$(mktemp -t dsh-smoke)"
trap 'rm -f "$jar"' EXIT
host="$(printf '%s' "$web_url" | sed -E 's#^[a-z]+://([^/]+)/.*#\1#')"
printf 'engine at %s\n' "$host"
code="$(curl -s -c "$jar" -o /dev/null -w '%{http_code}' "$web_url")"
[ "$code" = 303 ] || { echo "launch token refused ($code): $web_url" >&2; exit 1; }
call() { # call <endpoint> <args json>
  curl -s -b "$jar" -H 'Content-Type: application/json' \
    -d "{\"type\":\"client-request\",\"rpcId\":\"smoke\",\"method\":\"$1\",\"payload\":{\"args\":$2}}" \
    "http://$host/api/$1"
}

fail=0
check() { # check <label> <node expression over $r> <json>
  local label="$1" expr="$2" json="$3"
  if printf '%s' "$json" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const r=JSON.parse(s);process.exit((${expr})?0:1)})"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label"
    fail=1
  fi
}

bundles="$(call pluginManager/listBundles '{}')"
[ "$dsh" = "$pinned_dsh" ] || { echo "FAIL engine/package.json pins dsh $pinned_dsh, bundle has $dsh"; fail=1; }
check "every DSH bundle the engine lists is $dsh" \
  "r.result.value.filter(b => b.name.startsWith('@deepseek-ai/') && b.version).every(b => b.version === '$dsh')" "$bundles"
check "ds-bot bundle is $bot (pins.json says $pinned_bot)" \
  "r.result.value.some(b => b.name === 'ds-bot' && b.version === '$bot')" "$bundles"
[ "$bot" = "$pinned_bot" ] || { echo "FAIL pins.json pins ds-bot $pinned_bot, bundle has $bot"; fail=1; }
check "dsh-image-gen bundle is $imagegen (pins.json says $pinned_imagegen)" \
  "r.result.value.some(b => b.name === 'dsh-image-gen' && b.version === '$imagegen')" "$bundles"
[ "$imagegen" = "$pinned_imagegen" ] || { echo "FAIL pins.json pins dsh-image-gen $pinned_imagegen, bundle has $imagegen"; fail=1; }

rows="$(call pluginManager/listPlugins '{}')"
check "bot row mounted without error" \
  "r.result.value.some(x => (x.entryId === 'include:bot') && x.enabled === true && !x.error)" "$rows"
check "image-gen row mounted without error" \
  "r.result.value.some(x => /(^|:)image-gen$/.test(x.entryId) && x.enabled === true && !x.error)" "$rows"
check "no plugin row reports an error" "r.result.value.every(x => !x.error)" "$rows"

state="$(curl -s -b "$jar" -H 'Content-Type: application/json' -d '{"endpoint":"state","payload":{}}' \
  "http://$host/api/bot")"
check "ds-bot backend answers /api/bot" "r.ok === true && Array.isArray(r.value.bots)" "$state"

check "image-gen settings are served" "r.result.ok === true && r.result.value.namespaces.some(n => n.ns === 'image-gen')" \
  "$(call settings/describe '{}')"
health="$(curl -s -b "$jar" "http://$host/plugins/dsh-image-gen/settings-health")"
check "dsh-image-gen answers its settings-health route" "typeof r === 'object' && r !== null" "$health"

check "session list reads" "r.result.ok === true && Array.isArray(r.result.value.items)" \
  "$(call session/list '{"_request":{}}')"

[ "$missed" -eq 0 ] || { echo "FAIL $missed screens have no screenshot"; fail=1; }
[ "$fail" -eq 0 ] || { echo 'smoke: FAILED'; exit 1; }
echo 'smoke: passed — review the screenshots in '"$out"
