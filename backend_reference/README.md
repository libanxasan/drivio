# Backend reference

This directory contains an optional Supabase reference implementation for receiving compressed telemetry chunks.

## Files

- `supabase_schema.sql`: trip and chunk metadata tables, indexes, RLS, and storage bucket
- `supabase/functions/telemetry-upload/index.ts`: authenticated idempotent upload endpoint
- `supabase/functions/telemetry-upload/deno.json`: function-local dependency map
- `telemetry_decoder.ts`: reference DTL1 and Gzip decoder

## Security behavior

The function:

1. Validates the caller with `supabase.auth.getUser()`.
2. Derives the authoritative user identifier from the access token.
3. Rejects a mismatched `X-User-Id` header.
4. Validates the compressed payload SHA-256 checksum.
5. Stores the compressed bytes in a private Storage bucket.
6. Inserts searchable chunk metadata into Postgres.
7. Treats a repeated trip and chunk identifier with the same checksum as an idempotent success.
8. Rejects a repeated identifier with a different checksum.
9. Applies the final `tripManifest` artifact to close the trip and persist summary metadata.

The reference only stores telemetry. It does not decode chunks or calculate scores.
