# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
# Resolve PostgreSQL installation strictly via pg_config
# Usage:
# - Provide PG_CONFIG via -D PG_CONFIG=/path/to/pg_config or set ENV{PG_CONFIG} (e.g., via VS Code .cmake.env).
#
# Exposes (cache variables):
# - PG_BINDIR          : PostgreSQL bin directory (where postgres/psql live)
# - PG_SHAREDIR        : PostgreSQL sharedir
# - PG_PKGLIBDIR       : PostgreSQL pkglibdir (C extension .so/.dylib location)
# - PG_EXTENSION_DIR   : ${PG_SHAREDIR}/extension (where .control and .sql live)
# - PG_INCLUDEDIR_SERVER
# - PG_INCLUDEDIR
# - PG_LIBDIR
# - PG_VERSION_STR
#
# Also defines imported interface target Postgres::Postgres that propagates
# include paths and compiler/linker flags reported by pg_config.
#
# Minimum supported PostgreSQL version: 15

include_guard(GLOBAL)

# Accept PG_CONFIG from cache or environment
if(NOT DEFINED PG_CONFIG AND DEFINED ENV{PG_CONFIG})
  set(PG_CONFIG "$ENV{PG_CONFIG}")
endif()

set(PG_CONFIG "${PG_CONFIG}" CACHE FILEPATH "Path to pg_config; required (e.g., -DPG_CONFIG=/usr/local/bin/pg_config or set ENV{PG_CONFIG})")

if(NOT PG_CONFIG)
  message(FATAL_ERROR "PG_CONFIG is required. Configure with -DPG_CONFIG=/path/to/pg_config or set ENV{PG_CONFIG}")
endif()

if(NOT EXISTS "${PG_CONFIG}")
  message(FATAL_ERROR "PG_CONFIG='${PG_CONFIG}' does not exist.")
endif()

# Utility to run pg_config and capture output
function(_pgcfg_out varname flag)
  execute_process(
    COMMAND "${PG_CONFIG}" "${flag}"
    OUTPUT_VARIABLE _out
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
  )
  set(${varname} "${_out}" PARENT_SCOPE)
endfunction()

# Validate minimum supported PostgreSQL version (>= 15)
function(_validate_pg_version)
  execute_process(
    COMMAND "${PG_CONFIG}" --version
    OUTPUT_VARIABLE _verstr
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
  )

  if(NOT _verstr)
    message(FATAL_ERROR "Failed to run ${PG_CONFIG} --version")
  endif()

  # Extract major version: matches 'PostgreSQL 16.4' -> 16
  string(REGEX MATCH "PostgreSQL[ \t]+([0-9]+)" _m "${_verstr}")

  if(NOT _m)
    message(FATAL_ERROR "Could not parse PostgreSQL version from: '${_verstr}'")
  endif()

  set(_maj "${CMAKE_MATCH_1}")

  if(_maj LESS 15)
    message(FATAL_ERROR "PostgreSQL ${_maj}.x found via pg_config, but 15+ is required.")
  endif()
endfunction()

message(STATUS "Minnal: using pg_config at ${PG_CONFIG}")
_validate_pg_version()

# Query directories
_pgcfg_out(PG_INCLUDEDIR_SERVER "--includedir-server")
_pgcfg_out(PG_INCLUDEDIR "--includedir")
_pgcfg_out(PG_LIBDIR "--libdir")
_pgcfg_out(PG_PKGLIBDIR "--pkglibdir")
_pgcfg_out(PG_SHAREDIR "--sharedir")
_pgcfg_out(PG_BINDIR "--bindir")
_pgcfg_out(PG_VERSION_STR "--version")

# Query compiler/linker flags (PGXS-like)
_pgcfg_out(_PG_CPPFLAGS_STR "--cppflags")
_pgcfg_out(_PG_CFLAGS_STR0 "--cflags")
_pgcfg_out(_PG_LDFLAGS_STR "--ldflags")
_pgcfg_out(_PG_LDFLAGS_SL_STR "--ldflags_sl")

