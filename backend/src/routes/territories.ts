import { Hono } from "hono";
import { db } from "../db";
import { territories, users, adminRegions, rankings } from "../db/schema";
import { eq, and, sql } from "drizzle-orm";
import { authMiddleware, type AuthUser } from "../middleware/auth";
import {
  createTerritoryPolygon,
  findOverlaps,
  findContainingRegion,
} from "../services/geo";
import { randomUUID } from "crypto";
import { broadcastTerritoryUpdate } from "../services/websocket";
import type { Position } from "geojson";

const territoriesRouter = new Hono();

// POST /territories/claim - Claim a new territory from GPS track
territoriesRouter.post("/claim", authMiddleware, async (c) => {
  const firebaseUser = c.get("user") as AuthUser;

  // Find internal user
  const user = await db
    .select()
    .from(users)
    .where(eq(users.googleId, firebaseUser.uid))
    .get();

  if (!user) {
    return c.json({ error: "User not found. Please login first." }, 404);
  }

  const body = await c.req.json<{ coordinates: Position[] }>();

  if (!body.coordinates || body.coordinates.length < 4) {
    return c.json({ error: "Need at least 4 GPS points" }, 400);
  }

  // Create and validate polygon
  const result = createTerritoryPolygon(body.coordinates);
  if (!result) {
    return c.json(
      {
        error:
          "Invalid territory. Either the loop is not closed (>20m), area is too small (<100m²), or the shape is invalid.",
      },
      400
    );
  }

  const polygonJson = JSON.stringify(result.polygon);

  // Find admin regions for this territory
  const allRegions = await db.select().from(adminRegions).all();

  const municipalityRegions = allRegions.filter(
    (r) => r.level === "municipality"
  );
  const districtRegions = allRegions.filter((r) => r.level === "district");
  const cantonRegions = allRegions.filter((r) => r.level === "canton");
  const countryRegions = allRegions.filter((r) => r.level === "country");

  const municipalityId = findContainingRegion(
    result.polygon,
    municipalityRegions.map((r) => ({
      id: r.id,
      boundaryGeojson: r.boundaryGeojson || "",
    }))
  );
  const districtId = findContainingRegion(
    result.polygon,
    districtRegions.map((r) => ({
      id: r.id,
      boundaryGeojson: r.boundaryGeojson || "",
    }))
  );
  const cantonId = findContainingRegion(
    result.polygon,
    cantonRegions.map((r) => ({
      id: r.id,
      boundaryGeojson: r.boundaryGeojson || "",
    }))
  );
  const countryId = findContainingRegion(
    result.polygon,
    countryRegions.map((r) => ({
      id: r.id,
      boundaryGeojson: r.boundaryGeojson || "",
    }))
  );

  // Find overlapping territories from other users
  const existingTerritories = await db
    .select()
    .from(territories)
    .where(eq(territories.active, true))
    .all();

  const overlaps = findOverlaps(
    result.polygon,
    existingTerritories.map((t) => ({ id: t.id, polygonGeojson: t.polygonGeojson }))
  );

  // Deactivate fully contained territories
  for (const id of overlaps.fullyContained) {
    await db
      .update(territories)
      .set({ active: false })
      .where(eq(territories.id, id));
  }

  // Update partially overlapping territories
  for (const partial of overlaps.partialOverlaps) {
    const newArea = (await import("@turf/turf")).area(partial.remainingPolygon);
    await db
      .update(territories)
      .set({
        polygonGeojson: JSON.stringify(partial.remainingPolygon),
        areaSqm: newArea,
      })
      .where(eq(territories.id, partial.id));
  }

  // Create new territory
  const newTerritory = {
    id: randomUUID(),
    userId: user.id,
    polygonGeojson: polygonJson,
    areaSqm: result.areaSqm,
    municipalityId,
    districtId,
    cantonId,
    countryId,
    active: true,
  };

  await db.insert(territories).values(newTerritory);

  // Update rankings for all affected regions
  const regionIds = [municipalityId, districtId, cantonId, countryId].filter(
    Boolean
  ) as string[];
  await updateRankings(user.id, regionIds);

  // Also update rankings for users whose territories were affected
  const affectedUserIds = new Set<string>();
  for (const id of overlaps.fullyContained) {
    const t = existingTerritories.find((t) => t.id === id);
    if (t && t.userId !== user.id) affectedUserIds.add(t.userId);
  }
  for (const partial of overlaps.partialOverlaps) {
    const t = existingTerritories.find((t) => t.id === partial.id);
    if (t && t.userId !== user.id) affectedUserIds.add(t.userId);
  }
  for (const uid of affectedUserIds) {
    await updateRankings(uid, regionIds);
  }

  // Broadcast update to all connected clients
  broadcastTerritoryUpdate({
    type: "territory_claimed",
    territory: newTerritory,
    deactivated: overlaps.fullyContained,
    updated: overlaps.partialOverlaps.map((p) => p.id),
  });

  return c.json(
    {
      territory: newTerritory,
      overlaps: {
        taken: overlaps.fullyContained.length,
        trimmed: overlaps.partialOverlaps.length,
      },
    },
    201
  );
});

