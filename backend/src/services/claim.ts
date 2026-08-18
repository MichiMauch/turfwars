import { area, bbox } from "@turf/turf";
import { randomUUID } from "crypto";
import { eq, and, inArray, sql } from "drizzle-orm";
import type { Feature, Polygon, Position } from "geojson";

import { db } from "../db";
import { territories, territoryRegions, rankings } from "../db/schema";
import {
  createTerritoryPolygon,
  checkPlausibility,
  findOverlaps,
  regionSharesFor,
  primaryRegion,
  type RegionShare,
} from "./geo";
import { pathShare } from "./paths";
import { broadcastTerritoryUpdate } from "./websocket";

const MIN_AREA_SQM = 100;

/**
 * Bounding box of a polygon, shaped as the four columns the viewport query
 * filters on. Written at claim time because SQLite has no spatial index —
 * deriving it on read would mean parsing every polygon on every request.
 */
export function bboxColumns(polygon: Parameters<typeof bbox>[0]) {
  const box = bbox(polygon);
  // turf returns [minX, minY, maxX, maxY] for 2D and inserts an elevation
  // between them for 3D. GPS tracks are 2D, but reading the wrong four numbers
  // would silently hide territories, so pick by length rather than assume.
  const [minLng, minLat, maxLng, maxLat] =
    box.length === 6 ? [box[0], box[1], box[3], box[4]] : box;
  return { minLng, minLat, maxLng, maxLat };
}

/** Either the connection itself or an open transaction on it. */
type Tx = Parameters<Parameters<typeof db.transaction>[0]>[0];
type DbLike = typeof db | Tx;

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
  walkStats?: WalkStats,
  options: { skipPlausibility?: boolean } = {}
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

  // Dev tooling places territories directly and has no walk to show for it
  if (!options.skipPlausibility) {
    const plausible = checkPlausibility(polygon.polygon, {
      distanceM: walkStats?.distanceM,
      durationSec: walkStats?.durationSec,
    });
    if (!plausible.ok) {
      return { ok: false, status: 400, error: plausible.reason };
    }
  }

  // Looked up before the transaction opens — this calls an external service
  // and must not sit inside a write lock. A failure just means no number.
  const pathSharePercent = options.skipPlausibility
    ? null
    : await pathShare(
        walkStats?.trackCoordinates ?? polygon.polygon.geometry.coordinates[0]
      );

  let pending: Record<string, unknown> | null = null;

  // Read and write inside one transaction. The libsql client opens these in
  // write mode, so two claims cannot both read the same state and then both
  // write it — otherwise they could end up owning the same ground.
  const outcome = await db.transaction(async (tx): Promise<ClaimResult> => {
  const existingTerritories = await tx
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

  if (!overlaps.claimedPolygon) {
    return {
      ok: false,
      status: 400,
      error:
        overlaps.rejection === "inside-own-ground"
          ? "This loop lies inside a territory you already own — walk a wider one to gain ground."
          : "This loop sits in the middle of someone else's territory. Ground has to be taken from the edge inwards.",
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
    const previousShares = await tx
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
    await tx
      .update(territories)
      .set({ active: false })
      .where(eq(territories.id, id));
  }

  // Trim partly covered territories and redo their region split. These can
  // belong to anyone, so the totals have to be credited to their owner.
  for (const partial of overlaps.partialOverlaps) {
    const owner =
      existingTerritories.find((t) => t.id === partial.id)?.userId ?? userId;

    // The first piece keeps the original row — including its walk stats,
    // which belong to the walk that created it and must not be duplicated
    const [first, ...extraPieces] = partial.remainingPolygons;

    await tx
      .update(territories)
      .set({
        polygonGeojson: JSON.stringify(first),
        areaSqm: area(first),
        ...bboxColumns(first),
      })
      .where(eq(territories.id, partial.id));

    const firstShares = await writeRegionShares(tx, partial.id, first);
    await tx
      .update(territories)
      .set(regionColumns(firstShares))
      .where(eq(territories.id, partial.id));
    for (const share of firstShares) affected.add(pair(owner, share.regionId));

    // A claim cutting across a territory leaves it in several pieces. They
    // stay with their owner as territories in their own right.
    for (const piece of extraPieces) {
      const pieceId = randomUUID();
      const pieceShares = await regionSharesFor(piece);

      await tx.insert(territories).values({
        id: pieceId,
        userId: owner,
        polygonGeojson: JSON.stringify(piece),
        areaSqm: area(piece),
        ...bboxColumns(piece),
        ...regionColumns(pieceShares),
        active: true,
      });
      await writeRegionShares(tx, pieceId, piece);

      for (const share of pieceShares) affected.add(pair(owner, share.regionId));
    }
  }

  const shares = await regionSharesFor(overlaps.claimedPolygon);

  const newTerritory: typeof territories.$inferInsert = {
    id: randomUUID(),
    userId,
    polygonGeojson: JSON.stringify(overlaps.claimedPolygon),
    areaSqm: claimedAreaSqm,
    ...bboxColumns(overlaps.claimedPolygon),
    distanceM: walkStats?.distanceM ?? null,
    durationSec: walkStats?.durationSec ?? null,
    avgSpeedKmh: walkStats?.avgSpeedKmh ?? null,
    maxSpeedKmh: walkStats?.maxSpeedKmh ?? null,
    trackPointCount: walkStats?.trackPointCount ?? null,
    trackGeojson: buildTrackGeojson(walkStats),
    pathSharePercent,
    // Kept as the dominant region per level, for display and quick filtering
    ...regionColumns(shares),
    active: true,
  };

  await tx.insert(territories).values(newTerritory);
  await insertRegionShares(tx, newTerritory.id!, shares);

  for (const share of shares) affected.add(pair(userId, share.regionId));

  await recomputeRankings(tx, affected);

  pending = {
    type: "territory_claimed",
    territory: newTerritory,
    claimedBy: userId,
    deactivated: overlaps.fullyContained,
    updated: overlaps.partialOverlaps.map((p) => p.id),
    // So every client can tell its own player what this cost them
    losses: collectLosses(existingTerritories, overlaps, userId),
  };

  return {
    ok: true,
    territory: newTerritory,
    overlaps: {
      taken: overlaps.fullyContained.length,
      trimmed: overlaps.partialOverlaps.length,
    },
  };
  });

  // Only tell the world once the transaction actually committed
  if (pending) broadcastTerritoryUpdate(pending);

  return outcome;
}

