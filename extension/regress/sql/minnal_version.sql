-- Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
-- Verify minnal_version() returns the CMake project version
CREATE EXTENSION minnal;

SELECT minnal_version() = '0.1.0' AS ok;
