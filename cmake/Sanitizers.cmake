# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)

function(minnal_enable_sanitizers)
  cmake_parse_arguments(ARGS "" "" "ASAN;TSAN;UBSAN" ${ARGN})

  # Guard: avoid mixing sanitizers that conflict
  set(enabled_count 0)

  foreach(s IN ITEMS ASAN TSAN UBSAN)
    if(ARGS_${s})
      math(EXPR enabled_count "${enabled_count}+1")
    endif()
  endforeach()

  if(enabled_count GREATER 1)
    message(FATAL_ERROR "Enable only one sanitizer at a time (ASAN/TSAN/UBSAN).")
  endif()

  if(MSVC)
    # Limited sanitizer support
    if(ARGS_TSAN OR ARGS_UBSAN OR ARGS_ASAN)
      message(WARNING "Sanitizers are limited/unsupported on MSVC—skipping flags.")
    endif()
    return()
  endif()

  set(flags "")

  if(ARGS_ASAN)
    list(APPEND flags -fsanitize=address -fno-omit-frame-pointer)
  elseif(ARGS_TSAN)
    list(APPEND flags -fsanitize=thread -fno-omit-frame-pointer)
  elseif(ARGS_UBSAN)
    list(APPEND flags -fsanitize=undefined -fno-omit-frame-pointer)
  endif()

  if(flags)
    add_library(minnal_sanitizers INTERFACE)
    target_compile_options(minnal_sanitizers INTERFACE ${flags})
    target_link_options(minnal_sanitizers INTERFACE ${flags})
  else()
    add_library(minnal_sanitizers INTERFACE)
  endif()
endfunction()