/**
 * How much ground each player lost to this claim, so their app can say so
 * instead of silently showing a smaller territory.
 */
function collectLosses(
  before: (typeof territories.$inferSelect)[],
  overlaps: ReturnType<typeof findOverlaps>,
  claimingUserId: string
): Array<{ userId: string; territoryId: string; lostAreaSqm: number }> {
  const losses: Array<{
    userId: string;
    territoryId: string;
    lostAreaSqm: number;
  }> = [];

  for (const id of overlaps.fullyContained) {
    const previous = before.find((t) => t.id === id);
    if (!previous || previous.userId === claimingUserId) continue;
    losses.push({
      userId: previous.userId,
      territoryId: id,
      lostAreaSqm: previous.areaSqm,
    });
  }

  for (const partial of overlaps.partialOverlaps) {
    const previous = before.find((t) => t.id === partial.id);
    if (!previous || previous.userId === claimingUserId) continue;

    const kept = partial.remainingPolygons.reduce(
      (sum, piece) => sum + area(piece),
      0
    );
    const lost = previous.areaSqm - kept;
    if (lost > 0) {
      losses.push({
        userId: previous.userId,
        territoryId: partial.id,
        lostAreaSqm: lost,
      });
    }
  }

  return losses;
}

/** The denormalised "which region does this mostly belong to" columns. */
function regionColumns(shares: RegionShare[]) {
  return {
    municipalityId: primaryRegion(shares, "municipality"),
    districtId: primaryRegion(shares, "district"),
    cantonId: primaryRegion(shares, "canton"),
    countryId: primaryRegion(shares, "country"),
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

async function insertRegionShares(
  tx: DbLike,
  territoryId: string,
  shares: RegionShare[]
) {
  if (shares.length === 0) return;

  await tx.insert(territoryRegions).values(
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
  tx: DbLike,
  territoryId: string,
  polygon: Feature<Polygon>
): Promise<RegionShare[]> {
  const shares = await regionSharesFor(polygon);

  await tx
    .delete(territoryRegions)
    .where(eq(territoryRegions.territoryId, territoryId));
  await insertRegionShares(tx, territoryId, shares);

  return shares;
}

/**
 * Recalculate the given user/region totals from the region splits, then
 * re-rank every region that was touched.
 */
export async function recomputeRankings(
  tx: DbLike,
  affected: Set<AffectedPair>
) {
  const regionIds = new Set<string>();

  for (const entry of affected) {
    const [userId, regionId] = entry.split("|");
    regionIds.add(regionId);

    const total = await tx
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

    const existing = await tx
      .select()
      .from(rankings)
      .where(and(eq(rankings.userId, userId), eq(rankings.regionId, regionId)))
      .get();

    // Someone who holds nothing here does not belong on the board any more
    if (totalAreaSqm <= 0) {
      if (existing) {
        await tx.delete(rankings).where(eq(rankings.id, existing.id));
      }
      continue;
    }

    if (existing) {
      await tx
        .update(rankings)
        .set({ totalAreaSqm, updatedAt: new Date() })
        .where(eq(rankings.id, existing.id));
    } else {
      await tx
        .insert(rankings)
        .values({ id: randomUUID(), userId, regionId, totalAreaSqm });
    }
  }

  for (const regionId of regionIds) {
    await tx.run(sql`
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
