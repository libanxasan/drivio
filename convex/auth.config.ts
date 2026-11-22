import type { AuthConfig } from "convex/server";

const issuer = process.env.DRIVIO_AUTH_ISSUER;
const algorithm = process.env.DRIVIO_AUTH_ALGORITHM ?? "ES256";
if (algorithm !== "ES256" && algorithm !== "RS256") {
  throw new Error("DRIVIO_AUTH_ALGORITHM must be ES256 or RS256");
}

type Provider = AuthConfig["providers"][number];

const core: Provider[] = issuer
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
  : [];

// Convex Auth (applications on this deployment) plus DriVio core tokens.
export default {
  providers: [
    { domain: process.env.CONVEX_SITE_URL!, applicationID: "convex" },
    ...core,
  ],
} satisfies AuthConfig;
