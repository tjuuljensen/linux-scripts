#!/bin/bash
# Author: Torsten Juul-Jensen
# May 8, 2019
# Display current attached USB storage devices in the system (usb sticks) and dd commands running on the individual device
# Run the script with "watch list-usb-sticks.sh" to monitor currently attached devices
# Erase jobs started with the erase-usb.sh script will show up as output from this script

# Get the names of all disks in the system
DISKS=$(lsblk -l | grep disk | awk '{print $1}') #sda, sdb

# Loop through all disk devices
for DISK in $DISKS ; do
  DISKDEVICE="/dev/$DISK"
  USBSTORAGE=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep usb-storage )

  if [[ ! -z ${USBSTORAGE} ]] ; then #this disk device has an attached device of the type "usb-storage"
    # fetch information about the device
    ID_VENDOR=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep "ID_VENDOR=" )
    ID_MODEL=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep "ID_MODEL=" )
    ID_FS_LABEL=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep "ID_FS_LABEL=" )

    # get dd commend lines if there ara any running dd processes on this device
    RUNNINGDDCMD=$(pgrep "dd" -a | grep $DISKDEVICE ) #| cut -c 6-)
    #RUNNINGPID=$(pgrep "dd" -a | grep $DISKDEVICE | awk '{print $1}')

    # Print information to screen
    echo "$DISKDEVICE - ${ID_VENDOR##*=} ${ID_MODEL##*=} ${ID_FS_LABEL##*=}  $RUNNINGDDCMD $RUNNINGPID"

  fi
done
