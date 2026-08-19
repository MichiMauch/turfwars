import { Context, Next } from "hono";

export interface AuthUser {
  uid: string;
  email?: string;
  name?: string;
  picture?: string;
}

/**
 * Context shape for routers behind the auth middleware, so `c.get("user")`
 * is typed instead of `never`.
 */
export type AppEnv = { Variables: { user: AuthUser } };

interface GoogleTokenInfo {
  sub: string;
  email?: string;
  name?: string;
  picture?: string;
  aud: string;
  exp: string;
}

function googleClientId(): string | undefined {
  return process.env.GOOGLE_CLIENT_ID?.trim() || undefined;
}

/**
 * Verify the auth configuration on startup. Read lazily rather than at module
 * load so the check doesn't depend on dotenv running before this import.
 */
export function assertAuthConfig() {
  if (!googleClientId()) {
    throw new Error(
      "GOOGLE_CLIENT_ID is not set. Without it the audience of an ID token " +
        "cannot be verified, so tokens issued for any other Google app would " +
        "be accepted. Refusing to start."
    );
  }
}

/**
 * Verify Google ID token via Google's tokeninfo endpoint
 */
async function verifyGoogleIdToken(idToken: string): Promise<AuthUser | null> {
  // Fail closed: without a client ID the audience cannot be checked
  const clientId = googleClientId();
  if (!clientId) return null;

  const response = await fetch(
    `https://oauth2.googleapis.com/tokeninfo?id_token=${idToken}`
  );

  if (!response.ok) return null;

  const data = (await response.json()) as GoogleTokenInfo;

  // Verify audience matches our client ID
  if (data.aud !== clientId) return null;

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
 * Extract and verify the Google ID token from the Authorization header.
 * Returns the user, or an error response to send back.
 */
async function authenticate(
  c: Context
): Promise<{ user: AuthUser } | { error: Response }> {
  const authHeader = c.req.header("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return {
      error: c.json({ error: "Missing or invalid authorization header" }, 401),
    };
  }

  const user = await verifyGoogleIdToken(authHeader.slice(7));
  if (!user) {
    return { error: c.json({ error: "Invalid token" }, 401) };
  }

  return { user };
}

/**
 * Middleware that verifies Google ID token from Authorization header
 */
export async function authMiddleware(c: Context, next: Next) {
  const result = await authenticate(c);
  if ("error" in result) return result.error;

  c.set("user", result.user);
  await next();
}

/**
 * Accounts allowed to use the dev endpoints. Comma-separated list of
 * emails and/or Google account IDs (the token's `sub`) in DEV_ADMIN_ACCOUNTS.
 */
function devAdminAccounts(): string[] {
  return (process.env.DEV_ADMIN_ACCOUNTS || "")
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean);
}

/**
 * Middleware for the dev/testing endpoints. Requires a valid Google ID token
 * from an account listed in DEV_ADMIN_ACCOUNTS. If that variable is unset,
 * the endpoints behave as if they don't exist.
 */
/**
 * Whether this account may use the dev endpoints and see the dev tools.
 *
 * One place decides that, so the app cannot end up showing buttons for
 * endpoints the server would refuse — or hiding ones it would allow.
 */
export function isDevAdmin(user: AuthUser): boolean {
  const allowlist = devAdminAccounts();
  if (allowlist.length === 0) return false;

  return (
    allowlist.includes(user.uid.toLowerCase()) ||
    (!!user.email && allowlist.includes(user.email.toLowerCase()))
  );
}

export async function devAdminMiddleware(c: Context, next: Next) {
  // Without an allowlist the endpoints behave as if they do not exist, which
  // is checked before authenticating so their existence is not leaked.
  if (devAdminAccounts().length === 0) {
    return c.json({ error: "Not found" }, 404);
  }

  const result = await authenticate(c);
  if ("error" in result) return result.error;

  const { user } = result;

  if (!isDevAdmin(user)) {
    return c.json({ error: "Dev endpoints are restricted" }, 403);
  }

  c.set("user", user);
  await next();
}
