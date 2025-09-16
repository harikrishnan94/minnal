#!/usr/bin/env bash
# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
# Common helpers for CI scripts (Linux/macOS)
# This file is sourced by scripts in ../
# Do not set -e here; leave control to the calling script.

# ------------- OS helpers -------------
ci::is_linux() {
  [[ "${RUNNER_OS:-$(uname)}" == "Linux" ]]
}

ci::is_macos() {
  [[ "${RUNNER_OS:-$(uname)}" == "macOS" || "$OSTYPE" == darwin* ]]
}

ci::nproc() {
  if command -v nproc &>/dev/null; then
    nproc
  elif ci::is_macos && command -v sysctl &>/dev/null; then
    sysctl -n hw.ncpu
  else
    getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2
  fi
}

# ------------- Logging -------------
ci::log() { echo "::group::${1}"; }
ci::endgroup() { echo "::endgroup::"; }

# ------------- LLVM helpers -------------
ci::find_llvm_config() {
  if command -v llvm-config &>/dev/null; then
    echo "llvm-config"; return 0
  fi
  for v in 20 19 18 17 16 15; do
    if command -v "llvm-config-${v}" &>/dev/null; then
      echo "llvm-config-${v}"
      return 0
    fi
  done
  echo ""
  return 1
}

# Returns the LLVM runtime library dir suitable for adding to LD/DYLD_LIBRARY_PATH
# Prefers "<libdir>/c++" if it exists, else "<libdir>"
ci::llvm_libcxx_runtime_dir() {
  local LC_BIN="${1:-$(ci::find_llvm_config)}"
  local LIBDIR=""
  if [[ -n "${LC_BIN}" ]]; then
    LIBDIR="$("${LC_BIN}" --libdir 2>/dev/null || true)"
  fi
  if [[ -z "${LIBDIR}" ]]; then
    # Best-effort: try to derive from clang++
    local CXX_BIN
    CXX_BIN="$(command -v clang++ || true)"
    if [[ -n "${CXX_BIN}" ]]; then
      local BINDIR; BINDIR="$(dirname "${CXX_BIN}")"
      local PREFIX; PREFIX="$(dirname "${BINDIR}")"
      LIBDIR="${PREFIX}/lib"
    fi
  fi
  if [[ -n "${LIBDIR}" && -d "${LIBDIR}/c++" ]]; then
    echo "${LIBDIR}/c++"
    return 0
  fi
  echo "${LIBDIR}"
}

# ------------- Package helpers -------------
ci::apt_install_base() {
  # Base tools used across scripts
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    ninja-build ccache jq cmake curl ca-certificates tar xz-utils pkg-config python3
}

ci::brew_cmd() {
  # Run brew with problematic env cleared (macOS)
  env -u DYLD_LIBRARY_PATH -u LD_LIBRARY_PATH -u LIBRARY_PATH -u CPATH -u CXXFLAGS -u LDFLAGS brew "$@"
}

# ------------- Compiler setup -------------
ci::setup_gcc_14() {
  ci::log "Install and select GCC toolchain"
  sudo apt-get update
  sudo apt-get install -y gcc-14 g++-14 || {
    echo "Falling back to default gcc/g++ (gcc-14 unavailable)" >&2
    sudo apt-get install -y gcc g++
  }
  if command -v gcc-14 &>/dev/null; then
    export CC="gcc-14"
    export CXX="g++-14"
  else
    export CC="gcc"
    export CXX="g++"
  fi
  echo "CC=${CC}"
  echo "CXX=${CXX}"
  ci::endgroup
}

