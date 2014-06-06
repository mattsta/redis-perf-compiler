redis-perf-compiler: compile Redis to test performance.
=======================================================

Status
------
redis-perf-compiler is the tool used to run [Redis benchmarks
against different compiler options](https://matt.sh/redis-benchmark-compilers).

Usage
-----
By default, all data is stored in `/mnt/ramdisk`.

To change the storage directory, edit the `BASE` variable in `perf.sh`.
(Or, add `tmpfs       /mnt/ramdisk    tmpfs   nodev,nosuid,noatime,size=4096M  0   0`
to your `/etc/fstab` and `mkdir -p /mnt/ramdisk; mount /mnt/ramdisk`)

A single test requires two cores: one to run `redis-server` and one to run `redis-benchmark`.

Run "./perf.sh a" to bind to CPUs 0,1 and test in ascending tag order

Run "./perf.sh b" to bind to CPUs 2,3 and test in reverse tag order

If you are on a fancy machine (24 cores?) and you want to run as many
tests simultaenously as possible, you need to add more
`NAMESPACE_CPUS` checks at the top of `perf.sh`.  Feel free to refactor
the CPU assignment into more a more generic function, but so far that
hasn't been required.

To run the tests forever, just give it an ole' `while true; do ./perf.sh [a|b] |tee [a|b].out; done`

You will end up with directories looking like
```haskell
matt@neon:/mnt/ramdisk% ls
perf-out  redis  redisa  redisb  redis-latest
matt@neon:/mnt/ramdisk% ls perf-out
clang-O2  clang-O2-flto  clang-Ofast  clang-Ofast-flto  clang-Os  clang-Os-flto  gcc-4.9-O2  gcc-4.9-O2-flto  gcc-4.9-Ofast  gcc-4.9-Ofast-flto  gcc-4.9-Os  gcc-4.9-Os-flto
matt@neon:/mnt/ramdisk% ls perf-out/clang-O2/
2.6.0      2.6.0-rc3  2.6.0-rc6  2.6.1     2.6.10-2  2.6.12  2.6.14-1  2.6.16  2.6.3  2.6.6    2.6.8    2.6.9-1    2.8.0-rc2  2.8.0-rc5  2.8.2  2.8.5  2.8.8        3.0.0-beta2  3.0.0-beta5
2.6.0-rc1  2.6.0-rc4  2.6.0-rc7  2.6.10    2.6.10-3  2.6.13  2.6.14-2  2.6.17  2.6.4  2.6.7    2.6.8-1  2.8.0      2.8.0-rc3  2.8.0-rc6  2.8.3  2.8.6  2.8.9        3.0.0-beta3
2.6.0-rc2  2.6.0-rc5  2.6.0-rc8  2.6.10-1  2.6.11    2.6.14  2.6.15    2.6.2   2.6.5  2.6.7-1  2.6.9    2.8.0-rc1  2.8.0-rc4  2.8.1      2.8.4  2.8.7  3.0.0-beta1  3.0.0-beta4
matt@neon:/mnt/ramdisk% ls perf-out/clang-O2/3.0.0-beta4/
data-10436  data-15996  data-21710  data-26854  data-31966  data-66     meta-14003  meta-21178  meta-25267  meta-31059  meta-6252   pipe-12103  pipe-18282  pipe-24382  pipe-31040  pipe-5996
data-11130  data-17384  data-22074  data-27199  data-5632   meta-10436  meta-15996  meta-21710  meta-26854  meta-31966  meta-66     pipe-14003  pipe-21178  pipe-25267  pipe-31059  pipe-6252
data-12103  data-18282  data-24382  data-31040  data-5996   meta-11130  meta-17384  meta-22074  meta-27199  meta-5632   pipe-10436  pipe-15996  pipe-21710  pipe-26854  pipe-31966  pipe-66
data-14003  data-21178  data-25267  data-31059  data-6252   meta-12103  meta-18282  meta-24382  meta-31040  meta-5996   pipe-11130  pipe-17384  pipe-22074  pipe-27199  pipe-5632
```

The `data` files are results of data benchmarks.  The `pipe` files are results of pipe benchmarks.

The `meta` files contain compiler version information for each individual run (useful in case you
accidentially upgrade compilers during a multi-day test run and need to track down why things changed).

The numbers at the end of each file name are so we can save multiple results to the
same directory.  A single benchmark run uses the same random number for data, pipe, and meta files
so you can connect them later if necessary.

The contents of the data and pipe files is just CSV output from `redis-benchmark`.
