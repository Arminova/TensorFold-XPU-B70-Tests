#!/usr/bin/env bash
# run1.sh - one first run of TensorFold's Intel XPU backend on an Intel Arc Pro B70.
#
# It builds TensorFold at a fixed release tag for Battlemage, runs the project's own kernel-contract checks on one
# card, optionally times a Qwen3.8-27B checkpoint you already have, collects the environment and the GPU lines of
# the kernel log, and packs everything into one archive to send back. Nothing is uploaded and nothing is installed.
#
#   ./run1.sh               the whole run, results in ./run1-results.tar.gz
#   ./run1.sh --dry-run     print the plan and run nothing
#   ./run1.sh --no-gpu      environment report, source, build and pack only (no card touched; the device tests
#                           are not built, since building them runs a unit test that opens the card)
#   ./run1.sh --help        this text
#
# Options: --work DIR (default ./tf-b70-run1)  --device N (default 0)
#          --model DIR (a Qwen3.8-27B checkpoint you already have; enables seam, close and the speed table)
#          --ngen DIR (oneDNN's ngen directory, the one holding ngen.hpp; or NGEN_DIR=...)
#          --ocloc PATH (default: ocloc on PATH)  --zig PATH (default: zig on PATH)
set -u -o pipefail

PIN="v1.2.5"
PIN_SHA="8be9c408c"
UPSTREAM="https://github.com/ashhart/TensorFold.git"

WORK="./tf-b70-run1"
DEVICE="0"
MODEL=""
NGEN_DIR="${NGEN_DIR:-}"
OCLOC="${OCLOC:-ocloc}"
ZIG="${ZIG:-zig}"
DRY=0
NO_GPU=0
T_BUILD="${T_BUILD:-3600}"
T_DEVICE="${T_DEVICE:-1800}"
T_BENCH="${T_BENCH:-1200}"

usage() { sed -n '2,18p' "$0" | sed -n 's/^# \{0,1\}//p'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY=1 ;;
    --no-gpu) NO_GPU=1 ;;
    --work) WORK="${2:?--work needs a directory}"; shift ;;
    --device) DEVICE="${2:?--device needs a number}"; shift ;;
    --model) MODEL="${2:?--model needs a directory}"; shift ;;
    --ngen) NGEN_DIR="${2:?--ngen needs a directory}"; shift ;;
    --ocloc) OCLOC="${2:?--ocloc needs a path}"; shift ;;
    --zig) ZIG="${2:?--zig needs a path}"; shift ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(id -u)" = "0" ]; then
  echo "run1.sh: do not run this as root; it builds and runs your own copy of TensorFold." >&2
  exit 2
fi

LOGS="$WORK/logs"
REPO="$WORK/TensorFold"
SUMMARY="$WORK/summary.txt"
STEP_NAME=(); STEP_RC=(); STEP_SEC=()
FAILED=0
# The step commands run in a fresh bash: everything they read must be exported.
export LOGS REPO SUMMARY DEVICE MODEL NGEN_DIR OCLOC ZIG T_BENCH

say() { printf '%s\n' "$*"; }

