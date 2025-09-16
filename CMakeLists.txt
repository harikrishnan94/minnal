# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
cmake_minimum_required(VERSION 3.27)

# Project
project(minnal
  VERSION 0.1.0
  DESCRIPTION "Minnal: PostgreSQL-accelerated analytics engine (extension + engine)"
  LANGUAGES C CXX)

# Enforce supported compiler versions early to give clear diagnostics
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  if(CMAKE_CXX_COMPILER_VERSION VERSION_LESS 14)
    message(FATAL_ERROR
      "Minnal requires GCC 14 or newer (found ${CMAKE_CXX_COMPILER_VERSION}).")
  endif()
elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  if(CMAKE_CXX_COMPILER_VERSION VERSION_LESS 20)
    message(FATAL_ERROR
      "Minnal requires Clang 20 or newer (found ${CMAKE_CXX_COMPILER_VERSION}).")
  endif()
else()
  message(FATAL_ERROR
    "Minnal requires GCC >= 14 or Clang >= 20 (detected ${CMAKE_CXX_COMPILER_ID}).")
endif()

# Global language standard
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Options
option(MINNAL_WARNINGS_AS_ERRORS "Treat warnings as errors" ON)
option(MINNAL_ENABLE_UNITY "Enable unity builds (faster builds)" OFF)
option(MINNAL_ENABLE_IPO "Enable Interprocedural Optimization (LTO)" OFF)
option(MINNAL_ENABLE_ENG_ASAN "Enable AddressSanitizer for engine" OFF)
option(MINNAL_ENABLE_ENG_TSAN "Enable ThreadSanitizer for engine" OFF)
option(MINNAL_ENABLE_ENG_UBSAN "Enable UndefinedBehaviorSanitizer for engine" OFF)
option(MINNAL_ENABLE_ENG_MSAN "Enable MemorySanitizer for engine" OFF)

# Modules
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(Warnings)
include(Sanitizers)
include(IPO)

# Apply global policies / features
enable_testing()

# Warnings
minnal_set_project_warnings(
  WARNINGS_AS_ERRORS ${MINNAL_WARNINGS_AS_ERRORS}
)

# IPO/LTO
minnal_enable_ipo(${MINNAL_ENABLE_IPO})

# Unity builds
if(MINNAL_ENABLE_UNITY)
  set(CMAKE_UNITY_BUILD ON)
endif()

# Subprojects

# Cap'n Proto dependency (centralized)
include(CapnProto)

add_subdirectory(extension)

# Enable sanitizers for engine only (tests/tools), not the Postgres extension
# The extension inherits flags from Postgres; avoid conflicting sanitizer flags.
minnal_enable_sanitizers(
  ASAN ${MINNAL_ENABLE_ENG_ASAN}
  TSAN ${MINNAL_ENABLE_ENG_TSAN}
  UBSAN ${MINNAL_ENABLE_ENG_UBSAN}
  MSAN ${MINNAL_ENABLE_ENG_MSAN}
)

add_subdirectory(engine)

# Packaging metadata (basic)
include(CPack)

# CTest integration
include(CTest)
enable_testing()

set(CPACK_PACKAGE_NAME "minnal")
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
set(CPACK_GENERATOR "TGZ;ZIP")