# Setup Clang + libc++ on Linux: installs toolchain and exports CC/CXX and flags
# Adds:
# - CXXFLAGS += -stdlib=libc++ [-isystem <include/c++/v1>]
# - LDFLAGS  += -stdlib=libc++ [-L<libdir> -Wl,-rpath,<libdir>] -lc++ -lc++abi
# - CPATH/LIBRARY_PATH/LD_LIBRARY_PATH when lib/include dirs found
ci::setup_clang_libcxx_linux() {
  ci::log "Install and select Clang + libc++ toolchain (Linux)"
  sudo apt-get update
  sudo apt-get install -y \
    clang-20 lld-20 llvm-20-dev llvm-20-tools libc++-20-dev libc++abi-20-dev || true
  sudo apt-get install -y \
    clang lld llvm-dev llvm-tools libc++-dev libc++abi-dev || true

  local CLANG_BIN="clang"
  if command -v clang-20 &>/dev/null; then
    CLANG_BIN="clang-20"
  elif command -v clang-19 &>/dev/null; then
    CLANG_BIN="clang-19"
  elif command -v clang-18 &>/dev/null; then
    CLANG_BIN="clang-18"
  fi

  export CC="${CLANG_BIN}"
  export CXX="${CLANG_BIN/clang/clang++}"

  local LC_BIN; LC_BIN="$(ci::find_llvm_config || true)"
  local PREFIX="" LIBDIR=""
  if [[ -n "${LC_BIN}" ]]; then
    PREFIX="$("${LC_BIN}" --prefix 2>/dev/null || true)"
    LIBDIR="$("${LC_BIN}" --libdir 2>/dev/null || true)"
  else
    if command -v "${CXX}" &>/dev/null; then
      local BINDIR; BINDIR="$(dirname "$(command -v "${CXX}")")"
      PREFIX="$(dirname "${BINDIR}")"
      LIBDIR="${PREFIX}/lib"
    fi
  fi

  local LIBCXX_INCLUDE="${PREFIX:+${PREFIX}/include/c++/v1}"
  if [[ -z "${LIBCXX_INCLUDE}" || ! -d "${LIBCXX_INCLUDE}" ]]; then
    local RES_DIR="$("${CXX}" --print-resource-dir 2>/dev/null || true)"
    if [[ -n "${RES_DIR}" && -d "${RES_DIR}/include/c++/v1" ]]; then
      LIBCXX_INCLUDE="${RES_DIR}/include/c++/v1"
    else
      LIBCXX_INCLUDE=""
    fi
  fi

  local NEW_CXXFLAGS="${CXXFLAGS:-}"
  NEW_CXXFLAGS+=" -stdlib=libc++"
  if [[ -n "${LIBCXX_INCLUDE}" ]]; then
    NEW_CXXFLAGS+=" -isystem ${LIBCXX_INCLUDE}"
  fi
  export CXXFLAGS="${NEW_CXXFLAGS# }"

  local NEW_LDFLAGS="${LDFLAGS:-}"
  NEW_LDFLAGS+=" -stdlib=libc++"
  if [[ -n "${LIBDIR}" && -d "${LIBDIR}" ]]; then
    NEW_LDFLAGS+=" -L${LIBDIR} -Wl,-rpath,${LIBDIR}"
  fi
  NEW_LDFLAGS+=" -lc++ -lc++abi"
  export LDFLAGS="${NEW_LDFLAGS# }"

  if [[ -n "${LIBCXX_INCLUDE}" ]]; then
    export CPATH="${LIBCXX_INCLUDE}${CPATH+:${CPATH}}"
  fi
  if [[ -n "${LIBDIR}" && -d "${LIBDIR}" ]]; then
    export LIBRARY_PATH="${LIBDIR}${LIBRARY_PATH+:${LIBRARY_PATH}}"
    export LD_LIBRARY_PATH="${LIBDIR}${LD_LIBRARY_PATH+:${LD_LIBRARY_PATH}}"
  fi
  echo "CC=${CC}"
  echo "CXX=${CXX}"
  ci::endgroup
}

