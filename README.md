# pg_minnal ⚡️

[![CI](https://github.com/harikrishnan94/minnal/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/harikrishnan94/minnal/actions/workflows/ci.yml)
[![Linux x64](https://img.shields.io/github/actions/workflow/status/harikrishnan94/minnal/ci.yml?branch=main&job=Build%20%26%20Test%20%28ubuntu-24.04%2C%20gcc%2C%20RelWithDebInfo%29&label=Linux%20x64&logo=linux)](https://github.com/harikrishnan94/minnal/actions/workflows/ci.yml?query=branch%3Amain+Build%20%26%20Test%20%28ubuntu-24.04%2C%20gcc%2C%20RelWithDebInfo%29)
[![Linux ARM](https://img.shields.io/github/actions/workflow/status/harikrishnan94/minnal/ci.yml?branch=main&job=Build%20%26%20Test%20%28ubuntu-24.04-arm%2C%20gcc%2C%20RelWithDebInfo%29&label=Linux%20ARM&logo=linux)](https://github.com/harikrishnan94/minnal/actions/workflows/ci.yml?query=branch%3Amain+Build%20%26%20Test%20%28ubuntu-24.04-arm%2C%20gcc%2C%20RelWithDebInfo%29)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15%2B-blue)](https://www.postgresql.org/)

`pg_minnal` is a PostgreSQL extension that adds a real-time columnar execution engine alongside the standard row-oriented storage. It accelerates analytics (OLAP) directly on top of PostgreSQL without requiring a fork, external data warehouse, or complex ETL pipelines.
Minnal means lightning in Tamil ([தமிழ்](https://en.wikipedia.org/wiki/Tamil_language)) — reflecting the speed and immediacy of analytics it enables.

---

## ✨ Features

- Dual Engine
  PostgreSQL continues to handle all OLTP writes as the single source of truth. `pg_minnal` provides an optimized in-memory columnar execution path for analytics.

- Always Fresh Queries
  Single-statement queries are consistent up to a target WAL LSN at statement start (READ COMMITTED semantics). Users may also choose "stale but instant" mode for zero-delay analytics.

- Transparent Integration
  - Works directly through PostgreSQL (FDW / Custom Scan)
  - Minimal application changes — SQL remains the same

- Efficient Change Propagation
  Changes are consumed via logical replication slots and applied to in-memory columnar segments.

- Crash Recovery
  On restart, columnar snapshots are reloaded and WAL changes replayed to ensure consistency.

- User-Friendly Setup
  Installable as a standard PostgreSQL extension, with simple configuration knobs and smart defaults.

## Transaction Isolation and Eligibility

- Supported (offloaded): READ COMMITTED with a statement-level snapshot at statement start (up to a target WAL LSN).
- Not supported (offloaded): REPEATABLE READ and SERIALIZABLE. Such statements run in PostgreSQL; Minnal will not offload them.
- Transaction blocks: Statements executed inside explicit transaction blocks (START TRANSACTION/BEGIN … COMMIT/END) are not offloaded, even if the session isolation is READ COMMITTED. Use autocommit (single-statement) for offloading eligibility.
- EXPLAIN: Non-eligible statements show standard PostgreSQL plans (no MinnalScan).

## Consistency and MVCC

Minnal achieves PostgreSQL-equivalent visibility for offloaded single-statement READ COMMITTED queries using an LSN-based MVCC model in the engine and a snapshot-to-LSN mapping in the extension.

- Engine: stores row versions with (begin_lsn, end_lsn) and evaluates visibility at a per-statement boundary B.
- Extension: computes B from the backend’s snapshot and WAL metadata, then ensures the engine has applied commits up to B before serving results.

Details: see [MVCC Design](./docs/commit_lsn_based_mvcc.md).

---

## 🏗️ Architecture Overview

```
               ┌───────────────────┐
               │   Applications    │
               │ (SQL / BI Tools)  │
               └─────────┬─────────┘
                         │
                  PostgreSQL Frontend
                         │
        ┌────────────────┴────────────────┐
        │                                 │
   OLTP Engine (Row)              OLAP Engine (pg_minnal)
   - Source of Truth               - In-memory columnar
   - Handles writes                - Vectorized execution
                                   - Async WAL propagation
                                   - Disk snapshots
```

---

## 🚀 Goals

- Real-time analytics without leaving PostgreSQL
- Simplest learning curve — if you know Postgres, you know Minnal
- Open-source first, with production-grade performance
- Designed for single-node acceleration initially, extensible for scale

---

## 🔧 Development Setup

Requirements:
- PostgreSQL 15+ with an existing installation on your system
- You MUST provide the path to `pg_config` using `-DPG_CONFIG=/path/to/pg_config`
- Modern C++ compiler (GCC 14+ / Clang 20+), supporting C++23
- CMake (3.27+)

### PostgreSQL dependency

An existing PostgreSQL installation (15+) is required. Provide `PG_CONFIG` that points to the desired installation’s `pg_config`.

Example:
- `-DPG_CONFIG=/usr/local/bin/pg_config` (Linux, Homebrew on Intel macOS)
- `-DPG_CONFIG=/opt/homebrew/opt/postgresql@16/bin/pg_config` (Homebrew on Apple Silicon)

The build validates that the version is 15+ and uses its headers/flags.

Sanitizers:
- Engine-only sanitizer toggles:
  - Enable exactly one of: `-DMINNAL_ENABLE_ENG_ASAN=ON`, `-DMINNAL_ENABLE_ENG_TSAN=ON`, `-DMINNAL_ENABLE_ENG_UBSAN=ON`, `-DMINNAL_ENABLE_ENG_MSAN=ON`
  - These apply only to engine binary, tests. The extension inherits compile flags from PostgreSQL and should not set conflicting sanitizers.

### Build

Clone and configure:

```bash
git clone https://github.com/harikrishnan94/pg_minnal.git
cd pg_minnal

# Configure: you MUST pass PG_CONFIG to point at your PostgreSQL installation
cmake -S . -B build -DPG_CONFIG=/path/to/pg_config -DCMAKE_BUILD_TYPE=RelWithDebInfo

# Optional: enable sanitizers per-target
cmake -S . -B build \
  -DPG_CONFIG=/path/to/pg_config \
  -DMINNAL_ENABLE_ENG_ASAN=ON \
  -DCMAKE_BUILD_TYPE=Debug
```

Build:

```bash
cmake --build build -j
```

### Install Extension

This installs:
- The engine binary to `bin/`
- The extension module to the target PostgreSQL’s `pkglibdir`

```bash
cmake --install build
# Then in Postgres:
psql -d yourdb -c "CREATE EXTENSION pg_minnal;"
```

---

## 📚 Roadmap

- [ ] Columnar execution engine (scan, filter, projection)
- [ ] Query routing (Custom Scan + FDW)
- [ ] Benchmarking against real workloads
- [ ] WAL → columnar propagation
- [ ] Disk snapshotting and crash recovery
- [ ] Advanced memory management and limits

---

## 🤝 Contributing

Contributions are welcome!
Please open issues, share feedback, and send pull requests.

---

## 📜 License

This project is licensed under the [MIT License](LICENSE) — the most permissive open-source license.
