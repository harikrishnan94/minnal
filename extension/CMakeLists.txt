# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
# Minnal PostgreSQL extension packaging
# Installs control and SQL into PostgreSQL's share/extension.
# Requires an external PostgreSQL (15+) provided via -DPG_CONFIG; links against Postgres::Postgres.

# PostgreSQL resolution (requires PG_CONFIG)
include(../cmake/Postgres.cmake)

set(EXT_NAME "minnal")

# Build the extension as a MODULE (dlopen-able plugin). Keep sources under src/.
add_library(${EXT_NAME} MODULE
  src/pg_minnal.cpp
)

# Ensure the resulting filename matches PostgreSQL's platform DLSUFFIX:
# - no 'lib' prefix
# - on macOS use '.dylib', otherwise '.so'
if(APPLE)
  set(_ext_suffix ".dylib")
else()
  set(_ext_suffix ".so")
endif()

set_target_properties(${EXT_NAME} PROPERTIES
  OUTPUT_NAME "${EXT_NAME}"
  PREFIX ""
  SUFFIX "${_ext_suffix}"
  POSITION_INDEPENDENT_CODE ON
)

# Link to centralized Postgres target (propagates include/link flags when available)
target_link_libraries(${EXT_NAME}
  PRIVATE
    Postgres::Postgres
    minnal_ext_warnings
    CapnProto::capnp
    CapnProto::kj
)

# On macOS, allow unresolved PostgreSQL backend symbols to be resolved at load time
# by the loader (postgres). This mirrors PGXS behavior and fixes link errors like
# 'Undefined symbols: _cstring_to_text'.
if(APPLE)
  target_link_options(${EXT_NAME} PRIVATE "LINKER:-undefined,dynamic_lookup")
endif()

# Inject version macro from CMake project version for use in C++ code
# Expands to a C string literal e.g., "0.1.0"
target_compile_definitions(${EXT_NAME}
  PRIVATE MINNAL_VERSION=\"${PROJECT_VERSION}\"
)

# Install the module into PostgreSQL's pkglibdir (provided/derived by Postgres.cmake)
if(NOT DEFINED PG_PKGLIBDIR OR NOT DEFINED PG_SHAREDIR)
  message(FATAL_ERROR "PG_PKGLIBDIR/PG_SHAREDIR were not defined. Ensure cmake/Postgres.cmake is included at the top level before add_subdirectory(extension).")
endif()

install(TARGETS ${EXT_NAME}
  LIBRARY DESTINATION "${PG_PKGLIBDIR}"
)

# Install control and SQL files into sharedir/extension
file(GLOB EXT_SQL_FILES
  "${CMAKE_CURRENT_SOURCE_DIR}/${EXT_NAME}--*.sql"
  "${CMAKE_CURRENT_SOURCE_DIR}/${EXT_NAME}--*--*.sql"
)

install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/${EXT_NAME}.control"
    DESTINATION "${PG_SHAREDIR}/extension")

install(FILES ${EXT_SQL_FILES}
    DESTINATION "${PG_SHAREDIR}/extension")

# Local extension install helper to avoid full 'install' (which may try writing to system paths).
# Copies the built module and SQL/control files into the PostgreSQL directories resolved by pg_config.
add_custom_target(ext_install
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${PG_PKGLIBDIR}"
  COMMAND "${CMAKE_COMMAND}" -E copy "$<TARGET_FILE:${EXT_NAME}>" "${PG_PKGLIBDIR}/"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${PG_SHAREDIR}/extension"
  COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_CURRENT_SOURCE_DIR}/${EXT_NAME}.control" "${PG_SHAREDIR}/extension/"
  COMMAND "${CMAKE_COMMAND}" -E copy ${EXT_SQL_FILES} "${PG_SHAREDIR}/extension/"
  DEPENDS ${EXT_NAME}
  COMMENT "Installing ${EXT_NAME} extension files to PostgreSQL directories (PG_PKGLIBDIR/PG_SHAREDIR)"
)

# ------------------------------------------------------------------------------
# Regression testing (pg_regress)
# Requires PostgreSQL binaries via PG_CONFIG (provided by cmake/Postgres.cmake).
# Adds:
# - custom target: pg_regress
# - ctest entry  : pg_regress
# ------------------------------------------------------------------------------

# PG_REGRESS is resolved centrally by cmake/Postgres.cmake.

# Source and output dirs for regression
set(REGRESS_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/regress")
set(REGRESS_OUT_DIR "${CMAKE_BINARY_DIR}/regress")
file(MAKE_DIRECTORY "${REGRESS_OUT_DIR}")

# Schedule file (to be created under extension/regress)
set(REGRESS_SCHEDULE "${REGRESS_SRC_DIR}/test_schedule")

# Custom target to run pg_regress with a self-contained temporary instance
add_custom_target(pg_regress
  COMMAND "${PG_REGRESS}"
  --bindir "${PG_BINDIR}"
  --inputdir "${REGRESS_SRC_DIR}"
  --outputdir "${REGRESS_OUT_DIR}"
  --temp-instance "${CMAKE_BINARY_DIR}/pg_tmp"
  --schedule "${REGRESS_SCHEDULE}"
  --create-role "minnal_regress"
  --no-locale
  WORKING_DIRECTORY "${REGRESS_SRC_DIR}"
  USES_TERMINAL
)

# Ensure the extension is built and extension files are copied before running tests
add_dependencies(pg_regress ext_install)

add_test(
  NAME pg_regress
  COMMAND "${PG_REGRESS}"
  --bindir "${PG_BINDIR}"
  --inputdir "${REGRESS_SRC_DIR}"
  --outputdir "${REGRESS_OUT_DIR}"
  --temp-instance "${CMAKE_BINARY_DIR}/pg_tmp"
  --schedule "${REGRESS_SCHEDULE}"
  --create-role "minnal_regress"
  --no-locale
)
set_tests_properties(pg_regress PROPERTIES
  WORKING_DIRECTORY "${REGRESS_SRC_DIR}"
  LABELS "pg_regress"
)
