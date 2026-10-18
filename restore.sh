#!/usr/bin/env bash
# EOS restore from origin/main, with pre-restore recovery snapshot.
# Overwrites tracked config files and (when available) Moonraker/Spoolman DBs.
# Untracked files are NOT deleted automatically.
set -Eeuo pipefail
umask 077

REPO="${EOS_CONFIG_DIR:-$HOME/printer_data/config}"
BRANCH="${EOS_GIT_BRANCH:-main}"
REMOTE="${EOS_GIT_REMOTE:-origin}"
RECOVERY_ROOT="${EOS_RECOVERY_DIR:-$HOME/eos-recovery}"
MOONRAKER_DB="${EOS_MOONRAKER_DB:-$HOME/printer_data/database/moonraker-sql.db}"
SPOOLMAN_DB="${EOS_SPOOLMAN_DB:-$HOME/.local/share/spoolman/spoolman.db}"
MOONRAKER_SERVICE="${EOS_MOONRAKER_SERVICE:-moonraker}"
SPOOLMAN_SERVICE="${EOS_SPOOLMAN_SERVICE:-}"

log() { printf '[EOS restore] %s\n' "$*"; }
die() { printf '[EOS restore] ERROR: %s\n' "$*" >&2; exit 1; }
services_to_restart=()
restart_stopped_services() {
    local service
    for service in "${services_to_restart[@]}"; do
        if sudo systemctl start "$service"; then
            log "Started $service"
        else
            printf '[EOS restore] WARNING: Could not restart %s; check systemctl status.\n' "$service" >&2
        fi
    done
}
trap 'rc=$?; printf "[EOS restore] FAILED (exit %s, line %s); recovery files were saved before modifications.\n" "$rc" "$LINENO" >&2; exit "$rc"' ERR
trap restart_stopped_services EXIT

command -v git >/dev/null || die 'git is required'
command -v python3 >/dev/null || die 'python3 is required'
command -v tar >/dev/null || die 'tar is required'
[[ -d "$REPO/.git" ]] || die "No .git directory at $REPO"
cd "$REPO"
[[ "$(git branch --show-current)" == "$BRANCH" ]] || die "Checkout $BRANCH before restoring"
log "Fetching $REMOTE/$BRANCH (no local changes overwritten yet)..."
git fetch "$REMOTE" "$BRANCH"
remote_ref="refs/remotes/$REMOTE/$BRANCH"
git show-ref --verify --quiet "$remote_ref" || die "Missing $remote_ref"
git cat-file -e "$remote_ref^{commit}" || die 'Fetched reference does not resolve to a commit'
log "Current local commit: $(git rev-parse --short HEAD)"
log "GitHub target commit: $(git rev-parse --short "$remote_ref")"
log 'Tracked changes that would be overwritten:'
git diff --stat HEAD "$remote_ref" || true
log 'Uncommitted/untracked changes (snapshot will preserve them):'
git status --short || true

printf '\nTHIS WILL REPLACE TRACKED EOS CONFIG FILES AND AVAILABLE DATABASES WITH GITHUB VERSIONS.\n'
printf 'Enter RESTORE to proceed: '
IFS= read -r confirm
[[ "$confirm" == RESTORE ]] || { log 'Canceled. No files changed.'; exit 0; }

mkdir -p "$RECOVERY_ROOT"
recovery="$(mktemp -d "$RECOVERY_ROOT/restore-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
log "Saving recovery snapshot at $recovery"
# tar stores symlinks as links; exclude Git's internal object database.
tar -czf "$recovery/config-before.tar.gz" -C "$REPO" --exclude='./.git' .
tar -tzf "$recovery/config-before.tar.gz" >/dev/null
# Preserve local commits which might not be present on GitHub.
git bundle create "$recovery/local-git-history.bundle" --all
git bundle verify "$recovery/local-git-history.bundle" >/dev/null

sqlite_snapshot() {
    local source="$1" destination="$2"
    if ! python3 - "$source" "$destination" <<'PY'
import sqlite3,sys
src,dest=sys.argv[1:]
try:
    with sqlite3.connect('file:'+src+'?mode=ro',uri=True,timeout=15) as a:
        with sqlite3.connect(dest,timeout=15) as b:
            a.backup(b,pages=256,sleep=0.10)
            test=b.execute('PRAGMA quick_check').fetchone()[0]
            if test!='ok':raise RuntimeError(test)
except Exception as ex:
    print('Database snapshot failed: '+str(ex),file=sys.stderr)
    sys.exit(1)
PY
    then
        rm -f "$destination"
        die "Failed to snapshot current SQLite database: $source"
    fi
}
verify_sqlite() {
    python3 - "$1" <<'PY'
import sqlite3,sys
try:
    with sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True,timeout=10) as db:
        assert db.execute('PRAGMA quick_check').fetchone()[0]=='ok'
