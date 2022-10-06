#!/bin/bash
#
# whatismyip

# resolved ip address on OpenDNS and Google
OPENDNSRESOLVEDIP=$(dig +short myip.opendns.com @resolver1.opendns.com)
GOOGLERESOLVEDIP=$(dig TXT +short o-o.myaddr.l.google.com @ns1.google.com | sed 's/"//g')
LOCALIP=$(ip route get 8.8.8.8 | sed -n '/src/{s/.*src *\([^ ]*\).*/\1/p;q}')

# wanip: echo $(curl -s ipinfo.io/ip )
# localip=$(hostname -i|cut -f2 -d ' ')

# compare results - if different, report both (this happens sometimes on anonymized services)
if [ $OPENDNSRESOLVEDIP == $GOOGLERESOLVEDIP ] ; then
  echo "Public IP: " $OPENDNSRESOLVEDIP
  echo "Private IP: " $LOCALIP
  exit 0
else
  echo "OpenDNS resolved IP: " $OPENDNSRESOLVEDIP
  echo "Google resolved IP: " $GOOGLERESOLVEDIP
  exit 1
fi
