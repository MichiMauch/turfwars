import { Hono } from "hono";
import { db } from "../db";
import { users } from "../db/schema";
import { eq } from "drizzle-orm";
import { authMiddleware, type AuthUser } from "../middleware/auth";
import { randomUUID } from "crypto";

const auth = new Hono();

// POST /auth/login - Create or update user after Google Sign-In
auth.post("/login", authMiddleware, async (c) => {
  const firebaseUser = c.get("user") as AuthUser;

  // Check if user already exists
  const existing = await db
    .select()
    .from(users)
    .where(eq(users.googleId, firebaseUser.uid))
    .get();

  if (existing) {
    // Update display name and avatar if changed
    await db
      .update(users)
      .set({
        displayName: firebaseUser.name || existing.displayName,
        avatarUrl: firebaseUser.picture || existing.avatarUrl,
      })
      .where(eq(users.id, existing.id));

    return c.json({ user: existing });
  }

  // Create new user
  const newUser = {
    id: randomUUID(),
    googleId: firebaseUser.uid,
    displayName: firebaseUser.name || "Anonymous",
    avatarUrl: firebaseUser.picture || null,
  };

  await db.insert(users).values(newUser);

  return c.json({ user: newUser }, 201);
});

// GET /auth/me - Get current user profile
auth.get("/me", authMiddleware, async (c) => {
  const firebaseUser = c.get("user") as AuthUser;

  const user = await db
    .select()
    .from(users)
    .where(eq(users.googleId, firebaseUser.uid))
    .get();

  if (!user) {
    return c.json({ error: "User not found" }, 404);
  }

  return c.json({ user });
});

export default auth;
