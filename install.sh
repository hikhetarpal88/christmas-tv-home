#!/usr/bin/env bash
# Sets up Christmas TV Home on an Android TV or Google TV, over the network with adb.
#
#   ./install.sh TV_IP                   install the app, load the Christmas theme, switch on the screensaver
#   ./install.sh TV_IP clips             copy the screensaver's video clips to the TV (downloads four from Mixkit)
#   ./install.sh TV_IP theme [FILE]      reload the Christmas theme (or another config.json, like a preview)
#   ./install.sh TV_IP home              make TV Home the Home screen (switches the stock home off)
#   ./install.sh TV_IP undo-home         switch the stock home back on
#   ./install.sh TV_IP smart-home FILE   install the Smart Home add-on and give it your Home Assistant details
#   ./install.sh TV_IP old-screensaver   put back the screensaver you had before
#   ./install.sh TV_IP remove-theme      back to TV Home's normal look
#
# You need adb (Android's platform-tools) on your PATH. On the TV: Settings > System > About, press OK
# on "Android TV OS build" seven times, then Developer options > USB debugging on (and Network debugging,
# if your TV has that switch). The first time, the TV asks "Allow USB debugging?": tick Always allow.
#
# The APKs come from ./dist if you built them with ./build.sh, otherwise from the latest GitHub release,
# checked against the release's SHA256SUMS. On Windows, the README has the same steps as adb commands.
set -euo pipefail

HERE="$(cd -P "$(dirname "$0")" && pwd)"
RELEASE="https://github.com/hikhetarpal88/christmas-tv-home/releases/latest/download"
PKG=com.gathin.tvhome
ADDON=io.github.maxhayim.smarthome
DREAM="$PKG/.HolidayDream"
FILES="/sdcard/Android/data/$PKG/files"
THEME_URI="content://$PKG.theme"
STAGE=/data/local/tmp/christmas-tv-home
GOOGLE_TV_HOME=com.google.android.apps.tv.launcherx
GOOGLE_TV_SETUP=com.google.android.tungsten.setupwraith
OTHER_HOMES="com.google.android.tvlauncher com.google.android.leanbacklauncher"
# name and Mixkit id of the default clips: https://mixkit.co/free-stock-video/<title>-<id>/
CLIPS="1-fireplace:2707 2-tree-lights:2710 3-snowy-moon:3350 4-tree-closeup:44579"

say()  { printf '%s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
tv()   { adb -s "$SERIAL" shell "$@" | tr -d '\r'; }

connect() {
  local i state
  command -v adb >/dev/null || die "adb isn't installed. It's in Android's platform-tools: https://developer.android.com/tools/releases/platform-tools"
  for i in $(seq 1 30); do
    adb connect "$SERIAL" >/dev/null 2>&1 || true
    state="$(adb -s "$SERIAL" get-state 2>/dev/null || true)"
    [ "$state" = device ] && return 0
    if [ "$i" = 1 ]; then
      say "Waiting for the TV at $SERIAL. If it asks \"Allow USB debugging?\", tick Always allow and press OK."
    fi
    sleep 2
  done
  die "Couldn't reach the TV at $SERIAL. Is it on, on the same network, with USB (or Network) debugging on?"
}

# True when package $1 is installed and enabled (-e) or disabled (-d), matching the whole name.
pkg_is() { tv pm list packages "$2" "$1" | awk -v p="package:$1" '$0 == p { f = 1 } END { exit !f }'; }

home_now() {
  tv cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME \
    | grep '/' | grep -v '=' | sed 's/^[[:space:]]*//' | tail -1 || true
}

# A local copy of a release APK: dist/ or this folder first, else download it and check its checksum.
fetch() {
  local name="$1" dir="$HERE/build/downloads" want
  if [ -f "$HERE/dist/$name" ]; then printf '%s' "$HERE/dist/$name"; return 0; fi
  if [ -f "$HERE/$name" ]; then printf '%s' "$HERE/$name"; return 0; fi
  mkdir -p "$dir"
  say "Downloading $name..." >&2
  curl -fsSL -o "$dir/$name" "$RELEASE/$name" || die "couldn't download $RELEASE/$name"
  curl -fsSL -o "$dir/SHA256SUMS" "$RELEASE/SHA256SUMS" || die "couldn't download $RELEASE/SHA256SUMS"
  want="$(awk -v n="$name" '$2 == n { print $1 }' "$dir/SHA256SUMS")"
  [ -n "$want" ] && [ "$want" = "$(sha256 "$dir/$name")" ] || die "$name doesn't match the release's SHA256SUMS"
  printf '%s' "$dir/$name"
}

install_apk() { # FILE PACKAGE
  local out
  if out="$(adb -s "$SERIAL" install -r "$1" 2>&1)"; then ok "installed $(basename "$1")"; return 0; fi
  case "$out" in
    *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
      die "$2 is already on the TV, signed with a different key (your own CleanYourTV build, probably).
  Build this repo yourself instead (./build.sh signs with your ~/.android key, so it installs over yours),
  or remove the old one first: adb -s $SERIAL uninstall $2 (that loses its on-TV settings)." ;;
    *) die "adb install failed: $out" ;;
  esac
}

