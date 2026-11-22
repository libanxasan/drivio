import { authTables } from "@convex-dev/auth/server";
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { axisStatistics, streamKind, streamSource } from "./streamFormat";
import { chunkFields } from "./telemetryFormat";

export default defineSchema({
  // Anonymous Convex Auth accounts of DriVio's own clients.
  ...authTables,
  trips: defineTable({
    owner: v.string(),
    tripId: v.string(),
    startedAtMillis: v.optional(v.number()),
    endedAtMillis: v.optional(v.number()),
    latestLocationAt: v.optional(v.number()),
    latestLocationChunkIndex: v.optional(v.number()),
  }).index("by_owner_and_tripId", ["owner", "tripId"])
    .index("by_endedAtMillis", ["endedAtMillis"]),
  chunks: defineTable({
    ...chunkFields,
    trip: v.id("trips"),
    storageId: v.id("_storage"),
    hasReplay: v.boolean(),
  })
    .index("by_trip_and_chunkId", ["trip", "chunkId"])
    .index("by_trip_and_chunkIndex", ["trip", "chunkIndex"])
    .index("by_trip_and_hasReplay_and_chunkIndex", [
      "trip",
      "hasReplay",
      "chunkIndex",
    ])
    .index("by_storageId", ["storageId"]),

  // Live stream of each app's telemetry, kept until ARCHIVE_PERIOD. `kinds` says
  // what the app streams; backfill restores exactly those kinds from archives.
  streams: defineTable({
    app: v.string(), owner: v.string(), streamId: v.string(),
    kinds: v.array(streamKind),
    startedAt: v.number(), lastLiveAt: v.number(), lastDataAt: v.optional(v.number()),
    endedAt: v.optional(v.number()), active: v.boolean(),
  })
    .index("by_owner_and_streamId", ["owner", "streamId"])
    .index("by_active_and_lastLiveAt", ["active", "lastLiveAt"])
    .index("by_endedAt", ["endedAt"]),
  streamPoints: defineTable({
    stream: v.id("streams"), owner: v.string(), t: v.number(),
    latitude: v.number(), longitude: v.number(), speedMps: v.number(), headingDegrees: v.number(),
    accuracyMeters: v.number(), altitudeMeters: v.optional(v.number()),
    speedAccuracyMps: v.optional(v.number()), headingAccuracyDegrees: v.optional(v.number()),
    isMocked: v.boolean(), source: streamSource,
  }).index("by_stream_and_t", ["stream", "t"]).index("by_t", ["t"]),
  streamFrames: defineTable({
    stream: v.id("streams"), owner: v.string(), t: v.number(), durationMillis: v.number(),
    longitudinalAcceleration: axisStatistics, lateralAcceleration: axisStatistics,
    verticalAcceleration: axisStatistics, yawRate: axisStatistics,
    pitchRate: axisStatistics, rollRate: axisStatistics,
    phoneStability: v.number(), axisMappingCalibrated: v.boolean(), source: streamSource,
  }).index("by_stream_and_t", ["stream", "t"]).index("by_t", ["t"]),
  streamEvents: defineTable({
    stream: v.id("streams"), owner: v.string(), t: v.number(), endedAt: v.number(),
    eventId: v.string(), eventType: v.union(v.string(), v.number()), confidence: v.number(),
    minimumValue: v.number(), maximumValue: v.number(), meanValue: v.number(),
    latitude: v.optional(v.number()), longitude: v.optional(v.number()),
    speedBeforeMps: v.optional(v.number()), speedAfterMps: v.optional(v.number()),
    effectiveSpeedLimitKph: v.optional(v.number()), source: streamSource,
  }).index("by_stream_and_eventId", ["stream", "eventId"]).index("by_stream_and_t", ["stream", "t"])
    .index("by_t", ["t"]),
  // A stretch of the live stream without data while the stream was active.
  streamGaps: defineTable({
    stream: v.id("streams"), app: v.string(), owner: v.string(),
    from: v.number(), to: v.optional(v.number()),
    status: v.union(v.literal("open"), v.literal("partial"), v.literal("filled"), v.literal("unrecoverable")),
    filledUntil: v.optional(v.number()), restored: v.number(),
    attempts: v.number(), nextAttemptAt: v.number(), lastError: v.optional(v.string()),
  }).index("by_status_and_nextAttemptAt", ["status", "nextAttemptAt"])
    .index("by_stream_and_status", ["stream", "status"])
    .index("by_owner_and_status", ["owner", "status"])
    .index("by_from", ["from"]),
});
