#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
capture=${1:?Usage: scripts/prototype-qa/run.sh /absolute/path/to/owned-dashboard-capture}
output="$PWD/qa-output/prototype-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$PWD/qa-output"
python3 scripts/prototype-qa/augment.py "$capture" "$output"
swiftc scripts/prototype-qa/verify.swift -o "$PWD/qa-output/prototype-verifier-$$"
"$PWD/qa-output/prototype-verifier-$$" "$capture" "$output"
