# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)

function(minnal_set_project_warnings)
  cmake_parse_arguments(ARGS "" "WARNINGS_AS_ERRORS" "" ${ARGN})

  if(MSVC)
    set(WARNINGS
      /W4
      /permissive-
      /utf-8
      /Zc:__cplusplus
    )

    if(ARGS_WARNINGS_AS_ERRORS)
      list(APPEND WARNINGS /WX)
    endif()
  else()
    set(WARNINGS
      -Wall
      -Wextra
      -Wpedantic
      -Wconversion
      -Wsign-conversion
      -Wshadow
      -Wdouble-promotion
      -Wformat=2
      -Wundef
      -Wmissing-include-dirs
      -Wnon-virtual-dtor
      -Wold-style-cast
      -Woverloaded-virtual
      -Wimplicit-fallthrough
      -Wno-unknown-pragmas
    )

    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
      list(APPEND WARNINGS -Wno-unknown-warning-option)
    endif()

    if(ARGS_WARNINGS_AS_ERRORS)
      list(APPEND WARNINGS -Werror)
    endif()
  endif()

  add_library(minnal_engine_warnings INTERFACE)
  target_compile_options(minnal_engine_warnings INTERFACE ${WARNINGS})

  add_library(minnal_ext_warnings INTERFACE)
  target_compile_options(minnal_ext_warnings
    INTERFACE
    ${WARNINGS}
    -Wno-unused-parameter)
endfunction()
