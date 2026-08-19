import { Hono } from "hono";
import { db } from "../db";
import { users } from "../db/schema";
import { eq } from "drizzle-orm";
import { authMiddleware, type AppEnv } from "../middleware/auth";
import { randomUUID } from "crypto";
import {
  PLAYER_COLORS,
  defaultColorFor,
  isPlayerColor,
} from "../services/colors";

const auth = new Hono<AppEnv>();

// POST /auth/login - Create or update user after Google Sign-In
auth.post("/login", authMiddleware, async (c) => {
  const googleUser = c.get("user");

  // Check if user already exists
  const existing = await db
    .select()
    .from(users)
    .where(eq(users.googleId, googleUser.uid))
    .get();

  if (existing) {
    const updated = {
      ...existing,
      displayName: googleUser.name || existing.displayName,
      avatarUrl: googleUser.picture || existing.avatarUrl,
      // A player from before colours existed gets one on their next login, so
      // the map can tell them apart without waiting for the backfill script.
      color: existing.color ?? defaultColorFor(existing.id),
    };

    await db
      .update(users)
      .set({
        displayName: updated.displayName,
        avatarUrl: updated.avatarUrl,
        color: updated.color,
      })
      .where(eq(users.id, existing.id));

    // The updated row, not the one that was read — the client shows exactly
    // this, and handing back the stale name and avatar meant they only caught
    // up one login later.
    return c.json({ user: updated });
  }

  // Create new user
  const id = randomUUID();
  const newUser = {
    id,
    googleId: googleUser.uid,
    displayName: googleUser.name || "Anonymous",
    avatarUrl: googleUser.picture || null,
    color: defaultColorFor(id),
  };

  await db.insert(users).values(newUser);

  return c.json({ user: newUser }, 201);
});

// GET /auth/colors - The colours a player may choose from
auth.get("/colors", (c) => c.json({ colors: PLAYER_COLORS }));

// PATCH /auth/me - Change your own colour
auth.patch("/me", authMiddleware, async (c) => {
  const googleUser = c.get("user");

  const body: { color?: unknown } = await c.req
    .json<{ color?: unknown }>()
    .catch(() => ({}));
  // The server is the only authority on what is valid. A free colour would put
  // shades on the map that nobody can read, and two players on the same one.
  if (!isPlayerColor(body.color)) {
    return c.json({ error: "Unknown colour" }, 400);
  }

  const user = await db
    .select()
    .from(users)
    .where(eq(users.googleId, googleUser.uid))
    .get();

  if (!user) return c.json({ error: "User not found" }, 404);

  await db
    .update(users)
    .set({ color: body.color })
    .where(eq(users.id, user.id));

  return c.json({ user: { ...user, color: body.color } });
});

// GET /auth/me - Get current user profile
auth.get("/me", authMiddleware, async (c) => {
  const googleUser = c.get("user");

  const user = await db
    .select()
    .from(users)
    .where(eq(users.googleId, googleUser.uid))
    .get();

  if (!user) {
    return c.json({ error: "User not found" }, 404);
  }

  return c.json({ user });
});

export default auth;
