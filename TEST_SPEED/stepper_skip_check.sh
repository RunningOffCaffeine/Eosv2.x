#!/bin/bash

log_file="/home/brite/printer_data/logs/klippy.log"
state_file="/home/brite/mcu_pos_state.txt"

# --- DEBUG: Show raw input
echo "DEBUG: Received params: $@"

# --- Parse ACTION param
for arg in "$@"; do
    if [[ "$arg" == ACTION=* ]]; then
        action="${arg#ACTION=}"
    fi
done

# Validate action
if [[ "$action" != "start" && "$action" != "check" ]]; then
    echo "Usage: $0 ACTION=start|check"
    exit 1
fi

# --- Extract the latest line that has stepper_x and stepper_y
line=$(grep "mcu: stepper_x" "$log_file" | tail -n1)

# DEBUG: Print log line
echo "DEBUG: raw log line = [$line]"

# Parse stepper_x and stepper_y using regex
if [[ $line =~ stepper_x:([-0-9]+)[[:space:]]stepper_y:([-0-9]+) ]]; then
    x=${BASH_REMATCH[1]}
    y=${BASH_REMATCH[2]}
else
    echo "Failed to parse stepper positions from: $line"
    exit 1
fi

# --- Handle 'start' action
if [ "$action" == "start" ]; then
    echo "$x $y" > "$state_file"
    echo "Saved initial position: X=$x Y=$y"
    exit 0
fi

# --- Handle 'check' action
if [ "$action" == "check" ]; then
    if [ ! -f "$state_file" ]; then
        echo "No initial position saved."
        exit 1
    fi

    read x0 y0 < "$state_file"

    dx=$(( x - x0 ))
    dy=$(( y - y0 ))

    dx=${dx#-}
    dy=${dy#-}

    x_thresh=32
    y_thresh=32

    echo "Initial: X=$x0 Y=$y0"
    echo "Final:   X=$x Y=$y"
    echo "Delta:   X=$dx Y=$dy"
    echo "Threshold: X=$x_thresh Y=$y_thresh"

    if (( dx > x_thresh || dy > y_thresh )); then
        echo "⚠️  Stepper SKIP detected! [ ΔX=$dx, ΔY=$dy ]"
        exit 2
    else
        echo "✅ Stepper movement within limits."
        exit 0
    fi
fi