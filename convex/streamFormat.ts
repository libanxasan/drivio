import { v, type Infer } from "convex/values";

export const streamKind = v.union(v.literal("points"), v.literal("frames"), v.literal("events"));
export type StreamKind = Infer<typeof streamKind>;
export const streamSource = v.union(v.literal("live"), v.literal("archive"));

export const axisStatistics = v.object({
  minimum: v.number(), maximum: v.number(), mean: v.number(),
  standardDeviation: v.number(), rms: v.number(), sampleCount: v.number(),
});

/** A GPS sample, in DriVio's LocationSample shape. */
export const streamPoint = v.object({
  t: v.number(), latitude: v.number(), longitude: v.number(),
  speedMps: v.number(), headingDegrees: v.number(), accuracyMeters: v.number(),
  altitudeMeters: v.optional(v.number()), speedAccuracyMps: v.optional(v.number()),
  headingAccuracyDegrees: v.optional(v.number()), isMocked: v.boolean(),
});
export type StreamPoint = Infer<typeof streamPoint>;

/** A one-second motion frame, in DriVio's MotionFrame shape. */
export const streamFrame = v.object({
  t: v.number(), durationMillis: v.number(),
  longitudinalAcceleration: axisStatistics, lateralAcceleration: axisStatistics,
  verticalAcceleration: axisStatistics, yawRate: axisStatistics,
  pitchRate: axisStatistics, rollRate: axisStatistics,
  phoneStability: v.number(), axisMappingCalibrated: v.boolean(),
});
export type StreamFrame = Infer<typeof streamFrame>;

/** A driving event candidate. */
export const streamEvent = v.object({
  t: v.number(), endedAt: v.number(), eventId: v.string(),
  eventType: v.union(v.string(), v.number()), confidence: v.number(),
  minimumValue: v.number(), maximumValue: v.number(), meanValue: v.number(),
  latitude: v.optional(v.number()), longitude: v.optional(v.number()),
  speedBeforeMps: v.optional(v.number()), speedAfterMps: v.optional(v.number()),
  effectiveSpeedLimitKph: v.optional(v.number()),
});
export type StreamEvent = Infer<typeof streamEvent>;

/** Silence after which an active stream has a gap. */
export const gapThresholdMs = 60_000;
/** How long backfill keeps trying to fill a gap from archives. */
export const backfillDeadlineMs = 48 * 60 * 60_000;
/** Longest window one gap covers when the stream never resumed. */
export const maxOpenGapMs = 12 * 60 * 60_000;
