import { components } from "./_generated/api";
import { exposeTaxiXpress } from "../apps/taxi-xpress/host";

// Live-tracking functions of the Taxi Xpress driver app, called as taxiXpress:<name>.
export const { begin, publish, heartbeat, end, mine } = exposeTaxiXpress(components.taxiXpress);
