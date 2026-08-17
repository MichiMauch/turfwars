import { area } from "@turf/turf";
import { randomUUID } from "crypto";
import { eq, and, inArray, sql } from "drizzle-orm";
import type { Feature, Polygon, Position } from "geojson";

import { db } from "../db";
import { territories, territoryRegions, rankings } from "../db/schema";
import {
  createTerritoryPolygon,
  findOverlaps,
  regionSharesFor,
  primaryRegion,
  type RegionShare,
} from "./geo";
import { broadcastTerritoryUpdate } from "./websocket";

const MIN_AREA_SQM = 100;

export interface WalkStats {
  distanceM?: number;
  durationSec?: number;
  avgSpeedKmh?: number;
  maxSpeedKmh?: number;
  trackPointCount?: number;
  trackCoordinates?: Position[];
}

export type ClaimResult =
  | {
      ok: true;
      territory: typeof territories.$inferInsert;
      overlaps: { taken: number; trimmed: number };
    }
  | { ok: false; status: 400; error: string };

/** A user's total in one region has to be recalculated. */
type AffectedPair = `${string}|${string}`;

const pair = (userId: string, regionId: string): AffectedPair =>
  `${userId}|${regionId}`;

/**
 * Turn a walked loop into a territory for the given user.
 *
 * Resolves overlaps with existing territories, records how the territory
 * splits across admin regions and recalculates the rankings of every user
 * whose holdings changed. Takes an internal user id — authentication is the
 * caller's job.
 */
export async function claimTerritory(
  userId: string,
  coordinates: Position[],
  walkStats?: WalkStats
): Promise<ClaimResult> {
  const polygon = createTerritoryPolygon(coordinates);
  if (!polygon) {
    return {
      ok: false,
      status: 400,
      error:
        "Invalid territory. Either the loop is not closed, area is too small (<100m²), or the shape is invalid.",
    };
  }

  const existingTerritories = await db
    .select()
    .from(territories)
    .where(eq(territories.active, true))
    .all();

  const overlaps = findOverlaps(
    polygon.polygon,
    existingTerritories.map((t) => ({
      id: t.id,
      userId: t.userId,
      polygonGeojson: t.polygonGeojson,
    })),
    userId
  );

  // The loop sat inside ground the claimer already holds
  if (!overlaps.claimedPolygon) {
    return {
      ok: false,
      status: 400,
      error:
        "This loop lies inside a territory you already own — walk a wider one to gain ground.",
    };
  }

  const claimedAreaSqm = area(overlaps.claimedPolygon);
  if (claimedAreaSqm < MIN_AREA_SQM) {
    return {
      ok: false,
      status: 400,
      error:
        "Territory too small after removing overlap with existing territories.",
    };
  }

  const changedIds = [
    ...overlaps.fullyContained,
    ...overlaps.partialOverlaps.map((p) => p.id),
  ];

  // Which totals go stale? Collect before anything is written.
  const affected = new Set<AffectedPair>();
  if (changedIds.length > 0) {
    const previousShares = await db
      .select()
      .from(territoryRegions)
      .where(inArray(territoryRegions.territoryId, changedIds))
      .all();

    for (const share of previousShares) {
      const owner = existingTerritories.find(
        (t) => t.id === share.territoryId
      )?.userId;
      if (owner) affected.add(pair(owner, share.regionId));
    }
  }

  // Deactivate fully contained territories (own + conquered foreign)
  for (const id of overlaps.fullyContained) {
    await db
      .update(territories)
      .set({ active: false })
      .where(eq(territories.id, id));
  }

  // Trim partly covered territories and redo their region split. These can
  // belong to anyone, so the totals have to be credited to their owner.
  for (const partial of overlaps.partialOverlaps) {
    await db
      .update(territories)
      .set({
        polygonGeojson: JSON.stringify(partial.remainingPolygon),
        areaSqm: area(partial.remainingPolygon),
      })
      .where(eq(territories.id, partial.id));

    const owner =
      existingTerritories.find((t) => t.id === partial.id)?.userId ?? userId;
    const shares = await writeRegionShares(
      partial.id,
      partial.remainingPolygon
    );
    for (const share of shares) affected.add(pair(owner, share.regionId));
  }

  const shares = await regionSharesFor(overlaps.claimedPolygon);

  const newTerritory: typeof territories.$inferInsert = {
    id: randomUUID(),
    userId,
    polygonGeojson: JSON.stringify(overlaps.claimedPolygon),
    areaSqm: claimedAreaSqm,
    distanceM: walkStats?.distanceM ?? null,
    durationSec: walkStats?.durationSec ?? null,
    avgSpeedKmh: walkStats?.avgSpeedKmh ?? null,
    maxSpeedKmh: walkStats?.maxSpeedKmh ?? null,
    trackPointCount: walkStats?.trackPointCount ?? null,
    trackGeojson: buildTrackGeojson(walkStats),
    // Kept as the dominant region per level, for display and quick filtering
    municipalityId: primaryRegion(shares, "municipality"),
    districtId: primaryRegion(shares, "district"),
    cantonId: primaryRegion(shares, "canton"),
    countryId: primaryRegion(shares, "country"),
    active: true,
  };

  await db.insert(territories).values(newTerritory);
  await insertRegionShares(newTerritory.id!, shares);

  for (const share of shares) affected.add(pair(userId, share.regionId));

  await recomputeRankings(affected);

  broadcastTerritoryUpdate({
    type: "territory_claimed",
    territory: newTerritory,
    deactivated: overlaps.fullyContained,
    updated: overlaps.partialOverlaps.map((p) => p.id),
  });

  return {
    ok: true,
    territory: newTerritory,
    overlaps: {
      taken: overlaps.fullyContained.length,
      trimmed: overlaps.partialOverlaps.length,
    },
  };
}

