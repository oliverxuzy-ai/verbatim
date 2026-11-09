#!/bin/bash
# Temporary helper for the Settings screenshots workflow.
set -u
out="$1"
rm -rf "$out" && mkdir -p "$out"
"$HOME/dd/Build/Products/Debug/Verbatim.app/Contents/MacOS/Verbatim" --snapshot-settings "$out" &
pid=$!
for _ in $(seq 1 120); do kill -0 $pid 2>/dev/null || break; sleep 1; done
kill $pid 2>/dev/null || true
ls -la "$out"
