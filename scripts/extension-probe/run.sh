#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
probe_output=$(mktemp -d /private/tmp/pageglass-extension-probe-XXXXXX)
print "Probe output: $probe_output"
python3 scripts/test-server.py > "$probe_output/server.json" &
probe_server_pid=$!
trap 'kill "$probe_server_pid" 2>/dev/null || true' EXIT
for attempt in {1..50}; do [[ -s "$probe_output/server.json" ]] && break; sleep 0.1; done
probe_url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$probe_output/server.json")
xcrun swiftc -target arm64-apple-macos14.0 scripts/extension-probe/main.swift -o "$probe_output/probe"
"$probe_output/probe" "$probe_output" "$probe_url"
