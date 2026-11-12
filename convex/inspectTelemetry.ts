import { Inflate } from "pako";
import { inspectTelemetryLocations } from "../backend_reference/telemetry_decoder";
import type { DecodedLocation } from "../backend_reference/telemetry_decoder";
import {
  chunkTypes,
  maxDecompressedBytes,
  validCoordinates,
} from "./telemetryFormat";
import type { ChunkMetadata, ReplayPoint } from "./telemetryFormat";

const maxReplaySamples = 2_000;

type Inspection =
  | { ok: true; samples: ReplayPoint[] }
  | { ok: false; message: string };

function decompress(bytes: ArrayBuffer): Uint8Array {
  const inflater = new Inflate({ chunkSize: 32 * 1024, windowBits: 31 });
  const chunks: Uint8Array[] = [];
  let size = 0;
  let complete = false;
  inflater.onData = (chunk: Uint8Array) => {
    size += chunk.length;
    if (size > maxDecompressedBytes)
      throw new Error("Decompressed telemetry exceeds 8 MiB");
    chunks.push(chunk);
  };
  inflater.onEnd = (status) => {
    complete = status === 0;
  };
  if (!inflater.push(new Uint8Array(bytes), true) || !complete) {
    throw new Error("Invalid gzip telemetry");
  }

  const decoded = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    decoded.set(chunk, offset);
    offset += chunk.length;
  }
  return decoded;
}

function replayProjection(
  bytes: Uint8Array,
  tripId: string,
  chunk: ChunkMetadata,
): ReplayPoint[] {
  let samples: ReplayPoint[] = [];
  let validCount = 0;
  let stride = 1;
  let latest: ReplayPoint | undefined;

  function capture(location: DecodedLocation) {
    const {
      isMocked,
      latitude,
      longitude,
      timestampMillis,
      speedMps,
      headingDegrees,
    } = location;
    if (
      isMocked ||
      !validCoordinates(latitude, longitude) ||
      timestampMillis < chunk.startedAtMillis ||
      timestampMillis > chunk.endedAtMillis
    )
      return;

    latest = {
      latitude,
      longitude,
      recordedAtMillis: timestampMillis,
      speedMps,
      headingDegrees,
    };
    const index = validCount++;
    if (index % stride !== 0) return;
    if (samples.length === maxReplaySamples) {
      // Thin the collected points before accepting more. This bounds memory
      // even when a DTL1 chunk contains far more points than the replay limit.
      samples = samples.filter((_point, position) => position % 2 === 0);
      stride *= 2;
    }
    if (index % stride === 0) samples.push(latest);
  }

  const header = inspectTelemetryLocations(
    bytes,
    chunk.type === "continuous" ? capture : undefined,
  );
  if (
    header.tripId !== tripId ||
    header.chunkId !== chunk.chunkId ||
    header.chunkIndex !== chunk.chunkIndex ||
    header.chunkType !== chunkTypes.indexOf(chunk.type) ||
    header.schemaVersion !== chunk.schemaVersion ||
    header.startedAtMillis !== chunk.startedAtMillis ||
    header.endedAtMillis !== chunk.endedAtMillis
  ) {
    throw new Error("DTL1 chunk metadata mismatch");
  }
  if (latest && samples.at(-1) !== latest) {
    if (samples.length === maxReplaySamples) samples.pop();
    samples.push(latest);
  }
  return samples;
}

export async function inspectUpload(
  tripId: string,
  chunk: ChunkMetadata,
  bytes: ArrayBuffer,
): Promise<Inspection> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  const checksum = Array.from(digest, (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  if (checksum !== chunk.checksum)
    return { ok: false, message: "Checksum mismatch" };

  try {
    const decoded = decompress(bytes);
    if (chunk.format === "compact-binary") {
      return { ok: true, samples: replayProjection(decoded, tripId, chunk) };
    }

    const value: unknown = JSON.parse(new TextDecoder().decode(decoded));
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      return { ok: false, message: "Expected a JSON object" };
    }
    if (chunk.type === "tripManifest") {
      const manifest = value as Record<string, unknown>;
      if (
        manifest.tripId !== tripId ||
        manifest.schemaVersion !== chunk.schemaVersion ||
        manifest.startedAtMillis !== chunk.startedAtMillis ||
        manifest.endedAtMillis !== chunk.endedAtMillis ||
        manifest.status !== "closed"
      ) {
        return { ok: false, message: "Trip manifest metadata mismatch" };
      }
    }
    return { ok: true, samples: [] };
  } catch {
    return { ok: false, message: "Invalid or oversized telemetry payload" };
  }
}