# put LOCAL_FILE NAME: writes a file into TV Home's folder through its theme provider, so the file belongs
# to TV Home. (On Android 14, a file the adb shell creates under Android/data belongs to the shell and the
# app can't open it.) Android 8 and 9 have no `content write`; there a plain copy does the job.
put() {
  local src="$1" name="$2" staged result
  staged="$STAGE-$(printf '%s' "$name" | tr '/' '-')"
  adb -s "$SERIAL" push "$src" "$staged" >/dev/null 2>&1 || die "couldn't copy $(basename "$src") to the TV"
  result="$(tv "rm -f '$FILES/$name' 2>/dev/null
    o=\$(content write --uri '$THEME_URI/$name' < '$staged' 2>&1)
    if [ -z \"\$o\" ]; then echo provider
    elif mkdir -p '$(dirname "$FILES/$name")' && cp '$staged' '$FILES/$name'; then echo copied
    else echo \"failed: \$o\"; fi
    rm -f '$staged'")"
  case "$result" in
    provider|copied) return 0 ;;
    *) die "couldn't write $name on the TV: $result" ;;
  esac
}

# Restart TV Home so it rereads the theme. A force-stop also drops TV Home's accessibility services (the
# remote-key helpers, if you turned them on), so they're written back afterwards: the same dance as
# CleanYourTV's tools/theme.sh, which found that some TVs only rebind them after a full off and on.
restart_home() {
  tv "a=\$(settings get secure enabled_accessibility_services); am force-stop $PKG
    case \"\$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -n 1)\" in
      $PKG/*) am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null ;;
    esac
    case \"\$a\" in *$PKG*)
      sleep 1; settings put secure enabled_accessibility_services \"\$a\"; settings put secure accessibility_enabled 1
      sleep 1; settings put secure enabled_accessibility_services ''; settings put secure accessibility_enabled 0
      sleep 1; settings put secure enabled_accessibility_services \"\$a\"; settings put secure accessibility_enabled 1 ;;
    esac" >/dev/null
}

load_theme() {
  local cfg="${1:-$HERE/theme/christmas/config.json}"
  [ -f "$cfg" ] || die "no such file: $cfg"
  mkdir -p "$HERE/build"
  put "$cfg" config.json
  date +%s > "$HERE/build/theme_revision"
  put "$HERE/build/theme_revision" theme_revision
  restart_home
  ok "theme loaded from $(basename "$cfg") (the Christmas season runs until 1 January, then Home goes back to normal)"
}

set_screensaver() {
  local prev
  prev="$(tv settings get secure screensaver_components)"
  case "$prev" in
    ""|null|"$DREAM") ;;
    *) printf '%s\n' "$prev" > "$STATE_DIR/previous-screensaver" ;;
  esac
  tv "settings put secure screensaver_components $DREAM; settings put secure screensaver_enabled 1" >/dev/null
  case "$prev" in
    "$DREAM") ok "screensaver: already the Christmas one" ;;
    ""|null) ok "screensaver set to Christmas" ;;
    *) ok "screensaver set to Christmas (it was $prev; ./install.sh $TV old-screensaver puts it back)" ;;
  esac
}

cmd_setup() {
  local sdk
  sdk="$(tv getprop ro.build.version.sdk)"
  [ "${sdk:-0}" -ge 26 ] || die "TV Home needs Android 8.0 (API 26) or newer; this TV reports API ${sdk:-unknown}"
  install_apk "$(fetch christmas-tv-home.apk)" "$PKG"
  load_theme
  set_screensaver
  say ""
  say "Next:"
  say "  ./install.sh $TV clips   the fireplace and tree videos for the screensaver (about 190 MB)"
  say "  ./install.sh $TV home    make it your Home screen"
}

cmd_clips() {
  local dir="$HERE/clips" entry name id f n=0
  mkdir -p "$dir"
  if ! ls "$dir"/*.mp4 >/dev/null 2>&1; then
    for entry in $CLIPS; do
      name="${entry%%:*}"; id="${entry##*:}"; f="$dir/$name.mp4"
      say "Downloading $name.mp4 from Mixkit..."
      curl -fL --retry 2 -o "$f.part" "https://assets.mixkit.co/videos/$id/$id-1080.mp4" && mv "$f.part" "$f" \
        || { rm -f "$f.part"; die "couldn't download $name.mp4"; }
    done
  fi
  for f in "$dir"/*.mp4; do
    name="$(basename "$f")"
    case "$name" in
      *[!A-Za-z0-9_.-]*) warn "skipping '$name': use only letters, digits, dots, dashes and underscores"; continue ;;
    esac
    say "Copying $name to the TV..."
    put "$f" "holiday/$name"
    n=$((n + 1))
  done
  ok "$n clips on the TV. A clip with \"fireplace\" in its name is the main scene; it comes back between the others."
}

# Packages Android deletes saved Wi-Fi networks for when they're disabled: on Google TV the network you
# typed in during setup belongs to the setup app, so switching that off would knock the TV off Wi-Fi.
wifi_owned_by() {
  local conn
  conn="$(tv dumpsys connectivity)"
  case "$conn" in *"ni{ETHERNET"*) return 1 ;; esac
  tv dumpsys wifi | awk -v p="$1" '
    /Configured networks Begin/ { on = 1; next }
    /Configured networks End/ { on = 0 }
    on && /^ID: [0-9]+ SSID: "/ { s = $0; sub(/^ID: [0-9]+ SSID: "/, "", s); sub(/".*/, "", s); ssid = s }
    on && / cname=/ { c = $0; sub(/.* cname=/, "", c); sub(/ .*/, "", c); if (c == p) { print ssid; f = 1 } }
    END { exit !f }'
}

