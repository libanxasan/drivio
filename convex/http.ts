import { httpRouter } from "convex/server";
import { apps } from "./apps";

const http = httpRouter();

for (const app of apps) {
  for (const route of app.routes) {
    http.route({ path: route.path, method: "POST", handler: route.handler });
  }
}

export default http;
