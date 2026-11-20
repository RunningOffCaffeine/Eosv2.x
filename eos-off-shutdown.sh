#!/usr/bin/env bash
# EOS | Backup-verified Raspberry Pi shutdown
# Called ONLY by [gcode_shell_command eos_off_shutdown] after hotend cooldown.
set -Eeuo pipefail
umask 077

REPO="${EOS_CONFIG_DIR:-$HOME/printer_data/config}"
BACKUP="$REPO/backup.sh"
MOONRAKER_URL="${EOS_MOONRAKER_URL:-http://127.0.0.1:7125}"

log() { printf '[EOS OFF] %s\n' "$*"; }
die() { printf '[EOS OFF] ERROR: %s. Raspberry Pi will remain ON.\n' "$*" >&2; exit 1; }

[[ -f "$BACKUP" ]] || die "Backup script is missing: $BACKUP"
command -v curl >/dev/null || die 'curl is not installed'

log 'Starting verified EOS backup before OS shutdown...'
if bash "$BACKUP"; then
    log 'Backup script completed successfully; requesting full OS shutdown.'
else
    rc=$?
    printf '[EOS OFF] ERROR: Backup failed (exit %s). OS shutdown canceled.\n' "$rc" >&2
    exit "$rc"
fi

# Flush writes before asking Moonraker to shut down the Raspberry Pi.
sync
# Localhost is a trusted client in the supplied EOS moonraker.conf.
# Moonraker must be authorized to shut down the host OS.
if ! curl --fail --silent --show-error --connect-timeout 3 --max-time 15 \
    --request POST "$MOONRAKER_URL/machine/shutdown"; then
    die 'Moonraker shutdown request failed; check Moonraker permissions and logs'
fi
log 'Moonraker shutdown request accepted.'
