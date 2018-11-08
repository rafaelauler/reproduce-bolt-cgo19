# Makefile recipes to reproduce the open-source results reported in
# "BOLT: A Practical Binary Optimizer for Data Centers and Beyond"
# CGO 2019
#
# The open-source workload evaluated on this paper is clang 7. Our goal is
# to demonstrate that building clang with all optimizations, including LTO and
# PGO, still leaves opportunities for a post-link optimizer such as BOLT to do
# a better job at basic block placement and function reordering, significantly
# improving workload performance.
#
# In a nutshell, the paper advocates for a two-step profiling compilation
# pipeline, showing that doing a single pass of profiling collection is not
# enough. In this two-step approach, PGO or AutoFDO can be used to feed the
# compiler with profile information, which is important for obtaining better
# quality in inlining decisions, while a second pass to collect profile for a
# post-link optimizer such as BOLT is done to get the best basic block order
# and function order.
#
# The reason why the PGO-enabled compiler can't beat BOLT's reordering here is
# because BOLT profile is more accurate. Profiles used in compilers and BOLT,
# for space-efficiency reasons, are not traces but an aggregation of execution
# counts. This aggregation loses information, e.g. a given function accumulates
# the superposition of many traces, each one possibly using a different path
# depending on its callee. This data has limited applicability and, depending on
# the optimizations that the compiler applies, may render this aggregated data
# stale. For example, after the compiler decides to inline a function that
# was not previously inlined, it now lacks the correct profile for this function
# given that that call site should exercise a subset of the paths reported
# in the more general profile. BOLT, by operating at the final binary, has a
# more accurate view of the profile and is not affected by this and other
# issues, such as mapping back from binary addresses to high-level DWARF.
#
# Technical aspects:
#
# You will probably need a machine with at least 32GB RAM. The lower your core
# count, the slower it will be, as this is building a large code base several
# times, which benefits with a higher core count.
#
# This is a reproduction of the steps described at
#  https://github.com/facebookincubator/BOLT/blob/master/docs/OptimizingClang.md
#
# It is important to adjust NUMCORES to the number of cores in your system as
# it *will* affect results.
#
# Note: This is a regular Makefile. If you want to re-do a step, simply delete
# the rule target or touch one of its prerequisites to be more updated than the
# target.

NUMCORES       := 40
TOPLEV         := $(shell pwd)
SOURCES        := $(TOPLEV)/src
BOLTSOURCE     := $(SOURCES)/llvm
BOLT           := $(SOURCES)/install/bin/llvm-bolt
PERF2BOLT      := $(SOURCES)/install/bin/perf2bolt
BENCHMARKS     := $(TOPLEV)/benchmarks
CLANGSOURCE    := $(BENCHMARKS)/llvm
CLANGSTAGE1    := $(BENCHMARKS)/stage1/install/bin/clang
CLANGSTAGE2    := $(BENCHMARKS)/stage2/install/bin/clang
PGOPROFILE     := $(BENCHMARKS)/stage2/clang.profdata
CLANGPGO       := $(BENCHMARKS)/clangpgo/install/bin/clang
RAWDATA        := $(BENCHMARKS)/stage2/perf.data
BOLTDATA       := $(BENCHMARKS)/stage2/clang.fdata
BOLTEDCLANG    := $(BENCHMARKS)/clangbolt/install/bin/clang
BOLTLOG        := $(TOPLEV)/bolt.log
MEASUREMENTS_A := $(TOPLEV)/measurements_clang.txt
MEASUREMENTS_B := $(TOPLEV)/measurements_bolt.txt
MEASUREMENTS   := $(TOPLEV)/measurements.txt
COMPARISON     := $(TOPLEV)/comparison.txt
LOG_A          := $(TOPLEV)/output_clang.txt
LOG_B          := $(TOPLEV)/output_bolt.txt

all: print_results