except Exception as ex:
    print('Invalid restored database: '+str(ex),file=sys.stderr)
    sys.exit(1)
PY
}

# Preserve current databases before services are stopped.
[[ ! -f "$MOONRAKER_DB" ]] || sqlite_snapshot "$MOONRAKER_DB" "$recovery/moonraker-before.db"
[[ ! -f "$SPOOLMAN_DB" ]] || sqlite_snapshot "$SPOOLMAN_DB" "$recovery/spoolman-before.db"

# Extract and verify the database versions FROM THE FETCHED GITHUB COMMIT
# before replacing any config file or stopping a service.
fetch_db() {
    local git_path="$1" output="$2"
    if git cat-file -e "$remote_ref:$git_path" 2>/dev/null; then
        git show "$remote_ref:$git_path" > "$output"
        verify_sqlite "$output"
        log "Verified GitHub database: $git_path"
    else
        log "No database at $git_path in GitHub; current local DB will be kept."
    fi
}
fetch_db 'backups/moonraker/moonraker-sql.db' "$recovery/moonraker-from-github.db"
fetch_db 'backups/spoolman/spoolman.db' "$recovery/spoolman-from-github.db"

# Resolve exact unit name. The original installation used 'Spoolman', but
# standard installations often use 'spoolman'. Avoid restoring a live DB.
loaded_unit() {
    [[ "$(systemctl show --property=LoadState --value "$1" 2>/dev/null || true)" == loaded ]]
}
if [[ -z "$SPOOLMAN_SERVICE" ]]; then
    for candidate in Spoolman spoolman; do
        if loaded_unit "$candidate"; then SPOOLMAN_SERVICE="$candidate"; break; fi
    done
fi
if [[ -f "$recovery/moonraker-from-github.db" ]]; then
    loaded_unit "$MOONRAKER_SERVICE" || die "Moonraker service '$MOONRAKER_SERVICE' not found; refusing live database replacement."
fi
if [[ -f "$recovery/spoolman-from-github.db" ]]; then
    [[ -n "$SPOOLMAN_SERVICE" ]] && loaded_unit "$SPOOLMAN_SERVICE" || die 'Spoolman service not found; refusing live database replacement.'
fi

stop_if_running() {
    local unit="$1" state
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    if [[ "$state" == active || "$state" == activating ]]; then
        log "Stopping $unit..."
        sudo systemctl stop "$unit"
        services_to_restart+=("$unit")
    fi
}
[[ ! -f "$recovery/moonraker-from-github.db" ]] || stop_if_running "$MOONRAKER_SERVICE"
[[ ! -f "$recovery/spoolman-from-github.db" ]] || stop_if_running "$SPOOLMAN_SERVICE"

# No git clean: untracked files are intentionally preserved.
log "Restoring tracked config from $remote_ref..."
git reset --hard "$remote_ref"

replace_db() {
    local source="$1" destination="$2" directory tmp
    directory="$(dirname "$destination")"
    mkdir -p "$directory"
    tmp="$(mktemp "$directory/.eos-restore-XXXXXXXX.db")"
    cp "$source" "$tmp"
    if [[ -e "$destination" ]]; then
        chmod --reference="$destination" "$tmp"
        # Running as the database owner is recommended; preserve ownership when possible.
        chown --reference="$destination" "$tmp" 2>/dev/null || true
    fi
    # Database services must be stopped before removing the old WAL/SHM.
    rm -f "${destination}-wal" "${destination}-shm"
    mv -f "$tmp" "$destination"
}
[[ ! -f "$recovery/moonraker-from-github.db" ]] || replace_db "$recovery/moonraker-from-github.db" "$MOONRAKER_DB"
[[ ! -f "$recovery/spoolman-from-github.db" ]] || replace_db "$recovery/spoolman-from-github.db" "$SPOOLMAN_DB"

log 'Checking symlinks (broken symlinks are reported but not deleted)...'
find "$REPO" -path "$REPO/.git" -prune -o -type l ! -exec test -e '{}' \; -print || true
log 'SUCCESS: restore completed. Stopped services will be restarted now.'
log "Pre-restore recovery snapshot: $recovery"
log 'Untracked files were preserved. Run git status --short to review them.'