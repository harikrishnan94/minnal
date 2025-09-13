# CapnProto.cmake
# Centralized Cap'n Proto resolution for Minnal (system vs. fetched)
# - Provides consistent imported targets:
# CapnProto::capnp, CapnProto::kj
# (and if available)
# CapnProto::capnp-rpc, CapnProto::kj-async
# - When fetching sources, suppresses dependency install() rules so the superproject
# "install" target does not try to install Cap'n Proto globally.
#
# This module does NOT patch capnproto sources/CMake.

include_guard(GLOBAL)

# User-configurable options
if(NOT DEFINED MINNAL_USE_SYSTEM_CAPNP)
    option(MINNAL_USE_SYSTEM_CAPNP "Use system-installed Cap'n Proto via find_package" OFF)
endif()

set(CAPNP_GIT_TAG "v1.0.2" CACHE STRING "Cap'n Proto git tag to fetch")

if(MINNAL_USE_SYSTEM_CAPNP)
    # Use system-installed package
    find_package(CapnProto REQUIRED)
else()
    # Use FetchContent to build from source. We need manual Populate + add_subdirectory
    # to intercept and suppress install() rules for the dependency only.
    if(POLICY CMP0169)
        # Silence deprecation warning for manual Populate with declared details.
        cmake_policy(SET CMP0169 OLD)
    endif()

    include(FetchContent)

    # Disable tests for dependencies to speed up/avoid extra targets
    set(BUILD_TESTING OFF CACHE BOOL "Disable tests for dependencies" FORCE)

    FetchContent_Declare(capnproto
        GIT_REPOSITORY https://github.com/capnproto/capnproto.git
        GIT_TAG ${CAPNP_GIT_TAG}
        GIT_SHALLOW TRUE
    )
    FetchContent_GetProperties(capnproto)

    if(NOT capnproto_POPULATED)
        FetchContent_Populate(capnproto)

        # Suppress install() rules only while adding the capnproto subproject
        set(_prev_skip_install "${CMAKE_SKIP_INSTALL_RULES}")
        set(CMAKE_SKIP_INSTALL_RULES ON CACHE BOOL "Skip install rules for dependencies" FORCE)
        add_subdirectory(${capnproto_SOURCE_DIR}/c++ ${capnproto_BINARY_DIR}/c++ EXCLUDE_FROM_ALL)
        set(CMAKE_SKIP_INSTALL_RULES "${_prev_skip_install}" CACHE BOOL "Skip install rules for dependencies" FORCE)
    endif()

    # Provide consistent alias targets
    if(NOT TARGET CapnProto::capnp)
        add_library(CapnProto::capnp ALIAS capnp)
    endif()

    if(NOT TARGET CapnProto::kj)
        add_library(CapnProto::kj ALIAS kj)
    endif()

    if(TARGET capnp-rpc AND NOT TARGET CapnProto::capnp-rpc)
        add_library(CapnProto::capnp-rpc ALIAS capnp-rpc)
    endif()

    if(TARGET kj-async AND NOT TARGET CapnProto::kj-async)
        add_library(CapnProto::kj-async ALIAS kj-async)
    endif()
endif()

# Helper: include Cap'n Proto CMake macros (for capnp_generate_cpp) when needed.
# Safe to call in both system and fetched modes.
function(minnal_include_capnp_macros)
    if(MINNAL_USE_SYSTEM_CAPNP)
        include(CapnProtoMacros OPTIONAL)
    else()
        # Available from the fetched source tree
        include(${capnproto_SOURCE_DIR}/c++/cmake/CapnProtoMacros.cmake)
    endif()
endfunction()
