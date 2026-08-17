import * as turf from "@turf/turf";
import type { Feature, Polygon, MultiPolygon, Position } from "geojson";
import { db } from "../db";
import { adminRegions } from "../db/schema";

const MIN_AREA_SQM = 100;
const LOOP_CLOSE_DISTANCE_M = 30;

// --- Region Locator Cache ---

export type RegionLevel =
  | "municipality"
  | "district"
  | "canton"
  | "country";

export interface CachedRegion {
  id: string;
  name: string;
  level: RegionLevel;
  parentId: string | null;
  boundary: Feature<Polygon | MultiPolygon>;
  // Bounding box: [minLng, minLat, maxLng, maxLat]
  bbox: [number, number, number, number];
  /**
   * Area of the stored boundary. Boundaries are simplified on import, so this
   * is not the official area — but it is the same geometry the territory is
   * clipped against, which keeps shares consistent with their denominator.
   */
  areaSqm: number;
}

let regionCache: CachedRegion[] | null = null;

export async function loadRegionCache(): Promise<CachedRegion[]> {
  if (regionCache) return regionCache;

  const rows = await db
    .select({
      id: adminRegions.id,
      name: adminRegions.name,
      level: adminRegions.level,
      parentId: adminRegions.parentId,
      boundaryGeojson: adminRegions.boundaryGeojson,
    })
    .from(adminRegions)
    .all();

  const cache: CachedRegion[] = [];

  for (const row of rows) {
    if (!row.boundaryGeojson) continue;
    try {
      const boundary = JSON.parse(row.boundaryGeojson) as Feature<
        Polygon | MultiPolygon
      >;
      cache.push({
        id: row.id,
        name: row.name,
        level: row.level,
        parentId: row.parentId,
        boundary,
        bbox: turf.bbox(boundary) as [number, number, number, number],
        areaSqm: turf.area(boundary),
      });
    } catch {
      // skip invalid geometries
    }
  }

  regionCache = cache;
  console.log(`Region cache loaded: ${cache.length} regions`);
  return cache;
}

/** Regions whose bounding box overlaps the given box — cheap pre-filter. */
function candidatesInBbox(
  regions: CachedRegion[],
  [minLng, minLat, maxLng, maxLat]: [number, number, number, number]
): CachedRegion[] {
  return regions.filter(
    (r) =>
      r.bbox[0] <= maxLng &&
      r.bbox[2] >= minLng &&
      r.bbox[1] <= maxLat &&
      r.bbox[3] >= minLat
  );
}

/**
 * Locate which municipality a GPS point falls in.
 * Uses bounding-box pre-filter + point-in-polygon check.
 */
export async function locateMunicipality(
  lat: number,
  lng: number
): Promise<{ id: string; name: string; level: string; parentId: string | null } | null> {
  const cache = await loadRegionCache();
  const point = turf.point([lng, lat]);

  const candidates = candidatesInBbox(
    cache.filter((r) => r.level === "municipality"),
    [lng, lat, lng, lat]
  );

  for (const candidate of candidates) {
    if (turf.booleanPointInPolygon(point, candidate.boundary)) {
      return {
        id: candidate.id,
        name: candidate.name,
        level: candidate.level,
        parentId: candidate.parentId,
      };
    }
  }

  return null;
}

export interface RegionShare {
  regionId: string;
  level: RegionLevel;
  /** Area of the territory that lies inside this region */
  areaSqm: number;
}

/**
 * Split a territory across the admin regions it touches.
 *
 * A loop walked across a municipality boundary belongs to both, proportional
 * to how much of it lies on either side. Slivers below `minShareSqm` are
 * dropped so a metre of GPS noise across a border doesn't create a region
 * membership.
 */
export function computeRegionShares(
  polygon: Feature<Polygon>,
  regions: CachedRegion[],
  minShareSqm = 1
): RegionShare[] {
  const bbox = turf.bbox(polygon) as [number, number, number, number];
  const shares: RegionShare[] = [];

  for (const region of candidatesInBbox(regions, bbox)) {
    const overlap = turf.intersect(
      turf.featureCollection([polygon, region.boundary as Feature<Polygon>])
    );
    if (!overlap) continue;

    const areaSqm = turf.area(overlap);
    if (areaSqm < minShareSqm) continue;

    shares.push({ regionId: region.id, level: region.level, areaSqm });
  }

  return shares;
}

