#!/bin/bash
[[ -f .git/config ]] && sed -i 's|https://|ssh://git@|g' .git/config
