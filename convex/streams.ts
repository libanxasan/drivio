import { ConvexError, v } from "convex/values";
import { internalMutation, mutation, query } from "./_generated/server";
import type { MutationCtx } from "./_generated/server";
import type { Doc, Id } from "./_generated/dataModel";
import { drivioApp, principal } from "./identity";
import {
  gapThresholdMs, maxOpenGapMs, streamEvent, streamFrame, streamKind, streamPoint,
  type StreamEvent, type StreamFrame, type StreamKind, type StreamPoint,
} from "./streamFormat";

export type LiveBatch = {
  app: string; owner: string; streamId: string; kinds: StreamKind[];
  points?: StreamPoint[]; frames?: StreamFrame[]; events?: StreamEvent[];
};

async function findStream(ctx: MutationCtx, owner: string, streamId: string) {
  return ctx.db.query("streams")
    .withIndex("by_owner_and_streamId", q => q.eq("owner", owner).eq("streamId", streamId)).unique();
}

async function openEndedGap(ctx: MutationCtx, stream: Id<"streams">) {
  for (const status of ["open", "partial"] as const) {
    const gaps = await ctx.db.query("streamGaps")
      .withIndex("by_stream_and_status", q => q.eq("stream", stream).eq("status", status)).collect();
    const gap = gaps.find(g => g.to === undefined);
    if (gap) return gap;
  }
  return null;
}

/** Inserts items that are not stored yet (same stream and time, or same event id). */
export async function insertItems(
  ctx: MutationCtx, stream: Doc<"streams">, source: "live" | "archive",
  items: { points?: StreamPoint[]; frames?: StreamFrame[]; events?: StreamEvent[] },
) {
  let inserted = 0;
  const kinds = new Set(stream.kinds);
  if (kinds.has("points")) {
    for (const point of items.points ?? []) {
      const exists = await ctx.db.query("streamPoints")
        .withIndex("by_stream_and_t", q => q.eq("stream", stream._id).eq("t", point.t)).first();
      if (exists) continue;
      await ctx.db.insert("streamPoints", { ...point, stream: stream._id, owner: stream.owner, source });
      inserted++;
    }
  }
  if (kinds.has("frames")) {
    for (const frame of items.frames ?? []) {
      const exists = await ctx.db.query("streamFrames")
        .withIndex("by_stream_and_t", q => q.eq("stream", stream._id).eq("t", frame.t)).first();
      if (exists) continue;
      await ctx.db.insert("streamFrames", { ...frame, stream: stream._id, owner: stream.owner, source });
      inserted++;
    }
  }
  if (kinds.has("events")) {
    for (const event of items.events ?? []) {
      const exists = await ctx.db.query("streamEvents")
        .withIndex("by_stream_and_eventId", q => q.eq("stream", stream._id).eq("eventId", event.eventId)).first();
      if (exists) continue;
      await ctx.db.insert("streamEvents", { ...event, stream: stream._id, owner: stream.owner, source });
      inserted++;
    }
  }
  return inserted;
}

/**
 * Records a batch from the live stream. A jump of more than gapThresholdMs in the
 * data, or the end of a silence the cron already noticed, becomes a gap that
 * backfill fills from the app's archive.
 */
export async function recordLive(ctx: MutationCtx, batch: LiveBatch) {
  const times = [
    ...(batch.points ?? []).map(p => p.t), ...(batch.frames ?? []).map(f => f.t),
    ...(batch.events ?? []).map(e => e.t),
  ];
  const now = Date.now();
  let stream = await findStream(ctx, batch.owner, batch.streamId);
  if (!stream) {
    const id = await ctx.db.insert("streams", {
      app: batch.app, owner: batch.owner, streamId: batch.streamId, kinds: batch.kinds,
      startedAt: now, lastLiveAt: now, active: true,
    });
    stream = (await ctx.db.get(id))!;
  } else if (!stream.active) {
    await ctx.db.patch(stream._id, { active: true, endedAt: undefined });
  }
  if (times.length === 0) {
    await ctx.db.patch(stream._id, { lastLiveAt: now });
    return { stream: stream._id, inserted: 0 };
  }
  const first = Math.min(...times);
  const last = Math.max(...times);
  const gap = await openEndedGap(ctx, stream._id);
  if (gap) {
    if (first > gap.from) await ctx.db.patch(gap._id, { to: first, nextAttemptAt: now });
  } else if (stream.lastDataAt !== undefined && first - stream.lastDataAt > gapThresholdMs) {
    await ctx.db.insert("streamGaps", {
      stream: stream._id, app: stream.app, owner: stream.owner, from: stream.lastDataAt, to: first,
      status: "open", restored: 0, attempts: 0, nextAttemptAt: now + gapThresholdMs,
    });
  }
  const inserted = await insertItems(ctx, stream, "live", batch);
  await ctx.db.patch(stream._id, {
    lastLiveAt: now, lastDataAt: Math.max(stream.lastDataAt ?? last, last),
  });
  return { stream: stream._id, inserted };
}

