#!/bin/bash
#
# whatismyip.#!/bin/sh

# resolved ip address on OpenDNS and Google
OPENDNSRESOLVEDIP=$(dig +short myip.opendns.com @resolver1.opendns.com)
GOOGLERESOLVEDIP=$(dig TXT +short o-o.myaddr.l.google.com @ns1.google.com | sed 's/"//g')

# compare results - if different, report both (this happens sometimes on anonymized services)
if [ $OPENDNSRESOLVEDIP == $GOOGLERESOLVEDIP ] ; then
  echo $OPENDNSRESOLVEDIP
  exit 0
else
  echo "OpenDNS resolved IP: " $OPENDNSRESOLVEDIP
  echo "Google resolved IP: " $GOOGLERESOLVEDIP
  exit 1
fi