# A step: name, timeout in seconds, shell command. Output -> logs/<name>.log; a failure is recorded, never fatal.
step() {
  local name="$1" tmo="$2" cmd="$3" t0 t1 rc
  if [ "$DRY" = 1 ]; then
    say "  [$name, timeout ${tmo}s] $cmd"
    return 0
  fi
  say "== $name"
  t0=$(date +%s)
  if command -v timeout >/dev/null 2>&1; then
    timeout "$tmo" bash -c "$cmd" >"$LOGS/$name.log" 2>&1
    rc=$?
  else
    bash -c "$cmd" >"$LOGS/$name.log" 2>&1
    rc=$?
  fi
  t1=$(date +%s)
  STEP_NAME+=("$name"); STEP_RC+=("$rc"); STEP_SEC+=("$((t1 - t0))")
  if [ "$rc" = 0 ]; then
    say "   ok ($((t1 - t0)) s)"
  elif [ "$rc" = 124 ]; then
    FAILED=$((FAILED + 1)); say "   FAILED: timeout after ${tmo}s (logs/$name.log)"
  else
    FAILED=$((FAILED + 1)); say "   FAILED: exit $rc ($((t1 - t0)) s, logs/$name.log)"
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------- environment
environment_text() {
  local ocloc_ver ze_pkg cr_pkg drv mod v
  ocloc_ver=$(dpkg-query -W -f='${Version}' intel-ocloc 2>/dev/null || echo unknown)
  ze_pkg=$(dpkg-query -W -f='${Version}' libze1 2>/dev/null || dpkg-query -W -f='${Version}' libze-loader1 2>/dev/null || echo unknown)
  cr_pkg=$(dpkg-query -W -f='${Version}' intel-opencl-icd 2>/dev/null || echo unknown)
  drv=""
  for card in /sys/class/drm/card[0-9]*/device; do
    [ -d "$card" ] || continue
    mod=$(readlink -f "$card/driver/module" 2>/dev/null) || continue
    v=$(cat "$mod/version" 2>/dev/null)
    drv="$drv$(basename "$mod")${v:+/$v} "
  done
  drv=$(printf '%s' "$drv" | tr ' ' '\n' | awk 'NF' | sort -u | paste -sd' ' -)
  drv="${drv:-no dri driver bound (or not readable)}"

  cat <<EOF
# environment
date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)
kernel: $(uname -sr)
arch: $(uname -m)
distro: $(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}" || echo unknown)
cpu: $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)
nproc: $(nproc 2>/dev/null || echo unknown)
ram_gib: $(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo)
zig_version: $("$ZIG" version 2>/dev/null || echo MISSING)
zig_path: $(command -v "$ZIG" 2>/dev/null || echo MISSING)
ocloc_path: $(command -v "$OCLOC" 2>/dev/null || echo MISSING)
ocloc_package_version: $ocloc_ver
compute_runtime_package_version: $cr_pkg
level_zero_package_version: $ze_pkg
level_zero_loader: $(ldconfig -p 2>/dev/null | sed -n 's/.*\(libze_loader\.so[^ ]*\).*/\1/p' | sort -u | tr '\n' ' ')
gpu_kernel_driver: ${drv:-not loaded}
cxx: $(command -v g++ >/dev/null 2>&1 && g++ --version | head -1 || echo MISSING)
python3: $(command -v python3 >/dev/null 2>&1 && python3 -V 2>&1 || echo MISSING)
ngen_dir: ${NGEN_DIR:-unset}

# graphics devices, PCI ids only
EOF
  if command -v lspci >/dev/null 2>&1; then
    lspci -nn 2>/dev/null | grep -iE 'vga|display|3d' | sed 's/^/  /'
  else
    echo "  lspci MISSING"
  fi
  echo "# Intel GPUs as the compute runtime sees them"
  if command -v clinfo >/dev/null 2>&1; then
    clinfo -l 2>/dev/null | sed 's/^/  /'
  else
    echo "  clinfo MISSING (optional)"
  fi
  echo "# local card memory as the runtime reports it (GiB / MiB)"
  if command -v clinfo >/dev/null 2>&1; then
    clinfo 2>/dev/null | awk '
      /Device Name/ { name = $0; sub(/^.*Device Name[[:space:]]*/, "", name) }
      /Global memory size/ { printf "  %s: %s bytes %s\n", name, $4, $5 }
    ' | head -8
  fi
  for d in /sys/class/drm/card[0-9]*/device; do
    [ -d "$d" ] || continue
    id=$(cat "$d/device" 2>/dev/null) || continue
    vr=$(cat "$d/mem_info_vram_total" 2>/dev/null || echo "")
    echo "  pci_id=$id${vr:+ vram_total_bytes=$vr}"
  done
}

