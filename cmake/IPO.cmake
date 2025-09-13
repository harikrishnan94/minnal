# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)

include(CheckIPOSupported)

function(minnal_enable_ipo enable)
  if(NOT enable)
    return()
  endif()

  check_ipo_supported(RESULT ipo_supported OUTPUT ipo_msg)

  if(ipo_supported)
    set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ON)
  else()
    message(WARNING "IPO/LTO not supported: ${ipo_msg}")
  endif()
endfunction()