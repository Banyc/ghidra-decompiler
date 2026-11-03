#!/bin/sh
set -e
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
GHIDRA="$REPO_ROOT/reference/ghidra"
GHIDRA_COMMIT=d6192cb3f900f74152a4eeec1aa6758b6143b093
if [ ! -d "$GHIDRA" ]; then
    git init -q "$GHIDRA"
    git -C "$GHIDRA" fetch -q --depth 1 https://github.com/NationalSecurityAgency/ghidra.git "$GHIDRA_COMMIT"
    git -C "$GHIDRA" checkout -q FETCH_HEAD
fi
CPP="$GHIDRA/Ghidra/Features/Decompiler/src/decompile/cpp"
apply_once() {
    if (cd "$1" && patch -p1 --dry-run -s -f < "$2" > /dev/null 2>&1); then
        (cd "$1" && patch -p1 -s < "$2")
        rm -f "$CPP"/com_dbg/*.o "$CPP"/com_opt/*.o "$CPP"/test_dbg/*.o "$CPP"/sla_dbg/*.o "$CPP"/sla_opt/*.o
    fi
}
apply_once "$GHIDRA" "$REPO_ROOT/tools/trace/action_trace.patch"
apply_once "$CPP" "$REPO_ROOT/tools/fuzz/reference_fixes.patch"
apply_once "$CPP" "$REPO_ROOT/tools/reference/libstdcxx16_assertions.patch"
command -v bison >/dev/null || sudo apt-get install -y binutils-dev bison flex zlib1g-dev
# Fedora 44's libstdc++ 16 enables _GLIBCXX_ASSERTIONS for unoptimized builds and ships
# those assertions inside libstdc++.so itself, so the console aborts on the decompiler's
# long-standing out-of-range string indexing (directoryList() on an empty path). The
# patch above guards the sites the console reaches; the define keeps the objects built
# here from adding more. CXX mirrors the Makefile's `CXX=g++ -std=c++11`.
CXX_FLAGS="${CXX:-g++} -std=c++11 -D_GLIBCXX_NO_ASSERTIONS"
# Fedora's /usr/lib64/libbfd.so is an ld script over libbfd.a that omits the compression
# libraries bfd was built against, so the link fails on ZSTD_isError. Ask the toolchain
# which set it needs instead of guessing per distro.
bfd_link() {
    for flags in "-lz -lzstd -lsframe -liberty" "-lz"; do
        if echo 'int main(void){return 0;}' | ${CXX:-g++} -x c++ - -o /dev/null $flags -lbfd >/dev/null 2>&1; then
            echo "$flags"
            return
        fi
    done
    echo "-lz"
}
LNK_FLAGS="$(bfd_link)"
cd "$CPP"
mkdir -p com_dbg com_opt test_dbg sla_opt sla_dbg
touch xml.cc grammar.cc pcodeparse.cc slghparse.cc slghparse.hh slghscan.cc
make -j"$(nproc)" CXX="$CXX_FLAGS" LNK="$LNK_FLAGS" decomp_test_dbg decomp_dbg sleigh_opt
./sleigh_opt -a ../../../../../Processors

# Driving the two binaries (both need SLEIGHHOME="$GHIDRA" and -usesleighenv):
#
#   decomp_test_dbg -usesleighenv -path DIR datatests FILE.xml
#
# is the supported path for tracing: it loads through the XML `<binaryimage>`, so it
# needs no BFD, and it honours the two hooks the Rust harness also honours -
# GHIDRA_ACTION_TRACE=1 (one `A`/`R` event per line on stderr) and
# GHIDRA_TEST_OUTPUT=FILE (the script's printed output, `===`-separated).
#
# `decomp_dbg`'s console loads through BFD, and `load file` takes a **BFD target name**
# first and the file second (`load file elf32-little IMAGE`) - a Ghidra language string
# there fails as `invalid bfd target`. Single-target BFD builds (Fedora's) only carry the
# generic names, so `elf32-littlearm` is invalid while `elf32-little` works, and the
# language is then guessed from the object rather than from the target.