cmd_home() {
  local p off="" net now
  if [ "$(tv getprop ro.product.manufacturer)" = Amazon ]; then
    die "Fire TV won't let another app be the Home screen. The theme and the screensaver work anyway."
  fi
  case "$(tv cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME)" in
    *"$PKG/"*) ;;
    *) die "TV Home isn't installed yet. Run ./install.sh $TV first." ;;
  esac
  # Home goes to the highest-priority enabled home app, whatever you pick: the Google TV home first, then
  # its setup app's recovery screen, then everything else. So the setup app goes first (Home must never land
  # on the recovery screen, which tries to put the Google TV home back), and the stock home last.
  if pkg_is "$GOOGLE_TV_HOME" -e; then
    if pkg_is "$GOOGLE_TV_SETUP" -e; then off="$GOOGLE_TV_SETUP"; fi
    off="$off $GOOGLE_TV_HOME"
  fi
  for p in $OTHER_HOMES; do
    if pkg_is "$p" -e; then off="$off $p"; fi
  done
  if [ -z "$off" ]; then
    case "$(home_now)" in
      "$PKG/"*) ok "TV Home is already your Home screen"; return 0 ;;
    esac
  fi
  for p in $off; do
    if net="$(wifi_owned_by "$p")"; then
      die "$p saved your Wi-Fi network ($net) during setup, and Android deletes an app's networks when
  the app is switched off, so the TV would drop off Wi-Fi. Fix that first: Settings > Network & Internet >
  $net > Forget, then join it again with the remote (or plug in Ethernet). Then run this again."
    fi
  done
  for p in $off; do
    case "$(tv pm disable-user --user 0 "$p" 2>&1)" in
      *"new state: disabled-user"*) ok "switched off $p"; printf '%s\n' "$p" >> "$STATE_DIR/switched-off" ;;
      *) warn "couldn't switch off $p; undoing"; cmd_undo_home; exit 1 ;;
    esac
  done
  tv cmd package set-home-activity --user 0 "$PKG/.MainActivity" >/dev/null 2>&1 || true
  now="$(home_now)"
  case "$now" in
    "$PKG/"*) ;;
    *) warn "Home still goes to '${now:-nothing}', not TV Home; undoing"; cmd_undo_home; exit 1 ;;
  esac
  tv input keyevent KEYCODE_HOME
  ok "TV Home is your Home screen. ./install.sh $TV undo-home switches the stock home back on."
  say "  Before a factory reset, run undo-home first: the setup wizard needs the setup app."
  say "  On some TVs the remote's gear button stops opening quick settings; use the Settings pill on Home."
}

