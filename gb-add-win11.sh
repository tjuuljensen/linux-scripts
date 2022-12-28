#!/bin/bash
#
# https://www.ctrl.blog/entry/how-to-win11-in-gnome-boxes.html

# Check requirements
clear
echo Checking required packages...
REQUIREDPACKAGES=("edk2-ovmf" "swtpm")
for i in ${!REQUIREDPACKAGES[@]};
do
  rpm -q --quiet ${REQUIREDPACKAGES[$i]}  || sudo dnf install -y ${REQUIREDPACKAGES[$i]}
done

# User context:
echo Checking tpm config files...
swtpm_setup --create-config-files skip-if-exist
echo ''

# Get start context for VMs
STARTVMLIST=$(virsh list --all --name)
NEWVMLIST=${STARTVMLIST}

# Prompt to perform actions in Gnome Boxes
echo "0. CONSIDER REBOOTING if you have started a VM in this login session (may be nescessary)"
echo "1. Go to Gnome Boxes and add new VM. "
echo "2. Select Windows 11 ISO and start install (NOT express install)."
echo "3. At the Language select window, exit the install by clicking the close button (top right) of the installer window inside the VM."

read -r -p "Do you want to continue? [y/N] " RESPONSE
RESPONSE=${RESPONSE,,}
if [[ ! $RESPONSE =~ ^(yes|y| ) ]] ; then
  exit 2
fi

# Check if gnome-boxes is running and start if not
pidof -q gnome-boxes || nohup gnome-boxes >/dev/null 2>&1 &

# Wait until new VM is generated
while [ "${STARTVMLIST}" == "${NEWVMLIST}" ]
do
  NEWVMLIST=$(virsh list --all --name)
  sleep 2
done

# Get name of temporary vm
TMPXML=$(cd ~/.config/libvirt/qemu && ls *.xml -t -1 | awk NR==1)
TMPVMNAME=${TMPXML%%.*}

# close installation in GUI and wait to shut down VM
echo ''
echo After exiting the installation, please enter the name of the VM:


# Prompt for name
read -p "Enter name of VM: " VMLONGNAME

# characters to lower, replace space with hyphens, windows 11 to win11
NEWNAMELOWER="${VMLONGNAME,,}"
NEWNAMENOSPACE="${NEWNAMELOWER// /-}"
NEWNAMEWIN="${NEWNAMENOSPACE//windows-11/win11}"

# If 11th character is a hyphen, cut off at 10, else choose 11 chars
[[ "${NEWNAMEWIN:10:1}" == "-" ]] && NEWSHORTNAME="${NEWNAMEWIN:0:10}" || NEWSHORTNAME="${NEWNAMEWIN:0:11}"

# add suffix to short name if file exists
NUMBER=1
VMNAME="${NEWSHORTNAME}"
cd ~/.config/libvirt/qemu/
while [ -e "${VMNAME}.xml" ]; do
    printf -v VMNAME '%s-%02d' "${NEWSHORTNAME}" "$(( ++NUMBER ))"
  done

# force close VM if it is running
(virsh list --state-running --name | grep $TMPVMNAME -q ) &&  read -p "VM is still running, choose force shutdown in Boxes or press <Enter> to force close"
(virsh list --state-running --name | grep $TMPVMNAME -q ) &&  virsh destroy ${TMPVMNAME}

# Export VM XML to enable edit and reimport
EDITFILE=/tmp/${TMPXML}
virsh dumpxml --inactive --security-info ${TMPVMNAME} > ${EDITFILE}

# shut down gnome boxes
echo Closing gnome-boxes.
pkill gnome-boxes > /dev/null

echo Adding TPM...
sed -i '/<devices>/a <tpm model="tpm-crb">\n  <backend type="emulator" version="2.0"/>\n</tpm>' ${EDITFILE}

# check this line (match to verify BIOS virtualization is on):
# <type arch="x86_64" machine="pc-q35-6.1">hvm</type>
echo I should be checking something here...

# Check that /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd exists (fedora specific)
# It’s located in /usr/share/edk2/ovmf/ in Fedora Linux 34 and in /usr/share/OVMF/ in Ubuntu 22.
SECBOOTFILE=/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd
echo Adding loader info to xml...
grep -q loader ${EDITFILE} || sed -i "/<os>/a <loader readonly=\"yes\" type=\"pflash\">${SECBOOTFILE}</loader>" ${EDITFILE}

# Setting new name in XML
echo Renaming VM...
sed -i "s/<name>.*<\/name>/<name>${VMNAME}<\/name>/g" ${EDITFILE}
sed -i "s/<title>.*<\/title>/<title>${VMLONGNAME}<\/title>/g" ${EDITFILE}

# Rename storage file and change config so it matches
echo Renaming storage file and changing config file...
mv ~/.local/share/gnome-boxes/images/${TMPVMNAME} ~/.local/share/gnome-boxes/images/${VMNAME}
sed -i "s/gnome-boxes\/images\/${TMPVMNAME}/gnome-boxes\/images\/${VMNAME}/g" ${EDITFILE}

# Delete tmp VM and import new from file
virsh undefine ${TMPVMNAME} --managed-save > /dev/null
virsh define ${EDITFILE}

echo "Done. Remember to re-add Windows 11 ISO in VM"
# Check if gnome-boxes is running and start if not
pidof -q gnome-boxes || nohup gnome-boxes >/dev/null 2>&1 &