# Setup GCC 14 on macOS via Homebrew
ci::setup_gcc_14_macos() {
  ci::log "Install and select GCC 14 toolchain (macOS)"
  ci::brew_cmd update
  ci::brew_cmd install gcc@14 ninja ccache jq cmake || true

  # Make ccache's compiler wrappers available
  local CCACHE_LIBEXEC; CCACHE_LIBEXEC="$(ci::brew_cmd --prefix ccache)/libexec"
  export PATH="${CCACHE_LIBEXEC}:${PATH}"

  export CC="gcc-14"
  export CXX="g++-14"
  echo "CC=${CC}"
  echo "CXX=${CXX}"
  ci::endgroup
}

# ------------- PostgreSQL install -------------
ci::install_pg_linux_source() {
  ci::log "Install PostgreSQL (source) and set PG_CONFIG"
  local PG_MAJOR="${PG_MAJOR:-17}"
  local PG_VERSION="${PG_VERSION:-}"
  local BASE_URL="https://ftp.postgresql.org/pub/source"
  local EXTRA_CFLAGS="${1:-}"
  local EXTRA_CXXFLAGS="${2:-}"
  local EXTRA_LDFLAGS="${3:-}"

  if [[ -z "${PG_VERSION}" ]]; then
    echo "Resolving latest PostgreSQL ${PG_MAJOR}.x"
    set +o pipefail
    local LATEST_DIR
    LATEST_DIR=$(curl -fsSL "${BASE_URL}/" \
      | grep -Eo "v${PG_MAJOR}\.[0-9]+(\.[0-9]+)?/" \
      | sed -E 's#/##; s/^v//' \
      | sort -V | tail -n 1 || true)
    if [[ -n "${LATEST_DIR}" ]]; then
      PG_VERSION="${LATEST_DIR}"
    fi
    if [[ -z "${PG_VERSION}" ]]; then
      local CANDIDATES
      CANDIDATES=$(curl -fsSL "${BASE_URL}/" \
        | grep -Eo "postgresql-${PG_MAJOR}\.[0-9]+(\.[0-9]+)?\.tar\.(gz|bz2)" \
        | grep -vE 'beta|rc' || true)
      if [[ -n "${CANDIDATES}" ]]; then
        PG_VERSION=$(echo "${CANDIDATES}" \
          | sed -E 's/postgresql-//; s/\.tar\.(gz|bz2)//' \
          | sort -V | uniq | tail -n 1)
      fi
    fi
    set -o pipefail
  fi

  if [[ -z "${PG_VERSION}" ]]; then
    echo "Failed to resolve PostgreSQL version for major ${PG_MAJOR}" >&2
    return 1
  fi

  echo "Building PostgreSQL ${PG_VERSION} from source"
  local WORK_DIR; WORK_DIR="$(mktemp -d)"
  local TARBALL="" TARFLAGS=""
  if curl -fsI "${BASE_URL}/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.gz" >/dev/null 2>&1; then
    curl -fsSL "${BASE_URL}/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.gz" -o "${WORK_DIR}/postgresql-${PG_VERSION}.tar.gz"
    TARBALL="${WORK_DIR}/postgresql-${PG_VERSION}.tar.gz"; TARFLAGS="-xzf"
  elif curl -fsI "${BASE_URL}/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2" >/dev/null 2>&1; then
    curl -fsSL "${BASE_URL}/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2" -o "${WORK_DIR}/postgresql-${PG_VERSION}.tar.bz2"
    TARBALL="${WORK_DIR}/postgresql-${PG_VERSION}.tar.bz2"; TARFLAGS="-xjf"
  else
    echo "Could not download PostgreSQL ${PG_VERSION}" >&2
    return 1
  fi

  tar ${TARFLAGS} "${TARBALL}" -C "${WORK_DIR}"
  local SRC_DIR="${WORK_DIR}/postgresql-${PG_VERSION}"
  local PREFIX_DIR="${WORK_DIR}/install"
  mkdir -p "${PREFIX_DIR}"

  pushd "${SRC_DIR}" >/dev/null
  export CC="${CC:-cc}"
  export CXX="${CXX:-c++}"
  local EFFECTIVE_CFLAGS="${CFLAGS:-}"
  local EFFECTIVE_CXXFLAGS="${CXXFLAGS:-}"
  local EFFECTIVE_LDFLAGS="${LDFLAGS:-}"
  if [[ -n "${EXTRA_CFLAGS}" ]]; then EFFECTIVE_CFLAGS="${EFFECTIVE_CFLAGS:+${EFFECTIVE_CFLAGS} }${EXTRA_CFLAGS}"; fi
  if [[ -n "${EXTRA_CXXFLAGS}" ]]; then EFFECTIVE_CXXFLAGS="${EFFECTIVE_CXXFLAGS:+${EFFECTIVE_CXXFLAGS} }${EXTRA_CXXFLAGS}"; fi
  if [[ -n "${EXTRA_LDFLAGS}" ]]; then EFFECTIVE_LDFLAGS="${EFFECTIVE_LDFLAGS:+${EFFECTIVE_LDFLAGS} }${EXTRA_LDFLAGS}"; fi
  [[ -n "${EFFECTIVE_CFLAGS}" ]] && export CFLAGS="${EFFECTIVE_CFLAGS}"
  [[ -n "${EFFECTIVE_CXXFLAGS}" ]] && export CXXFLAGS="${EFFECTIVE_CXXFLAGS}"
  [[ -n "${EFFECTIVE_LDFLAGS}" ]] && export LDFLAGS="${EFFECTIVE_LDFLAGS}"

  ./configure --prefix="${PREFIX_DIR}" --without-readline --without-zlib
  local JOBS; JOBS="$(ci::nproc)"
  make -j "${JOBS}"
  make install
  popd >/dev/null

  export PG_CONFIG="${PREFIX_DIR}/bin/pg_config"
  echo "PG_CONFIG=${PG_CONFIG}"
  ci::endgroup
}

