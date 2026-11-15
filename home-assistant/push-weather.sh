#!/usr/bin/env bash
# Puts Home Assistant's weather on TV Home's date line: "SATURDAY 14 NOVEMBER · 12° RAIN".
#
# TV Home has no internet permission, so it can't fetch the weather itself. Something on your network
# writes it into a TV setting over adb, and TV Home (and the Christmas screensaver) show it. A reading
# older than three hours is hidden rather than shown stale, so if this stops running, the weather just
# disappears.
#
#   HA_URL=http://192.168.1.10:8123 HA_TOKEN_FILE=~/.ha-token TV=192.168.1.50 ./push-weather.sh
#
# Run it every 5 or 10 minutes. With cron (crontab -e):
#   */10 * * * * HA_URL=http://192.168.1.10:8123 HA_TOKEN_FILE=$HOME/.ha-token TV=192.168.1.50 /path/to/push-weather.sh
#
# HA_TOKEN_FILE holds a long-lived access token and nothing else (Home Assistant > your profile >
# Security > Long-lived access tokens); chmod 600 it. WEATHER picks the entity (default
# weather.forecast_home, the one Home Assistant's built-in Met.no integration makes).
# Needs curl and adb. When the TV is off or asleep it quietly does nothing and the next run catches up.
set -euo pipefail

: "${HA_URL:?set HA_URL, e.g. http://192.168.1.10:8123}"
: "${HA_TOKEN_FILE:?set HA_TOKEN_FILE to a file holding a long-lived access token}"
: "${TV:?set TV to the TV IP address}"
WEATHER="${WEATHER:-weather.forecast_home}"
case "$TV" in *:*) SERIAL="$TV" ;; *) SERIAL="$TV:5555" ;; esac

# The token goes to curl as a header file, so it never shows up in the process list.
json="$(curl -fsS -m 10 -H @<(printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' < "$HA_TOKEN_FILE")") \
  "$HA_URL/api/states/$WEATHER")" || { echo "Home Assistant didn't answer for $WEATHER" >&2; exit 1; }
temp="$(printf '%s' "$json" | grep -o '"temperature":[-0-9.]*' | awk -F: 'NR == 1 { print $2 }')"
cond="$(printf '%s' "$json" | grep -o '"state":"[^"]*"' | awk -F'"' 'NR == 1 { print $4 }')"
[ -n "$temp" ] || { echo "$WEATHER has no temperature" >&2; exit 1; }

case "$cond" in
  clear-night) word=Clear ;; cloudy) word=Cloudy ;; exceptional) word=Severe ;; fog) word=Fog ;;
  hail) word=Hail ;; lightning) word=Thunder ;; lightning-rainy) word=Storms ;;
  partlycloudy) word="Partly cloudy" ;; pouring) word="Heavy rain" ;; rainy) word=Rain ;;
  snowy) word=Snow ;; snowy-rainy) word=Sleet ;; sunny) word=Sunny ;; windy|windy-variant) word=Windy ;;
  *) word="$cond" ;;
esac
text="$(printf '%.0f' "$temp")° $word"

adb connect "$SERIAL" >/dev/null 2>&1 || true
[ "$(adb -s "$SERIAL" get-state 2>/dev/null || true)" = device ] || exit 0
adb -s "$SERIAL" shell "settings put global bravia_weather '$(date +%s)|$text'"
echo "$(date '+%F %T') TV shows: $text"
