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
    const polygon = turf.polygon([ring]);

    // Clean up self-intersections
    const cleaned = turf.cleanCoords(polygon);

    const areaSqm = turf.area(cleaned);
    if (areaSqm < MIN_AREA_SQM) return null;

    return {
      polygon: cleaned as Feature<Polygon>,
      areaSqm,
    };
  } catch {
    return null;
  }
}

/** Above this share of its area, a territory counts as enclosed. */
const CONTAINED_RATIO = 0.95;

export interface OverlapResult {
  /** Existing territories to deactivate (enclosed by the claim) */
  fullyContained: string[];
  /** Own territories to trim (partial overlap with the claim) */
  partialOverlaps: Array<{ id: string; remainingPolygon: Feature<Polygon> }>;
  /** The claim after foreign territories were removed, or null if rejected */
  claimedPolygon: Feature<Polygon> | null;
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

  const claimedPolygon = newPolygon;
  const claimedArea = turf.area(claimedPolygon);
  const fullyContained: string[] = [];
  const partialOverlaps: OverlapResult["partialOverlaps"] = [];

  // --- Phase 1: the claim sits inside ground the user already owns? ---
  // Nothing to gain from that, and it would only carve up their own holdings.
  for (const territory of parsed) {
    if (territory.userId !== claimingUserId) continue;

    const overlap = overlapArea(claimedPolygon, territory.polygon);
    if (
      overlap / claimedArea > CONTAINED_RATIO &&
      overlap / turf.area(territory.polygon) <= CONTAINED_RATIO
    ) {
      return REJECTED;
    }
  }

  // --- Phase 2: everything the loop covers changes hands ---
  for (const territory of parsed) {
    const overlap = overlapArea(claimedPolygon, territory.polygon);
    if (overlap === 0) continue;

    if (overlap / turf.area(territory.polygon) > CONTAINED_RATIO) {
      // Enclosed by the loop → taken over as a whole
      fullyContained.push(territory.id);
      continue;
    }

    // Partly covered → trimmed back to what stays outside the loop
    const remaining = largestPolygon(
      turf.difference(turf.featureCollection([territory.polygon, claimedPolygon]))
    );

    if (remaining) {
      partialOverlaps.push({ id: territory.id, remainingPolygon: remaining });
    } else {
      // Nothing recognisable left over — treat it as taken
      fullyContained.push(territory.id);
    }
  }

  return { fullyContained, partialOverlaps, claimedPolygon };
}

/** Area shared by two polygons, 0 when they don't overlap. */
function overlapArea(a: Feature<Polygon>, b: Feature<Polygon>): number {
  const intersection = turf.intersect(turf.featureCollection([a, b]));
  return intersection ? turf.area(intersection) : 0;
}

/** Reduce a difference result to a single polygon — the biggest piece. */
function largestPolygon(
  feature: Feature<Polygon | MultiPolygon> | null
): Feature<Polygon> | null {
  if (!feature) return null;

  if (feature.geometry.type === "Polygon") {
    return feature as Feature<Polygon>;
  }

  const pieces = feature.geometry.coordinates.map((coords) =>
    turf.polygon(coords)
  );
  if (pieces.length === 0) return null;

  return pieces.reduce((a, b) => (turf.area(a) > turf.area(b) ? a : b));
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
