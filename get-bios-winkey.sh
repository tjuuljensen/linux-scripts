#!/bin/bash
# Outputs BIOS Windows Key

sudo strings /sys/firmware/acpi/tables/MSDM | tail -1
