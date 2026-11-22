import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();
crons.interval("detect silent streams", { minutes: 1 }, internal.streams.detectSilence);
crons.interval("backfill stream gaps from archives", { minutes: 5 }, internal.backfill.run);
crons.interval("delete telemetry older than ARCHIVE_PERIOD", { hours: 1 }, internal.retention.purge);
export default crons;