# Build and install PostgreSQL from source on macOS (exports PG_CONFIG)
ci::install_pg_macos_source() {
  ci::log "Install PostgreSQL (source, macOS) and set PG_CONFIG"
  local PG_MAJOR="${PG_MAJOR:-17}"
  local PG_VERSION="${PG_VERSION:-}"
  local BASE_URL="https://ftp.postgresql.org/pub/source"

  # Ensure required build tools for PostgreSQL are available
  ci::brew_cmd update
  ci::brew_cmd install bison flex || true
  # Prefer Homebrew's newer bison over the system one
  if ci::brew_cmd list bison &>/dev/null; then
    export PATH="$(ci::brew_cmd --prefix bison)/bin:${PATH}"
  fi

  if [[ -z "${PG_VERSION}" ]]; then
    echo "Resolving latest PostgreSQL ${PG_MAJOR}.x"
    # Avoid aborting due to pipefail when there are no matches
    set +o pipefail
    local LATEST_DIR
    LATEST_DIR=$(curl -fsSL "${BASE_URL}/" \
      | grep -Eo "v${PG_MAJOR}\\.[0-9]+(\\.[0-9]+)?/" \
      | sed -E 's#/##; s/^v//' \
      | sort -V \
      | tail -n 1 || true)
    if [[ -n "${LATEST_DIR}" ]]; then
      PG_VERSION="${LATEST_DIR}"
    fi

    # Fallback: tarball filenames in top-level index
    if [[ -z "${PG_VERSION}" ]]; then
      local CANDIDATES
      CANDIDATES=$(curl -fsSL "${BASE_URL}/" \
        | grep -Eo "postgresql-${PG_MAJOR}\\.[0-9]+(\\.[0-9]+)?\\.tar\\.(gz|bz2)" \
        | grep -vE 'beta|rc' || true)
      if [[ -n "${CANDIDATES}" ]]; then
        PG_VERSION=$(echo "${CANDIDATES}" \
          | sed -E 's/postgresql-//; s/\\.tar\\.(gz|bz2)//' \
          | sort -V \
          | uniq \
          | tail -n 1)
      fi
    fi
    set -o pipefail
  fi

  if [[ -z "${PG_VERSION}" ]]; then
    echo "Failed to determine PostgreSQL version for major ${PG_MAJOR}" >&2
    return 1
  fi

  echo "Building PostgreSQL ${PG_VERSION} from source (macOS)"
  local WORK_DIR; WORK_DIR="$(mktemp -d)"
  local TAR_GZ_URL="${BASE_URL}/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.gz"
  local TAR_BZ2_URL="${BASE_URL}/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2"
  local TARBALL="" TARFLAGS=""

  if curl -fsI "${TAR_GZ_URL}" >/dev/null 2>&1; then
    curl -fsSL "${TAR_GZ_URL}" -o "${WORK_DIR}/postgresql-${PG_VERSION}.tar.gz"
    TARBALL="${WORK_DIR}/postgresql-${PG_VERSION}.tar.gz"
    TARFLAGS="-xzf"
  elif curl -fsI "${TAR_BZ2_URL}" >/dev/null 2>&1; then
    curl -fsSL "${TAR_BZ2_URL}" -o "${WORK_DIR}/postgresql-${PG_VERSION}.tar.bz2"
    TARBALL="${WORK_DIR}/postgresql-${PG_VERSION}.tar.bz2"
    TARFLAGS="-xjf"
  else
    echo "Could not find a tarball (.tar.gz or .tar.bz2) for PostgreSQL ${PG_VERSION}" >&2
    return 1
  fi

  tar ${TARFLAGS} "${TARBALL}" -C "${WORK_DIR}"
  local SRC_DIR="${WORK_DIR}/postgresql-${PG_VERSION}"
  local PREFIX_DIR="${WORK_DIR}/install"
  mkdir -p "${PREFIX_DIR}"

  pushd "${SRC_DIR}" >/dev/null

  export CC="${CC:-cc}"
  export CXX="${CXX:-c++}"
  [[ -n "${CFLAGS:-}" ]] && export CFLAGS="${CFLAGS}"
  [[ -n "${CXXFLAGS:-}" ]] && export CXXFLAGS="${CXXFLAGS}"
  [[ -n "${LDFLAGS:-}" ]] && export LDFLAGS="${LDFLAGS}"

  # Keep consistent with Linux: avoid optional deps to speed CI
  ./configure --prefix="${PREFIX_DIR}" --without-readline --without-zlib --without-icu

  local JOBS; JOBS="$(ci::nproc)"
  make -j "${JOBS}"
  make install
  popd >/dev/null

  export PG_CONFIG="${PREFIX_DIR}/bin/pg_config"
  echo "PG_CONFIG=${PG_CONFIG}"
  ci::endgroup
}

ci::install_pg_macos_brew() {
  ci::log "Install PostgreSQL via Homebrew (macOS)"
  ci::brew_cmd update
  ci::brew_cmd install postgresql@17 || true
  if ci::brew_cmd list postgresql@17 &>/dev/null; then
    export PG_CONFIG="$(ci::brew_cmd --prefix postgresql@17)/bin/pg_config"
  elif ci::brew_cmd list postgresql@16 &>/dev/null; then
    export PG_CONFIG="$(ci::brew_cmd --prefix postgresql@16)/bin/pg_config"
  else
    echo "Homebrew postgresql@17/@16 not installed" >&2
    return 1
  fi
  echo "PG_CONFIG=${PG_CONFIG}"
  ci::endgroup
}

# ------------- ccache -------------
ci::ccache_init() {
  ci::log "Configure ccache"
  ccache --version || true
  ccache --max-size=500M || true
  ccache --zero-stats || true
  ci::endgroup
}
