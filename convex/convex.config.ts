import { defineApp } from "convex/server";
import taxiXpress from "../apps/taxi-xpress/convex/convex.config";

/**
 * The shared DriVio deployment holds live data only: each application built on
 * DriVio is mounted as its own component (see convex/apps.ts). Long-term data
 * (users, profiles, approvals, trip archives) lives in Neon.
 */
const app = defineApp();
app.use(taxiXpress);

export default app;
