#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: Rust/Cargo is required (https://rustup.rs)" >&2
  exit 1
fi

cargo build --release --locked
mkdir -p lib
install -m 755 target/release/simplefinder-daemon lib/simplefinder-daemon

echo "SimpleFinder installed: $ROOT_DIR/lib/simplefinder-daemon"
