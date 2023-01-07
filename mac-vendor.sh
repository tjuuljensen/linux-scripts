#!/bin/bash
#
# Author: tjuuljensen@gmail.com
#
# mac-vendor.sh - Get the vendor for a mac address from the terminal.
# Original idea & credits to: redperadot@darkgem.net

# define constants
INSTALLDIR=/opt/macvendor
INSTALL_FILE=$INSTALLDIR/oui.txt
TEMPLATE_START="tmp.macvndr-"
TEMPLATE_TODAY=$TEMPLATE_START$(date +"%Y-%m-%d")
TMPFILE_TEMPLATE=$TEMPLATE_TODAY"-XXXX"
TMPDIR=/tmp
OUI_AGE=7

# Define variables
LATEST_FILE_FROM_TODAY=$(find $TMPDIR -type f -size +0 -name $TEMPLATE_TODAY* -printf "%T@ %Td-%Tb-%TY %Tk:%TM %p\n" 2>/dev/null | sort -n -r | awk ' NR==1 { print $4 }')
OUI_TXTFILE="" # Declare global variable for later use
BG_PID=0 # Declare global variable for later use
DATABASE=""
# Define Functions

help()
{
  SCRIPT_NAME=$(basename $0)
  echo "MAC Vendor Help"
  echo "$SCRIPT_NAME -a 'MAC Address' | Get the vendor of the specified address."
  echo "$SCRIPT_NAME -s 'MAC Address' | Silent, only output result."
  echo "$SCRIPT_NAME -i | Install the program on your system (put oui.txt in ${INSTALLDIR})"
  exit 0
}

download_oui_bg()
{
  # Test Connection
  ping -c 1 standards-oui.ieee.org &> /dev/null
  [[ $? > 0 ]] && echo "[Error 68:$(($LINENO - 1))] Was unable to reach the database." && exit 68

  # Create temp file
  OUI_TXTFILE=$(mktemp --tmpdir $TMPFILE_TEMPLATE)
  chmod +r $OUI_TXTFILE

  # Start loading process in the background
  curl -sf https://standards-oui.ieee.org/oui/oui.txt -o $OUI_TXTFILE&

  # get PID of job in background
  BG_PID=$!

}

get_oui_file()
{
  # Check for installed or cached files or start the download in the background
  if [[ -f $INSTALL_FILE ]] ; then # Installed
    if [[ $(find "$INSTALL_FILE" -mtime +$OUI_AGE -print) ]]; then # file is older than x days (from variable $OUI_AGE)
      if [[ "$UID" -ne 0 ]] ; then # user is not root
        echo "File $INSTALL_FILE exists and is older than $OUI_AGE days."
        echo "You should update the file as root."
        OUI_TXTFILE=$INSTALL_FILE
      else # file is older than 7 days and user has root privileges
        echo "File $INSTALL_FILE exists and is older than $OUI_AGE days."
        install_local
        OUI_TXTFILE=$INSTALL_FILE
      fi
    else
      OUI_TXTFILE=$INSTALL_FILE
    fi
  elif [[ -f $LATEST_FILE_FROM_TODAY ]] && [[ -s $LATEST_FILE_FROM_TODAY ]] ; then # cached / A non-zero byte file exists from today
    OUI_TXTFILE=$LATEST_FILE_FROM_TODAY
  else # must download first
    # start download in background - OUI_TXTFILE will be set inside the function
    download_oui_bg
    # exit with status code from function
  fi

}

get_database()
{

  # If file is donwloading in the background, finish before continuing
  if [ ! $BG_PID==0 ] ; then # database file was started downloading in the background
    if ps -p $BG_PID >/dev/null ; then
      [[ $silent != true ]] && echo "Downloading database..."
      wait $BG_PID # wait for background download to finish
    fi
    if  [ ! -s $OUI_TXTFILE ] ; then # if file is zero byte
      echo "Could not fetch the database." && exit 2
    fi
  fi

  # load file into database variable
  DATABASE=$(cat $OUI_TXTFILE)
  [[ -z $DATABASE ]] && echo "[Error 72:$(($LINENO - 1))] Could not read the database." && exit 72

}

format_vendor_address()
{
  [[ -n $1 ]] && vendor_address="$1"

  vendor_address="$(echo "$vendor_address" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
  if [[ ${#vendor_address} == "6" ]]; then
    return
  else
    vendor_address="$(echo "$vendor_address" | cut -c1-6)"
  fi

}


get_mac_address()
{
  # Get Vendor Address
  [[ -z $vendor_address && -n $1 ]] && vendor_address="$1"
  [[ -z $vendor_address ]] && read -p "Vender address to test for [##:##:##:##:##:##]: " vendor_address
  if [ -z $vendor_address ] ; then
    cleanup
    exit 0
  fi

  # Check the vendor address input
  format_vendor_address
  [[ ${#vendor_address} < 6 || ! $vendor_address =~ ^[0-9A-F]{6}$ ]] \
    && echo "[Error 65:$LINENO] The address '$vendor_address' was invalid." && exit 65

}

search_and_output()
{

  vendor="$(echo "$DATABASE" | grep -E "$vendor_address.*(base 16)" | awk '{for(i=4;i<NF;i++) printf"%s",$i OFS;if(NF)printf"%s",$NF;printf ORS}')"
  [[ -z $vendor ]] && vendor="Unknown"

  # Print Result
  [[ $silent != true ]] && echo -n "The MAC address prefix "
  echo -n "$vendor_address "
  [[ $silent != true ]] && echo -n "belongs to "
  echo "$vendor"

}

install_local()
{
  if [ ! -d $INSTALLDIR ]; then
    mkdir -p $INSTALLDIR
  fi

  cd $INSTALLDIR
  download_oui_bg

  echo "Downloading database file. Please wait."
  wait $BG_PID # wait until background job finishes

  if  [ ! -s $OUI_TXTFILE ] ; then
    echo "Could not fetch the database." && exit 2
  else
    chmod +r $OUI_TXTFILE
    mv $OUI_TXTFILE $INSTALL_FILE
    echo "Installed OUI database in $INSTALLDIR."
  fi

  # cleanup - remove all
  find $TMPDIR -type f -name "$TEMPLATE_START*" -delete 2>/dev/null


}


cleanup()
{
  LATEST_FILE=$(find $TMPDIR -type f -size +0 -name $TEMPLATE_TODAY* -printf "%T@ %Td-%Tb-%TY %Tk:%TM %p\n" 2>/dev/null | sort -n -r | awk ' NR==1 { print $4 }')

  if [ ! -z $LATEST_FILE ] ; then
    LATEST_FILENAME=$(basename $LATEST_FILE)
    find $TMPDIR -type f -name "$TEMPLATE_START*" -not -name $LATEST_FILENAME -delete 2>/dev/null
  else
    find $TMPDIR -type f -name "$TEMPLATE_START*" -delete 2>/dev/null
  fi

}


# Check options from command line
while getopts ":s:a:ih" opt; do
  case $opt in
    s )
        silent=true
        vendor_address="$OPTARG"
        ;;
    a )
        vendor_address="$OPTARG"
        ;;
    i )
        [ "$UID" -eq 0 ] || exec sudo bash "$0" "$@"
        install_local
        exit 0
        ;;
    h )
        help
        ;;
    \?)
        echo "[Error] Invalid option: -$OPTARG" ; exit 1
        ;;
  esac
done


# Do the following when opts are s, a or empty

# Set the name of the file to use (optionally start background download)
get_oui_file
# Read user input
get_mac_address $@
# read OUI file
get_database
# Search OUI file
search_and_output
# Delete tmpfiles except the latest
cleanup

exit 0
