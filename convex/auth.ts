import { convexAuth } from "@convex-dev/auth/server";
import { components } from "./_generated/api";
import type { MutationCtx } from "./_generated/server";
import type { Id } from "./_generated/dataModel";
import { appForProvider } from "./identity";
import { taxiXpressPhone } from "../apps/taxi-xpress/host/auth";

/**
 * Convex Auth for every application on the shared deployment. Each application
 * brings its own sign-in providers; accounts are never linked across
 * applications, so the same phone number gives separate users per application.
 */
export const { auth, signIn, signOut, store, isAuthenticated } = convexAuth({
  providers: [taxiXpressPhone(components.taxiXpress)],
  jwt: { durationMs: 60 * 60 * 1000 },
  callbacks: {
    async createOrUpdateUser(ctx: MutationCtx, args) {
      const verified = args.profile.phoneVerified || args.type === "verification";
      if (args.existingUserId !== null) {
        const existing = args.existingUserId as Id<"users">;
        if (verified) await ctx.db.patch(existing, { phoneVerificationTime: Date.now() });
        return existing;
      }
      const provider = appForProvider(args.provider.id);
      if (!provider) throw new Error(`Provider ${args.provider.id} belongs to no application`);
      await provider.beforeCreateUser(ctx, args.profile.phone);
      return ctx.db.insert("users", {
        app: provider.app,
        phone: typeof args.profile.phone === "string" ? args.profile.phone : undefined,
        ...(verified ? { phoneVerificationTime: Date.now() } : {}),
      });
    },
  },
});
