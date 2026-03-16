import { Context, Next } from "hono";

export interface AuthUser {
  uid: string;
  email?: string;
  name?: string;
  picture?: string;
}

interface GoogleTokenInfo {
  sub: string;
  email?: string;
  name?: string;
  picture?: string;
  aud: string;
  exp: string;
}

/**
 * Verify Google ID token via Google's tokeninfo endpoint
 */
async function verifyGoogleIdToken(idToken: string): Promise<AuthUser | null> {
  const response = await fetch(
    `https://oauth2.googleapis.com/tokeninfo?id_token=${idToken}`
  );

  if (!response.ok) return null;

  const data = (await response.json()) as GoogleTokenInfo;

  // Verify audience matches our client ID
  const clientId = process.env.GOOGLE_CLIENT_ID;
  if (clientId && data.aud !== clientId) return null;

  // Check expiration
  if (parseInt(data.exp) * 1000 < Date.now()) return null;

  return {
    uid: data.sub,
    email: data.email,
    name: data.name,
    picture: data.picture,
  };
}

/**
 * Middleware that verifies Google ID token from Authorization header
 */
export async function authMiddleware(c: Context, next: Next) {
  const authHeader = c.req.header("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return c.json({ error: "Missing or invalid authorization header" }, 401);
  }

  const token = authHeader.slice(7);

  const user = await verifyGoogleIdToken(token);
  if (!user) {
    return c.json({ error: "Invalid token" }, 401);
  }

  c.set("user", user);
  await next();
}
