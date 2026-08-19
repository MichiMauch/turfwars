import { Hono } from "hono";
import { db } from "../db";
import {
  territories,
  territoryRegions,
  rankings,
  users,
} from "../db/schema";
import { eq, and, or, sql, gte, lte, isNull, inArray } from "drizzle-orm";
import {
  authMiddleware,
  devAdminMiddleware,
  type AppEnv,
} from "../middleware/auth";
import { claimTerritory, type WalkStats } from "../services/claim";
import { loadRegionCache } from "../services/geo";
import type { Position } from "geojson";

const territoriesRouter = new Hono<AppEnv>();

// POST /territories/claim - Claim a new territory from GPS track
territoriesRouter.post("/claim", authMiddleware, async (c) => {
  const googleUser = c.get("user");

  // Find internal user
  const user = await db
    .select()
    .from(users)
    .where(eq(users.googleId, googleUser.uid))
    .get();

  if (!user) {
    return c.json({ error: "User not found. Please login first." }, 404);
  }

  const body = await c.req.json<{
    coordinates: Position[];
    walkStats?: WalkStats;
  }>();

  if (!body.coordinates || body.coordinates.length < 4) {
    return c.json({ error: "Need at least 4 GPS points" }, 400);
  }

  const result = await claimTerritory(user.id, body.coordinates, body.walkStats);

  if (!result.ok) {
    return c.json({ error: result.error }, result.status);
  }

  return c.json(
    { territory: result.territory, overlaps: result.overlaps },
    201
  );
});

/**
 * Parse a "minLng,minLat,maxLng,maxLat" query value. Returns null when the
 * parameter was absent and "invalid" when it was present but unusable — a
 * malformed box must not quietly widen back out to the whole world, which is
 * exactly what this route used to do.
 */
function parseBounds(raw: string | undefined) {
  if (raw === undefined) return null;

  const parts = raw.split(",").map(Number);
  if (parts.length !== 4 || !parts.every(Number.isFinite)) return "invalid";

  const [minLng, minLat, maxLng, maxLat] = parts as [
    number,
    number,
    number,
    number
  ];
  if (minLng > maxLng || minLat > maxLat) return "invalid";

  return { minLng, minLat, maxLng, maxLat };
}

// GET /territories - Active territories in a viewport and/or a region
territoriesRouter.get("/", async (c) => {
  const regionId = c.req.query("region_id");
  const bounds = parseBounds(c.req.query("bounds"));

  if (bounds === "invalid") {
    return c.json(
      { error: "bounds must be minLng,minLat,maxLng,maxLat" },
      400
    );
  }

  const filters = [eq(territories.active, true)];

  if (bounds) {
    filters.push(
      or(
        // Rows written before the box columns existed keep null until the
        // backfill has run. Showing them is the lesser evil: a territory
        // missing from the map reads as data loss, an extra one off-screen
        // only costs a little payload.
        isNull(territories.minLng),
        and(
          lte(territories.minLng, bounds.maxLng),
          gte(territories.maxLng, bounds.minLng),
          lte(territories.minLat, bounds.maxLat),
          gte(territories.maxLat, bounds.minLat)
        )
      )!
    );
  }

  if (regionId) {
    // A subquery rather than a join: a territory has one territory_regions row
    // per level, so joining would risk handing the same territory back twice.
    filters.push(
      inArray(
        territories.id,
        db
          .select({ id: territoryRegions.territoryId })
          .from(territoryRegions)
          .where(eq(territoryRegions.regionId, regionId))
      )
    );
  }

  const query = db
    .select({
      id: territories.id,
      userId: territories.userId,
      polygonGeojson: territories.polygonGeojson,
      areaSqm: territories.areaSqm,
      distanceM: territories.distanceM,
      durationSec: territories.durationSec,
      avgSpeedKmh: territories.avgSpeedKmh,
      maxSpeedKmh: territories.maxSpeedKmh,
      trackPointCount: territories.trackPointCount,
      trackGeojson: territories.trackGeojson,
      displayName: users.displayName,
      avatarUrl: users.avatarUrl,
      color: users.color,
      createdAt: territories.createdAt,
    })
    .from(territories)
    .innerJoin(users, eq(territories.userId, users.id))
    .where(and(...filters));

  const results = await query.all();

  return c.json({ territories: results });
});

