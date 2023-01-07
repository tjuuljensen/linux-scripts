#!/bin/bash
#
# urlxray.sh - command line URL X-ray for looking up tiny url's from command line
# By: tjuuljensen@gmail.com
# Date: 7 January 2023


if [[ $# == 0 ]] ; then
  echo "Missing input."
  echo "Syntax: $0 <INPUT_URL>"
  exit 1
fi

RESPONSE=$(curl -iL ${1} 2>&1 | grep "location:" | cut -d' ' -f2)
if [[ -z $RESPONSE ]] ; then
  exit 2
else
  echo $RESPONSE
fi