function buildTrackGeojson(walkStats?: WalkStats): string | null {
  const coords = walkStats?.trackCoordinates;
  if (!coords || coords.length === 0) return null;

  return JSON.stringify({
    type: "Feature",
    properties: {},
    geometry: { type: "LineString", coordinates: coords },
  });
}

async function insertRegionShares(territoryId: string, shares: RegionShare[]) {
  if (shares.length === 0) return;

  await db.insert(territoryRegions).values(
    shares.map((share) => ({
      id: randomUUID(),
      territoryId,
      regionId: share.regionId,
      level: share.level,
      areaSqm: share.areaSqm,
    }))
  );
}

/** Replace a territory's region split with the one of its current shape. */
export async function writeRegionShares(
  territoryId: string,
  polygon: Feature<Polygon>
): Promise<RegionShare[]> {
  const shares = await regionSharesFor(polygon);

  await db
    .delete(territoryRegions)
    .where(eq(territoryRegions.territoryId, territoryId));
  await insertRegionShares(territoryId, shares);

  return shares;
}

/**
 * Recalculate the given user/region totals from the region splits, then
 * re-rank every region that was touched.
 */
export async function recomputeRankings(affected: Set<AffectedPair>) {
  const regionIds = new Set<string>();

  for (const entry of affected) {
    const [userId, regionId] = entry.split("|");
    regionIds.add(regionId);

    const total = await db
      .select({
        total: sql<number>`coalesce(sum(${territoryRegions.areaSqm}), 0)`,
      })
      .from(territoryRegions)
      .innerJoin(territories, eq(territories.id, territoryRegions.territoryId))
      .where(
        and(
          eq(territoryRegions.regionId, regionId),
          eq(territories.userId, userId),
          eq(territories.active, true)
        )
      )
      .get();

    const totalAreaSqm = total?.total ?? 0;

    const existing = await db
      .select()
      .from(rankings)
      .where(and(eq(rankings.userId, userId), eq(rankings.regionId, regionId)))
      .get();

    if (existing) {
      await db
        .update(rankings)
        .set({ totalAreaSqm, updatedAt: new Date() })
        .where(eq(rankings.id, existing.id));
    } else {
      await db
        .insert(rankings)
        .values({ id: randomUUID(), userId, regionId, totalAreaSqm });
    }
  }

  for (const regionId of regionIds) {
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
