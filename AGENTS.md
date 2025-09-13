# Agents Guide for Minnal

For Cline and OpenAI Codex. Use this file as the single source for generation and reviews.

## 1. Project idea and architecture

* Goal: PostgreSQL extension that adds a secondary, real‑time columnar engine for analytics; PostgreSQL remains the single source of truth for OLTP.
* Change capture: Logical decoding / replication slots feed an ingest pipeline that converts row changes to columnar segments.
* Execution and storage: Vectorized operators run over in‑memory columnar data; periodic compressed snapshots enable fast restart.
* Query routing: Local offload via Custom Scan and shared‑memory IPC; optional remote path via FDW/RPC.
* Recovery and freshness: Load the latest snapshot and replay WAL from the last persisted LSN. Default is up‑to‑LSN freshness; bounded staleness is configurable.
* Separation of concerns: `extension/` contains PostgreSQL glue code; `engine/` is standalone with no PostgreSQL dependencies.

## 2. Code generation and PR review rules

* Language: C++23.
* Formatting: clang‑format (use the repo config). PRs must be formatted.
* Comments: doxygen style
* Static analysis: clang‑tidy (modernize, bugprone, performance, readability, selected cppcoreguidelines). No new warnings.
* Standard I/O and formatting: prefer `std::format` and `std::print`.
* Guidelines Support Library: use ms::gsl where it improves clarity and safety (e.g., span, not\_null, narrow).
* Recoverable errors: use `std::expected<T, Status>`.
* PostgreSQL boundary:
  * Do not let exceptions escape functions that are directly invoked by PostgreSQL. Wrap entry points with try/catch and convert failures to `ereport`.
  * From non‑PostgreSQL threads, do not call PostgreSQL APIs.
* Engine isolation: code under `src/engine/` is a standalone C++ application and must not depend on PostgreSQL headers or symbols.
* Build and dependencies: build system is CMake only. Use FetchContent only for dependency retrieval. Keep external packages minimal and pinned.
* Commits: subject line length ≤ 72 characters; include rationale and testing notes in the body.
* File headers (required): every source, header, script, and SQL file must start with the copyright line below (first line of the file):  
  * Canonical line:  
    ```
    Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
    ```
  * Language-appropriate templates (pick the one that matches the file):

    * C/C++ (`.c`, `.cc`, `.cpp`, `.h`, `.hpp`):
      ```cpp
      // Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
      ```

    * CMake / Shell / Config (`CMakeLists.txt`, `.cmake`, `.sh`, `.cfg`, `.ini`, `.toml`, `.yaml`, `.yml`):
      ```cmake
      # Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
      ```

    * Python (`.py`):
      ```python
      # Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
      ```

    * SQL (`.sql`):
      ```sql
      -- Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
      ```
* PR checklist:
  * Builds and tests pass on the active preset.
  * clang‑format and clang‑tidy are clean.
  * PostgreSQL boundary rules are respected; engine remains standalone.
  * Any new dependency is added via FetchContent with a pinned tag or commit and documented.

## 3. Build policy

* Use CMake only. Use FetchContent only for third‑party code.
* Always use the active configure/build preset defined in `CMakePresets.json`. Do not create ad‑hoc build directories.
* Configure, build, and test must all use the same active preset and its build directory.

## 4. Repository layout (brief)

* src/extension — PostgreSQL extension code.
* src/engine — standalone engine (no PostgreSQL deps).
* cmake, CMakeLists.txt, configuration files.

End.