export async function endStream(ctx: MutationCtx, owner: string, streamId: string) {
  const stream = await findStream(ctx, owner, streamId);
  if (stream?.active) await ctx.db.patch(stream._id, { active: false, endedAt: Date.now() });
}

const batchLimits = { points: 300, frames: 300, events: 100 };

async function drivioOwner(ctx: { auth: { getUserIdentity(): Promise<any> } }) {
  const who = principal(await ctx.auth.getUserIdentity());
  if (who?.app !== drivioApp) throw new ConvexError("Sign in to continue");
  return who.owner;
}

const streamIdValidator = (streamId: string) => {
  if (!/^[A-Za-z0-9._:-]{1,128}$/.test(streamId)) throw new ConvexError("Invalid stream id");
};

/** Live telemetry from DriVio's own clients. `kinds` declares what the client streams. */
export const publish = mutation({
  args: {
    streamId: v.string(), kinds: v.array(streamKind),
    points: v.optional(v.array(streamPoint)), frames: v.optional(v.array(streamFrame)),
    events: v.optional(v.array(streamEvent)),
  },
  returns: v.object({ inserted: v.number() }),
  handler: async (ctx, args) => {
    const owner = await drivioOwner(ctx);
    streamIdValidator(args.streamId);
    if ((args.points?.length ?? 0) > batchLimits.points || (args.frames?.length ?? 0) > batchLimits.frames ||
        (args.events?.length ?? 0) > batchLimits.events) {
      throw new ConvexError("Batch too large");
    }
    const { inserted } = await recordLive(ctx, { app: drivioApp, owner, ...args });
    return { inserted };
  },
});

export const close = mutation({
  args: { streamId: v.string() }, returns: v.null(),
  handler: async (ctx, { streamId }) => {
    await endStream(ctx, await drivioOwner(ctx), streamId);
    return null;
  },
});

/** The caller's stream items after `after`, oldest first. */
export const recent = query({
  args: {
    streamId: v.string(), kind: streamKind, after: v.optional(v.number()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, { streamId, kind, after = 0, limit = 200 }) => {
    const owner = await drivioOwner(ctx);
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 500) throw new ConvexError("Limit 1 to 500");
    const stream = await ctx.db.query("streams")
      .withIndex("by_owner_and_streamId", q => q.eq("owner", owner).eq("streamId", streamId)).unique();
    if (!stream) return { items: [], gaps: [] };
    const table = kind === "points" ? "streamPoints" : kind === "frames" ? "streamFrames" : "streamEvents";
    const items = await ctx.db.query(table)
      .withIndex("by_stream_and_t", q => q.eq("stream", stream._id).gt("t", after)).take(limit);
    const gaps = [];
    for (const status of ["open", "partial", "filled", "unrecoverable"] as const) {
      gaps.push(...await ctx.db.query("streamGaps")
        .withIndex("by_stream_and_status", q => q.eq("stream", stream._id).eq("status", status)).collect());
    }
    return {
      items: items.map(({ _id, _creationTime, stream: _s, owner: _o, ...item }) => item),
      gaps: gaps.map(g => ({ from: g.from, to: g.to ?? null, status: g.status, restored: g.restored })),
    };
  },
});

/** Opens a gap for active streams that went silent, and ends streams silent for too long. */
export const detectSilence = internalMutation({
  args: {}, returns: v.null(),
  handler: async ctx => {
    const now = Date.now();
    const silent = await ctx.db.query("streams")
      .withIndex("by_active_and_lastLiveAt", q => q.eq("active", true).lt("lastLiveAt", now - gapThresholdMs))
      .take(100);
    for (const stream of silent) {
      if (now - stream.lastLiveAt > maxOpenGapMs) {
        await ctx.db.patch(stream._id, { active: false, endedAt: stream.lastLiveAt });
      }
      if (await openEndedGap(ctx, stream._id)) continue;
      await ctx.db.insert("streamGaps", {
        stream: stream._id, app: stream.app, owner: stream.owner,
        from: stream.lastDataAt ?? stream.lastLiveAt, status: "open", restored: 0, attempts: 0,
        nextAttemptAt: now + 5 * 60_000,
      });
    }
    return null;
  },
});
