#!/bin/bash
# lock-kernel.sh
#
# locks specific installed kernel with versionlock

KERNELVER="5.4.7"

BOOTIMAGE=$(ls /boot/vmlinuz* | grep $KERNELVER)
grubby --set-default $BOOTIMAGE
rpm -qa kernel* | grep $KERNELVER | xargs dnf versionlock add

#dnf versionlock delete *
