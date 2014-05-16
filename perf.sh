#!/bin/bash -x

COUNT=120000
BENCH_NORMAL="../../redis-latest/src/redis-benchmark -n $COUNT --csv"
BENCH_DATA="$BENCH_NORMAL -r 32 -d 64"
BENCH_PIPE="$BENCH_DATA -P 1000"
if hash timeout 2>/dev/null; then
    TIMEOUT="timeout 300"
fi

BASE=/mnt/ramdisk
PERF_OUT="$BASE/perf-out/"
here="$(pwd)/$(dirname "$0")"
COMPILERS="clang gcc-4.9"
OPTS="-O2 -Os -Ofast"
FLAGS="-flto"

PIN_TO_CPU=true
#REDIS_CPUSET_TASKS=/dev/cpuset/redis/tasks
# view current layout: cset set -l -r

if $PIN_TO_CPU; then
    if hash taskset 2>/dev/null; then
        TASKSET=taskset
        TASKSET_BENCH="$TASKSET -c 0"
        TASKSET_REDIS="$TASKSET -c 1"
    fi
fi

#set -e  # enable die-on-error
cd "$BASE"

# Set up the redis-server we'll use
if [[ -e redis/ ]]; then
    pushd redis
    git reset --hard HEAD
    git clean -dfx
    git checkout unstable
    git pull
    popd
else
    git clone https://github.com/antirez/redis
fi

# Set up the redis-benchmark we'll use
if [[ -e redis-latest/ ]]; then
    pushd redis-latest/src
    git checkout unstable
    git pull
    make -j
    popd
else
    git clone redis redis-latest
    pushd redis-latest/src
    make -j
    popd
fi

cd redis/src
VERSIONS=$(git tag|egrep "^2\\.[68]|^3")
set +e  # disable die-on-error

for version in $VERSIONS; do
    rm -f dump.rdb
    git reset --hard HEAD
    git clean -dfx
    git checkout unstable
#    set +e
    git branch -D "$version"  # may fail, but that's okay
#    set -e
    git checkout -b "$version" "$version"
    for compiler in $COMPILERS; do
        export CC="$compiler"
        for opt in $OPTS; do
            export OPT="$opt"
            for flags in "" $FLAGS; do
                BASE=$PERF_OUT/$compiler$opt$flags/$version
#                if [[ -d "$BASE" ]]; then
#                    break; # For now, ignore all already-processed dirs
#                fi
                echo "Base: $BASE"
                mkdir -p "$BASE"
                # We generate random extensions so we can run
                # the test multiple times without clobbering previous
                # results.
                EXT1=$RANDOM
                EXT2=$RANDOM
                EXT3=$RANDOM
                for e in $EXT1 $EXT2 $EXT3; do
                    # record version of compiler for test
                    $compiler --version > "$BASE/meta-$e"
                    if hash gdate 2>/dev/null; then
                        USE_DATE=$(gdate --iso-8601=seconds)
                    else
                        USE_DATE=$(date --iso-8601=seconds)
                    fi
                    echo "Date:$USE_DATE" >> "$BASE/meta-$e"
                done
                make distclean
                git checkout Makefile
                unset REDIS_CFLAGS
                unset REDIS_LDFLAGS
                if [[ $flags == "-flto" && $compiler == "gcc-4.9" ]]; then
                    export REDIS_CFLAGS="-flto=3"
                    export REDIS_LDFLAGS="-flto=3 $opt"
                elif [[ $flags == "-flto" && $compiler == "clang" ]]; then
                    # clang outputs ".bc" llvm instead of ".o", so we need to force
                    # the Makefile to use the correct names
                    sed -i 's/\.o/.bc/g' Makefile
                    sed -i 's/linenoise\.bc/linenoise.o/' Makefile
                    sed -i 's/ $(RDB_MERGER_NAME)//g' Makefile
                    export REDIS_CFLAGS="-emit-llvm"
                fi
                if [[ $compiler == "clang" ]]; then
                    sed -i 's/-rdynamic//' Makefile
                fi
                # Try to compile deps with lto too?
                # export CFLAGS=$REDIS_CFLAGS
                make -j V=1
                if [[ $? != 0 ]]; then
                    echo "SKIPPING $version due to bad compile" > "$BASE/skip-$ExT1"
                fi
                RPID="$BASE/pidf"
                RWHERE=". ./obj.x86_64"
                for where in $RWHERE; do
                    if [[ -f "$where"/redis-server ]]; then
                        $TASKSET_REDIS "$where"/redis-server --daemonize yes --save "\"\"" --pidfile "$RPID"
                        break;
                    fi
                done
                if [[ ! -f "$RPID" ]]; then
                    sleep 2  # daemon starts before init, so give time to listen
                fi
                REDIS_PID=$(cat "$RPID")
                echo "Testing normal $version $compiler $flags..."
                time $TASKSET_BENCH $TIMEOUT $BENCH_NORMAL > "$BASE/regular-$EXT1"
                time $TASKSET_BENCH $TIMEOUT $BENCH_NORMAL > "$BASE/regular-$EXT2"
                time $TASKSET_BENCH $TIMEOUT $BENCH_NORMAL > "$BASE/regular-$EXT3"
                echo "Testing data $version $compiler $flags..."
                time $TASKSET_BENCH $TIMEOUT $BENCH_DATA > "$BASE/data-$EXT1"
                time $TASKSET_BENCH $TIMEOUT $BENCH_DATA > "$BASE/data-$EXT2"
                time $TASKSET_BENCH $TIMEOUT $BENCH_DATA > "$BASE/data-$EXT3"
                echo "Testing pipe $version $compiler $flags..."
                time $TASKSET_BENCH $TIMEOUT $BENCH_PIPE > "$BASE/pipe-$EXT1"
                time $TASKSET_BENCH $TIMEOUT $BENCH_PIPE > "$BASE/pipe-$EXT2"
                time $TASKSET_BENCH $TIMEOUT $BENCH_PIPE > "$BASE/pipe-$EXT3"
#                kill -9 "$REDIS_PID" || echo "Redis already dead?"
                pkill -9 redis-server
            done
        done
    done
    git checkout unstable
    git branch -D "$version"
done
