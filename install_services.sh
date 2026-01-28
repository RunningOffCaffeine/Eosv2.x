#!/bin/bash

# Configuration
BASE_DIR="$HOME"
KLIPPER_PATH="$HOME/klipper"

# Array of dependencies based on your moonraker.conf
# Format: "DirectoryName|RepoURL|InstallScript"
DEPS=(
    "crowsnest|https://github.com/mainsail-crew/crowsnest.git|tools/pkglist.sh"
    "klipper_z_calibration|https://github.com/protoloft/klipper_z_calibration.git|install.sh"
    "filaments-klipper-extra|https://github.com/garethky/filaments-klipper-extra.git|install.sh"
    "change-nozzle-klipper-extra|https://github.com/garethky/change-nozzle-klipper-extra.git|install.sh"
    "klipper-led_effect|https://github.com/julianschill/klipper-led_effect.git|install-led_effect.sh"
    "Klipper-Adaptive-Meshing-Purging|https://github.com/kyleisah/Klipper-Adaptive-Meshing-Purging.git|none"
    "klipper_auto_speed|https://github.com/anonoei/klipper_auto_speed.git|install.sh"
    "beacon_klipper|https://github.com/beacon3d/beacon_klipper.git|install.sh"
    "klippain_shaketune|https://github.com/Frix-x/klippain-shaketune.git|install.sh"
    "klipper_tmc_autotune|https://github.com/andrewmcgr/klipper_tmc_autotune.git|install.sh"
    "KlipperScreen|https://github.com/KlipperScreen/KlipperScreen.git|scripts/KlipperScreen-install.sh"
)

echo "🚀 Starting system and service installation..."

# 1. Install System Dependencies for backup/restore (sqlite3, curl, git)
echo "--- Checking System Dependencies ---"
SYS_PACKAGES=(sqlite3 curl git libcamera-apps)
PACKAGES_TO_INSTALL=()

for pkg in "${SYS_PACKAGES[@]}"; do
    if ! command -v "$pkg" &> /dev/null; then
        echo "⏳ $pkg is missing, adding to install list..."
        PACKAGES_TO_INSTALL+=("$pkg")
    else
        echo "✅ $pkg is already installed."
    fi
done

if [ ${#PACKAGES_TO_INSTALL[@]} -ne 0 ]; then
    echo "🛠️ Installing missing system packages: ${PACKAGES_TO_INSTALL[*]}..."
    sudo apt-get update && sudo apt-get install -y "${PACKAGES_TO_INSTALL[@]}"
fi

# 2. Process Moonraker Update Manager Dependencies
for dep in "${DEPS[@]}"; do
    IFS="|" read -r DIR URL SCRIPT <<< "$dep"
    
    echo "--- Processing: $DIR ---"
    
    # Clone if directory doesn't exist
    if [ ! -d "$BASE_DIR/$DIR" ]; then
        echo "📥 Cloning $URL..."
        git clone "$URL" "$BASE_DIR/$DIR"
        
        # Run Install Script if defined
        if [ "$SCRIPT" != "none" ]; then
            cd "$BASE_DIR/$DIR"
            if [ -f "$SCRIPT" ]; then
                echo "🛠️ Running install script: $SCRIPT..."
                chmod +x "$SCRIPT"
                ./"$SCRIPT"
            else
                # Fallback for common naming conventions
                if [ -f "install.sh" ]; then
                    chmod +x install.sh
                    ./install.sh
                fi
            fi
        fi
    else
        echo "✅ $DIR already exists, skipping clone/install."
    fi
    cd "$BASE_DIR"
done

# 3. Handle Special Includes (OctoEverywhere)
echo "--- Checking OctoEverywhere ---"
if [ ! -d "$HOME/octoeverywhere" ]; then
    echo "📥 Installing OctoEverywhere..."
    bash <(curl -s https://octoeverywhere.com/install.sh)
else
    echo "✅ OctoEverywhere already exists."
fi

echo "🎉 All specified dependencies and system tools processed!"
echo "⚠️  Note: Remember to restart Klipper and Moonraker."
