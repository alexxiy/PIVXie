#!/bin/bash

set -x -e

APP="${1:-pivxie}"

mkdir -p build
. ./config.sh

wait
echo "Done"
