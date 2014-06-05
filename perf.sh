#!/bin/bash -x

NAMESPACE_CPUS=$1
if [[ $NAMESPACE_CPUS == "a" ]]; then
    REDIS_PORT=4444
    NAMESPACE=a
    REV=''
    CPU0=0
    CPU1=1
elif [[ $NAMESPACE_CPUS == "b" ]]; then
    REDIS_PORT=4445
    NAMESPACE=b
    REV='r'
    CPU0=2
    CPU1=3
else
    echo "Must launch with 'a' or 'b' as an argument."
    echo "Argument 'a' binds to CPUs 0,1 and processes tags in ascending order."
    echo "Argument 'b' binds to CPUs 2,3 and processes tags in reverse order."
    exit 1
fi

echo $(date) >> runcount-$NAMESPACE

COUNT=120000
BENCH_NORMAL="../../redis-latest/src/redis-benchmark -n $COUNT --csv -p $REDIS_PORT"
BENCH_DATA="$BENCH_NORMAL -r 9999999999 -d 64"
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
        TASKSET_BENCH="$TASKSET -c $CPU0"
        TASKSET_REDIS="$TASKSET -c $CPU1"
        TASKSET_BOTH="$TASKSET -c $CPU0,$CPU1"
    fi
fi

#set -e  # enable die-on-error
cd "$BASE"

# Set up the redis-server we'll use
if [[ -e redis$NAMESPACE/ ]]; then
    pushd redis$NAMESPACE
    git reset --hard HEAD
    git clean -dfx
    git checkout unstable
    git pull --force
    popd
else
    git clone https://github.com/antirez/redis redis$NAMESPACE
fi

# Set up the redis-benchmark we'll use
if [[ -e redis-latest/ ]]; then
    pushd redis-latest/src
    git checkout unstable
    git pull --force
    $TASKSET_BOTH make -j
    popd
else
    git clone redis$NAMESPACE redis-latest
    pushd redis-latest/src
    $TASKSET_BOTH make -j
    popd
fi

cd redis$NAMESPACE/src
VERSIONS=$(git tag|egrep "^2\\.[68]|^3"|sort -n$REV|grep -v alpha)
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
                $TASKSET_BOTH make distclean
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
                $TASKSET_BOTH make -j V=1
                if [[ $? != 0 ]]; then
                    echo "SKIPPING $version due to bad compile" >> "$BASE/skip-$EXT1"
                    continue
                fi
                RPID="$BASE/pidf-$NAMESPACE"
                RWHERE=". ./obj.x86_64"
                for where in $RWHERE; do
                    if [[ -f "$where"/redis-server ]]; then
                        $TASKSET_REDIS "$where"/redis-server --daemonize yes --save "\"\"" --pidfile "$RPID" --port $REDIS_PORT
                        break;
                    fi
                done
                sleepCounter=0
                while [[ ! -f "$RPID" ]]; do
                    if [[ $(( sleepCounter++ )) -gt 20 ]]; then
                        echo "Skipping version $version because no PID appeared." >> "$BASE/skip-$EXT1"
                        continue 2  # continue up a level, not continue checking for pid
                    fi
                    sleep 0.3  # daemon starts before init, so give time to listen
                done
                REDIS_PID=$(cat "$RPID")
#                echo "Testing normal $version $compiler $flags..."
#                time $TASKSET_BENCH $TIMEOUT $BENCH_NORMAL > "$BASE/regular-$EXT1"
#                time $TASKSET_BENCH $TIMEOUT $BENCH_NORMAL > "$BASE/regular-$EXT2"
#                time $TASKSET_BENCH $TIMEOUT $BENCH_NORMAL > "$BASE/regular-$EXT3"
                echo "Testing data $version $compiler $flags..."
                time $TASKSET_BENCH $TIMEOUT $BENCH_DATA > "$BASE/data-$EXT1"
                time $TASKSET_BENCH $TIMEOUT $BENCH_DATA > "$BASE/data-$EXT2"
                time $TASKSET_BENCH $TIMEOUT $BENCH_DATA > "$BASE/data-$EXT3"
                echo "Testing pipe $version $compiler $flags..."
                time $TASKSET_BENCH $TIMEOUT $BENCH_PIPE > "$BASE/pipe-$EXT1"
                time $TASKSET_BENCH $TIMEOUT $BENCH_PIPE > "$BASE/pipe-$EXT2"
                time $TASKSET_BENCH $TIMEOUT $BENCH_PIPE > "$BASE/pipe-$EXT3"
                kill -9 "$REDIS_PID" || echo "Redis already dead?"
                rm -f "$RPID"
#                pkill -9 redis-server
            done
        done
    done
    git checkout unstable
    git branch -D "$version"
done
