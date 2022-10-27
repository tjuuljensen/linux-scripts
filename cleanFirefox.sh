#!/bin/bash
#
# From: https://www.msi.umn.edu/support/faq/i-receive-error-firefox-already-running-not-responding-when-trying-use-firefox
#
# Use this script to clean locks inside the .mozilla directory that
# prevent firefox from running on multiple machines that share an
# NFS system. If you open firefox and get a window claiming,
# "another instance of this application is already running [...]"
# running this script will enable you to open the application on another
# host.

files=`find ~/.mozilla -name "*lock"`
for file in `echo $files`
do
    echo "removing $file..."
    rm "$file"
done
