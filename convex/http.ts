import { httpRouter } from "convex/server";
import { internal } from "./_generated/api";
import { httpAction } from "./_generated/server";
import { chunkTypes, maxCompressedBytes } from "./telemetryFormat";
import type { ChunkMetadata } from "./telemetryFormat";

class InvalidUpload extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
  }
}

function requiredHeader(headers: Headers, name: string): string {
  const value = headers.get(name);
  if (!value || value.length > 128) throw new InvalidUpload(`Missing or invalid ${name}`);
  return value;
}

function integerHeader(headers: Headers, name: string): number {
  const text = requiredHeader(headers, name);
  const number = Number(text);
  if (!/^\d+$/.test(text) || !Number.isSafeInteger(number)) {
    throw new InvalidUpload(`Invalid ${name}`);
  }
  return number;
}

function readMetadata(headers: Headers): ChunkMetadata {
  const chunkId = requiredHeader(headers, "x-chunk-id");
  const chunkIndex = integerHeader(headers, "x-chunk-index");
  const schemaVersion = integerHeader(headers, "x-schema-version");
  const startedAtMillis = integerHeader(headers, "x-started-at-ms");
  const endedAtMillis = integerHeader(headers, "x-ended-at-ms");
  const checksum = requiredHeader(headers, "x-checksum-sha256").toLowerCase();
  const type = chunkTypes.find((value) => value === headers.get("x-chunk-type"));
  const format = type === "route" || type === "tripManifest" ? "json" : "compact-binary";
  if (!type || headers.get("x-payload-format") !== format || schemaVersion !== 1 ||
    endedAtMillis < startedAtMillis || !/^[a-f0-9]{64}$/.test(checksum)) {
    throw new InvalidUpload("Invalid chunk metadata");
  }
  return { chunkId, chunkIndex, schemaVersion, startedAtMillis, endedAtMillis, checksum, type, format };
}

async function readCompressedBody(request: Request): Promise<ArrayBuffer> {
  if (Number(request.headers.get("content-length")) > maxCompressedBytes) {
    throw new InvalidUpload("Compressed telemetry exceeds 4 MiB", 413);
  }
  const reader = request.body?.getReader();
  if (!reader) throw new InvalidUpload("Missing telemetry payload");
  const parts: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxCompressedBytes) {
        await reader.cancel();
        throw new InvalidUpload("Compressed telemetry exceeds 4 MiB", 413);
      }
      parts.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (size === 0) throw new InvalidUpload("Missing telemetry payload");
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.byteLength;
  }
  return bytes.buffer;
}

const http = httpRouter();

http.route({
  path: "/v1/telemetry/chunks",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return Response.json({ message: "Unauthorized" }, { status: 401 });
    if (request.headers.get("x-user-id") !== identity.subject) {
      return Response.json({ message: "User identifier mismatch" }, { status: 403 });
    }

    try {
      const tripId = requiredHeader(request.headers, "x-trip-id");
      const chunk = readMetadata(request.headers);
      const key = request.headers.get("idempotency-key");
      if (key !== null && key !== `${tripId}:${chunk.chunkId}`) {
        throw new InvalidUpload("Invalid idempotency key");
      }
      const bytes = await readCompressedBody(request);
      const inspection = await ctx.runAction(internal.inspectTelemetry.inspect, { tripId, chunk, bytes });
      if (!inspection.ok) return Response.json({ message: inspection.message }, { status: 422 });

      const storageId = await ctx.storage.store(new Blob([bytes], { type: "application/octet-stream" }));
      let receipt;
      try {
        receipt = await ctx.runMutation(internal.telemetry.persist, {
          owner: identity.tokenIdentifier,
          tripId,
          chunk,
          storageId,
          samples: inspection.samples,
        });
      } catch (error) {
        await ctx.runMutation(internal.telemetry.discardUnlinkedBlob, { storageId }).catch(
          (cleanupError: unknown) => console.error("Telemetry blob cleanup failed", cleanupError),
        );
        throw error;
      }
      if (receipt.status === "conflict") {
        return Response.json({ message: "Conflicting trip chunk ID or index" }, { status: 409 });
      }
      const alreadyExisted = receipt.status === "duplicate";
      return Response.json({ accepted: true, alreadyExisted, chunkId: receipt.id }, {
        status: alreadyExisted ? 200 : 201,
      });
    } catch (error) {
      if (error instanceof InvalidUpload) {
        return Response.json({ message: error.message }, { status: error.status });
      }
      console.error("Telemetry upload failed", error);
      return Response.json({ message: "Unable to store telemetry" }, { status: 500 });
    }
  }),
});

export default http;
