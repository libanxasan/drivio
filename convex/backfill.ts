import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalAction, internalMutation, internalQuery } from "./_generated/server";
import type { ActionCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { decodeTelemetryChunk } from "../backend_reference/telemetry_decoder";
import { archiveSourceFor, type ArchivedChunk } from "./apps";
import { decompress } from "./inspectTelemetry";
import { insertItems } from "./streams";
import {
  backfillDeadlineMs, maxOpenGapMs, streamEvent, streamFrame, streamPoint,
  type StreamEvent, type StreamFrame, type StreamPoint,
} from "./streamFormat";

/**
 * Backfill: when a stream had a gap (the phone was offline but kept recording),
 * the app's archive eventually receives those recordings. Backfill finds the
 * continuous chunks overlapping the gap, decodes them, and restores exactly the
 * kinds of data the app streams, marked `source: "archive"`.
 */

const gapsPerRun = 20;

export const dueGaps = internalQuery({
  args: { now: v.number() },
  handler: async (ctx, { now }) => {
    const due = [];
    for (const status of ["open", "partial"] as const) {
      due.push(...await ctx.db.query("streamGaps")
        .withIndex("by_status_and_nextAttemptAt", q => q.eq("status", status).lte("nextAttemptAt", now))
        .take(gapsPerRun));
    }
    return due.slice(0, gapsPerRun).map(g => ({ id: g._id, app: g.app, owner: g.owner, from: g.from, to: g.to ?? null, attempts: g.attempts, stream: g.stream }));
  },
});

/** DriVio's own archive: continuous chunks stored on this deployment. */
export const coreChunks = internalQuery({
  args: { owner: v.string(), from: v.number(), to: v.number() },
  handler: async (ctx, { owner, from, to }) => {
    const trips = await ctx.db.query("trips")
      .withIndex("by_owner_and_tripId", q => q.eq("owner", owner)).collect();
    const found = [];
    for (const trip of trips) {
      if ((trip.endedAtMillis ?? Infinity) < from || (trip.startedAtMillis ?? 0) > to) continue;
      const chunks = await ctx.db.query("chunks")
        .withIndex("by_trip_and_chunkIndex", q => q.eq("trip", trip._id)).collect();
      for (const chunk of chunks) {
        if (chunk.type !== "continuous" || chunk.endedAtMillis < from || chunk.startedAtMillis > to) continue;
        found.push({
          chunkId: chunk.chunkId, startedAtMs: chunk.startedAtMillis, endedAtMs: chunk.endedAtMillis,
          checksumSha256: chunk.checksum, storageId: chunk.storageId,
        });
      }
    }
    return found;
  },
});

async function sha256(bytes: ArrayBuffer) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, b => b.toString(16).padStart(2, "0")).join("");
}

function toItems(bytes: ArrayBuffer, from: number, to: number) {
  const decoded = decodeTelemetryChunk(decompress(bytes));
  const inside = (t: number) => t > from && t < to;
  const points: StreamPoint[] = decoded.locations.filter(l => inside(l.timestampMillis)).map(l => ({
    t: l.timestampMillis, latitude: l.latitude, longitude: l.longitude, speedMps: l.speedMps,
    headingDegrees: l.headingDegrees, accuracyMeters: l.accuracyMeters, altitudeMeters: l.altitudeMeters,
    speedAccuracyMps: l.speedAccuracyMps, headingAccuracyDegrees: l.headingAccuracyDegrees, isMocked: l.isMocked,
  }));
  const frames = decoded.motionFrames
    .filter(f => inside(f.startedAtMillis as number))
    .map(({ startedAtMillis, ...frame }) => ({ ...frame, t: startedAtMillis }) as unknown as StreamFrame);
  const events: StreamEvent[] = decoded.events.filter(e => inside(e.startedAtMillis as number)).map(e => ({
    t: e.startedAtMillis as number, endedAt: e.endedAtMillis as number, eventId: e.id as string,
    eventType: e.eventType as number, confidence: e.confidence as number,
    minimumValue: e.minimumValue as number, maximumValue: e.maximumValue as number, meanValue: e.meanValue as number,
    latitude: e.latitude as number | undefined, longitude: e.longitude as number | undefined,
    speedBeforeMps: e.speedBeforeMps as number | undefined, speedAfterMps: e.speedAfterMps as number | undefined,
    effectiveSpeedLimitKph: e.effectiveSpeedLimitKph as number | undefined,
  }));
  return { points, frames, events };
}

