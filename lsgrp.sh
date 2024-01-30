#!/bin/bash
# This script is using normal basic tools (available on all NIX systems) to display group memberships
# 

if [[ $# == 0 ]] ; then
  echo "Syntax: $0 <GROUP NAME>"
  exit 1
fi

# All members of a group
grep ${1} /etc/group | awk -F":" '{print $4}' | sort

# All groups (sorted) awk -F":" '{print $1}' /etc/group | sort
