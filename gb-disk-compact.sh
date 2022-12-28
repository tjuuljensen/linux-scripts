#!/bin/bash
# gb-disk-compact.sh
# script to compact qcow2 format images (KVM, gnome-boxes)
#
# Author: Torsten Juul-Jensen
# Date: December 28, 2022
#
# Compacts a qcow2 disk and starts gnome boxes to trigger a user check of the VM
# Some VMs are slow booting after the compact.

file $1 | grep "QEMU QCOW2"

if [ $? -eq 0 ]
then
  DISKNAME=$(basename ${1})
  echo Converting and compacting image file...
  qemu-img convert -p -c -O qcow2 ${1} ${DISKNAME}.tmp
else
  echo "Filetype is not of the expected type" >&2
  exit 2
fi

if [ $? -eq 0 ]
then
  echo Moving original disk to .bak...
  mv ${1} ${DISKNAME}.bak
else
  echo "Error occured. Please proceed manually." >&2
  exit 2
fi

if [ $? -eq 0 ]
then
  echo Moving new disk to original location...
  mv ${DISKNAME}.tmp ${1}
  chmod 744 ${1}
else
  echo "Error occured. Please proceed manually." >&2
  exit 2
fi

echo Please check the integrity of the virtual machine.
pidof -q gnome-boxes || nohup gnome-boxes >/dev/null 2>&1 &

read -r -p "Do you want to delete the original disk? [y/N] " RESPONSE
RESPONSE=${RESPONSE,,}
if [[ $RESPONSE =~ ^(yes|y| ) ]] ; then
  echo  Deleting original disk file
  rm "${DISKNAME}.bak"
else
  read -r -p "Do you want to REVERT to the original disk? [y/N] " RESPONSE
  RESPONSE=${RESPONSE,,}
  if [[ $RESPONSE =~ ^(yes|y| ) ]] ; then
    rm ${1}
    mv ${DISKNAME}.bak ${1}
    exit 0
  else
    echo You must delete ${DISKNAME}.bak manually...
    exit 2
  fi
fi

echo Compacted succesfully
