#!/usr/bin/env bash
# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
# Ubuntu static analysis: clang-format + clang-tidy (modularized)
set -Eeuo pipefail

BUILD_TYPE="Debug"
CMAKE_GENERATOR_DEFAULT="Ninja"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/ci-static-analysis.sh [--build-type Debug|RelWithDebInfo]

Runs static analysis on Ubuntu:
- Installs base tools via common lib
- Installs LLVM/Clang toolchain + analysis tools (clang-format, clang-tidy, run-clang-tidy if available)
- Builds PostgreSQL from source to provide PG_CONFIG (via common lib)
- Configures the project with Clang to produce compile_commands.json
- Runs clang-format --Werror and clang-tidy across repo sources
EOF
}

# Resolve and source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-common.sh
source "${SCRIPT_DIR}/lib/ci-common.sh"

# Shortcuts
log() { ci::log "$@"; }
endgroup() { ci::endgroup; }

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-type) BUILD_TYPE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if ! ci::is_linux; then
  echo "This script is intended for Ubuntu/Linux runners." >&2
  exit 1
fi

# Always show ccache stats at the end
trap 'ccache --show-stats || true' EXIT

# ---- Install base tools (common) ----
log "Install base tools"
ci::apt_install_base
endgroup

# ---- Install LLVM/Clang toolchain + analysis tools ----
log "Install LLVM/Clang toolchain and analysis tools"
# Try specific version packages first, then fall back to unversioned
sudo apt-get install -y \
  clang-20 llvm-20-tools llvm-20-dev lld-20 clang-tidy-20 clang-format-20 || true
sudo apt-get install -y \
  clang llvm-tools llvm-dev lld clang-tidy clang-format || true

# Resolve clang binaries
CLANG="$(command -v clang-20 || command -v clang || echo clang)"
CLANGXX="$(command -v clang++-20 || command -v clang++ || echo clang++)"
CLANG_TIDY="$(command -v clang-tidy-20 || command -v clang-tidy || true)"
CLANG_FORMAT="$(command -v clang-format-20 || command -v clang-format || true)"
RUN_CLANG_TIDY="$(command -v run-clang-tidy || true)"
LLVM_CONFIG="$(ci::find_llvm_config || true)"

if ! command -v "${CLANG}" >/dev/null 2>&1; then
  echo "clang not found on PATH" >&2
  exit 1
fi
if [[ -z "${CLANG_TIDY}" ]]; then
  echo "clang-tidy not found" >&2
  exit 1
fi
if [[ -z "${CLANG_FORMAT}" ]]; then
  echo "clang-format not found" >&2
  exit 1
fi

echo "clang: $(command -v ${CLANG})"
echo "clang++: $(command -v ${CLANGXX})"
echo "clang-tidy: ${CLANG_TIDY}"
echo "clang-format: ${CLANG_FORMAT}"
echo "run-clang-tidy: ${RUN_CLANG_TIDY:-not found}"
echo "llvm-config: ${LLVM_CONFIG:-not found}"
endgroup

# ---- PostgreSQL (source) to get PG_CONFIG (common) ----
ci::install_pg_linux_source

# ---- ccache (common) ----
ci::ccache_init

# ---- Configure to produce compile_commands.json ----
log "Configure (CMake) for compile_commands.json"
GEN="${CMAKE_GENERATOR:-$CMAKE_GENERATOR_DEFAULT}"
cmake -S . -B build \
  -G "${GEN}" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DPG_CONFIG="${PG_CONFIG}" \
  -DCMAKE_C_COMPILER="${CLANG}" \
  -DCMAKE_CXX_COMPILER="${CLANGXX}" \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
endgroup

# ---- clang-format check ----
log "clang-format check"
mapfile -t FILES < <(git ls-files '*.c' '*.cc' '*.cpp' '*.h' '*.hh' '*.hpp')
if (( ${#FILES[@]} > 0 )); then
  "${CLANG_FORMAT}" --version
  "${CLANG_FORMAT}" -n --Werror "${FILES[@]}"
else
  echo "No C/C++ files to format-check."
fi
endgroup

# ---- clang-tidy ----
log "clang-tidy"
if [[ ! -f build/compile_commands.json ]]; then
  echo "compile_commands.json not found" >&2
  exit 1
fi

# Create filtered compile_commands.json with only repo files (exclude build/ and third_party/)
REPO_ROOT="$(git rev-parse --show-toplevel)"
mkdir -p build-tidy
jq --arg root "$REPO_ROOT" '
  [ .[]
    | . as $e
    | select(
        ((if ($e.file | startswith("/")) then $e.file else ($e.directory + "/" + $e.file) end) | startswith($root + "/")) and
        ((if ($e.file | startswith("/")) then $e.file else ($e.directory + "/" + $e.file) end) | startswith($root + "/build/") | not) and
        ((if ($e.file | startswith("/")) then $e.file else ($e.directory + "/" + $e.file) end) | test("/third_party/") | not)
      )
    | $e
  ]' build/compile_commands.json > build-tidy/compile_commands.json

RC=0
if [[ -n "${RUN_CLANG_TIDY}" ]]; then
  echo "Using ${RUN_CLANG_TIDY}"
  "${RUN_CLANG_TIDY}" -p build-tidy -j 4 -clang-tidy-binary "${CLANG_TIDY}" || RC=$?
else
  # Try run-clang-tidy.py from PATH or from LLVM install
  if command -v run-clang-tidy.py &>/dev/null; then
    echo "Using run-clang-tidy.py (PATH)"
    run-clang-tidy.py -p build-tidy -j 2 -clang-tidy-binary "${CLANG_TIDY}" || RC=$?
  elif [[ -n "${LLVM_CONFIG}" ]]; then
    RCT_PY="$("${LLVM_CONFIG}" --prefix)/share/clang/run-clang-tidy.py"
    if [[ -f "${RCT_PY}" ]]; then
      echo "Using run-clang-tidy.py at ${RCT_PY}"
      python3 "${RCT_PY}" -p build-tidy -j 2 -clang-tidy-binary "${CLANG_TIDY}" || RC=$?
    else
      echo "run-clang-tidy not found (neither binary nor Python script)" >&2
      RC=1
    fi
  else
    echo "run-clang-tidy not found (neither binary nor Python script)" >&2
    RC=1
  fi
fi
endgroup

exit "${RC}"
