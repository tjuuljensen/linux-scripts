#!/bin/bash
DISKS=$(lsblk -l | grep disk | awk '{print $1}') #sda, sdb
LATESTDEVICE=$(dmesg | tail | grep -Eo '\[...\]' | uniq | grep -oP '(?<=\[)[^\]]+')

for DISK in $DISKS ; do
  DISKDEVICE="/dev/$DISK"
  USBSTORAGE=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep usb-storage )
  if [[ ! -z ${USBSTORAGE} ]] ; then

    ID_VENDOR=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep "ID_VENDOR=" )
    ID_MODEL=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep "ID_MODEL=" )
    ID_FS_LABEL=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep "ID_FS_LABEL=" )
    #echo "ps -C dd -f | sed 's/^.*dd/dd/g' | grep $DISKDEVICE"
    RUNNINGDDCMD=$(pgrep "dd" -a | grep $DISKDEVICE | cut -c 7-)
    RUNNINGPID=$(pgrep "dd" -a | grep $DISKDEVICE | awk '{print $1}')

    echo "$DISKDEVICE - ${ID_VENDOR##*=} ${ID_MODEL##*=}  ${ID_FS_LABEL##*=}   $RUNNINGDDCMD $RUNNINGPID"
    #sudo bash -c "dd if=/dev/urandom of=$DISKDEVICE bs=1M conv=fdatasync &"

  fi
done
