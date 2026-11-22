import { v } from "convex/values";
import { GeospatialIndex } from "@convex-dev/geospatial";
import { components, internal } from "./_generated/api";
import { internalMutation } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { archivePeriodMs } from "./archivePeriod";
import { taxiXpressPurge } from "../apps/taxi-xpress/host";

const batch = 200;
const locations = new GeospatialIndex<Id<"trips">, { owner: string }>(components.geospatial);

/**
 * Deletes telemetry older than ARCHIVE_PERIOD: stream data, gaps, ended streams,
 * archived trips with their chunk files, and application sessions. Without
 * ARCHIVE_PERIOD nothing is deleted.
 */
export const purge = internalMutation({
  args: {}, returns: v.object({ deleted: v.number(), cutoff: v.union(v.number(), v.null()) }),
  handler: async ctx => {
    const period = archivePeriodMs();
    if (period === null) return { deleted: 0, cutoff: null };
    const cutoff = Date.now() - period;
    let deleted = 0;
    let more = false;
    for (const table of ["streamPoints", "streamFrames", "streamEvents"] as const) {
      const rows = await ctx.db.query(table).withIndex("by_t", q => q.lt("t", cutoff)).take(batch);
      for (const row of rows) await ctx.db.delete(row._id);
      deleted += rows.length;
      more ||= rows.length === batch;
    }
    const gaps = await ctx.db.query("streamGaps").withIndex("by_from", q => q.lt("from", cutoff)).take(batch);
    for (const gap of gaps) await ctx.db.delete(gap._id);
    const streams = await ctx.db.query("streams")
      .withIndex("by_endedAt", q => q.gt("endedAt", 0).lt("endedAt", cutoff)).take(batch);
    for (const stream of streams) await ctx.db.delete(stream._id);
    const trips = await ctx.db.query("trips")
      .withIndex("by_endedAtMillis", q => q.gt("endedAtMillis", 0).lt("endedAtMillis", cutoff)).take(20);
    for (const trip of trips) {
      const chunks = await ctx.db.query("chunks")
        .withIndex("by_trip_and_chunkIndex", q => q.eq("trip", trip._id)).collect();
      for (const chunk of chunks) {
        await ctx.storage.delete(chunk.storageId);
        await ctx.db.delete(chunk._id);
      }
      await locations.remove(ctx, trip._id);
      await ctx.db.delete(trip._id);
    }
    const sessions = await taxiXpressPurge(components.taxiXpress)(ctx, cutoff);
    deleted += gaps.length + streams.length + trips.length + sessions.deleted;
    more ||= gaps.length === batch || streams.length === batch || trips.length === 20;
    if (more) await ctx.scheduler.runAfter(0, internal.retention.purge, {});
    return { deleted, cutoff };
  },
});
