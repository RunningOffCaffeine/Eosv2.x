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
failure_context='GitHub backup is NOT confirmed; any local commit remains on disk.'
trap 'rc=$?; printf "[EOS backup] FAILED (exit %s, line %s). %s\n" "$rc" "$LINENO" "$failure_context" >&2' ERR

command -v git >/dev/null || die 'git is not installed'
command -v python3 >/dev/null || die 'python3 is not installed'
command -v curl >/dev/null || die 'curl is not installed'
command -v realpath >/dev/null || die 'realpath is not installed'
[[ -d "$REPO/.git" ]] || die "No .git directory at $REPO"
cd "$REPO"
REPO="$(pwd -P)"
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

# Guard the explicit retirement list against accidentally reintroducing
# a retired configuration file into new commits.
if [[ -f .eos-retired-files ]]; then
    python3 - "$REPO" <<'PY_RETIRED'
import os, pathlib, subprocess, sys
repo = pathlib.Path(sys.argv[1]).resolve()
manifest = repo / '.eos-retired-files'
for entry in manifest.read_text().splitlines():
    if not entry or entry.startswith('#'):
        continue
    parts = entry.split('/')
    if (entry.startswith('/') or '\r' in entry or
            any(p in ('', '.', '..', '.git') for p in parts) or
            entry == '.eos-retired-files'):
        raise SystemExit('Invalid retired file path in .eos-retired-files: ' + repr(entry))
    result = subprocess.run(['git', '-C', str(repo), 'ls-files',
                             '--error-unmatch', '--', entry],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode == 0:
        raise SystemExit('Retired file is tracked/staged again: ' + entry)
    location = repo.joinpath(*parts)
    if location.exists() or location.is_symlink():
        raise SystemExit('Retired file has reappeared locally: ' + entry)
PY_RETIRED
fi
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
    log 'No pending commits; checking the remote directly.'
else
    log 'Pushing pending commits to GitHub...'
    git push "$REMOTE" "HEAD:refs/heads/$BRANCH"
fi

# git push succeeding is not enough for deletion: check the live remote ref.
# Do not remove any local archives unless GitHub itself advertises EXACTLY HEAD.
remote_head="$(git ls-remote --exit-code "$REMOTE" "refs/heads/$BRANCH" | awk 'NR==1 {print $1}')"
[[ -n "$remote_head" && "$remote_head" == "$(git rev-parse HEAD)" ]] || die 'Remote HEAD is not confirmed equal to local HEAD. No archive cleanup performed.'
log "SUCCESS: GitHub confirmed at $(git rev-parse --short HEAD)."
failure_context='Configuration/database commit is confirmed on GitHub. Archive cleanup may be incomplete; no unbacked files should have been removed.'

# Cloud-backed archive cleanup (opt-in via default EOS_CLEAN_ARCHIVES=1).
# A .zip/.bkp is eligible ONLY if it is tracked in the exact commit confirmed
# above, is a regular local file, and still matches its committed blob.
# Ignore .zip/.bkp files which are untracked, ignored, modified or symlinked.
if [[ "${EOS_CLEAN_ARCHIVES:-1}" == 1 ]]; then
    archive_paths=()
    while IFS= read -r -d '' path; do
        case "${path,,}" in
            *.zip|*.bkp) ;;
            *) continue ;;
        esac
        if [[ ! -f "$path" || -L "$path" ]]; then
            log "Skipping missing/non-regular/symlink archive: $path"
            continue
        fi
        # Protect against symlinked parent directories resolving outside repo.
        resolved="$(realpath -m -- "$path")"
        if [[ "$resolved" != "$REPO/"* ]]; then
            log "WARNING: Skipping path outside repository: $path"
            continue
        fi
        # Verify the bytes on disk still match what GitHub has received.
        committed_blob="$(git rev-parse --verify "HEAD:$path")"
        disk_blob="$(git hash-object -- "$path")"
        if [[ "$disk_blob" != "$committed_blob" ]]; then
            log "Skipping changed archive (not identical to pushed commit): $path"
            continue
        fi
        archive_paths+=("$path")
    done < <(git ls-files -z)

    if (( ${#archive_paths[@]} > 0 )); then
        log "Removing ${#archive_paths[@]} archive(s) whose exact bytes are backed up on GitHub..."
        # git rm deletes local files AND stages the removal; this is safe because
        # the immediately preceding commit containing them is on GitHub.
        for path in "${archive_paths[@]}"; do
            git rm -- "$path"
        done
        git commit -m 'EOS: retire cloud-backed ZIP/BKP archives'
        log 'Pushing archive-removal commit (normal non-forced push)...'
        git push "$REMOTE" "HEAD:refs/heads/$BRANCH"
        remote_head="$(git ls-remote --exit-code "$REMOTE" "refs/heads/$BRANCH" | awk 'NR==1 {print $1}')"
        [[ -n "$remote_head" && "$remote_head" == "$(git rev-parse HEAD)" ]] || die 'Archive-removal commit is not confirmed on GitHub; local cleanup commit is retained for retry.'
        log 'SUCCESS: archive-removal commit confirmed; files remain recoverable from prior Git history.'
    else
        log 'No eligible tracked .zip/.bkp files to clean. Untracked/ignored archives are never deleted.'
    fi
else
    log 'Archive cleanup disabled (EOS_CLEAN_ARCHIVES is not 1).'
fi
log "Backup complete at commit $(git rev-parse --short HEAD)."