do_environment() {
  say "== environment"
  environment_text >"$LOGS/environment.txt" 2>&1
  STEP_NAME+=("environment"); STEP_RC+=("0"); STEP_SEC+=("0")
  say "   written: logs/environment.txt"
}

# ---------------------------------------------------------------------------------------------------- source
do_clone() {
  local url="${TF_REPO:-$UPSTREAM}" head ok=1 ref
  if [ -d "$REPO/.git" ]; then
    head=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
    say "   $REPO already present, leaving it as it is (${head:0:9})"
    case "$head" in
      "$PIN_SHA"*) ;;
      *) say "   WARNING: it is not $PIN (${PIN_SHA}); delete $REPO to fetch the pin again" ;;
    esac
    echo "existing source: head=$head" >>"$LOGS/source.log"
    STEP_NAME+=("source"); STEP_RC+=("0"); STEP_SEC+=("0")
    return 0
  fi
  say "== source at $PIN ($PIN_SHA) from $url"
  mkdir -p "$REPO" || return 1
  git -C "$REPO" init -q
  git -C "$REPO" remote add origin "$url" 2>/dev/null || true
  for ref in "refs/tags/$PIN" "$PIN" "$PIN_SHA"; do
    if git -C "$REPO" fetch -q --depth 1 origin "$ref" >>"$LOGS/source.log" 2>&1; then ok=0; break; fi
  done
  if [ "$ok" != 0 ]; then
    say "   shallow fetch of the tag failed, fetching the whole repository (larger, slower)"
    git -C "$REPO" fetch -q origin >>"$LOGS/source.log" 2>&1 || { STEP_NAME+=("source"); STEP_RC+=("1"); STEP_SEC+=("0"); return 1; }
  fi
  git -C "$REPO" checkout -q FETCH_HEAD >>"$LOGS/source.log" 2>&1 ||
    git -C "$REPO" checkout -q "$PIN_SHA" >>"$LOGS/source.log" 2>&1 ||
    { STEP_NAME+=("source"); STEP_RC+=("1"); STEP_SEC+=("0"); return 1; }
  head=$(git -C "$REPO" rev-parse HEAD)
  echo "pin=$PIN expected_sha=$PIN_SHA head=$head" >>"$LOGS/source.log"
  STEP_NAME+=("source"); STEP_RC+=("0"); STEP_SEC+=("0")
  case "$head" in
    "$PIN_SHA"*) say "   checked out $PIN (${head:0:9})" ;;
    *) say "   WARNING: $PIN resolved to ${head:0:9}, expected ${PIN_SHA} (see logs/source.log)" ;;
  esac
}

# ----------------------------------------------------------------------------------------------------- tools
missing_tools() {
  local missing="" zv
  zv=$("$ZIG" version 2>/dev/null)
  case "$zv" in
    0.17*) ;;
    "") missing="$missing zig-0.17(not runnable)" ;;
    *) missing="$missing zig-0.17(found $zv)" ;;
  esac
  command -v "$OCLOC" >/dev/null 2>&1 || missing="$missing ocloc"
  { command -v g++ >/dev/null 2>&1 || command -v c++ >/dev/null 2>&1; } || missing="$missing c++17-compiler"
  { [ -n "$NGEN_DIR" ] && [ -f "$NGEN_DIR/ngen.hpp" ]; } || missing="$missing ngen-headers"
  printf '%s' "$missing"
}

try_ngen_dirs() {
  [ -n "$NGEN_DIR" ] && return 0
  local d
  for d in "$HOME/ngen" "$HOME/oneDNN/third_party/ngen" "$HOME/dev/oneDNN/third_party/ngen" /usr/include/ngen /usr/local/include/ngen; do
    if [ -f "$d/ngen.hpp" ]; then NGEN_DIR="$d"; return 0; fi
  done
}