# Step 1: Downloading clang sources
$(CLANGSOURCE):
	mkdir -p $(BENCHMARKS)
	cd $(BENCHMARKS)               && git clone -q --depth=1 --branch=release_70 \
	  https://git.llvm.org/git/llvm.git/ llvm
	cd $(BENCHMARKS)/llvm/tools    && git clone -q --depth=1 --branch=release_70 \
	  https://git.llvm.org/git/clang.git/
	cd $(BENCHMARKS)/llvm/projects && git clone -q --depth=1 --branch=release_70 \
	  https://git.llvm.org/git/lld.git/
	cd $(BENCHMARKS)/llvm/projects && git clone -q --depth=1 --branch=release_70 \
	  https://git.llvm.org/git/compiler-rt.git/

# Step 2: Building stage1 clang compiler so we use the same compiler used in the
# paper. Our goal is to improve our workload on top of this compiler.
$(CLANGSTAGE1): $(BENCHMARKS)/llvm
	mkdir -p $(BENCHMARKS)/stage1
	cd $(BENCHMARKS)/stage1 && cmake $(CLANGSOURCE) -DLLVM_TARGETS_TO_BUILD=X86 \
	  -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
	  -DCMAKE_ASM_COMPILER=gcc -DCMAKE_INSTALL_PREFIX=$(BENCHMARKS)/stage1/install
	cd $(BENCHMARKS)/stage1 && make install -j $(NUMCORES)

# Step 3: Building stage2 clang with instrumentation capability. This is our
# workload (clang itself). We have to enable instrumentation in order to collect
# profile data for it, which will enable us to build a faster clang.
$(CLANGSTAGE2): $(CLANGSTAGE1)
	mkdir -p $(BENCHMARKS)/stage2
	cd $(BENCHMARKS)/stage2 && cmake $(CLANGSOURCE) \
	  -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_C_COMPILER=$(CLANGSTAGE1) \
	  -DCMAKE_CXX_COMPILER=$(CLANGSTAGE1)++ \
	  -DLLVM_USE_LINKER=lld -DLLVM_BUILD_INSTRUMENTED=ON \
	  -DCMAKE_INSTALL_PREFIX=$(BENCHMARKS)/stage2/install
	cd $(BENCHMARKS)/stage2 && make install -j $(NUMCORES)

# Step 4: Collect profile data for our workload. Remember our workload is clang,
# and since it is a compiler, we have to build something to collect profile. We
# build clang itself again for this.
$(BENCHMARKS)/stage2/profiles: $(CLANGSTAGE2)
	mkdir -p $(BENCHMARKS)/train
	cd $(BENCHMARKS)/train && cmake $(CLANGSOURCE) \
	  -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_C_COMPILER=$(CLANGSTAGE2) \
	  -DCMAKE_CXX_COMPILER=$(CLANGSTAGE2)++ \
	  -DLLVM_USE_LINKER=lld \
	  -DCMAKE_INSTALL_PREFIX=$(BENCHMARKS)/train/install
	cd $(BENCHMARKS)/train && make clang -j $(NUMCORES)

# Step 5: Merge profiles. Intermediate step to generate the PGO data to build
# a faster workload (clang + lto + pgo).
$(PROFILE): $(BENCHMARKS)/stage2/profiles
	cd $(BENCHMARKS)/stage2/profiles && \
	  $(BENCHMARKS)/stage1/install/bin/llvm-profdata merge \
	  -output=$(PROFILE) *.profraw

# Step 6: Build the fastest version of our open-source workload: PGO- and LTO-
# enabled. We will show that BOLT can further speedup this binary (which is
# clang the compiler driver and C++ frontend).
$(CLANGPGO): $(PROFILE)
	mkdir -p $(BENCHMARKS)/clangpgo
	export LDFLAGS="-Wl,-q" && cd $(BENCHMARKS)/clangpgo && cmake $(CLANGSOURCE) \
	  -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_C_COMPILER=$(CLANGSTAGE1) \
	  -DCMAKE_CXX_COMPILER=$(CLANGSTAGE1)++ \
	  -DLLVM_USE_LINKER=lld \
	  -DLLVM_ENABLE_LTO=Full \
	  -DLLVM_PROFDATA_FILE=$(PROFILE) \
	  -DCMAKE_INSTALL_PREFIX=$(BENCHMARKS)/clangpgo/install
	cd $(BENCHMARKS)/clangpgo && make install -j $(NUMCORES)

