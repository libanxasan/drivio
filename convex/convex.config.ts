import batchedReplay from "@convex-dev/batched-replay/convex.config.js";
import geospatial from "@convex-dev/geospatial/convex.config.js";
import { defineApp } from "convex/server";
import taxiXpress from "../apps/taxi-xpress/convex/convex.config";

/**
 * DriVio core is the root app of the shared deployment. Each application built
 * on DriVio is mounted as its own component (see convex/apps.ts), with its own
 * tables and jobs, and reuses the core telemetry archive.
 */
const app = defineApp();
app.use(geospatial);
app.use(batchedReplay);
app.use(taxiXpress);

export default app;
