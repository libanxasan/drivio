import { components } from "./_generated/api";
import { exposeTaxiXpress, taxiXpressApp } from "../apps/taxi-xpress/host";
import { endStream, recordLive } from "./streams";

// Live-tracking functions of the Taxi Xpress driver app, called as taxiXpress:<name>.
// Accepted positions also go to DriVio's telemetry stream (session = stream), so
// gaps can be backfilled from the Taxi Xpress archive on Neon.
export const { begin, publish, heartbeat, end, mine } = exposeTaxiXpress(components.taxiXpress, {
  onPosition: (ctx, caller, sessionId, point) => recordLive(ctx, {
    app: taxiXpressApp, owner: caller.owner, streamId: sessionId, kinds: ["points"],
    points: [{
      t: point.capturedAt, latitude: point.latitude, longitude: point.longitude,
      speedMps: point.speedMps, headingDegrees: point.headingDegrees,
      accuracyMeters: point.accuracyMeters, isMocked: point.isMocked,
    }],
  }).then(() => undefined),
  onSessionEnded: (ctx, caller, sessionId) => endStream(ctx, caller.owner, sessionId),
});
