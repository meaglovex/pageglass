#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output="$PWD/qa-output/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$output"
python3 scripts/test-server.py > "$output/server.json" &
test_server_pid=$!
trap 'kill "$test_server_pid" 2>/dev/null || true' EXIT
for attempt in {1..50}; do [[ -s "$output/server.json" ]] && break; sleep 0.1; done
test_url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$output/server.json")
dist/Pageglass.app/Contents/MacOS/Pageglass --smoke "$output" --asset-test-url "$test_url" --exit "$@"
cat "$output/report.json"
