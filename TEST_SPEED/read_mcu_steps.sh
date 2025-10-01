#!/bin/bash

# Find the latest MCU Position line from the log
line=$(grep "MCU Position" /home/brite/printer_data/logs/klippy.log | tail -n1)

# Extract values using regex
if [[ $line =~ x=([-0-9]+)\ y=([-0-9]+) ]]; then
    echo "MCU Stepper Positions => X: ${BASH_REMATCH[1]}, Y: ${BASH_REMATCH[2]}"
else
    echo "Could not find MCU position data."
fi
