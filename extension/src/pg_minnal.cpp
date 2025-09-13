// Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)

extern "C" {
#include "postgres.h"

#include "fmgr.h"
#include "utils/builtins.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(minnal_version); // NOLINT

/*
 * Returns the Minnal extension version as a text datum.
 * The version is injected at compile time via the MINNAL_VERSION macro
 * from CMake (derived from PROJECT_VERSION).
 */
auto minnal_version(PG_FUNCTION_ARGS) -> Datum {
  const char *version = MINNAL_VERSION;
  PG_RETURN_TEXT_P(cstring_to_text(version));
}
}
