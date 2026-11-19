#!/bin/bash
set -eu
cd "$(dirname "$0")"
output=./mac-input
for source in ./*.swift; do
    if [ ! -x "$output" ] || [ "$source" -nt "$output" ]; then
        xcrun swiftc -swift-version 5 -O ./*.swift -o "$output"
        break
    fi
done
if [ "$#" -gt 0 ]; then exec "$output" "$@"; fi
"$output" --displays
read -r -p "Mac LAN IPv4: " local_ip
read -r -p "Windows receiver LAN IPv4: " windows_ip
read -r -p "Mirrored display ID (Return for main): " display
if [ -n "$display" ]; then exec "$output" "$local_ip" "$windows_ip" "$display"; fi
exec "$output" "$local_ip" "$windows_ip"
