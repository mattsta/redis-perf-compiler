#!/bin/bash -x

pkill -9 redis-server
pkill -9 perf.sh
pkill -9 redis-benchmark
