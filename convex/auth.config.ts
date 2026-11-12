import type { AuthConfig } from "convex/server";

const issuer = process.env.DRIVIO_AUTH_ISSUER;
const algorithm = process.env.DRIVIO_AUTH_ALGORITHM ?? "ES256";
if (algorithm !== "ES256" && algorithm !== "RS256") {
  throw new Error("DRIVIO_AUTH_ALGORITHM must be ES256 or RS256");
}

export default {
  providers: issuer
    ? [
        {
          type: "customJwt",
          issuer,
          algorithm,
          applicationID: process.env.DRIVIO_AUTH_AUDIENCE ?? "authenticated",
          jwks:
            process.env.DRIVIO_AUTH_JWKS ??
            `${issuer.replace(/\/$/, "")}/.well-known/jwks.json`,
        },
      ]
    : [],
} satisfies AuthConfig;