# Step 7: Download the open-source BOLT tool (which is being evaluated here)
$(BOLTSOURCE):
	mkdir -p $(SOURCES)
	cd $(SOURCES)            && git clone https://github.com/llvm-mirror/llvm \
	  llvm -q --single-branch
	cd $(SOURCES)/llvm/tools && git checkout -b llvm-bolt \
	  f137ed238db11440f03083b1c88b7ffc0f4af65e
	cd $(SOURCES)/llvm/tools && git clone \
	  https://github.com/facebookincubator/BOLT llvm-bolt
	cd $(SOURCES)/llvm && patch -p1 < tools/llvm-bolt/llvm.patch

# Step 8: Build BOLT
$(BOLT): $(BOLTSOURCE)
	mkdir -p $(SOURCES)/build
	cd $(SOURCES)/build && cmake $(BOLTSOURCE) \
	  -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
	  -DCMAKE_INSTALL_PREFIX=$(SOURCES)/install
	cd $(SOURCES)/build && make install -j $(NUMCORES)

# Step 9: Collect BOLT data for our workload (clang built with PGO and LTO)
# BOLT data is collected with Linux perf, the same used for AutoFDO. We don't
# evaluate AutoFDO here, but we use PGO, which yields superior quality profiles
# for the compiler. We show that even in this case, BOLT can still get
# performance improvements (competing with a instrumented profile for the
# compiler). The goal is to show that even feeding the most accurate profile
# for the compiler is not enough to capture all performance benefits from
# profile-guided compilation, and that a post-link tool is beneficial.
$(RAWDATA): $(BOLT) $(CLANGPGO)
	-rm -rf $(BENCHMARKS)/train
	mkdir -p $(BENCHMARKS)/train
	cd $(BENCHMARKS)/train && cmake $(CLANGSOURCE) \
	  -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_C_COMPILER=$(CLANGPGO) -DCMAKE_CXX_COMPILER=$(CLANGPGO)++ \
	  -DLLVM_USE_LINKER=lld -DCMAKE_INSTALL_PREFIX=$(BENCHMARKS)/train/install
	cd $(BENCHMARKS)/train && \
	  perf record -e cycles:u -j any,u -o $(RAWDATA) -- make clang -j $(NUMCORES)

# Step 10: Aggregating data. This is a data conversion step, reading perf.data
# generated by Linux perf and creating the profile file used by BOLT. This needs
# to read every sample recorded at each hardware performance counter event, read
# the LBR for this event (16 branches or 32 addresses) and convert them to
# aggregated edge counts. For this experiment, since the collected raw perf.data
# is very large (10GB), this step will take some time (30+ minutes).
$(BOLTDATA): $(RAWDATA) $(PERF2BOLT)
	cd $(BENCHMARKS)/stage2 && \
	  $(PERF2BOLT) $(CLANGPGO)-7 -p perf.data -o $(BOLTDATA) -w $(BOLTDATA).yaml \
	  |& tee $(BOLTLOG)

# Step 11: Run BOLT now that we have both inputs: the profile data collected by
# perf and the input binary (clang built with PGO/LTO-enabled clang). BOLT
# should provide a log of the work it did and output a faster binary (faster
# clang, for this case).
$(CLANGPGO)-7.bolt: $(BOLTDATA) $(CLANGPGO)
	cd $(BENCHMARKS)/stage2/install/bin && \
	  $(BOLT) $(CLANGPGO)-7 -o $(CLANGPGO)-7.bolt -b $(BOLTDATA).yaml \
	  -reorder-blocks=cache+ -reorder-functions=hfsort+ -split-functions=3 \
	  -split-all-cold -dyno-stats -icf=1 -use-gnu-stack |& tee -a $(BOLTLOG)

# Step 12: Create a new clang installation with a clang binary processed by BOLT
# A compiler installation is quite complex because it depends on header and
# library files. This one is just the compiler. The clang driver will try to
# automatically locate your system headers and libraries and use that to provide
# a full C/C++ toolchain.
$(BOLTEDCLANG): $(CLANGPGO)-7.bolt
	mkdir -p $(BENCHMARKS)/clangbolt
	cd $(BENCHMARKS)/clangbolt && cp -vr $(BENCHMARKS)/stage2/install .
	cp $(CLANGPGO)-7.bolt $(BOLTEDCLANG)

