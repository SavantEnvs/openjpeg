#!/usr/bin/env bash
#
# mayhem/build.sh — build the OpenJPEG fuzz harnesses (sanitized) and the test-oracle binaries.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# UBSan `function` is relaxed (and only it): openjpeg stores codec callbacks through casts such as
# (void (*)(void *, opj_dparameters_t *)) opj_j2k_setup_decoder, so clang-19's -fsanitize=function aborts
# every input at the first indirect call (openjpeg.c:434) and the targets record 2 edges. ASan and
# the rest of UBSan stay on and halting.
RELAX_FLAGS="-fno-sanitize=function"
# Coverage instrumentation for the library, so libFuzzer sees the code under test and not just the harness.
COV_FLAGS="-fsanitize=fuzzer-no-link"

# 1) The project itself (static libopenjp2, no CLI tools), sanitized + DWARF 3. Build dirs live under
#    mayhem/ so the additive mayhem/.gitignore keeps them out of `git clean -ffdX`-surviving state.
FUZZ_BUILD="$SRC/mayhem/build-fuzz"
cmake -S "$SRC" -B "$FUZZ_BUILD" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $RELAX_FLAGS $COV_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $RELAX_FLAGS $COV_FLAGS $DEBUG_FLAGS"
cmake --build "$FUZZ_BUILD" -j"$MAYHEM_JOBS"
LIBOPENJP2="$FUZZ_BUILD/bin/libopenjp2.a"

# 2) Harnesses (mayhem-local copies of the in-tree OSS-Fuzz ones, size guard enabled), each twice: libFuzzer + standalone run-once reproducer.
#    LSan is switched off at build time via lsan_off.cc (ASan + UBSan stay active).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$SRC/mayhem/build-fuzz/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SRC/mayhem/build-fuzz/standalone_main.o"
for H in opj_decompress_fuzzer_J2K opj_decompress_fuzzer_JP2; do
  SRCF="$SRC/mayhem/harness/$H.cpp"
  $CXX $SANITIZER_FLAGS $RELAX_FLAGS $DEBUG_FLAGS -std=c++11 \
      -I"$SRC/src/lib/openjp2" -I"$FUZZ_BUILD/src/lib/openjp2" \
      "$SRCF" "$FUZZ_BUILD/lsan_off.o" $LIB_FUZZING_ENGINE "$LIBOPENJP2" -lm -lpthread \
      -o "/mayhem/$H"
  $CXX $SANITIZER_FLAGS $RELAX_FLAGS $COV_FLAGS $DEBUG_FLAGS -std=c++11 \
      -I"$SRC/src/lib/openjp2" -I"$FUZZ_BUILD/src/lib/openjp2" \
      "$SRCF" "$FUZZ_BUILD/lsan_off.o" "$FUZZ_BUILD/standalone_main.o" "$LIBOPENJP2" -lm -lpthread \
      -o "/mayhem/$H-standalone"
done

# 3) The test oracle: the CLI codec (opj_compress/opj_decompress/opj_dump) with NORMAL flags, no sanitizers.
TEST_BUILD="$SRC/mayhem/build-tests"
cmake -S "$SRC" -B "$TEST_BUILD" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CODEC=ON -DBUILD_TESTING=OFF \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TEST_BUILD" -j"$MAYHEM_JOBS"
