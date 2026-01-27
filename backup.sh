#!/bin/bash

# --- CONFIGURATION ---
repo_folder=~/printer_data/config
branch=main
moonraker_db=~/printer_data/database/moonraker-sql.db
spoolman_db_dir=~/.local/share/spoolman
SPOOLMAN_PORT=7912

echo "--- Starting Organized Backup (Including Symlinks) ---"

# 1. Prepare Folders
mkdir -p "$repo_folder/backups/moonraker"
mkdir -p "$repo_folder/backups/spoolman"

# 2. Hot-Copy Databases
if [ -f "$moonraker_db" ]; then
    echo "Cloning Moonraker DB..."
    sqlite3 "$moonraker_db" ".backup '$repo_folder/backups/moonraker/moonraker-sql.db'"
fi

echo "Triggering Spoolman API backup..."
# We use a 5-second timeout so the script doesn't hang if Spoolman is down
curl -X POST "http://localhost:$SPOOLMAN_PORT/api/v1/backup" -s --max-time 5
latest_spool_backup=$(ls -t $spoolman_db_dir/backups/*.db 2>/dev/null | head -1)

if [ -f "$latest_spool_backup" ]; then
    cp "$latest_spool_backup" "$repo_folder/backups/spoolman/spoolman.db"
    echo "✔ Spoolman DB copied."
fi

# 3. Sync to GitHub
# The '|| exit' ensures we don't run git commands in the wrong directory if cd fails
cd "$repo_folder" || { echo "Error: Could not enter config directory"; exit 1; }

# Pull first to avoid merge conflicts
git pull origin $branch --no-rebase

# Add all changes, including deletions and symlinks
git add -A 

# Only commit if there are actually changes to save
if git diff-index --quiet HEAD --; then
    echo "No changes detected. Skipping push."
else
    current_date=$(date +"%Y-%m-%d %T")
    git commit -m "Organized Backup: $current_date"
    git push origin $branch
    echo "--- Backup Complete! ---"
fi