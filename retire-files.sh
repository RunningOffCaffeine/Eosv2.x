#!/usr/bin/env bash
# Retire selected remote-tracked files absent from the EOS working tree.
# Creates a normal deletion commit on main; never rewrites Git history.
set -Eeuo pipefail
umask 077

REPO="${EOS_CONFIG_DIR:-$HOME/printer_data/config}"
BRANCH="${EOS_GIT_BRANCH:-main}"
REMOTE="${EOS_GIT_REMOTE:-origin}"
MANIFEST='.eos-retired-files'

log() { printf '[EOS retire] %s\n' "$*"; }
die() { printf '[EOS retire] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage:
  ./retire-files.sh --list
       List files tracked in GitHub's main branch but absent from EOS.
  ./retire-files.sh --retire PATH [PATH ...]
       Retire only the named, absent files (confirm before commit/push).

Paths are relative to ~/printer_data/config. Quote paths containing spaces.
No files on EOS are deleted by this script. The GitHub contents remain
recoverable from previous commits; git-filter-repo is not needed.
USAGE
}
valid_path() {
    local path="$1" part
    [[ -n "$path" && "$path" != /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
    [[ "$path" != *'//'* ]] || return 1
    local -a parts
    IFS='/' read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        [[ -n "$part" && "$part" != . && "$part" != .. && "$part" != .git ]] || return 1
    done
    [[ "$path" != "$MANIFEST" ]] || return 1
    return 0
}

(( $# > 0 )) || { usage; exit 2; }
mode="$1"; shift
[[ "$mode" == --list || "$mode" == --retire ]] || { usage; exit 2; }
[[ "$mode" != --list || $# -eq 0 ]] || die '--list does not accept paths.'
[[ "$mode" != --retire || $# -gt 0 ]] || die 'Supply exact paths after --retire.'
command -v git >/dev/null || die 'git is required'
[[ -d "$REPO/.git" ]] || die "No .git directory at $REPO"
cd "$REPO"
[[ "$(git branch --show-current)" == "$BRANCH" ]] || die "Checkout branch $BRANCH first."
[[ "$(git config --bool core.sparseCheckout || true)" != true ]] || die 'Sparse checkout is enabled; refusing missing-file retirement.'
git fsck --full >/dev/null || die 'Git object corruption detected.'
log "Fetching $REMOTE/$BRANCH (without altering EOS files)..."
git fetch --quiet "$REMOTE" "$BRANCH"
remote_ref="refs/remotes/$REMOTE/$BRANCH"
git show-ref --verify --quiet "$remote_ref" || die "Cannot resolve $remote_ref"

if [[ "$mode" == --list ]]; then
    count=0
    log 'Files tracked at GitHub HEAD but currently missing on EOS:'
    while IFS= read -r -d '' path; do
        if [[ ! -e "$path" && ! -L "$path" ]]; then
            printf '  %q\n' "$path"
            count=$((count + 1))
        fi
    done < <(git ls-tree -r -z --name-only "$remote_ref")
    log "$count missing GitHub-tracked path(s). Review carefully before retiring."
    exit 0
fi

# Do not mix retirement into an unrelated staged commit.
git diff --cached --quiet || die 'The Git index has staged changes; commit or unstage them before retiring files.'
if ! git merge-base --is-ancestor "$remote_ref" HEAD; then
    die "Local branch is behind/diverged from $remote_ref. Reconcile history first; no files were changed."
fi

paths=("$@")
for path in "${paths[@]}"; do
    valid_path "$path" || die "Invalid or protected relative path: $path"
    [[ ! -e "$path" && ! -L "$path" ]] || die "File exists on EOS and will NOT be retired: $path"
    git ls-tree -r --name-only "$remote_ref" -- "$path" | grep -Fxq -- "$path" || die "Not an exact file tracked on GitHub: $path"
    git ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || die "Path is not in the local Git index: $path"
done

printf '\nThe following already-absent files will be deleted in a NEW Git commit:\n'
printf '  %s\n' "${paths[@]}"
printf 'GitHub history will retain the old contents. No live EOS files are removed.\n'
printf 'Enter RETIRE to commit and push these deletions: '
IFS= read -r confirm
[[ "$confirm" == RETIRE ]] || { log 'Canceled; nothing changed.'; exit 0; }

if [[ ! -e "$MANIFEST" ]]; then
    printf '# Retired EOS config files. Exact paths relative to config root; no globs.\n' > "$MANIFEST"
fi
for path in "${paths[@]}"; do
    if ! grep -Fxq -- "$path" "$MANIFEST"; then
        printf '%s\n' "$path" >> "$MANIFEST"
    fi
    git add -u -- "$path"
done
git add -- "$MANIFEST"
git diff --cached --name-status
if git diff --cached --quiet; then
    log 'Nothing to commit: these files were already retired locally.'
    exit 0
fi
git commit -m "Retire obsolete EOS configuration files"
log 'Pushing normal fast-forward commit to GitHub...'
git push "$REMOTE" "HEAD:refs/heads/$BRANCH"
log "SUCCESS: retired ${#paths[@]} path(s). They remain recoverable in Git history."
