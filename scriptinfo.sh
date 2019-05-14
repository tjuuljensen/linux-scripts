grep -E '^[[:space:]]*([[:alnum:]_]+[[:space:]]*\(\)|function[[:space:]]+[[:alnum:]_]+)' fedora-lib.sh  | sed -e 's/[(){)]//g' 
