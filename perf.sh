#!/bin/bash -x

COUNT=120000
BENCH_NORMAL="../redis-latest/src/redis-benchmark -n $COUNT --csv"
BENCH_DATA="$BENCH_NORMAL -r 32 -d 64"
BENCH_PIPE="$BENCH_DATA -P 1000"
if hash timeout 2>/dev/null; then
    TIMEOUT="timeout 300"
fi

BASE=/mnt/ramdisk
PERF_OUT="$BASE"/perf-out/
here=`dirname $0`
COMPILERS="gcc-4.9 clang"
OPTS="-O2 -Ofast -Os"
FLAGS="'' -flto"

set -e  # enable die-on-error
cd "$BASE"

# Set up the redis-server we'll use
if [[ -e redis/ ]]; then
    cd redis
    git checkout unstable
    git pull
    cd -
else
    git clone https://github.com/antirez/redis
fi

# Set up the redis-benchmark we'll use
if [[ -e redis-latest/ ]]; then
    cd redis-latest/src
    git checkout unstable
    git pull
    make -j
    cd -
else
    git clone redis redis-latest
    cd redis-latest/src
    make -j
    cd -
fi

cd redis/src
VERSIONS=`git tag|grep ^2\\.[68]`
set +e  # disable die-on-error

for version in $VERSIONS; do
    rm -f dump.rdb
    git checkout unstable
    git branch -D $version  # may fail, but that's okay
    git checkout -b $version
    git reset --hard HEAD
    git clean -dfx
    for compiler in $COMPILERS; do
        export CC="$compiler"
        for opt in $OPTS; do
            export OPT="$opt"
            for flags in $FLAGS; do
                BASE=$PERF_OUT/ct/$compiler$opt$flags/$version
                echo "Base: $BASE"
                mkdir -p $BASE
                # We generate random extensions so we can run
                # the test multiple times without clobbering previous
                # results.
                EXT1=$RANDOM
                EXT2=$RANDOM
                EXT3=$RANDOM
                for e in $EXT1 $EXT2 $EXT3; do
                    # record version of compiler for test
                    $compiler --version > meta-$e
                    if hash gdate 2>/dev/null; then
                        USE_DATE=`gdate --iso-8601=seconds`
                    else
                        USE_DATE=`date --iso-8601=seconds`
                    fi
                    echo Date:$USE_DATE >> meta-$e
                done
                make distclean
                unset REDIS_CFLAGS
                unset REDIS_LDFLAGS
                if [[ $flags == "-flto" && $compiler == "gcc-4.9" ]]; then
                    export REDIS_CFLAGS="-flto=3"
                    export REDIS_LDFLAGS="-flto=3 $opt"
                elif [[ $flags == "-flto" && $compiler == "clang" ]]; then
                    # clang outputs ".bc" llvm instead of ".o", so we need to force
                    # the Makefile  to write out explicit object files
                    git checkout Makefile
                    patch -p2  < "$here"/fixmake.patch 
                    export REDIS_CFLAGS="-emit-llvm"
                fi
                # Try to compile deps with lto too?
                # export CFLAGS=$REDIS_CFLAGS
                make -j
                ./redis-server --daemonize yes --save "\"\"" --pidfile pidf
                sleep 0.1  # daemon starts before init, so give time to listen
                echo "Testing normal $compiler $flags $version..."
                time $TIMEOUT $BENCH_NORMAL > $BASE/regular-$EXT1
                time $TIMEOUT $BENCH_NORMAL > $BASE/regular-$EXT2
                time $TIMEOUT $BENCH_NORMAL > $BASE/regular-$EXT3
                echo "Testing data $compiler $flags $version..."
                time $TIMEOUT $BENCH_DATA > $BASE/data-$EXT1
                time $TIMEOUT $BENCH_DATA > $BASE/data-$EXT2
                time $TIMEOUT $BENCH_DATA > $BASE/data-$EXT3
                echo "Testing pipe $compiler $flags $version..."
                time $TIMEOUT $BENCH_PIPE > $BASE/pipe-$EXT1
                time $TIMEOUT $BENCH_PIPE > $BASE/pipe-$EXT2
                time $TIMEOUT $BENCH_PIPE > $BASE/pipe-$EXT3
                pkill -9 `cat pidf`
            done
        done
    done
    git checkout unstable
    git branch -D $version
done
