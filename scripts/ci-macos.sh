#!/usr/bin/env bash
# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
# macOS CI script for build & test (modularized)
set -Eeuo pipefail

# Defaults
COMPILER="gcc"   # Only supported option for macOS in our matrix
BUILD_TYPE="Debug"        # Debug | RelWithDebInfo
CMAKE_GENERATOR_DEFAULT="Ninja"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/ci-macos.sh [--compiler gcc] [--build-type Debug|RelWithDebInfo]

Replicates previous composite actions on macOS with shared helpers:
- Installs GCC 14 via Homebrew (ci::setup_gcc_14_macos)
- Builds PostgreSQL 17 from source and exports PG_CONFIG (ci::install_pg_macos_source)
- Configures, builds, installs, and tests
- ccache setup is handled inside the script (ci::ccache_init)
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
    --compiler)
      COMPILER="$2"; shift 2;;
    --build-type)
      BUILD_TYPE="$2"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown arg: $1" >&2
      usage; exit 1;;
  esac
done

if ! ci::is_macos; then
  echo "This script is intended for macOS runners." >&2
  exit 1
fi

if [[ "${COMPILER}" != "gcc" ]]; then
  echo "On macOS, only --compiler gcc is supported." >&2
  exit 1
fi

# Always show ccache stats at the end
trap 'ccache --show-stats || true' EXIT

# Setup compiler and tools (Homebrew), then PostgreSQL
ci::setup_gcc_14_macos
ci::install_pg_macos_source

# ccache setup
ci::ccache_init

# Configure/build/install
log "Configure (CMake)"
GEN="${CMAKE_GENERATOR:-$CMAKE_GENERATOR_DEFAULT}"
EXTRA_CFG=()
EXTRA_CFG+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)

[[ -n "${CFLAGS:-}" ]] && EXTRA_CFG+=(-DCMAKE_C_FLAGS="${CFLAGS}")
[[ -n "${CXXFLAGS:-}" ]] && EXTRA_CFG+=(-DCMAKE_CXX_FLAGS="${CXXFLAGS}")
[[ -n "${LDFLAGS:-}" ]] && EXTRA_CFG+=(-DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}")

cmake -S . -B build \
  -G "${GEN}" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DPG_CONFIG="${PG_CONFIG}" \
  -DCMAKE_C_COMPILER="${CC}" \
  -DCMAKE_CXX_COMPILER="${CXX}" \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  "${EXTRA_CFG[@]}"
endgroup

log "Build"
cmake --build build -j
endgroup

log "Install"
sudo cmake --install build
endgroup

# Test
log "Test"
set +e
ctest --test-dir build --output-on-failure
TEST_RC=$?
set -e
endgroup

exit "${TEST_RC}"