// GET /territories/stats - Holdings of the current user, per region
territoriesRouter.get("/stats", authMiddleware, async (c) => {
  const googleUser = c.get("user");
  const user = await db
    .select()
    .from(users)
    .where(eq(users.googleId, googleUser.uid))
    .get();

  if (!user) return c.json({ error: "User not found" }, 404);

  const mine = await db
    .select()
    .from(territories)
    .where(and(eq(territories.userId, user.id), eq(territories.active, true)))
    .all();

  const shares = await db
    .select({
      regionId: territoryRegions.regionId,
      level: territoryRegions.level,
      areaSqm: sql<number>`sum(${territoryRegions.areaSqm})`,
    })
    .from(territoryRegions)
    .innerJoin(territories, eq(territories.id, territoryRegions.territoryId))
    .where(and(eq(territories.userId, user.id), eq(territories.active, true)))
    .groupBy(territoryRegions.regionId, territoryRegions.level)
    .all();

  const regionById = new Map(
    (await loadRegionCache()).map((r) => [r.id, r])
  );

  const myRankings = await db
    .select()
    .from(rankings)
    .where(eq(rankings.userId, user.id))
    .all();
  const rankByRegion = new Map(myRankings.map((r) => [r.regionId, r.rank]));

  const regions = shares
    .map((share) => {
      const region = regionById.get(share.regionId);
      return {
        id: share.regionId,
        name: region?.name ?? share.regionId,
        level: share.level,
        areaSqm: share.areaSqm,
        regionAreaSqm: region?.areaSqm ?? null,
        sharePercent: region ? (share.areaSqm / region.areaSqm) * 100 : null,
        rank: rankByRegion.get(share.regionId) ?? null,
      };
    })
    .sort((a, b) => b.areaSqm - a.areaSqm);

  // Nach Fläche gewichtet — ein grosser Walk prägt den Schnitt stärker als
  // eine kurze Runde. Gebiete ohne Messwert bleiben aussen vor.
  const measured = mine.filter((t) => t.pathSharePercent !== null);
  const measuredArea = measured.reduce((sum, t) => sum + t.areaSqm, 0);
  const pathSharePercent =
    measuredArea > 0
      ? measured.reduce(
          (sum, t) => sum + t.pathSharePercent! * t.areaSqm,
          0
        ) / measuredArea
      : null;

  return c.json({
    pathSharePercent,
    territoryCount: mine.length,
    totalAreaSqm: mine.reduce((sum, t) => sum + t.areaSqm, 0),
    largestAreaSqm: mine.reduce((max, t) => Math.max(max, t.areaSqm), 0),
    totalDistanceM: mine.reduce((sum, t) => sum + (t.distanceM ?? 0), 0),
    totalDurationSec: mine.reduce((sum, t) => sum + (t.durationSec ?? 0), 0),
    regions,
  });
});

// GET /territories/mine - Get current user's territories
territoriesRouter.get("/mine", authMiddleware, async (c) => {
  const googleUser = c.get("user");
  const user = await db
    .select()
    .from(users)
    .where(eq(users.googleId, googleUser.uid))
    .get();

  if (!user) return c.json({ error: "User not found" }, 404);

  const myTerritories = await db
    .select()
    .from(territories)
    .where(and(eq(territories.userId, user.id), eq(territories.active, true)))
    .all();

  return c.json({ territories: myTerritories });
});

// DEV ONLY: Claim a territory in another user's name (for testing scenarios).
// Runs through the same pipeline as a real claim, so overlaps, region
// assignment and rankings behave exactly as they would for that user.
territoriesRouter.post("/dev/place", devAdminMiddleware, async (c) => {
  const body = await c.req.json<{
    userId: string;
    coordinates: Position[];
    walkStats?: WalkStats;
  }>();

  if (!body.userId || !body.coordinates || body.coordinates.length < 4) {
    return c.json({ error: "Need userId and at least 4 coordinates" }, 400);
  }

  // Verify user exists
  const user = await db
    .select()
    .from(users)
    .where(eq(users.id, body.userId))
    .get();

  if (!user) {
    return c.json({ error: "User not found" }, 404);
  }

  const result = await claimTerritory(
    body.userId,
    body.coordinates,
    body.walkStats,
    { skipPlausibility: true }
  );

  if (!result.ok) {
    return c.json({ error: result.error }, result.status);
  }

  return c.json(
    {
      territory: result.territory,
      overlaps: result.overlaps,
      user: user.displayName,
    },
    201
  );
});

// DEV ONLY: List all users
territoriesRouter.get("/dev/users", devAdminMiddleware, async (c) => {
  const allUsers = await db
    .select({
      id: users.id,
      displayName: users.displayName,
      avatarUrl: users.avatarUrl,
    })
    .from(users)
    .all();
  return c.json({ users: allUsers });
});

export default territoriesRouter;
