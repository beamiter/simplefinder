#!/usr/bin/env bash
set -euo pipefail

cargo build --release

rm -rf lib
mkdir -p lib
cp target/release/simplefinder-daemon lib/

echo "Installed to ./lib. Ensure this plugin directory is on 'runtimepath'."
