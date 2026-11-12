import { BatchedReplay } from "@convex-dev/batched-replay";
import { GeospatialIndex } from "@convex-dev/geospatial";
import { ConvexError, v } from "convex/values";
import { components } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import { internalMutation, query } from "./_generated/server";
import type { QueryCtx } from "./_generated/server";
import { chunkFields, chunkMetadata, coordinates, replayPoint, validCoordinates } from "./telemetryFormat";
import type { ChunkMetadata, ReplayPoint } from "./telemetryFormat";

const locations = new GeospatialIndex<Id<"trips">, { owner: string }>(components.geospatial);
const replay = new BatchedReplay<ReplayPoint>(components.batchedReplay, {
  retentionMs: 7 * 24 * 60 * 60 * 1_000,
});

function findTrip(db: QueryCtx["db"], owner: string, tripId: string) {
  return db.query("trips")
    .withIndex("by_owner_and_tripId", (q) => q.eq("owner", owner).eq("tripId", tripId))
    .unique();
}

async function requireOwner(ctx: QueryCtx) {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) throw new ConvexError("Unauthorized");
  return identity.tokenIdentifier;
}

export const persist = internalMutation({
  args: {
    owner: v.string(),
    tripId: v.string(),
    storageId: v.id("_storage"),
    chunk: chunkMetadata,
    samples: v.array(replayPoint),
  },
  returns: v.union(
    v.object({ status: v.union(v.literal("stored"), v.literal("duplicate")), id: v.id("chunks") }),
    v.object({ status: v.literal("conflict") }),
  ),
  handler: async (ctx, { owner, tripId, storageId, chunk, samples }) => {
    const trip = await findTrip(ctx.db, owner, tripId);
    if (trip) {
      const existing = await ctx.db.query("chunks")
        .withIndex("by_trip_and_chunkId", (q) => q.eq("trip", trip._id).eq("chunkId", chunk.chunkId))
        .unique();
      if (existing) {
        await ctx.storage.delete(storageId);
        const same = (Object.keys(chunkFields) as (keyof ChunkMetadata)[])
          .every((key) => existing[key] === chunk[key]);
        return same ? { status: "duplicate", id: existing._id } : { status: "conflict" };
      }
      const atIndex = await ctx.db.query("chunks")
        .withIndex("by_trip_and_chunkIndex", (q) => q.eq("trip", trip._id).eq("chunkIndex", chunk.chunkIndex))
        .unique();
      if (atIndex || (chunk.type === "tripManifest" && trip.endedAtMillis !== undefined)) {
        await ctx.storage.delete(storageId);
        return { status: "conflict" };
      }
    }

    const tripKey = trip?._id ?? await ctx.db.insert("trips", { owner, tripId });
    const first = samples[0];
    const latest = samples.at(-1);
    const chunkKey = await ctx.db.insert("chunks", {
      ...chunk,
      trip: tripKey,
      storageId,
      hasReplay: latest !== undefined,
    });

    if (chunk.type === "tripManifest") {
      await ctx.db.patch(tripKey, {
        startedAtMillis: chunk.startedAtMillis,
        endedAtMillis: chunk.endedAtMillis,
      });
    }
    if (first && latest) {
      const previousAt = trip?.latestLocationAt ?? -1;
      const previousIndex = trip?.latestLocationChunkIndex ?? -1;
      if (latest.recordedAtMillis > previousAt ||
        (latest.recordedAtMillis === previousAt && chunk.chunkIndex > previousIndex)) {
        await locations.insert(ctx, tripKey, {
          latitude: latest.latitude,
          longitude: latest.longitude,
        }, { owner }, latest.recordedAtMillis);
        await ctx.db.patch(tripKey, {
          latestLocationAt: latest.recordedAtMillis,
          latestLocationChunkIndex: chunk.chunkIndex,
        });
      }

      const span = latest.recordedAtMillis - first.recordedAtMillis;
      const duration = Math.min(span, 60_000);
      const scale = span > 60_000 ? duration / span : 1;
      // One stream per archived chunk keeps late uploads in capture order on read.
      // Retain capture time separately because the component assigns server time.
      const appended = await replay.append(ctx, {
        room: tripKey,
        stream: chunkKey,
        duration,
        samples: samples.map((point) => ({
          t: Math.min(duration, (point.recordedAtMillis - first.recordedAtMillis) * scale),
          v: point,
        })),
      });
      if (!appended) throw new Error("Telemetry replay batch was not stored");
    }

    return { status: "stored", id: chunkKey };
  },
});

