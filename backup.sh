#!/bin/bash

# --- CONFIGURATION ---
repo_folder=~/printer_data/config
branch=main

# Paths to live files
moonraker_db=~/printer_data/database/moonraker-sql.db
spoolman_db_dir=~/.local/share/spoolman
SPOOLMAN_PORT=7912 

echo "--- Starting Organized Backup ---"

# 1. Create subfolder structure if it doesn't exist
mkdir -p "$repo_folder/backups/moonraker"
mkdir -p "$repo_folder/backups/spoolman"

# 2. Backup Moonraker DB (Hot Copy)
if [ -f "$moonraker_db" ]; then
    echo "Cloning Moonraker DB..."
    sqlite3 "$moonraker_db" ".backup '$repo_folder/backups/moonraker/moonraker-sql.db'"
fi

# 3. Backup Spoolman DB (API Trigger)
echo "Triggering Spoolman API backup..."
curl -X POST "http://localhost:$SPOOLMAN_PORT/api/v1/backup" -s
latest_spool_backup=$(ls -t $spoolman_db_dir/backups/*.db 2>/dev/null | head -1)

if [ -f "$latest_spool_backup" ]; then
    cp "$latest_spool_backup" "$repo_folder/backups/spoolman/spoolman.db"
    echo "✔ Spoolman DB organized."
fi

# 4. Git Push
cd $repo_folder
git pull origin $branch --no-rebase
git add -A
current_date=$(date +"%Y-%m-%d %T")
git commit -m "Organized Backup: $current_date"
git push origin $branch

echo "--- Backup Complete! ---"