/** Region shares for a territory, using the cached boundaries. */
export async function regionSharesFor(
  polygon: Feature<Polygon>
): Promise<RegionShare[]> {
  return computeRegionShares(polygon, await loadRegionCache());
}

export interface ClaimResult {
  polygon: Feature<Polygon>;
  areaSqm: number;
}

/**
 * Check if a GPS track forms a closed loop (start/end within 30m)
 */
export function isLoopClosed(coordinates: Position[]): boolean {
  if (coordinates.length < 4) return false; // Need at least 4 points for a polygon
  const start = turf.point(coordinates[0]);
  const end = turf.point(coordinates[coordinates.length - 1]);
  const distance = turf.distance(start, end, { units: "meters" });
  return distance <= LOOP_CLOSE_DISTANCE_M;
}

/**
 * Create a polygon from GPS coordinates and validate it.
 * Accepts either:
 * - Already closed coordinates (first == last) from frontend loop-slice
 * - Open coordinates where start/end are within LOOP_CLOSE_DISTANCE_M
 */
export function createTerritoryPolygon(
  coordinates: Position[]
): ClaimResult | null {
  if (coordinates.length < 4) return null;

  // Check if already closed (first ~= last point)
  const first = coordinates[0];
  const last = coordinates[coordinates.length - 1];
  const alreadyClosed =
    Math.abs(first[0] - last[0]) < 1e-8 &&
    Math.abs(first[1] - last[1]) < 1e-8;

  let ring: Position[];
  if (alreadyClosed) {
    // Already closed — use as-is
    ring = coordinates;
  } else if (isLoopClosed(coordinates)) {
    // Close the ring (first point = last point for valid GeoJSON)
    ring = [...coordinates, coordinates[0]];
  } else {
    return null;
  }

  try {
    const polygon = turf.cleanCoords(turf.polygon([ring])) as Feature<Polygon>;

    // A track that crosses itself produces lobes with opposite winding, and
    // turf.area then subtracts one from the other — a symmetric figure eight
    // measures zero. Untangle it and keep the largest lobe.
    const untangled = untangle(polygon);
    if (!untangled) return null;

    const areaSqm = turf.area(untangled);
    if (areaSqm < MIN_AREA_SQM) return null;

    return { polygon: untangled, areaSqm };
  } catch {
    return null;
  }
}

/** Split a self-crossing ring into simple polygons and keep the biggest. */
function untangle(polygon: Feature<Polygon>): Feature<Polygon> | null {
  let pieces: Feature<Polygon>[];
  try {
    pieces = turf.unkinkPolygon(polygon).features as Feature<Polygon>[];
  } catch {
    // unkinkPolygon chokes on some degenerate rings — fall back to the ring
    return polygon;
  }

  if (pieces.length === 0) return null;
  if (pieces.length === 1) return pieces[0];

  return pieces.reduce((a, b) => (turf.area(a) > turf.area(b) ? a : b));
}

/** Ceiling on how fast a claimed loop can plausibly have been covered. */
export const MAX_SPEED_KMH = 25;

/**
 * A recorded track has many points; a hand-drawn shape has a handful of
 * corners. Kept loose on purpose — sparse fixes happen in tunnels, under
 * power saving and when a track gets thinned out before sending.
 */
export const MAX_POINT_SPACING_M = 150;
export const MIN_TRACK_POINTS = 10;

export interface WalkEvidence {
  distanceM?: number;
  durationSec?: number;
}

export type Plausibility = { ok: true } | { ok: false; reason: string };

/**
 * Sanity-check a claim against the walk it is supposed to come from.
 *
 * This raises the bar, it does not close the door: everything here comes from
 * the client, so a determined faker can fabricate a track that passes. What it
 * does stop is the cheap version — four corners around half a canton, a loop
 * covered at driving speed, a claim whose own numbers contradict each other.
 */
