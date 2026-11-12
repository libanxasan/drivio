import { v } from "convex/values";
import type { Infer } from "convex/values";

// DTL1 uses the index in this list as its numeric chunk type.
export const chunkTypes = [
  "continuous",
  "eventEvidence",
  "hourlyAggregate",
  "route",
  "tripManifest",
] as const;

export const chunkFields = {
  chunkId: v.string(),
  chunkIndex: v.number(),
  type: v.union(...chunkTypes.map((type) => v.literal(type))),
  schemaVersion: v.literal(1),
  format: v.union(v.literal("compact-binary"), v.literal("json")),
  startedAtMillis: v.number(),
  endedAtMillis: v.number(),
  checksum: v.string(),
};

export const chunkMetadata = v.object(chunkFields);
export type ChunkMetadata = Infer<typeof chunkMetadata>;

export const coordinates = v.object({
  latitude: v.number(),
  longitude: v.number(),
});

export const replayPoint = v.object({
  ...coordinates.fields,
  recordedAtMillis: v.number(),
  speedMps: v.number(),
  headingDegrees: v.number(),
});
export type ReplayPoint = Infer<typeof replayPoint>;

export const maxCompressedBytes = 4 * 1024 * 1024;
export const maxDecompressedBytes = 8 * 1024 * 1024;

export function validCoordinates(latitude: number, longitude: number): boolean {
  return latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180;
}
