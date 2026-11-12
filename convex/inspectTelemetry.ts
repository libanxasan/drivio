"use node";

import { createHash } from "node:crypto";
import { gunzipSync } from "node:zlib";
import { v } from "convex/values";
import { decodeTelemetryChunk } from "../backend_reference/telemetry_decoder";
import { internalAction } from "./_generated/server";
import {
  chunkMetadata,
  chunkTypes,
  maxDecompressedBytes,
  replayPoint,
  validCoordinates,
} from "./telemetryFormat";
import type { ReplayPoint } from "./telemetryFormat";

const maxReplaySamples = 2_000;

export const inspect = internalAction({
  args: { tripId: v.string(), chunk: chunkMetadata, bytes: v.bytes() },
  returns: v.union(
    v.object({ ok: v.literal(true), samples: v.array(replayPoint) }),
    v.object({ ok: v.literal(false), message: v.string() }),
  ),
  handler: async (_ctx, { tripId, chunk, bytes }) => {
    const compressed = Buffer.from(bytes);
    if (createHash("sha256").update(compressed).digest("hex") !== chunk.checksum) {
      return { ok: false, message: "Checksum mismatch" } as const;
    }

    try {
      const decoded = gunzipSync(compressed, { maxOutputLength: maxDecompressedBytes });
      if (chunk.format === "json") {
        const value: unknown = JSON.parse(decoded.toString("utf8"));
        if (value === null || typeof value !== "object" || Array.isArray(value)) {
          return { ok: false, message: "Expected a JSON object" } as const;
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
            return { ok: false, message: "Trip manifest metadata mismatch" } as const;
          }
        }
        return { ok: true, samples: [] } as const;
      }

      const telemetry = decodeTelemetryChunk(decoded);
      if (
        telemetry.tripId !== tripId ||
        telemetry.chunkId !== chunk.chunkId ||
        telemetry.chunkIndex !== chunk.chunkIndex ||
        telemetry.chunkType !== chunkTypes.indexOf(chunk.type) ||
        telemetry.schemaVersion !== chunk.schemaVersion ||
        telemetry.startedAtMillis !== chunk.startedAtMillis ||
        telemetry.endedAtMillis !== chunk.endedAtMillis
      ) {
        return { ok: false, message: "DTL1 chunk metadata mismatch" } as const;
      }
      if (chunk.type !== "continuous") return { ok: true, samples: [] } as const;

      const points = telemetry.locations.filter(
        ({ isMocked, latitude, longitude, timestampMillis }) =>
          !isMocked &&
          validCoordinates(latitude, longitude) &&
          timestampMillis >= chunk.startedAtMillis &&
          timestampMillis <= chunk.endedAtMillis,
      );
      const count = Math.min(points.length, maxReplaySamples);
      const samples: ReplayPoint[] = [];
      for (let index = 0; index < count; index++) {
        // For oversized batches, keep an even sample and both endpoints.
        const point = points[Math.floor((index * (points.length - 1)) / Math.max(1, count - 1))];
        samples.push({
          latitude: point.latitude,
          longitude: point.longitude,
          recordedAtMillis: point.timestampMillis,
          speedMps: point.speedMps,
          headingDegrees: point.headingDegrees,
        });
      }
      return { ok: true, samples } as const;
    } catch {
      return { ok: false, message: "Invalid or oversized compressed telemetry" } as const;
    }
  },
});