export function checkPlausibility(
  polygon: Feature<Polygon>,
  evidence: WalkEvidence
): Plausibility {
  const ring = polygon.geometry.coordinates[0];
  const perimeterM = turf.length(turf.polygonToLine(polygon), {
    units: "meters",
  });

  if (ring.length - 1 < MIN_TRACK_POINTS) {
    return {
      ok: false,
      reason: `A walk has more than ${ring.length - 1} recorded points.`,
    };
  }

  const spacing = perimeterM / Math.max(ring.length - 1, 1);
  if (spacing > MAX_POINT_SPACING_M) {
    return {
      ok: false,
      reason: `Track is too coarse to be a recorded walk (${Math.round(spacing)} m between points).`,
    };
  }

  const { durationSec, distanceM } = evidence;

  if (!durationSec || durationSec <= 0) {
    return { ok: false, reason: "Claim is missing the duration of the walk." };
  }

  // You cannot have walked less than the loop you are claiming
  if (distanceM !== undefined && distanceM < perimeterM * 0.9) {
    return {
      ok: false,
      reason: "Reported distance is shorter than the claimed loop.",
    };
  }

  const speedKmh = (Math.max(distanceM ?? 0, perimeterM) / durationSec) * 3.6;
  if (speedKmh > MAX_SPEED_KMH) {
    return {
      ok: false,
      reason: `Loop was covered at ${speedKmh.toFixed(0)} km/h, which is faster than this game allows.`,
    };
  }

  return { ok: true };
}

/** Above this share of its area, a territory counts as enclosed. */
const CONTAINED_RATIO = 0.95;

export interface OverlapResult {
  /** Existing territories to deactivate (enclosed by the claim) */
  fullyContained: string[];
  /**
   * Territories the claim cut into. A claim that runs across a territory
   * leaves more than one piece — every piece stays with its owner, otherwise
   * a thin loop through the middle would destroy far more than it covers.
   */
  partialOverlaps: Array<{ id: string; remainingPolygons: Feature<Polygon>[] }>;
  /** The claim, or null if it was rejected */
  claimedPolygon: Feature<Polygon> | null;
  /** Why the claim was turned down, when it was */
  rejection?: "inside-own-ground" | "no-foothold";
}

const REJECTED: OverlapResult = {
  fullyContained: [],
  partialOverlaps: [],
  claimedPolygon: null,
};

/**
 * Find territories that overlap with a new claim.
 *
 * Ownership rules:
 * - Whatever the walked loop encloses becomes the claimer's, no matter who
 *   held it before. A territory enclosed outright is taken over completely;
 *   one that is only partly covered gets trimmed back to what stays outside.
 * - The claim itself is never cut down by other players. Big holdings are
 *   therefore attackable at the edges, in small bites, instead of only by
 *   walking a loop around the whole thing.
 *
 * Resolved in two phases so the outcome never depends on the order the
 * territories come out of the database. Both phases judge against the loop
 * as it was walked, which is what makes the result order-independent.
 */
export function findOverlaps(
  newPolygon: Feature<Polygon>,
  existingTerritories: Array<{
    id: string;
    userId: string;
    polygonGeojson: string;
  }>,
  claimingUserId: string
): OverlapResult {
  const parsed = existingTerritories.map((t) => ({
    id: t.id,
    userId: t.userId,
    polygon: JSON.parse(t.polygonGeojson) as Feature<Polygon>,
  }));

  const claimedArea = turf.area(newPolygon);
  const fullyContained: string[] = [];
  const partialOverlaps: OverlapResult["partialOverlaps"] = [];

  // --- Phase 1: the claim sits inside ground the user already owns? ---
  // Nothing to gain from that, and it would only carve up their own holdings.
  for (const territory of parsed) {
    if (territory.userId !== claimingUserId) continue;

    const overlap = overlapArea(newPolygon, territory.polygon);
    if (
      overlap / claimedArea > CONTAINED_RATIO &&
      overlap / turf.area(territory.polygon) <= CONTAINED_RATIO
    ) {
      return { ...REJECTED, rejection: "inside-own-ground" };
    }
  }

  // --- Phase 2: ground with no foothold on the rim stays where it is ---
  // Taking a bite out of the middle of a territory would leave a hole. You
  // have to reach in from the edge instead, and the walk that takes costs
  // real distance — which is what gives a large territory a defended
  // interior rather than a bigger target.
  const unreachable = unreachableParts(newPolygon, parsed);

  const claimedPolygon =
    unreachable.length === 0
      ? newPolygon
      : splitIntoPolygons(
          turf.difference(
            turf.featureCollection([newPolygon, ...unreachable] as any)
          )
        )[0] ?? null;

  if (!claimedPolygon) {
    return { ...REJECTED, rejection: "no-foothold" };
  }

  // --- Phase 3: everything the loop still covers changes hands ---
  for (const territory of parsed) {
    const overlap = overlapArea(claimedPolygon, territory.polygon);
    if (overlap === 0) continue;

    if (overlap / turf.area(territory.polygon) > CONTAINED_RATIO) {
      // Enclosed by the loop → taken over as a whole
      fullyContained.push(territory.id);
      continue;
    }

    // Partly covered → trimmed back to whatever stays outside the loop,
    // in as many pieces as the claim happened to cut it into
    const remaining = splitIntoPolygons(
      turf.difference(turf.featureCollection([territory.polygon, claimedPolygon]))
    );

    if (remaining.length > 0) {
      partialOverlaps.push({ id: territory.id, remainingPolygons: remaining });
    } else {
      // Nothing above the minimum size left over — treat it as taken
      fullyContained.push(territory.id);
    }
  }

  return { fullyContained, partialOverlaps, claimedPolygon };
}

