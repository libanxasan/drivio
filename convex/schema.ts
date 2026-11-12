import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { chunkFields } from "./telemetryFormat";

export default defineSchema({
  trips: defineTable({
    owner: v.string(),
    tripId: v.string(),
    startedAtMillis: v.optional(v.number()),
    endedAtMillis: v.optional(v.number()),
    latestLocationAt: v.optional(v.number()),
    latestLocationChunkIndex: v.optional(v.number()),
  }).index("by_owner_and_tripId", ["owner", "tripId"]),
  chunks: defineTable({
    ...chunkFields,
    trip: v.id("trips"),
    storageId: v.id("_storage"),
    hasReplay: v.boolean(),
  })
    .index("by_trip_and_chunkId", ["trip", "chunkId"])
    .index("by_trip_and_chunkIndex", ["trip", "chunkIndex"])
    .index("by_trip_and_hasReplay_and_chunkIndex", ["trip", "hasReplay", "chunkIndex"])
    .index("by_storageId", ["storageId"]),
});
