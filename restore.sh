#!/bin/bash

# --- CONFIGURATION ---
repo_folder=~/printer_data/config
branch=main
moonraker_dest=~/printer_data/database/moonraker-sql.db
spoolman_dest=~/.local/share/spoolman/spoolman.db

# Service Names (Match exactly as seen in systemctl)
MOONRAKER_SVC="moonraker"
SPOOLMAN_SVC="Spoolman"

echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!! WARNING: This will overwrite local data and databases  !!"
echo "!! with the version currently stored on GitHub ($branch). !!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -p "Proceed with organized restore? (y/n): " confirm

if [[ $confirm != [yY] ]]; then 
    echo "Restore aborted."
    exit 1
fi

# 1. Sync from GitHub
echo "Syncing with GitHub..."
cd $repo_folder
git fetch origin
git reset --hard origin/$branch

# 2. Stop Services
echo "Stopping services..."
sudo systemctl stop $MOONRAKER_SVC $SPOOLMAN_SVC 2>/dev/null

# 3. Restore Moonraker
if [ -f "$repo_folder/backups/moonraker/moonraker-sql.db" ]; then
    cp "$repo_folder/backups/moonraker/moonraker-sql.db" "$moonraker_dest"
    echo "✔ Moonraker database restored."
fi

# 4. Restore Spoolman
if [ -f "$repo_folder/backups/spoolman/spoolman.db" ]; then
    mkdir -p ~/.local/share/spoolman
    cp "$repo_folder/backups/spoolman/spoolman.db" "$spoolman_dest"
    echo "✔ Spoolman database restored."
fi

# 5. Check for Broken Symlinks
echo "Checking for broken symlinks..."
find . -type l | while read -r link; do
    if [ ! -e "$link" ]; then
        echo "⚠ WARNING: Broken symlink found: $link -> $(readlink "$link")"
    fi
done

# 6. Restart Services
echo "Restarting services..."
sudo systemctl start $MOONRAKER_SVC $SPOOLMAN_SVC 2>/dev/null

echo "--- Restore Complete ---"