/** The interior rings of a polygon, as polygons in their own right. */
function holesOf(polygon: Feature<Polygon>): Feature<Polygon>[] {
  return polygon.geometry.coordinates
    .slice(1)
    .map((ring) => turf.polygon([ring]));
}

/**
 * Parts of a claim that would punch a hole into an existing territory.
 *
 * A bite only counts if what stays behind still hangs together with the rim.
 * Anything the claim would isolate in the middle is handed back — the claimer
 * has to eat their way in from the edge to get it.
 *
 * Judged against the untouched claim for every territory, so the result does
 * not depend on the order they are looked at.
 */
function unreachableParts(
  claim: Feature<Polygon>,
  territories: Array<{ polygon: Feature<Polygon> }>
): Feature<Polygon>[] {
  const unreachable: Feature<Polygon>[] = [];

  for (const territory of territories) {
    if (overlapArea(claim, territory.polygon) === 0) continue;

    const remainder = turf.difference(
      turf.featureCollection([territory.polygon, claim])
    );
    if (!remainder) continue; // fully covered, nothing to isolate

    const pieces =
      remainder.geometry.type === "Polygon"
        ? [remainder as Feature<Polygon>]
        : remainder.geometry.coordinates.map((rings) => turf.polygon(rings));

    // Holes the territory already had belong to somebody else, not to it
    const before = holesOf(territory.polygon);

    for (const piece of pieces) {
      for (const hole of holesOf(piece)) {
        const holeArea = turf.area(hole);
        const existedBefore = before.some(
          (old) => overlapArea(hole, old) / holeArea > 0.9
        );
        if (!existedBefore) unreachable.push(hole);
      }
    }
  }

  return unreachable;
}

/** Area shared by two polygons, 0 when they don't overlap. */
function overlapArea(a: Feature<Polygon>, b: Feature<Polygon>): number {
  const intersection = turf.intersect(turf.featureCollection([a, b]));
  return intersection ? turf.area(intersection) : 0;
}

/**
 * Break a difference result into separate polygons, keeping any holes and
 * dropping slivers that fall under the game's minimum size.
 */
function splitIntoPolygons(
  feature: Feature<Polygon | MultiPolygon> | null
): Feature<Polygon>[] {
  if (!feature) return [];

  const pieces =
    feature.geometry.type === "Polygon"
      ? [feature as Feature<Polygon>]
      : // Each entry is a full list of rings, so holes survive the split
        feature.geometry.coordinates.map((rings) => turf.polygon(rings));

  return pieces
    .filter((piece) => turf.area(piece) >= MIN_AREA_SQM)
    .sort((a, b) => turf.area(b) - turf.area(a));
}

/** The region with the largest share on a given level, if any. */
export function primaryRegion(
  shares: RegionShare[],
  level: RegionLevel
): string | null {
  const onLevel = shares.filter((s) => s.level === level);
  if (onLevel.length === 0) return null;

  return onLevel.reduce((a, b) => (a.areaSqm > b.areaSqm ? a : b)).regionId;
}
