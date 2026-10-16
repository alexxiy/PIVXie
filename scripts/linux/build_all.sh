#!/bin/bash

set -x -e

APP="${1:-pivxie}"

mkdir -p build
./build_secure_storage_deps.sh

./build_secp256k1.sh

./build_opencv.sh

wait
echo "Done building"
