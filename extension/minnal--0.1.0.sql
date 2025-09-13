-- Copyright (c) Harikrishnan Prabakaran (harikrishnanprabakaran@gmail.com)
-- Minnal extension install script

-- Defines: minnal_version() -> text
-- UDF to return the extension version (from CMake's PROJECT_VERSION via compile definition)
CREATE FUNCTION minnal_version() RETURNS text AS 'MODULE_PATHNAME',
'minnal_version' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

COMMENT ON FUNCTION minnal_version() IS 'Return the Minnal extension version';
