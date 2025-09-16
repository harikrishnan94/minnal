#!/usr/bin/env bash
# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
# Ubuntu coverage build-and-test (GCC + gcov/gcovr) [modularized]
set -Eeuo pipefail

BUILD_TYPE="Debug"
CMAKE_GENERATOR_DEFAULT="Ninja"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/ci-coverage.sh [--build-type Debug|RelWithDebInfo]

Behavior:
- Uses common helpers for base setup, compiler, PostgreSQL, and ccache
- GCC 14 toolchain
- Installs coverage tools (lcov, gcovr)
- Configures build-cov with coverage flags
- Build, install, test, and generate coverage.xml via gcovr
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

# ---- Install base + coverage tools ----
log "Install base tools"
ci::apt_install_base
endgroup

log "Install coverage tools (lcov, gcovr)"
sudo apt-get install -y lcov gcovr
endgroup

# ---- GCC toolchain (common helper) ----
ci::setup_gcc_14

# ---- PostgreSQL (source) to get PG_CONFIG (common helper) ----
ci::install_pg_linux_source

# ---- ccache (common helper) ----
ci::ccache_init

# ---- Configure/build/install ----
log "Configure (CMake with coverage flags)"
GEN="${CMAKE_GENERATOR:-$CMAKE_GENERATOR_DEFAULT}"
EXTRA_CFG=()
# Prepend user flags if provided
if [[ -n "${CFLAGS:-}" ]]; then EXTRA_CFG+=(-DCMAKE_C_FLAGS="${CFLAGS} --coverage"); else EXTRA_CFG+=(-DCMAKE_C_FLAGS="--coverage"); fi
if [[ -n "${CXXFLAGS:-}" ]]; then EXTRA_CFG+=(-DCMAKE_CXX_FLAGS="${CXXFLAGS} --coverage"); else EXTRA_CFG+=(-DCMAKE_CXX_FLAGS="--coverage"); fi
if [[ -n "${LDFLAGS:-}" ]]; then
  EXTRA_CFG+=(-DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS} --coverage" -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS} --coverage")
else
  EXTRA_CFG+=(-DCMAKE_EXE_LINKER_FLAGS="--coverage" -DCMAKE_SHARED_LINKER_FLAGS="--coverage")
fi
EXTRA_CFG+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)

cmake -S . -B build-cov \
  -G "${GEN}" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DPG_CONFIG="${PG_CONFIG}" \
  -DCMAKE_C_COMPILER="${CC}" \
  -DCMAKE_CXX_COMPILER="${CXX}" \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  "${EXTRA_CFG[@]}"
endgroup

log "Build (coverage)"
cmake --build build-cov -j
endgroup

log "Install (coverage)"
sudo cmake --install build-cov
endgroup

# ---- Test ----
log "Test (coverage)"
ctest --test-dir build-cov --output-on-failure
endgroup

# ---- Coverage report ----
log "Generate coverage report (gcovr)"
GCOV_EXE="$(command -v gcov-14 || command -v gcov || echo gcov)"
gcovr -r . \
  --gcov-executable "${GCOV_EXE}" \
  --exclude='build.*' \
  --exclude='.*third_party.*' \
  --xml-pretty -o coverage.xml
echo "coverage.xml generated"
endgroup

exit 0
