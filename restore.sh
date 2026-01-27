#!/bin/bash

# --- CONFIGURATION ---
repo_folder=~/printer_data/config
branch=main
moonraker_dest=~/printer_data/database/moonraker-sql.db
spoolman_dest=~/.local/share/spoolman/spoolman.db

echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!! WARNING: This will overwrite local data from folders.  !!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -p "Proceed with organized restore? (y/n): " confirm

if [[ $confirm != [yY] ]]; then exit 1; fi

# 1. Sync from GitHub
cd $repo_folder
git fetch origin
git reset --hard origin/$branch

# 2. Stop Services
sudo systemctl stop moonraker spoolman

# 3. Restore Moonraker
if [ -f "$repo_folder/backups/moonraker/moonraker-sql.db" ]; then
    cp "$repo_folder/backups/moonraker/moonraker-sql.db" "$moonraker_dest"
    echo "✔ Moonraker restored from backups/moonraker/"
fi

# 4. Restore Spoolman
if [ -f "$repo_folder/backups/spoolman/spoolman.db" ]; then
    mkdir -p ~/.local/share/spoolman
    cp "$repo_folder/backups/spoolman/spoolman.db" "$spoolman_dest"
    echo "✔ Spoolman restored from backups/spoolman/"
fi

# 5. Restart Services
sudo systemctl start moonraker spoolman
echo "--- Restore Complete ---"