tool_help() {
  say ""
  say "MISSING:$1"
  say ""
  say "What each one is, from TensorFold's B70 recipe, docs/xpu/RECIPE-qwen38-27b-b70.md section 1 (\"What you need\"):"
  say "  zig 0.17          the repository's .zig-version names the release; https://ziglang.org/download"
  say "  ocloc             Intel's offline compiler (Debian/Ubuntu package intel-ocloc)"
  say "  c++17 compiler    builds the prompt-GEMM generator at build time (g++ or c++)"
  say "  nGEN headers      oneDNN's ngen directory, the one that holds ngen.hpp; pass --ngen DIR or set NGEN_DIR"
  say ""
  say "The card steps also need the 'xe' kernel driver and Intel's Level Zero runtime; the same recipe section"
  say "names them. 'clinfo -l' and 'ls /dev/dri' show whether the runtime sees the card."
}

# ----------------------------------------------------------------------------------------------------- build
# xpu-qwen27-tests also runs the runner's unit tests, one of which opens the card: left out under --no-gpu.
build_command() {
  local targets="xpu-qwen27 xpu-qwen27-tests"
  [ "$NO_GPU" = 1 ] && targets="xpu-qwen27"
  printf 'cd %q && %q build %s -Doptimize=ReleaseFast -Dxpu-device=bmg -Dngen-include=%q -Docloc=%q && %q build -Dxpu-contract=true tf-xpu-contract-run -Doptimize=ReleaseFast -Dxpu-device=bmg -Dngen-include=%q -Docloc=%q; rc=$?; echo; echo "binaries:"; ls -l zig-out/bin/; exit $rc' \
    "$REPO" "$ZIG" "$targets" "$NGEN_DIR" "$OCLOC" "$ZIG" "$NGEN_DIR" "$OCLOC"
}

# ------------------------------------------------------------------------------------------------ card steps
contract_cmd() { printf 'cd %q && ./zig-out/bin/tf-xpu-contract-run --device %q' "$REPO" "$DEVICE"; }
means_cmd() { printf 'cd %q && ./zig-out/bin/tf-xpu-qwen27-means-test' "$REPO"; }
seam_cmd() { printf 'cd %q && ./zig-out/bin/tf-xpu-qwen27-seam-test %q' "$REPO" "$MODEL"; }
close_cmd() { printf 'cd %q && ./zig-out/bin/tf-xpu-qwen27-close-test %q' "$REPO" "$MODEL"; }

# One prompt size of the speed table: a synthetic prompt of N tokens, then 32 greedy tokens. XPU_CTX is the KV
# cache's row count, so it must hold the prompt and the decoded tokens: N + 256.
bench_cmd() {
  printf 'cd %q && XPU_CTX=%s ./zig-out/bin/xpu-qwen27 %q --bench=%s 32' "$REPO" "$(( $1 + 256 ))" "$MODEL" "$1"
}

# prompt tok/s and decode tok/s from the runner's own printout ("prompt: N tokens in X s (Y tok/s)").
rate() { sed -n "s/^$1: .*(\([0-9.]*\) tok\/s).*/\1/p" "$2" | head -1; }

# Fills logs/speed.txt from the per-size logs (called once, after the sizes ran).
speed_table() {
  local n out="$LOGS/speed.txt" p d
  printf '%-7s %-14s %-14s %s\n' tokens prompt_tok/s decode_tok/s note >"$out"
  for n in 2048 4096 8192 16384 32768 65536 131072; do
    if grep -q '^prompt:' "$LOGS/bench-$n.log" 2>/dev/null; then
      p=$(rate prompt "$LOGS/bench-$n.log"); d=$(rate decode "$LOGS/bench-$n.log")
      printf '%-7s %-14s %-14s\n' "$n" "${p:--}" "${d:--}" >>"$out"
    else
      printf '%-7s %-14s %-14s %s\n' "$n" "-" "-" "failed or did not fit, logs/bench-$n.log" >>"$out"
    fi
  done
  cat "$out"
}

