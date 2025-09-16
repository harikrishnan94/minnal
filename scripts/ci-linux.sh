#!/usr/bin/env bash
# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
# Linux CI script for build & test (modularized)
set -Eeuo pipefail

# Globals / defaults
COMPILER="gcc"            # gcc | clang-libc++
BUILD_TYPE="Debug"        # Debug | RelWithDebInfo
CMAKE_GENERATOR_DEFAULT="Ninja"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/ci-linux.sh [--compiler gcc|clang-libc++] [--build-type Debug|RelWithDebInfo]

Replicates the previous composite actions:
- Setup compiler (gcc-14 or clang + libc++) and toolchain paths/flags
- Install PostgreSQL (source build; resolves latest minor for major 17)
- Configure, build, install, and test
- Setup and print ccache stats inside the script
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

if ! ci::is_linux; then
  echo "This script is intended for Linux runners." >&2
  exit 1
fi

# Always show ccache stats at the end
trap 'ccache --show-stats || true' EXIT

# Ensure sudo is available
if ! command -v sudo &>/dev/null; then
  echo "sudo not available; installing minimal prerequisites might fail." >&2
fi

log "Install base build tools"
ci::apt_install_base
endgroup

# Compiler setup via common lib
case "${COMPILER}" in
  gcc) ci::setup_gcc_14 ;;
  clang-libc++) ci::setup_clang_libcxx_linux ;;
  *)
    echo "Unsupported --compiler: ${COMPILER}" >&2
    exit 1;;
esac

# PostgreSQL setup (source install on Linux)
ci::install_pg_linux_source

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
RUNTIME_DIR=""
if [[ "${COMPILER}" == "clang-libc++" ]]; then
  LC_BIN="$(ci::find_llvm_config || true)"
  RUNTIME_DIR="$(ci::llvm_libcxx_runtime_dir "${LC_BIN}")"
fi

if [[ -n "${RUNTIME_DIR}" ]]; then
  echo "Using libc++ runtime dir: ${RUNTIME_DIR}"
  export LD_LIBRARY_PATH="${RUNTIME_DIR}${LD_LIBRARY_PATH+:${LD_LIBRARY_PATH}}"
  echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"
fi

ctest --test-dir build --output-on-failure
TEST_RC=$?
set -e
endgroup

exit "${TEST_RC}"
