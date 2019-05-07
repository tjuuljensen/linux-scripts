#!/bin/bash
#
# erase-usb.dh
# Erase USB device using dd and urandom.

DISKDEVICE=$1

USBSTORAGE=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep usb-storage )
if [[ ! -z ${USBSTORAGE} ]] ; then

  ID_VENDOR=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep "ID_VENDOR=" )
  ID_MODEL=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep "ID_MODEL=" )
  ID_FS_LABEL=$(udevadm info --query=all -n $DISKDEVICE 2>/dev/null | grep "ID_FS_LABEL=" )

  echo $DISKDEVICE
  echo "Starting background erase of USB device: ${ID_VENDOR##*=} ${ID_MODEL##*=}  ${ID_FS_LABEL##*=}"
  sudo bash -c "dd if=/dev/urandom of=$DISKDEVICE bs=1M conv=fdatasync &"
else
  echo Device not found or device is not a USB storage device
  exit 2
fi