# Existing tools only; nothing of ours.
card_numbers() {
  local out="$LOGS/card.txt" found=0
  : >"$out"
  if command -v clpeak >/dev/null 2>&1; then
    found=1
    { echo "# clpeak"; timeout 900 clpeak -d "$DEVICE" 2>&1 || timeout 900 clpeak 2>&1; } >>"$out"
  else
    echo "# clpeak: not installed, skipped" >>"$out"
  fi
  if command -v ze_peak >/dev/null 2>&1; then
    found=1
    { echo "# ze_peak"; timeout 900 ze_peak 2>&1; } >>"$out"
  else
    echo "# ze_peak: not installed, skipped" >>"$out"
  fi
  [ "$found" = 1 ] || echo "# neither clpeak nor ze_peak is installed: no card numbers collected"
  cat "$out"
}

kernel_log() {
  local out="$LOGS/kernel-log.txt" since="$1"
  : >"$out"
  if journalctl -k --since "$since" >"$out.raw" 2>/dev/null ||
     journalctl -k -n 5000 >"$out.raw" 2>/dev/null ||
     dmesg >"$out.raw" 2>/dev/null; then
    grep -iE 'xe |i915|gpu hang|drm|level.?zero|guc|reset' "$out.raw" 2>/dev/null | tail -n 400 >"$out"
    rm -f "$out.raw"
  fi
  [ -s "$out" ] || echo "# kernel log not readable without privileges, or no GPU lines in it: skipped" >"$out"
  echo "# $(( $(grep -ci 'gpu hang\|reset' "$out" 2>/dev/null || echo 0) )) hang/reset lines" >>"$out"
}

