# Minnal RPC

Status: Draft

This document describes the RPC layer between the Minnal Client and the Minnal Engine.

## Overview

- Cap'n Proto is used for both:
  - Interface/schema definition and message serialization
  - RPC between the Minnal Client and the Minnal Engine
- Reference: https://capnproto.org/

## Transport

- Current: Cap'n Proto RPC over standard socket transports (e.g., TCP or Unix Domain Sockets).
  - Exact defaults and endpoints are implementation details and may evolve; the protocol and schemas aim to remain stable.
- Planned: Shared-memory transport for intra-node communication in a later release.
  - This is not the primary use case and will be introduced after the main networked RPC stabilizes.

## Interface and Schemas

- All request/response shapes are defined in Cap'n Proto `.capnp` schemas.
- Versioning:
  - Backwards-compatible field additions are preferred.
  - Avoid field re-use; deprecate old fields and add new fields with new ordinals.
  - Protocol changes should be accompanied by a protocol version gate where necessary.

## Services and Method Stubs (TBD)

Note: The following are stubs/placeholders for upcoming detailed definitions. Names, shapes, and streaming semantics may change as the engine and client mature.

## Security and Auth (TBD)

- Authentication and authorization mechanisms are TBD and will be defined alongside deployment/packaging.
- Considerations include:
  - Local development on loopback
  - Production engine deployments (IPC/UDS/TCP)
  - Role-based method access (e.g., `shutdown`)

## Future Work

- Shared-memory transport for intra-node scenarios (planned; not primary use case).
- Concrete method specs, field definitions, and streaming capabilities.
- Stable error code taxonomy and status mapping.
- AuthN/Z scheme and secure defaults.
- Detailed versioning policy and migration guidelines.
