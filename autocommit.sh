#!/bin/bash

# --- CONFIGURATION ---
config_folder=~/printer_data/config
branch=main

# Database Paths
moonraker_db=~/printer_data/database/moonraker-sql.db
spoolman_db_dir=~/.local/share/spoolman

# Spoolman API Port (Default is usually 7912 or 8000)
SPOOLMAN_PORT=7912 

echo "--- Starting Live Backup ---"

# 1. Safe Moonraker Backup (Hot Copy)
if [ -f "$moonraker_db" ]; then
    echo "Cloning Moonraker DB..."
    sqlite3 "$moonraker_db" ".backup '$config_folder/moonraker-sql.db'"
    echo "✔ Moonraker DB synced."
fi

# 2. Safe Spoolman Backup via API
# We trigger Spoolman to make its own backup, then grab that file
echo "Triggering Spoolman API backup..."
curl -X POST "http://localhost:$SPOOLMAN_PORT/api/v1/backup" -s

# Find the most recent backup Spoolman just generated
latest_spool_backup=$(ls -t $spoolman_db_dir/backups/*.db 2>/dev/null | head -1)

if [ -f "$latest_spool_backup" ]; then
    cp "$latest_spool_backup" "$config_folder/spoolman.db"
    echo "✔ Spoolman DB synced from: $(basename $latest_spool_backup)"
else
    # Fallback: if API backup fails, try a direct copy (slightly riskier but usually fine)
    echo "API backup not found, attempting direct copy of spoolman.db..."
    cp "$spoolman_db_dir/spoolman.db" "$config_folder/spoolman.db"
fi

# --- 3. GITHUB PUSH ---
echo "Finalizing Git push..."
cd $config_folder
git pull origin $branch --no-rebase
git add .
current_date=$(date +"%Y-%m-%d %T")
git commit -m "Live Printer Backup: $current_date"
git push origin $branch

echo "--- Backup Complete! Services stayed online. ---"