import { Hono } from "hono";
import { db } from "../db";
import { rankings, users, adminRegions } from "../db/schema";
import { eq, desc } from "drizzle-orm";
import { locateMunicipality } from "../services/geo";

const rankingsRouter = new Hono();

// GET /rankings/regions/locate?lat=...&lng=... - Locate municipality for a GPS point
rankingsRouter.get("/regions/locate", async (c) => {
  const lat = parseFloat(c.req.query("lat") || "0");
  const lng = parseFloat(c.req.query("lng") || "0");

  if (lat === 0 && lng === 0) {
    return c.json({ municipality: null });
  }

  const municipality = await locateMunicipality(lat, lng);
  return c.json({ municipality });
});

// GET /rankings/:regionId - Get rankings for a specific region
rankingsRouter.get("/:regionId", async (c) => {
  const regionId = c.req.param("regionId");
  const limit = parseInt(c.req.query("limit") || "50");

  const results = await db
    .select({
      rank: rankings.rank,
      userId: rankings.userId,
      displayName: users.displayName,
      avatarUrl: users.avatarUrl,
      totalAreaSqm: rankings.totalAreaSqm,
    })
    .from(rankings)
    .innerJoin(users, eq(rankings.userId, users.id))
    .where(eq(rankings.regionId, regionId))
    .orderBy(desc(rankings.totalAreaSqm))
    .limit(limit)
    .all();

  return c.json({ rankings: results });
});

// GET /rankings/regions/nearby?lat=...&lng=... - Get admin regions near a point
rankingsRouter.get("/regions/nearby", async (c) => {
  const lat = parseFloat(c.req.query("lat") || "0");
  const lng = parseFloat(c.req.query("lng") || "0");

  // For MVP: return all regions (later: spatial query)
  const regions = await db
    .select({
      id: adminRegions.id,
      name: adminRegions.name,
      level: adminRegions.level,
      parentId: adminRegions.parentId,
    })
    .from(adminRegions)
    .all();

  return c.json({ regions });
});

export default rankingsRouter;
