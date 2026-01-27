#!/bin/bash

# --- CONFIGURATION ---
config_folder=~/printer_data/config
branch=main

# Destination Paths
moonraker_db_dest=~/printer_data/database/moonraker-sql.db
spoolman_db_dest=~/.local/share/spoolman/spoolman.db

echo "--- Starting Restore Process ---"

# 1. Pull latest from GitHub
echo "Pulling latest files from GitHub..."
cd $config_folder
git fetch origin
git reset --hard origin/$branch

# 2. Stop Services
echo "Stopping services for safe restore..."
sudo systemctl stop moonraker
sudo systemctl stop spoolman

# 3. Restore Moonraker Database
if [ -f "$config_folder/moonraker-sql.db" ]; then
    echo "Restoring Moonraker DB..."
    cp "$config_folder/moonraker-sql.db" "$moonraker_db_dest"
else
    echo "⚠ No Moonraker backup found in config folder."
fi

# 4. Restore Spoolman Database
if [ -f "$config_folder/spoolman.db" ]; then
    echo "Restoring Spoolman DB..."
    # Ensure the directory exists first
    mkdir -p ~/.local/share/spoolman
    cp "$config_folder/spoolman.db" "$spoolman_db_dest"
else
    echo "⚠ No Spoolman backup found in config folder."
fi

# 5. Restart Services
echo "Restarting services..."
sudo systemctl start moonraker
sudo systemctl start spoolman

echo "--- Restore Complete! ---"
echo "Please perform a FIRMWARE_RESTART in your dashboard."