export const discardUnlinkedBlob = internalMutation({
  args: { storageId: v.id("_storage") },
  returns: v.null(),
  handler: async (ctx, { storageId }) => {
    const stored = await ctx.db.query("chunks")
      .withIndex("by_storageId", (q) => q.eq("storageId", storageId))
      .unique();
    if (!stored) await ctx.storage.delete(storageId);
    return null;
  },
});

export const nearby = query({
  args: { ...coordinates.fields, radiusMeters: v.number(), limit: v.optional(v.number()) },
  returns: v.array(v.object({
    ...coordinates.fields,
    tripId: v.string(),
    recordedAtMillis: v.number(),
    distanceMeters: v.number(),
  })),
  handler: async (ctx, { latitude, longitude, radiusMeters, limit = 20 }) => {
    const owner = await requireOwner(ctx);
    if (!validCoordinates(latitude, longitude) || !(radiusMeters > 0 && radiusMeters <= 100_000) ||
      !Number.isSafeInteger(limit) || limit < 1 || limit > 50) {
      throw new ConvexError("Invalid coordinates, radius (0–100000 m) or limit (1–50)");
    }
    const hits = await locations.nearest(ctx, {
      point: { latitude, longitude },
      maxDistance: radiusMeters,
      limit,
      filter: (q) => q.eq("owner", owner),
    });
    const results = await Promise.all(hits.map(async (hit) => {
      const trip = await ctx.db.get(hit.key);
      if (trip?.owner !== owner || trip.latestLocationAt === undefined) return null;
      return {
        ...hit.coordinates,
        tripId: trip.tripId,
        recordedAtMillis: trip.latestLocationAt,
        distanceMeters: hit.distance,
      };
    }));
    return results.filter((result) => result !== null);
  },
});

export const history = query({
  args: { tripId: v.string(), afterChunkIndex: v.optional(v.number()), limit: v.optional(v.number()) },
  returns: v.object({
    chunks: v.array(v.object({ chunkIndex: v.number(), samples: v.array(replayPoint) })),
    nextChunkIndex: v.union(v.number(), v.null()),
  }),
  handler: async (ctx, { tripId, afterChunkIndex = -1, limit = 4 }) => {
    const owner = await requireOwner(ctx);
    if (!Number.isSafeInteger(afterChunkIndex) || afterChunkIndex < -1 ||
      !Number.isSafeInteger(limit) || limit < 1 || limit > 8 || tripId.length > 128) {
      throw new ConvexError("Invalid trip ID, chunk cursor or page limit (1–8)");
    }
    const trip = await findTrip(ctx.db, owner, tripId);
    if (!trip) return { chunks: [], nextChunkIndex: null };
    const rows = await ctx.db.query("chunks")
      .withIndex("by_trip_and_hasReplay_and_chunkIndex", (q) =>
        q.eq("trip", trip._id).eq("hasReplay", true).gt("chunkIndex", afterChunkIndex))
      .take(limit + 1);
    const chunks = await Promise.all(rows.slice(0, limit).map(async (row) => {
      const page = await replay.history(ctx, { room: trip._id, stream: row._id, limit: 1 });
      const batch = page.batches[0];
      if (!batch) return null;
      return { chunkIndex: row.chunkIndex, samples: batch.samples.map((sample) => sample.v as ReplayPoint) };
    }));
    return {
      chunks: chunks.filter((chunk) => chunk !== null),
      nextChunkIndex: rows.length > limit ? rows[limit - 1].chunkIndex : null,
    };
  },
});
