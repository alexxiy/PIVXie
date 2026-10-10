#!/bin/bash

set -x -e

APP="${1:-pivxie}"

# ensure ios rust triples are there
rustup target add aarch64-apple-ios
rustup target add x86_64-apple-ios

wait
echo "Done building"
