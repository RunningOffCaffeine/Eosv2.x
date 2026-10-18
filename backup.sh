#!/usr/bin/env bash
# EOS configuration + Moonraker/Spoolman backup
# Works with normal Git repositories (including symlinks). Never force-pushes.
set -Eeuo pipefail
umask 077

REPO="${EOS_CONFIG_DIR:-$HOME/printer_data/config}"
BRANCH="${EOS_GIT_BRANCH:-main}"
REMOTE="${EOS_GIT_REMOTE:-origin}"
MOONRAKER_DB="${EOS_MOONRAKER_DB:-$HOME/printer_data/database/moonraker-sql.db}"
SPOOLMAN_DIR="${EOS_SPOOLMAN_DIR:-$HOME/.local/share/spoolman}"
SPOOLMAN_PORT="${EOS_SPOOLMAN_PORT:-7912}"

log() { printf '[EOS backup] %s\n' "$*"; }
die() { printf '[EOS backup] ERROR: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "[EOS backup] FAILED (exit %s, line %s). GitHub backup is NOT confirmed; any local commit remains on disk.\n" "$rc" "$LINENO" >&2' ERR

command -v git >/dev/null || die 'git is not installed'
command -v python3 >/dev/null || die 'python3 is not installed'
command -v curl >/dev/null || die 'curl is not installed'
[[ -d "$REPO/.git" ]] || die "No .git directory at $REPO"
cd "$REPO"
[[ "$(git branch --show-current)" == "$BRANCH" ]] || die "Checkout branch $BRANCH before backing up (currently: $(git branch --show-current))."
git remote get-url "$REMOTE" >/dev/null || die "Git remote '$REMOTE' is unavailable"

# Ensure prior corruption has not returned before writing further Git objects.
log 'Verifying local Git object database...'
git fsck --full >/dev/null || die 'Git object corruption detected. Configuration NOT pushed.'

# Atomic, consistent SQLite backup via Python's built-in online backup API.
# Each destination is replaced only after SQLite quick_check passes.
sqlite_snapshot() {
    local source="$1" destination="$2" directory tmp
    [[ -s "$source" ]] || die "SQLite source is missing/empty: $source"
    directory="$(dirname "$destination")"
    mkdir -p "$directory"
    tmp="$(mktemp "$directory/.eos-db-XXXXXXXX.db")"
    if ! python3 - "$source" "$tmp" <<'PY'
import sqlite3, sys
src_path, dst_path = sys.argv[1:]
try:
    with sqlite3.connect('file:' + src_path + '?mode=ro', uri=True, timeout=15) as src:
        with sqlite3.connect(dst_path, timeout=15) as dst:
            src.backup(dst, pages=256, sleep=0.10)
            result = dst.execute('PRAGMA quick_check').fetchone()[0]
            if result != 'ok':
                raise RuntimeError('SQLite quick_check failed: ' + result)
except Exception as exc:
    print('SQLite backup failed: ' + str(exc), file=sys.stderr)
    sys.exit(1)
PY
    then
        rm -f "$tmp"
        die "Could not verify database backup: $source"
    fi
    mv -f "$tmp" "$destination"
}

log 'Creating consistent database snapshots...'
if [[ -f "$MOONRAKER_DB" ]]; then
    sqlite_snapshot "$MOONRAKER_DB" "$REPO/backups/moonraker/moonraker-sql.db"
    log 'Moonraker database verified and saved.'
else
    die "Moonraker database not found: $MOONRAKER_DB"
fi

# The Spoolman API returns a JSON object containing the actual backup path.
# Never silently reuse an old backup if the API fails or omits this path.
log 'Requesting fresh Spoolman API backup...'
response="$(curl --fail --silent --show-error --max-time 20 --request POST "http://127.0.0.1:$SPOOLMAN_PORT/api/v1/backup")"
spoolman_source="$(printf '%s' "$response" | python3 -c 'import json,sys; v=json.load(sys.stdin); print(v.get("path", "") if isinstance(v,dict) else "")')"
[[ -n "$spoolman_source" ]] || die "Spoolman did not return a backup path. Response: $response"
# Restrict the returned path to Spoolman's own backup directory.
case "$(realpath -m "$spoolman_source")" in
    "$(realpath -m "$SPOOLMAN_DIR/backups")"/*) ;;
    *) die "Unexpected Spoolman backup path: $spoolman_source" ;;
esac
sqlite_snapshot "$spoolman_source" "$REPO/backups/spoolman/spoolman.db"
log 'Spoolman database verified and saved.'

log 'Staging configuration, database snapshots, and symlinks...'
git add -A -- .
if ! git diff --cached --quiet; then
    git commit -m "EOS backup: $(date '+%Y-%m-%d %H:%M:%S %Z')"
else
    log 'No new file changes; checking for earlier unpushed commits.'
fi

# A normal push can fail when GitHub has moved. Do not auto-merge/rebase,
# hard-reset, or force-push from an unattended backup job.
log "Fetching $REMOTE/$BRANCH to validate the push..."
git fetch --quiet "$REMOTE" "$BRANCH"
remote_ref="refs/remotes/$REMOTE/$BRANCH"
git show-ref --verify --quiet "$remote_ref" || die "Cannot find fetched $remote_ref"
if ! git merge-base --is-ancestor "$remote_ref" HEAD; then
    die "Remote history diverged. Your local commit is saved. Reconcile $REMOTE/$BRANCH manually; no force push attempted."
fi
if [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$remote_ref")" ]]; then
    log 'SUCCESS: GitHub already matches local HEAD.'
else
    log 'Pushing pending commits to GitHub...'
    git push "$REMOTE" "HEAD:refs/heads/$BRANCH"
    log 'SUCCESS: GitHub push completed.'
fi
log "Backup complete at commit $(git rev-parse --short HEAD)."