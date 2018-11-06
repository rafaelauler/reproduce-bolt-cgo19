
NUMCORES    := 12
TOPLEV      := $(shell pwd)
BENCHMARKS  := $(TOPLEV)/benchmarks
CLANGSOURCE := $(BENCHMARKS)/llvm
CLANGSTAGE1 := $(BENCHMARKS)/stage1/install/bin/clang
CLANGSTAGE2 := $(BENCHMARKS)/stage2/install/bin/clang

all: $(CLANGSTAGE2)

# Downloading clang sources
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

# Building stage1 clang compiler
$(CLANGSTAGE1): $(BENCHMARKS)/llvm
	mkdir -p $(BENCHMARKS)/stage1
	cd $(BENCHMARKS)/stage1 && cmake $(CLANGSOURCE) -DLLVM_TARGETS_TO_BUILD=X86 \
	  -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
	  -DCMAKE_ASM_COMPILER=gcc -DCMAKE_INSTALL_PREFIX=$(BENCHMARKS)/stage1/install
	cd $(BENCHMARKS)/stage1 && make install -j $(NUMCORES)

# Building stage2 clang with instrumentation
$(CLANGSTAGE2): $(CLANGSTAGE1)
	mkdir -p $(BENCHMARKS)/stage2
	cd $(BENCHMARKS)/stage2 && cmake $(CLANGSOURCE) \
	  -DLLVM_TARGETS_TO_BUILD=X86 -DCMAKE_BUILD_TYPE=Release \
	  -DCMAKE_C_COMPILER=$(CLANGSTAGE1) \
	  -DCMAKE_CXX_COMPILER=$(CLANGSTAGE1)++ \
	  -DLLVM_USE_LINKER=lld -DLLVM_BUILD_INSTRUMENTED=ON \
	  -DCMAKE_INSTALL_PREFIX=$(BENCHMARKS)/stage2/install

clean:
	-rm -rf $(BENCHMARKS)