async function archivedChunks(ctx: ActionCtx, app: string, owner: string, from: number, to: number)
  : Promise<ArchivedChunk[] | null> {
  if (app === "drivio") {
    const chunks = await ctx.runQuery(internal.backfill.coreChunks, { owner, from, to });
    return chunks.map(chunk => ({
      startedAtMs: chunk.startedAtMs, endedAtMs: chunk.endedAtMs, checksumSha256: chunk.checksumSha256,
      download: async () => {
        const blob = await ctx.storage.get(chunk.storageId as Id<"_storage">);
        if (!blob) throw new Error(`Chunk ${chunk.chunkId} is missing from storage`);
        return blob.arrayBuffer();
      },
    }));
  }
  const source = archiveSourceFor(app);
  return source ? source.find(owner, from, to) : null;
}

/** Fills due gaps from archives. Runs every few minutes and after archive uploads. */
export const run = internalAction({
  args: {}, returns: v.null(),
  handler: async ctx => {
    const now = Date.now();
    for (const gap of await ctx.runQuery(internal.backfill.dueGaps, { now })) {
      const to = gap.to ?? Math.min(now, gap.from + maxOpenGapMs);
      let points: StreamPoint[] = [], frames: StreamFrame[] = [], events: StreamEvent[] = [];
      let coveredUntil = gap.from;
      let error: string | undefined;
      try {
        const chunks = await archivedChunks(ctx, gap.app, gap.owner, gap.from, to);
        if (chunks === null) error = `No archive configured for ${gap.app}`;
        for (const chunk of chunks ?? []) {
          const bytes = await chunk.download();
          if (await sha256(bytes) !== chunk.checksumSha256) throw new Error("Archive checksum mismatch");
          const items = toItems(bytes, gap.from, to);
          points = points.concat(items.points);
          frames = frames.concat(items.frames);
          events = events.concat(items.events);
          coveredUntil = Math.max(coveredUntil, chunk.endedAtMs);
        }
      } catch (failure) {
        error = failure instanceof Error ? failure.message : String(failure);
      }
      await ctx.runMutation(internal.backfill.restore, {
        gap: gap.id, points, frames, events, coveredUntil,
        complete: gap.to !== null && coveredUntil >= gap.to, error,
      });
    }
    return null;
  },
});

export const restore = internalMutation({
  args: {
    gap: v.id("streamGaps"), points: v.array(streamPoint), frames: v.array(streamFrame),
    events: v.array(streamEvent), coveredUntil: v.number(), complete: v.boolean(),
    error: v.optional(v.string()),
  },
  returns: v.null(),
  handler: async (ctx, { gap: gapId, points, frames, events, coveredUntil, complete, error }) => {
    const gap = await ctx.db.get(gapId);
    const stream = gap ? await ctx.db.get(gap.stream) : null;
    if (!gap || !stream || gap.status === "filled" || gap.status === "unrecoverable") return null;
    const restored = gap.restored + await insertItems(ctx, stream, "archive", { points, frames, events });
    const now = Date.now();
    const attempts = gap.attempts + 1;
    const expired = now > gap.from + backfillDeadlineMs;
    const status = complete ? "filled" : expired ? (restored > 0 ? "filled" : "unrecoverable")
      : restored > 0 ? "partial" : gap.status;
    await ctx.db.patch(gapId, {
      status, restored, attempts, lastError: error,
      filledUntil: Math.max(gap.filledUntil ?? gap.from, coveredUntil),
      nextAttemptAt: now + Math.min(5 * 60_000 * 2 ** Math.min(attempts, 4), 60 * 60_000),
    });
    return null;
  },
});

/** Makes an owner's open gaps due now, after new archive data arrived. */
export const wake = internalMutation({
  args: { owner: v.string() }, returns: v.null(),
  handler: async (ctx, { owner }) => {
    const now = Date.now();
    for (const status of ["open", "partial"] as const) {
      const gaps = await ctx.db.query("streamGaps")
        .withIndex("by_owner_and_status", q => q.eq("owner", owner).eq("status", status)).collect();
      for (const gap of gaps) await ctx.db.patch(gap._id, { nextAttemptAt: now });
    }
    await ctx.scheduler.runAfter(0, internal.backfill.run, {});
    return null;
  },
});
