#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the OpenJPEG codec round-trip oracle (CLI built by mayhem/build.sh).
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/mayhem/build-tests/bin"
DATA="$SRC/mayhem/testdata"
for t in opj_compress opj_decompress opj_dump; do
  [ -x "$BIN/$t" ] || { echo "missing $BIN/$t — mayhem/build.sh must build it" >&2; emit_ctrf "openjpeg-roundtrip" 0 1 0; exit 1; }
done
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
PASSED=0; FAILED=0

ok()   { PASSED=$((PASSED+1)); echo "PASS $1"; }
fail() { FAILED=$((FAILED+1)); echo "FAIL $1: $2" >&2; }

NP() { python3 "$SRC/mayhem/netpbm.py" "$@"; }

# roundtrip <name> <input> <ext> <opj_compress options...>
# Lossless encode then decode; the decoded pixels MUST equal the input's (the decoder only adds a header comment).
roundtrip() {
  local name="$1" in="$2" ext="$3"; shift 3
  local enc="$W/$name.$ext" dec="$W/$name.out.${in##*.}"
  rm -f "$enc" "$dec"
  "$BIN/opj_compress" -i "$in" -o "$enc" "$@" >"$W/$name.enc.log" 2>&1 || { fail "$name" "opj_compress failed"; return; }
  [ -s "$enc" ] || { fail "$name" "no codestream produced"; return; }
  "$BIN/opj_decompress" -i "$enc" -o "$dec" >"$W/$name.dec.log" 2>&1 || { fail "$name" "opj_decompress failed"; return; }
  if NP same "$in" "$dec"; then ok "$name"; else fail "$name" "decoded image differs from input"; fi
}

G8="$DATA/gray8.pgm"; RGB="$DATA/rgb8.ppm"; G16="$DATA/gray16.pgm"
roundtrip gray8_j2k   "$G8"  j2k
roundtrip gray8_jp2   "$G8"  jp2
roundtrip rgb_j2k     "$RGB" j2k
roundtrip rgb_jp2_rpcl "$RGB" jp2 -p RPCL
roundtrip rgb_tiled_pcrl "$RGB" j2k -t 32,32 -n 3 -p PCRL
roundtrip rgb_tiled_cprl "$RGB" j2k -t 32,16 -n 3 -p CPRL
roundtrip gray16_j2k  "$G16" j2k
roundtrip gray16_jp2  "$G16" jp2 -n 3
roundtrip gray8_sop_eph "$G8" j2k -SOP -EPH
roundtrip gray8_layers "$G8" j2k -r 20,10,1
roundtrip gray8_precincts "$G8" j2k -c "[16,16],[8,8]" -n 3
roundtrip gray8_bypass "$G8" j2k -M 1
roundtrip gray8_reset_termall "$G8" j2k -M 6
roundtrip gray8_vsc_pterm_segsym "$G8" j2k -M 56
roundtrip rgb_codeblock "$RGB" j2k -b 16,16

# Lossy: error is bounded but non-zero (it really is lossy), and the stream is smaller than the lossless one.
lossy="$W/lossy.j2k"; lossydec="$W/lossy.out.ppm"
if "$BIN/opj_compress" -i "$RGB" -o "$lossy" -I -r 12 >/dev/null 2>&1 && \
   "$BIN/opj_decompress" -i "$lossy" -o "$lossydec" >/dev/null 2>&1 && \
   NP lossy "$RGB" "$lossydec" 12 && \
   [ "$(stat -c %s "$lossy")" -lt "$(stat -c %s "$W/rgb_j2k.j2k")" ]; then
  ok lossy_bounded_error; else fail lossy_bounded_error "lossy round-trip out of bounds"; fi

# Reduced resolution: 97x83 decodes at -r 1 to ceil(97/2) x ceil(83/2) = 49x42 with a similar mean.
if "$BIN/opj_decompress" -i "$W/gray8_j2k.j2k" -o "$W/red.pgm" -r 1 >/dev/null 2>&1 && \
   NP dims "$W/red.pgm" 49 42 && NP mean "$G8" "$W/red.pgm" 6; then
  ok decode_reduced_dims; else fail decode_reduced_dims "wrong reduced image"; fi

# Decode area: -d x0,y0,x1,y1 must yield exactly that window of the original pixels.
if "$BIN/opj_decompress" -i "$W/gray8_j2k.j2k" -o "$W/crop.pgm" -d 4,3,60,45 >/dev/null 2>&1 && \
   NP crop "$G8" "$W/crop.pgm" 4 3 60 45; then
  ok decode_area_window; else fail decode_area_window "window mismatch"; fi

# opj_dump reports the real geometry of the stream.
dump="$("$BIN/opj_dump" -i "$W/rgb_j2k.j2k" 2>&1)" || true
if echo "$dump" | grep -q "x1=72, y1=56" && echo "$dump" | grep -q "numcomps=3"; then ok dump_geometry
else fail dump_geometry "opj_dump did not report 72x56x3"; fi

# A truncated codestream must be rejected, not silently decoded to success.
head -c 60 "$W/rgb_j2k.j2k" > "$W/trunc.j2k"
if "$BIN/opj_decompress" -i "$W/trunc.j2k" -o "$W/trunc.ppm" >/dev/null 2>&1; then
  fail truncated_rejected "decoder accepted a truncated stream"; else ok truncated_rejected; fi

emit_ctrf "openjpeg-roundtrip" "$PASSED" "$FAILED" 0
