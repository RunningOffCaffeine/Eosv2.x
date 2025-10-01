#!/bin/bash

# Parameter: filename (initial.txt or final.txt)
target_file="$1"
log_path="/home/brite/printer_data/logs/klippy.log"

line=$(grep "MCU Position" "$log_path" | tail -n1)

if [[ $line =~ x=([-0-9]+)\ y=([-0-9]+) ]]; then
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}" > "/home/brite/printer_data/config/TEST_SPEED/${target_file}"
    echo "Saved MCU position to ${target_file}: X=${BASH_REMATCH[1]}, Y=${BASH_REMATCH[2]}"
else
    echo "Could not parse MCU position from log."
fi