import batchedReplay from "@convex-dev/batched-replay/convex.config.js";
import geospatial from "@convex-dev/geospatial/convex.config.js";
import { defineApp } from "convex/server";

const app = defineApp();
app.use(geospatial);
app.use(batchedReplay);

export default app;
