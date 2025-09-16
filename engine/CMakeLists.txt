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
    minnal_sanitizers
    CapnProto::capnp
    CapnProto::kj
)

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