// GET /territories - Get all active territories (optionally filtered by region)
territoriesRouter.get("/", async (c) => {
  const regionId = c.req.query("region_id");
  const bounds = c.req.query("bounds"); // "minLng,minLat,maxLng,maxLat"

  let query = db
    .select({
      id: territories.id,
      userId: territories.userId,
      polygonGeojson: territories.polygonGeojson,
      areaSqm: territories.areaSqm,
      displayName: users.displayName,
      avatarUrl: users.avatarUrl,
      createdAt: territories.createdAt,
    })
    .from(territories)
    .innerJoin(users, eq(territories.userId, users.id))
    .where(eq(territories.active, true));

  const results = await query.all();

  return c.json({ territories: results });
});

// GET /territories/mine - Get current user's territories
territoriesRouter.get("/mine", authMiddleware, async (c) => {
  const firebaseUser = c.get("user") as AuthUser;
  const user = await db
    .select()
    .from(users)
    .where(eq(users.googleId, firebaseUser.uid))
    .get();

  if (!user) return c.json({ error: "User not found" }, 404);

  const myTerritories = await db
    .select()
    .from(territories)
    .where(and(eq(territories.userId, user.id), eq(territories.active, true)))
    .all();

  return c.json({ territories: myTerritories });
});

async function updateRankings(userId: string, regionIds: string[]) {
  for (const regionId of regionIds) {
    // Calculate total area for this user in this region
    const userTerritories = await db
      .select()
      .from(territories)
      .where(
        and(
          eq(territories.userId, userId),
          eq(territories.active, true),
          sql`(${territories.municipalityId} = ${regionId} OR ${territories.districtId} = ${regionId} OR ${territories.cantonId} = ${regionId} OR ${territories.countryId} = ${regionId})`
        )
      )
      .all();

    const totalArea = userTerritories.reduce((sum, t) => sum + t.areaSqm, 0);

    // Upsert ranking
    const existingRanking = await db
      .select()
      .from(rankings)
      .where(
        and(eq(rankings.userId, userId), eq(rankings.regionId, regionId))
      )
      .get();

    if (existingRanking) {
      await db
        .update(rankings)
        .set({ totalAreaSqm: totalArea, updatedAt: new Date() })
        .where(eq(rankings.id, existingRanking.id));
    } else {
      await db.insert(rankings).values({
        id: randomUUID(),
        userId,
        regionId,
        totalAreaSqm: totalArea,
      });
    }

    // Recalculate ranks for this region
    await db.run(sql`
      UPDATE rankings
      SET rank = (
        SELECT COUNT(*) + 1
        FROM rankings r2
        WHERE r2.region_id = rankings.region_id
          AND r2.total_area_sqm > rankings.total_area_sqm
      )
      WHERE region_id = ${regionId}
    `);
  }
}

export default territoriesRouter;