# Step 13: Measure compile time to build a large project (clang itself) using
# clang built with lto+pgo.
$(MEASUREMENTS_A)%: $(CLANGPGO)
	-rm -rf $(BENCHMARKS)/train
	mkdir -p $(BENCHMARKS)/train
	cd $(BENCHMARKS)/train && cmake $(CLANGSOURCE) \
	  -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_C_COMPILER=$(CLANGPGO) -DCMAKE_CXX_COMPILER=$(CLANGPGO)++ \
	  -DLLVM_USE_LINKER=lld -DCMAKE_INSTALL_PREFIX=$(BENCHMARKS)/train/install
	cd $(BENCHMARKS)/train && perf stat -x , \
	  -o $@ -- make clang -j $(NUMCORES) &> $(LOG_A)

# Step 14: Measure compile time to build a large project (clang itself) using
# clang built with lto+pgo+bolt
$(MEASUREMENTS_B)%: $(BOLTEDCLANG)
	-rm -rf $(BENCHMARKS)/train
	mkdir -p $(BENCHMARKS)/train
	cd $(BENCHMARKS)/train && cmake $(CLANGSOURCE) \
	  -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_C_COMPILER=$(BOLTEDCLANG) -DCMAKE_CXX_COMPILER=$(BOLTEDCLANG)++ \
	  -DLLVM_USE_LINKER=lld -DCMAKE_INSTALL_PREFIX=$(BENCHMARKS)/train/install
	cd $(BENCHMARKS)/train && perf stat -x , \
	  -o $@ -- make clang -j $(NUMCORES) &> $(LOG_B)

# Step 15: Aggregate results in a single file
$(MEASUREMENTS): $(MEASUREMENTS_A).1 $(MEASUREMENTS_A).2 $(MEASUREMENTS_A).3 $(MEASUREMENTS_B).1 $(MEASUREMENTS_B).2 $(MEASUREMENTS_B).3
	cat $^ &> $(MEASUREMENTS)

AWK_SCRIPT := '                                                               \
	BEGIN                                                                       \
	{                                                                           \
	  sum = 0;                                                                  \
	  sumsq = 0;                                                                \
	};                                                                          \
	{                                                                           \
    sum += $$1;                                                               \
    sumsq += ($$1)^2;                                                         \
	  printf "Data point %s: %f\n", NR, $$1                                     \
  }                                                                           \
  END                                                                         \
	{                                                                           \
	  printf "Mean: %f StdDev: %f\n", sum/NR, sqrt((sumsq - sum^2/NR)/(NR-1))   \
	};  \
'

# Step 16: Compare and print results
print_results: $(MEASUREMENTS)
	echo "SIDE A: Without BOLT:"
	cat $(MEASUREMENTS) | grep task-clock | head -n 3 | awk -F',' \
	  $(AWK_SCRIPT) |& tee $(COMPARISON)
	echo "SIDE B: With BOLT:"
	cat $(MEASUREMENTS) | grep task-clock | tail -n 3 | awk -F',' \
	  $(AWK_SCRIPT) |& tee -a $(COMPARISON)
	ASIDE=`cat $(COMPARISON) | head -n 4 | tail -n 1 | awk '{print $$2}'` \
	  BSIDE=`cat $(COMPARISON) | tail -n 1 | awk '{print $$2}'` \
	  sh <<< 'COMP=$$(echo "scale=4;($$ASIDE / $$BSIDE - 1) * 100" | bc); \
	          echo -ne "\n\nclang+pgo+lto+bolt is $${COMP}% faster than \
	          clang+pgo+lto, average of 3 experiments\n\n"'

# Cleaning steps - clean removes benchmarks and BOLT sources
# distclean removes even the last experiment results and logs
clean:
	-rm -rf $(BENCHMARKS) $(SOURCES)

distclean: clean
	-rm -rf $(LOG_A) $(LOG_B) $(MEASUREMENTS_A) $(MEASUREMENTS_B) $(BOLTLOG) \
	  $(MEASUREMENTS) $(COMPARISON)