cmd_undo_home() {
  local p list homes comp
  # The stock home first, so Home goes straight back to it and never through the setup app's recovery screen.
  list="$GOOGLE_TV_HOME $OTHER_HOMES $GOOGLE_TV_SETUP"
  for p in $list; do
    if ! pkg_is "$p" -d; then continue; fi
    case "$(tv pm enable "$p" 2>&1)" in
      *"new state: enabled"*) ok "switched $p back on" ;;
      *) warn "couldn't switch $p back on; try: adb -s $SERIAL shell pm enable $p" ;;
    esac
  done
  rm -f "$STATE_DIR/switched-off"
  homes="$(tv cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME \
    | grep '/' | grep -v '=' | sed 's/^[[:space:]]*//' || true)"
  for p in $GOOGLE_TV_HOME $OTHER_HOMES; do
    comp="$(printf '%s\n' "$homes" | awk -v p="$p/" 'index($0, p) == 1 && !f { print; f = 1 }')"
    if [ -n "$comp" ]; then
      tv cmd package set-home-activity --user 0 "$comp" >/dev/null 2>&1 || true
      break
    fi
  done
  ok "Home button -> $(home_now)"
}

cmd_smart_home() {
  local cfg="${1:-}" staged=/data/local/tmp/smart-home-config.json out
  [ -n "$cfg" ] && [ -f "$cfg" ] \
    || die "usage: ./install.sh $TV smart-home my-config.json (start from home-assistant/smart-home.example.json)"
  grep -q '"token"' "$cfg" || die "$cfg has no \"token\""
  install_apk "$(fetch smart-home-addon.apk)" "$ADDON"
  # The token goes in as a file through the add-on's provider (only the adb shell may write it), never on a
  # command line, and the staged copy is removed straight away.
  adb -s "$SERIAL" push "$cfg" "$staged" >/dev/null 2>&1 || die "couldn't copy $cfg to the TV"
  out="$(tv "content write --user 0 --uri content://$ADDON.config/config.json < $staged 2>&1; rm -f $staged")"
  [ -z "$out" ] || die "Smart Home didn't take the config: $out"
  ok "Smart Home has your Home Assistant details."
  say "  Press Home on the TV: TV Home asks once whether to show the Smart Home card."
}

cmd_old_screensaver() {
  local prev
  prev="$(cat "$STATE_DIR/previous-screensaver" 2>/dev/null || true)"
  [ -n "$prev" ] || die "There's no record of the old screensaver here. Pick one in the TV's settings, or:
  adb -s $SERIAL shell settings put secure screensaver_components PACKAGE/CLASS"
  tv settings put secure screensaver_components "$prev" >/dev/null
  ok "screensaver back to $prev"
}

cmd_remove_theme() {
  tv "content delete --uri $THEME_URI/config.json >/dev/null 2>&1; rm -f $FILES/config.json" >/dev/null 2>&1 || true
  mkdir -p "$HERE/build"; date +%s > "$HERE/build/theme_revision"
  put "$HERE/build/theme_revision" theme_revision
  restart_home
  ok "theme removed; TV Home is back to its usual look"
}

[ $# -ge 1 ] || { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
TV="$1"; shift
case "$TV" in *:*) SERIAL="$TV" ;; *) SERIAL="$TV:5555" ;; esac
STATE_DIR="$HERE/.tv-${TV%%:*}"; mkdir -p "$STATE_DIR"
connect
case "${1:-setup}" in
  setup) cmd_setup ;;
  clips) cmd_clips ;;
  theme) load_theme "${2:-}" ;;
  home) cmd_home ;;
  undo-home) cmd_undo_home ;;
  smart-home) cmd_smart_home "${2:-}" ;;
  old-screensaver) cmd_old_screensaver ;;
  remove-theme) cmd_remove_theme ;;
  *) die "unknown command '$1'. Run ./install.sh with no arguments for the list." ;;
esac
