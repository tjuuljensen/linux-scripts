#!/bin/bash
DISKS=$(lsblk -l | grep disk | awk '{print $1}') #sda, sdb

for DISK in $DISKS ; do
  DISKDEVICE="/dev/$DISK"
  USBSTORAGE=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep usb-storage )
  if [[ ! -z ${USBSTORAGE} ]] ; then

    ID_VENDOR=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep "ID_VENDOR=" )
    ID_MODEL=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep "ID_MODEL=" )
    ID_FS_LABEL=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep "ID_FS_LABEL=" )

    RUNNINGDDCMD=$(pgrep "dd" -a | grep $DISKDEVICE ) #| cut -c 6-)
    #RUNNINGPID=$(pgrep "dd" -a | grep $DISKDEVICE | awk '{print $1}')

    echo "$DISKDEVICE - ${ID_VENDOR##*=} ${ID_MODEL##*=} ${ID_FS_LABEL##*=}  $RUNNINGDDCMD $RUNNINGPID"

  fi
done
