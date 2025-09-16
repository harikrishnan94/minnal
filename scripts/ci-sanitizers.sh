#!/usr/bin/env bash
# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
# Ubuntu sanitizers build-and-test (modularized)
set -Eeuo pipefail

SANITIZER="asan"          # asan | ubsan | tsan | msan
BUILD_TYPE="Debug"
CMAKE_GENERATOR_DEFAULT="Ninja"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/ci-sanitizers.sh [--sanitizer asan|ubsan|tsan|msan] [--build-type Debug|RelWithDebInfo]

Behavior:
- GCC 14 for asan/ubsan/tsan
- Clang + libc++ for msan
- Builds PostgreSQL from source to export PG_CONFIG
- Configures, builds, installs, tests with selected sanitizer
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
    --sanitizer) SANITIZER="$2"; shift 2 ;;
    --build-type) BUILD_TYPE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if ! ci::is_linux; then
  echo "This script is intended for Ubuntu/Linux runners." >&2
  exit 1
fi

if ! [[ "${SANITIZER}" =~ ^(asan|ubsan|tsan|msan)$ ]]; then
  echo "Invalid --sanitizer: ${SANITIZER} (expected asan|ubsan|tsan|msan)" >&2
  exit 1
fi

# Always show ccache stats at the end
trap 'ccache --show-stats || true' EXIT

# ---- Install base tools (common) ----
log "Install base tools"
ci::apt_install_base
endgroup

# ---- Compiler setup ----
if [[ "${SANITIZER}" == "msan" ]]; then
  ci::setup_clang_libcxx_linux
else
  ci::setup_gcc_14
fi

# ---- PostgreSQL setup (common) ----
# Build PostgreSQL with the same sanitizer flags as the job
SAN_FLAGS=""
case "${SANITIZER}" in
  ubsan) SAN_FLAGS="-fsanitize=undefined -fno-omit-frame-pointer" ;;
  tsan) SAN_FLAGS="-fsanitize=thread -fno-omit-frame-pointer" ;;
  # PostgreSQL build fails with MSAN enabled and pg_regress fails with ASan enabled
  # asan) SAN_FLAGS="-fsanitize=address -fno-omit-frame-pointer" ;;
  # msan) SAN_FLAGS="-fsanitize=memory -fno-omit-frame-pointer" ;;
esac

export ASAN_OPTIONS=halt_on_error=0
export UBSAN_OPTIONS=halt_on_error=0
export TSAN_OPTIONS=halt_on_error=0
ci::install_pg_linux_source "${SAN_FLAGS}" "${SAN_FLAGS}" "${SAN_FLAGS}"

# ---- ccache (common) ----
ci::ccache_init

# ---- Configure/build/install ----
log "Configure (CMake with sanitizer)"
GEN="${CMAKE_GENERATOR:-$CMAKE_GENERATOR_DEFAULT}"

EXTRA_FLAGS=()
case "${SANITIZER}" in
  asan) EXTRA_FLAGS+=(-DMINNAL_ENABLE_ENG_ASAN=ON) ;;
  ubsan) EXTRA_FLAGS+=(-DMINNAL_ENABLE_ENG_UBSAN=ON) ;;
  tsan) EXTRA_FLAGS+=(-DMINNAL_ENABLE_ENG_TSAN=ON) ;;
  msan) EXTRA_FLAGS+=(-DMINNAL_ENABLE_ENG_MSAN=ON) ;;
esac

EXTRA_CFG=()
EXTRA_CFG+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
[[ -n "${CFLAGS:-}" ]] && EXTRA_CFG+=(-DCMAKE_C_FLAGS="${CFLAGS}")
[[ -n "${CXXFLAGS:-}" ]] && EXTRA_CFG+=(-DCMAKE_CXX_FLAGS="${CXXFLAGS}")
[[ -n "${LDFLAGS:-}" ]] && EXTRA_CFG+=(-DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}")

cmake -S . -B build-san \
  -G "${GEN}" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DPG_CONFIG="${PG_CONFIG}" \
  -DCMAKE_C_COMPILER="${CC}" \
  -DCMAKE_CXX_COMPILER="${CXX}" \
  "${EXTRA_FLAGS[@]}" \
  "${EXTRA_CFG[@]}"
endgroup

log "Build (sanitizer)"
cmake --build build-san -j
endgroup

log "Install (sanitizer)"
sudo cmake --install build-san
endgroup

# ---- Test ----
unset ASAN_OPTIONS
unset UBSAN_OPTIONS
unset TSAN_OPTIONS
log "Test (sanitizer)"
set +e
if [[ "${SANITIZER}" == "msan" ]]; then
  # Need libc++ runtime path with clang
  LC_BIN="$(ci::find_llvm_config || true)"
  LIBDIR="$(ci::llvm_libcxx_runtime_dir "${LC_BIN}")"
  if [[ -n "${LIBDIR}" && -d "${LIBDIR}" ]]; then
    export LD_LIBRARY_PATH="${LIBDIR}${LD_LIBRARY_PATH+:${LD_LIBRARY_PATH}}"
    echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"
  fi
fi

ctest --test-dir build-san --output-on-failure
RC=$?
set -e
endgroup

exit "${RC}"
