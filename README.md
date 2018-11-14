# reproduce-bolt-cgo19

The open-source workload evaluated on this paper is clang 7 and gcc 8.2. Our goal is
to demonstrate that building clang/gcc with all optimizations, including LTO and
PGO, still leaves opportunities for a post-link optimizer such as BOLT to do
a better job at basic block placement and function reordering, significantly
improving workload performance.

In a nutshell, the paper advocates for a two-step profiling
pipeline, showing that doing a single pass of profiling collection is not
enough. In this two-step approach, PGO or AutoFDO can be used to feed the
compiler with profile information, which is important for obtaining better
quality in inlining decisions, while a second pass to collect profile for a
post-link optimizer such as BOLT is done to get the best basic block order
and function order.

The reason why the PGO-enabled compiler can't beat BOLT's reordering here is
because BOLT profile is more accurate. Profiles used in compilers and BOLT,
for space-efficiency reasons, are not traces but an aggregation of execution
counts. This aggregation loses information, e.g. a given function accumulates
the superposition of many traces, each one possibly using a different path
depending on its callee. This data has limited applicability and, depending on
the optimizations that the compiler applies, may render this aggregated data
stale. For example, after the compiler decides to inline a function that
was not previously inlined, it now lacks the correct profile for this function
given that that call site should exercise a subset of the paths reported
in the more general profile. BOLT, by operating at the final binary, has a
more accurate view of the profile and is not affected by this and other
issues, such as mapping back from binary addresses to high-level DWARF.

## Usage

Clone this repo, cd to either clang or gcc folder, depending on the workload
you want to evaluate, and run make as in the following commands:

```
> cd clang      # or gcc
> vim Makefile  # edit NUMCORES variables according to your system
> make
> cat results.txt
```

Check the results.txt file with the numbers for the clang-build bars in
Figure 7/8.

You will probably need a machine with at least 64GB RAM and 115GB free disk space.
This machine needs an Intel processor with LBR support for profiling data
collection. By now, LBR is pretty established on Intel processors -
microarchitectures Sandy Bridge (2011) and later supports LBR.
The lower your core count, the slower it will be, as this is building a large
code base several times, which benefits with a higher core count. The whole
process takes about 6 hours in a 48-core machine for both evaluations.

These Makefile rules are based on the steps described at
https://github.com/facebookincubator/BOLT/blob/master/docs/OptimizingClang.md

List of pre-requisites along with the corresponding CentOS 7 package install
command:

```
> git -- yum install git
> cmake -- yum install cmake
> ninja -- yum install ninja-build
> flex -- yum install flex
```

Since we build Clang/LLVM, check here for a list
of requirements: http://llvm.org/docs/GettingStarted.html#requirements

In general, for building Clang/LLVM, you should be fine if your system has a
relatively modern C++ compiler such as gcc version 4.8.0 or higher.

# Troubleshooting

Make sure you understand the rules in the Makefile before diagnosing an issue
and check the log files.
If one of the steps to build a compiler failed, it is best to wipe the compiler
build folder entirely before running make again.

There are 5 compilers installed for clang and 4 for gcc:

```
> benchmarks/stage1
> benchmarks/stage2       # (clang only)
> benchmarks/clangbolt    # or gccbolt
> benchmarks/clangpgo     # or gccpgo
> benchmarks/clangpgobolt $ or gccpgobolt
```

You may want to delete one of these folders if the rules failed to make the
compiler. The next time you run make, it will restart the build process for
the compiler you deleted. Once these 5 (or 4) compilers are built, the Makefile will limit
itself to measure the speed of 4 configurations and report them to you.

## Out of memory

If your system freezes, you may have ran out of memory when doing the expensive
full LTO step for clang when building benchmarks/clangpgo. Edit the Makefile
in Step 6 and change make install -j $(NUMCORES) to a lower number (remove
$(NUMCORES) and use the number of threads you believe your system will
handle).

## Downloading sources

If your machine uses a proxy and you run into trouble with the default Makefile
rules to download sources, it is easier to download the sources yourself and
put them into the designated folders, so make can proceed to the build steps by
using your manually downloaded sources. These are the source folders used:

```
> benchmarks/llvm     # llvm repo with Clang, LLD and compiler-rt (check Step 1)
> benchmarks/gcc      # gcc sources after running ./contrib/download_prerequisites
>                     # (check step 9)
> src/llvm            # llvm repo with BOLT (check step 7)
```

If you wish to run the Makefile steps organized in separate download, build and
experimental phases, you can use special rules to do so. This can be specially
useful if you need to download all sources first in a machine that has internet
connection, then transfer the files to machine with restricted connection and
then resume build and experimental steps there. The special rules are:

```
> make download_sources
> make build_all
> make results
```

## makeinfo failures

When building gcc, makeinfo failures can happen if the times of source files
are inconsistent. In this case, you will see a "missing makeinfo" failure in
a gcc build. Notice that this message may be present in logs, but it is not
a fatal error. It is only fatal if make thinks it needs to update the
documentation files. This may happen if you manually copied gcc source files
without preserving original file dates, tricking make into thinking it needs
to call makeinfo to regenerate tex files. Always copy gcc sources by
packing them with the original dates.
