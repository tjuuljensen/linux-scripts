#!/bin/sh
#
# This routine was written by "Amerefelie"
# https://www.linuxquestions.org/quest...nature-137111/
# Last updated 090507 by Andy Lavarre alavarre@gmail.com to insert comment analysis documentation
# Last edited 081231 by Amerefelieat 07:58 AM.. Reason: updated script for hash test fail.

# Usage:
# file-check.sh $1
# where $1 is the name of the xxx.tar.gz file

# Name the key ring
VENDOR_KEYRING=vendors.gpg

# Report the input

# If the signature file xxx.tar.gz.sig exists
if [ -e "$1.sig" ] ; then
  KEYID="0x`gpg --verify $1.sig $1 2>&1 | grep 'key ID' | awk '{print $NF}'`"
  echo "The key ID is "$KEYID
  # Pull the public key from the default key server to the Vendor keyring
  gpg --no-default-keyring --keyring $VENDOR_KEYRING --keyserver pgp.mit.edu --recv-key $KEYID
  # Verify the file
  gpg --keyring $VENDOR_KEYRING --verify $1.sig $1
  # Otherwise, if the signature file is an ASCII
  elif [ -e "$1.asc" ]
  # Then strip off the name of the file
  then KEYID="`gpg --verify $1.asc $1 2>&1 | grep 'RSA key' | awk '{print $NF}'`"
  echo "The key ID is "$KEYID
  # Pull the public key from the default key server to the Vendor keyring
  gpg --no-default-keyring --keyring $VENDOR_KEYRING --keyserver pgp.mit.edu --recv-key $KEYID
  # Verify the file
  gpg --keyring $VENDOR_KEYRING --verify $1.asc $1
  # Otherwise complain that it does not exist
else echo "No GPG signature File"
  # Finish
fi

# Now if not PGP/GPG, but an MD5 instead and the hash file exists
if [ -e "$1.md5" ] ; then
  if md5sum $1 | diff -i - $1.md5 2> /dev/null ; then
    echo "Md5 hash match!"
  # Otherwise complain
  else echo "Md5 hash does not match!"
    # Finish
  fi
else echo "Md5 hash file not found."
  # Finish
fi

# Now if not PGP/GPG, but an sha1 instead and the hash file exists
if [ -e "$1.sha1" ] ; then
  if sha1sum $1 | diff -i - $1.sha1 2> /dev/null ; then
    echo "Sha1 hash match!"
    # Otherwise complain
  else echo "Sha1 hash does not match!"
    # Finish
  fi
    # Otherwise complain that it does not exist
else echo "Sha1 hash file not found."
  # Finish
fi

# Now if not PGP/GPG, but an sha256 instead and the hash file exists
if [ -e "$1.sha256" ] ; then
    if sha256sum $1 | diff -i - $1.sha256 2> /dev/null ; then
      echo "Sha256 hash match!"
    else echo "Sha256 hash does not match!"
      # Finish
    fi
# Otherwise complain that it does not exist
else echo "Sha256 hash file not found."
  # Finish
fi

# Quit
exit 0
