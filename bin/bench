#!/usr/bin/env bash

clear
echo "Build Bench Debug"
zig build-exe src/benchmark.zig --name bm_debug -ODebug
echo "Build Bench Safe"
zig build-exe src/benchmark.zig --name bm_safe -OReleaseSafe
echo "Build Bench Fast"
zig build-exe src/benchmark.zig --name bm_fast -OReleaseFast

./bm_debug
./bm_safe
./bm_fast
