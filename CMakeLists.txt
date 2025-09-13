# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
cmake_minimum_required(VERSION 3.27)

# Project
project(minnal
  VERSION 0.1.0
  DESCRIPTION "Minnal: PostgreSQL-accelerated analytics engine (extension + engine)"
  LANGUAGES C CXX)

# Global language standard
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Options
option(MINNAL_WARNINGS_AS_ERRORS "Treat warnings as errors" ON)
option(MINNAL_ENABLE_UNITY "Enable unity builds (faster builds)" OFF)
option(MINNAL_ENABLE_IPO "Enable Interprocedural Optimization (LTO)" OFF)
option(MINNAL_ENABLE_ASAN "Enable AddressSanitizer" OFF)
option(MINNAL_ENABLE_TSAN "Enable ThreadSanitizer" OFF)
option(MINNAL_ENABLE_UBSAN "Enable UndefinedBehaviorSanitizer" OFF)

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

# Sanitizers (mutually exclusive via module guard)
minnal_enable_sanitizers(
  ASAN ${MINNAL_ENABLE_ASAN}
  TSAN ${MINNAL_ENABLE_TSAN}
  UBSAN ${MINNAL_ENABLE_UBSAN}
)

# IPO/LTO
minnal_enable_ipo(${MINNAL_ENABLE_IPO})

# Unity builds
if(MINNAL_ENABLE_UNITY)
  set(CMAKE_UNITY_BUILD ON)
endif()

# Subprojects
# Sanitizer split options
set(EXT_SANITIZERS "" CACHE STRING "Comma-separated sanitizers for extension (e.g., address,undefined).")
set(ENG_SANITIZERS "" CACHE STRING "Comma-separated sanitizers for engine (e.g., address,undefined).")

# Cap'n Proto dependency (centralized)
include(CapnProto)

add_subdirectory(extension)
add_subdirectory(engine)

# Packaging metadata (basic)
include(CPack)

# CTest integration
include(CTest)
enable_testing()

set(CPACK_PACKAGE_NAME "minnal")
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
set(CPACK_GENERATOR "TGZ;ZIP")
