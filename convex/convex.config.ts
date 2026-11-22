import batchedReplay from "@convex-dev/batched-replay/convex.config.js";
import geospatial from "@convex-dev/geospatial/convex.config.js";
import { defineApp } from "convex/server";
import taxiXpress from "../apps/taxi-xpress/convex/convex.config";

/**
 * DriVio's telemetry deployment. The root app holds telemetry for every app:
 * archived chunks, nearby search, replay, and the live stream with its backfill.
 * Applications are mounted as components for their own live logic.
 */
const app = defineApp();
app.use(geospatial);
app.use(batchedReplay);
app.use(taxiXpress);

export default app;