# ---------------------------------------------------------------------------------------------------- scrub
# Run over every text file that will be packed: no user name, host name, home path, IP or MAC leaves this machine.
scrub() {
  local f home_re user_re host_re
  home_re=$(printf '%s' "$HOME" | sed 's/[][\.*^$/]/\\&/g')
  user_re=$(id -un | sed 's/[][\.*^$/]/\\&/g')
  host_re=$({ hostname; hostname -f 2>/dev/null; hostname -s 2>/dev/null; } | awk 'NF' | sort -u |
             sed 's/[][\.*^$/]/\\&/g' | paste -sd'|')
  local -a rules=()
  # an empty pattern would match everywhere, so each rule only when its pattern is not empty
  [ -n "$home_re" ] && [ "$HOME" != "/" ] && rules+=(-e "s|${home_re}|~|g")
  rules+=(-e 's|/home/[A-Za-z0-9._-]+|~|g' -e 's|/root\b|~|g')
  [ -n "$host_re" ] && rules+=(-e "s/(${host_re})/HOST/g")
  [ -n "$user_re" ] && rules+=(-e "s|\\b${user_re}\\b|USER|g")
  rules+=(-e 's|\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b|MAC|g')
  for f in "$LOGS"/*.log "$LOGS"/*.txt "$SUMMARY"; do
    [ -f "$f" ] || continue
    sed -E -i "${rules[@]}" "$f" 2>/dev/null
    # IPv4 addresses, except in the environment report, whose package versions look like dotted quads
    [ "$(basename "$f")" = environment.txt ] || sed -E -i 's|\b([0-9]{1,3}\.){3}[0-9]{1,3}\b|IP|g' "$f" 2>/dev/null
  done
}

# -------------------------------------------------------------------------------------------------- summary
write_summary() {
  local failed="$1" i total="$2"
  {
    echo "TensorFold on an Intel XPU - first run"
    echo "generated_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "pin: $PIN (${PIN_SHA}...)"
    echo "head: $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "device_ordinal: $DEVICE"
    echo "checkpoint: ${MODEL:-none given}"
    echo "no_gpu_mode: $NO_GPU"
    echo "total_seconds: $total"
    echo
    printf '%-18s %-8s %s\n' step result seconds
    for i in "${!STEP_NAME[@]}"; do
      printf '%-18s %-8s %s\n' "${STEP_NAME[$i]}" "$([ "${STEP_RC[$i]}" = 0 ] && echo ok || echo FAILED)" "${STEP_SEC[$i]}"
    done
    echo
    if [ "$NO_GPU" = 1 ]; then
      echo "summary: --no-gpu run, no card touched"
    elif [ "$failed" = 0 ]; then
      echo "summary: every step passed"
    else
      echo "summary: $failed step(s) failed; each one's log is in logs/"
    fi
    [ -s "$LOGS/speed.txt" ] && { echo; echo "speed table (logs/speed.txt):"; cat "$LOGS/speed.txt"; }
    [ -s "$LOGS/contract.log" ] && { echo; echo "contract runner:"; grep 'SUMMARY' "$LOGS/contract.log" | tail -2 | sed 's/^/  /'; }
    [ -s "$LOGS/kernel-log.txt" ] && { echo; tail -1 "$LOGS/kernel-log.txt" | sed 's/^# /kernel log: /'; }
  } >"$SUMMARY"
}

pack() {
  local parent base tar sha
  parent=$(pwd)   # run1-results.tar.gz lands where the run was started
  base=$(basename "$WORK")
  tar="$parent/run1-results.tar.gz"
  if command -v sha256sum >/dev/null 2>&1; then sha=sha256sum; else sha="shasum -a 256"; fi
  scrub
  rm -f "$tar"
  tar czf "$tar" -C "$(dirname "$WORK")" "$base/logs" "$base/summary.txt" || return 1
  ( cd "$parent" && $sha "run1-results.tar.gz" >"run1-results.tar.gz.sha256" )
  say ""
  say "packed:   $tar"
  say "sha256:   $(cut -d' ' -f1 "$tar.sha256")"
  say "send back: run1-results.tar.gz"
  return 0
}

# ----------------------------------------------------------------------------------------------------- main
main() {
  local t0 total cmd
  t0=$(date +%s)
  try_ngen_dirs
  say "TensorFold on an Intel Arc Pro B70 - first run"
  say "pin $PIN, work folder $WORK, card ordinal $DEVICE${MODEL:+, checkpoint $MODEL}"
  if [ "$DRY" = 1 ]; then
    say ""
    say "plan (nothing is created, cloned, built or run):"
    say "  environment   the machine, driver and runtime versions, PCI ids, card memory -> logs/environment.txt"
    say "  source        clone ${TF_REPO:-$UPSTREAM} at $PIN into $REPO"
    say "  build         zig build xpu-qwen27 xpu-qwen27-tests and -Dxpu-contract=true tf-xpu-contract-run, -Dxpu-device=bmg (timeout ${T_BUILD}s)"
    if [ "$NO_GPU" = 1 ]; then
      say "  card steps    skipped (--no-gpu; the device tests are not built either)"
    else
      say "  contract      ./zig-out/bin/tf-xpu-contract-run --device $DEVICE   (gates 1-4, planted controls, gate 5 live, timeout ${T_DEVICE}s)"
      say "  means         ./zig-out/bin/tf-xpu-qwen27-means-test               (group means against FP64, no model)"
      if [ -n "$MODEL" ]; then
        say "  seam          ./zig-out/bin/tf-xpu-qwen27-seam-test $MODEL          (prompt cut at 64 / 1024 / whole: same logits)"
        say "  close         ./zig-out/bin/tf-xpu-qwen27-close-test $MODEL         (three opens give the card back)"
        say "  speed         xpu-qwen27 $MODEL --bench=N 32 for N = 2K..128K with XPU_CTX=N+256, one cold run each (timeout ${T_BENCH}s a size)"
      else
        say "  seam, close, speed  need a 27B checkpoint: skipped (pass --model DIR to include them)"
      fi
      say "  card          clpeak / ze_peak if already installed, else skipped"
      say "  kernel-log    journalctl -k / dmesg, GPU lines only"
    fi
    say "  summary       summary.txt: pass / fail and seconds per step"
    say "  pack          run1-results.tar.gz (logs/ and summary.txt), identity scrubbed, sha256 printed"
    say ""
    say "estimated time: about $([ -n "$MODEL" ] && echo '45-60 min' || echo '25 min') (build is the bulk)"
    say "the tool check would report: $(missing_tools)"
    exit 0
  fi

  mkdir -p "$LOGS" || exit 1
  say "estimated time: about $([ -n "$MODEL" ] && echo '45-60 min' || echo '25 min') (build is the bulk)"
  say "logs: $LOGS; nothing is uploaded"
  do_environment

  if [ -n "$MODEL" ] && [ ! -d "$MODEL" ]; then
    say ""
    say "--model $MODEL is not a directory: the checkpoint steps would fail."
    say "Fix the path, or leave --model out to run only the checks that need no checkpoint."
    write_summary 1 0
    return 2
  fi
  if [ -n "$MODEL" ] && [ ! -f "$MODEL/config.json" ]; then
    say "note: $MODEL has no config.json; upstream reads one when it is there, so this may still work"
  fi

  local missing
  missing=$(missing_tools)
  if [ -n "$missing" ]; then
    tool_help "$missing"
    write_summary 1 0
    say ""
    say "nothing was built; fix the tools above and run again"
    return 2
  fi

  if ! do_clone; then
    write_summary 1 0
    say ""
    say "cannot get the source at $PIN; see $LOGS/source.log"
    return 1
  fi

  step build "$T_BUILD" "$(build_command)"
  if [ -f "$LOGS/build.log" ] && grep -q 'run test w' "$LOGS/build.log"; then
    # Known and harmless: the runner's own host test needs a card in this build's host-test list; the binaries in
    # zig-out/bin are still made (the build's exit status decides that, not this line). Recorded, not hidden.
    printf '\n(note: "run test w" is the runner host test asking for a card; the build itself succeeded, see the binaries above)\n' \
      >>"$LOGS/build.log"
  fi

  if [ "$NO_GPU" = 1 ]; then
    say "== card steps skipped (--no-gpu): nothing on this machine was run on a GPU"
  else
    step contract "$T_DEVICE" "$(contract_cmd)"
    step means "$T_DEVICE" "$(means_cmd)"
    if [ -n "$MODEL" ]; then
      step seam "$T_DEVICE" "$(seam_cmd)"
      step close "$T_DEVICE" "$(close_cmd)"
      local n
      for n in 2048 4096 8192 16384 32768 65536 131072; do
        step "bench-$n" "$T_BENCH" "$(bench_cmd "$n")"
      done
      speed_table >"$LOGS/speed.log" 2>&1
      say "== speed table"
      sed 's/^/   /' "$LOGS/speed.log"
      STEP_NAME+=("speed-table"); STEP_RC+=("0"); STEP_SEC+=("0")
    else
      say "== seam, close and the speed table need a 27B checkpoint: pass --model DIR to include them"
    fi
    step card "$T_DEVICE" "$(declare -f card_numbers); card_numbers"
    step kernel-log 120 "$(declare -f kernel_log); kernel_log $(date -u -d "@$t0" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  total=$(( $(date +%s) - t0 ))
  write_summary "$FAILED" "$total"
  pack || { say "packing failed; the folder $WORK is still there" >&2; return 1; }
  if [ "$FAILED" != 0 ]; then
    say "one or more steps failed; the archive is still complete and worth sending (summary.txt says which)"
  fi
  say ""
  cat "$SUMMARY"
  say ""
  say "total: ${total}s"
  [ "$FAILED" = 0 ] || return 1
  return 0
}

main
