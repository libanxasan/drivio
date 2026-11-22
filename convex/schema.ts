import { authTables } from "@convex-dev/auth/server";
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { chunkFields } from "./telemetryFormat";

export default defineSchema({
  // Convex Auth, shared by every application on the deployment.
  ...authTables,
  users: defineTable({
    name: v.optional(v.string()),
    image: v.optional(v.string()),
    email: v.optional(v.string()),
    emailVerificationTime: v.optional(v.number()),
    phone: v.optional(v.string()),
    phoneVerificationTime: v.optional(v.number()),
    isAnonymous: v.optional(v.boolean()),
    /** The application the account was created for, such as "taxi-xpress". */
    app: v.optional(v.string()),
  })
    .index("email", ["email"])
    .index("phone", ["phone"])
    .index("app_and_phone", ["app", "phone"]),
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
    .index("by_trip_and_hasReplay_and_chunkIndex", [
      "trip",
      "hasReplay",
      "chunkIndex",
    ])
    .index("by_storageId", ["storageId"]),
});
