#!/usr/bin/env bash

set -x -e -o pipefail

RELEASE_MODE=Debug

zig build-exe src/main.zig --name vanish -O $RELEASE_MODE -lc
zig build-lib src/root.zig -dynamic --name vanish -O $RELEASE_MODE
