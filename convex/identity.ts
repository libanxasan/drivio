import { getAuthUserId } from "@convex-dev/auth/server";
import type { UserIdentity } from "convex/server";
import { internalQuery } from "./_generated/server";
import type { QueryCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { v } from "convex/values";
import { components } from "./_generated/api";
import {
  taxiXpressApp, taxiXpressBeforeCreateUser, taxiXpressPhoneProviderId,
} from "../apps/taxi-xpress/host/auth";

type BeforeCreateUser = (ctx: { runQuery: QueryCtx["runQuery"] }, phone: unknown) => Promise<void>;

/**
 * Sign-in providers of each application mounted on the deployment, with the
 * check that runs before the application's first user record is created.
 */
const providerApps: Record<string, { app: string; beforeCreateUser: BeforeCreateUser }> = {
  [taxiXpressPhoneProviderId]: {
    app: taxiXpressApp,
    beforeCreateUser: taxiXpressBeforeCreateUser(components.taxiXpress),
  },
};

export function appForProvider(providerId: string) {
  return providerApps[providerId];
}

const convexAuthIssuer = () => process.env.CONVEX_SITE_URL?.replace(/\/$/, "");

/**
 * The stable owner of an identity's data. Convex Auth subjects are
 * "<userId>|<sessionId>", so their owner is the user, not the session;
 * other providers keep their token identifier.
 */
export function principal(identity: UserIdentity) {
  if (identity.issuer.replace(/\/$/, "") === convexAuthIssuer()) {
    const userId = identity.subject.split("|")[0];
    return { owner: `${identity.issuer}|${userId}`, subject: userId, userId };
  }
  return { owner: identity.tokenIdentifier, subject: identity.subject, userId: null };
}

export const appOfUser = internalQuery({
  args: { userId: v.string() },
  returns: v.union(v.string(), v.null()),
  handler: async (ctx, { userId }) => {
    const id = ctx.db.normalizeId("users", userId);
    return id ? (await ctx.db.get(id))?.app ?? null : null;
  },
});

/** The signed-in user of `app` in a query or mutation, or null. */
export function identifyAppUser(app: string) {
  return async (ctx: QueryCtx) => {
    const userId = await getAuthUserId(ctx);
    if (!userId) return null;
    const user = await ctx.db.get(userId as Id<"users">);
    if (user?.app !== app) return null;
    const identity = (await ctx.auth.getUserIdentity())!;
    const { owner } = principal(identity);
    return { owner, subject: userId };
  };
}
