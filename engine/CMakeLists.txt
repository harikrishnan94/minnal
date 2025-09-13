# Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)

# Engine service/binary
add_executable(minnal_engine
  src/main.cpp
)

target_include_directories(minnal_engine
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(minnal_engine
  PRIVATE
    minnal_engine_warnings
    CapnProto::capnp
    CapnProto::kj
)

# Apply engine-specific sanitizer flags if provided via ENG_SANITIZERS (comma-separated list)
if(DEFINED ENG_SANITIZERS AND NOT ENG_SANITIZERS STREQUAL "")
  string(REPLACE "," ";" _eng_san_list "${ENG_SANITIZERS}")
  string(JOIN "," _eng_san_join ${_eng_san_list})
  set(_eng_san_flag "-fsanitize=${_eng_san_join}")
  target_compile_options(minnal_engine PRIVATE ${_eng_san_flag} -fno-omit-frame-pointer)
  target_link_options(minnal_engine PRIVATE ${_eng_san_flag})
endif()

set_target_properties(minnal_engine PROPERTIES
  OUTPUT_NAME "minnal-engine"
)

if(DEFINED PG_BINDIR AND PG_BINDIR)
  # Install engine binary into PostgreSQL's bin dir resolved via pg_config
  install(TARGETS minnal_engine
    RUNTIME DESTINATION "${PG_BINDIR}"
  )
else()
  # Fallback to local 'bin' when PG_BINDIR is not available
  install(TARGETS minnal_engine
    RUNTIME DESTINATION bin
  )
endif()
