#!/bin/bash
LATESTDEVICE=$(dmesg | tail | grep -Eo '\[...\]' | uniq | grep -oP '(?<=\[)[^\]]+')
USBSTORAGE=$(udevadm info --query=all -n /dev/$LATESTDEVICE 2>/dev/null | grep usb-storage )
ID_VENDOR=$(udevadm info --query=all -n /dev/$LATESTDEVICE 2>/dev/null | grep "ID_VENDOR=" )
ID_MODEL=$(udevadm info --query=all -n /dev/$LATESTDEVICE 2>/dev/null | grep "ID_MODEL=" )
ID_FS_LABEL=$(udevadm info --query=all -n /dev/$LATESTDEVICE 2>/dev/null | grep "ID_FS_LABEL=" )
[[ ! -z ${USBSTORAGE} ]] && echo "/dev/$LATESTDEVICE - ${ID_VENDOR##*=} ${ID_MODEL##*=} - ${ID_FS_LABEL##*=}  " 
