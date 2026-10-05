#!/bin/zsh
set -eu
cd "${0:A:h:h}"
result=$(swift run --build-system native --scratch-path .build-v0.4 AirDropDrawer --self-check) || { print -r -- "$result"; exit 1; }
print -r -- "$result"
[[ "$result" == *'Native checks passed'* ]]