# Split into lists
if(_PG_CPPFLAGS_STR)
  separate_arguments(_PG_CPPFLAGS NATIVE_COMMAND "${_PG_CPPFLAGS_STR}")
endif()

if(_PG_CFLAGS_STR0)
  separate_arguments(_PG_CFLAGS0 NATIVE_COMMAND "${_PG_CFLAGS_STR0}")
endif()

if(_PG_LDFLAGS_STR)
  separate_arguments(_PG_LDFLAGS NATIVE_COMMAND "${_PG_LDFLAGS_STR}")
endif()

if(_PG_LDFLAGS_SL_STR)
  separate_arguments(_PG_LDFLAGS_SL NATIVE_COMMAND "${_PG_LDFLAGS_SL_STR}")
endif()

# Expose cache variables for visibility
set(PG_INCLUDEDIR_SERVER "${PG_INCLUDEDIR_SERVER}" CACHE PATH "PostgreSQL server include dir.")
set(PG_INCLUDEDIR "${PG_INCLUDEDIR}" CACHE PATH "PostgreSQL include dir.")
set(PG_LIBDIR "${PG_LIBDIR}" CACHE PATH "PostgreSQL lib dir.")
set(PG_PKGLIBDIR "${PG_PKGLIBDIR}" CACHE PATH "PostgreSQL pkglib dir.")
set(PG_SHAREDIR "${PG_SHAREDIR}" CACHE PATH "PostgreSQL share dir.")
set(PG_BINDIR "${PG_BINDIR}" CACHE PATH "PostgreSQL bin dir.")
set(PG_EXTENSION_DIR "${PG_SHAREDIR}/extension" CACHE PATH "PostgreSQL extension directory (for .control and .sql)")

mark_as_advanced(PG_CONFIG)

# Locate pg_regress (regression test driver).
# Allow users to predefine PG_REGRESS; otherwise search common locations:
# - ${PG_BINDIR}
# - PGXS paths under ${PG_LIBDIR} and ${PG_PKGLIBDIR}
if(NOT DEFINED PG_REGRESS OR NOT EXISTS "${PG_REGRESS}")
  set(_PGXS_REGRESS_DIRS
    "${PG_LIBDIR}/postgresql/pgxs/src/test/regress"
    "${PG_PKGLIBDIR}/pgxs/src/test/regress"
  )
  find_program(PG_REGRESS NAMES pg_regress
    HINTS
      "${PG_BINDIR}"
      ${_PGXS_REGRESS_DIRS}
    NO_DEFAULT_PATH
  )

  # As a last resort, allow PATH search
  if(NOT PG_REGRESS)
    find_program(PG_REGRESS NAMES pg_regress)
  endif()

  if(NOT PG_REGRESS)
    message(FATAL_ERROR
      "pg_regress not found. Searched:\n"
      "  PG_BINDIR='${PG_BINDIR}'\n"
      "  ${_PGXS_REGRESS_DIRS}\n"
      "Install PostgreSQL test binaries (e.g., 'make -C src/test/regress install') "
      "or ensure pg_regress is on PATH.")
  endif()
endif()

set(PG_REGRESS "${PG_REGRESS}" CACHE FILEPATH "Path to pg_regress test runner")
mark_as_advanced(PG_REGRESS)

# Imported interface target
add_library(Postgres::Postgres INTERFACE IMPORTED)
set_target_properties(Postgres::Postgres PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${PG_INCLUDEDIR};${PG_INCLUDEDIR_SERVER}"
)

if(_PG_CPPFLAGS)
  target_compile_options(Postgres::Postgres INTERFACE ${_PG_CPPFLAGS})
endif()

if(_PG_CFLAGS0)
  target_compile_options(Postgres::Postgres INTERFACE ${_PG_CFLAGS0})
endif()

if(_PG_LDFLAGS)
  target_link_options(Postgres::Postgres INTERFACE ${_PG_LDFLAGS})
endif()

if(_PG_LDFLAGS_SL)
  target_link_options(Postgres::Postgres INTERFACE ${_PG_LDFLAGS_SL})
endif()
