#!/usr/bin/env bash
# EOS OFF | verified backup -> verified HS103 countdown -> clean Pi shutdown
# This plug powers EOS *and* the Raspberry Pi. Never turn the relay off directly.
set -Eeuo pipefail
umask 077

REPO="${EOS_CONFIG_DIR:-$HOME/printer_data/config}"
BACKUP="$REPO/backup.sh"
KASA="$REPO/eos-hs103.py"
PLUG_SETTINGS="$REPO/eos-hs103.env"
MOONRAKER_URL="${EOS_MOONRAKER_URL:-http://127.0.0.1:7125}"

log() { printf '[EOS OFF] %s\n' "$*"; }
die() { printf '[EOS OFF] ERROR: %s. Raspberry Pi remains ON.\n' "$*" >&2; exit 1; }

[[ -f "$BACKUP" && -f "$KASA" && -f "$PLUG_SETTINGS" ]] || \
    die 'Missing backup.sh, eos-hs103.py, or eos-hs103.env in the EOS config directory'
command -v curl >/dev/null && command -v python3 >/dev/null || die 'curl and python3 are required'
# shellcheck disable=SC1090
source "$PLUG_SETTINGS"
export EOS_HS103_IP EOS_HS103_DELAY EOS_HS103_EXPECTED_MAC

check_safe() {
    local response
    response="$(curl --fail --silent --show-error --connect-timeout 3 --max-time 8 \
        "$MOONRAKER_URL/printer/objects/query?extruder=temperature,target&print_stats=state")" || \
        die 'Moonraker/printer status unavailable; refusing shutdown'
    printf '%s' "$response" | python3 -c '
import json,sys
try:
 s=json.load(sys.stdin)["result"]["status"]
 t=s["extruder"]
 state=s["print_stats"]["state"]
 temp=float(t["temperature"])
 target=float(t["target"])
 if state not in ("standby", "complete", "cancelled", "error"):
  raise ValueError("active print state: " + str(state))
 if temp > 50 or target > 0:
  raise ValueError("hotend still hot or heater enabled (%.1f C, target %.1f C)" % (temp,target))
 print("[EOS OFF] Safety check OK: no print and hotend <=50C.")
except (ValueError,KeyError,TypeError) as ex:
 print("[EOS OFF] ERROR: printer not safe for shutdown: " + str(ex),file=sys.stderr)
 sys.exit(1)
' || die 'Refusing shutdown while printing, hot, or status uncertain'
}

log 'Checking printer state and HS103 countdown availability...'
check_safe
python3 "$KASA" preflight || die 'HS103 timer is unavailable; nothing will be powered off'

log 'Starting verified GitHub/SQLite backup...'
if bash "$BACKUP"; then
    log 'GitHub backup finished successfully.'
else
    rc=$?
    printf '[EOS OFF] ERROR: Backup failed (exit %s). Timer NOT armed. Shutdown canceled.\n' "$rc" >&2
    exit "$rc"
fi

# The backup may take minutes; check again before arming the external timer.
check_safe
sync
log 'Arming HS103 local OFF countdown (does not switch power off yet)...'
python3 "$KASA" arm || die 'Timer not confirmed. OS shutdown canceled. Check Kasa app if timer state uncertain'

log 'Requesting clean Raspberry Pi shutdown from Moonraker...'
response="$(mktemp)"
http_code=""
if http_code="$(curl --silent --show-error --connect-timeout 3 --max-time 12 \
    --output "$response" --write-out '%{http_code}' \
    --request POST "$MOONRAKER_URL/machine/shutdown")" && \
    [[ "$http_code" == 200 ]] && \
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1])).get("result") == "ok"' "$response"; then
    rm -f "$response"
    log 'Moonraker accepted OS shutdown. HS103 will remove AC power after its grace timer.'
    exit 0
fi
rm -f "$response"
printf '[EOS OFF] ERROR: OS shutdown could not be confirmed (HTTP %s). Trying to cancel HS103 countdown.\n' "$http_code" >&2
if python3 "$KASA" cancel; then
    die 'Shutdown was not confirmed; HS103 timer canceled. Inspect Moonraker status.'
else
    printf '[EOS OFF] CRITICAL: Could not cancel HS103 timer; check Kasa app NOW. Outlet may cut power.\n' >&2
    exit 1
fi
