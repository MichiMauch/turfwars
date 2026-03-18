import * as turf from "@turf/turf";
import type { Feature, Polygon, MultiPolygon, Position } from "geojson";
import { db } from "../db";
import { adminRegions } from "../db/schema";
import { eq } from "drizzle-orm";

const MIN_AREA_SQM = 100;
const LOOP_CLOSE_DISTANCE_M = 30;

// --- Region Locator Cache ---

interface CachedRegion {
  id: string;
  name: string;
  level: string;
  parentId: string | null;
  boundary: Feature<Polygon | MultiPolygon>;
  // Bounding box: [minLng, minLat, maxLng, maxLat]
  bbox: [number, number, number, number];
}

let regionCache: CachedRegion[] | null = null;

async function loadRegionCache(): Promise<CachedRegion[]> {
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
    .where(eq(adminRegions.level, "municipality"))
    .all();

  regionCache = [];

  for (const row of rows) {
    if (!row.boundaryGeojson) continue;
    try {
      const boundary = JSON.parse(row.boundaryGeojson) as Feature<Polygon | MultiPolygon>;
      const bbox = turf.bbox(boundary) as [number, number, number, number];
      regionCache.push({
        id: row.id,
        name: row.name,
        level: row.level,
        parentId: row.parentId,
        boundary,
        bbox,
      });
    } catch {
      // skip invalid geometries
    }
  }

  console.log(`Region cache loaded: ${regionCache.length} municipalities`);
  return regionCache;
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

  // Bounding-box filter
  const candidates = cache.filter(
    (r) => lng >= r.bbox[0] && lat >= r.bbox[1] && lng <= r.bbox[2] && lat <= r.bbox[3]
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

/**
 * Find territories that overlap with a new claim.
 *
 * Ownership rules (Option C):
 * - Own territories: always overwritten (fully contained → deactivate, partial → trim)
 * - Foreign territories: only taken if fully contained by the new polygon.
 *   Partial overlap with foreign territories → the NEW polygon gets trimmed instead.
 */
export function findOverlaps(
  newPolygon: Feature<Polygon>,
  existingTerritories: Array<{
    id: string;
    userId: string;
    polygonGeojson: string;
  }>,
  claimingUserId: string
): {
  /** Existing territories to deactivate (fully contained by new polygon) */
  fullyContained: string[];
  /** Existing territories to trim (own territories with partial overlap) */
  partialOverlaps: Array<{ id: string; remainingPolygon: Feature<Polygon> }>;
  /** The (possibly trimmed) new polygon after removing foreign overlaps, or null if rejected */
  claimedPolygon: Feature<Polygon> | null;
} {
  const fullyContained: string[] = [];
  const partialOverlaps: Array<{
    id: string;
    remainingPolygon: Feature<Polygon>;
  }> = [];

  let claimedPolygon: Feature<Polygon> | null = newPolygon;

  for (const territory of existingTerritories) {
    const existing = JSON.parse(territory.polygonGeojson) as Feature<Polygon>;
    const isOwn = territory.userId === claimingUserId;

    const intersection = turf.intersect(
      turf.featureCollection([claimedPolygon, existing])
    );

    if (!intersection) continue; // No overlap

    const existingArea = turf.area(existing);
    const intersectionArea = turf.area(intersection);
    const isFullyContained = intersectionArea / existingArea > 0.95;

    if (isOwn) {
      // Check if new loop is fully inside own territory → skip (no benefit)
      const newArea = turf.area(claimedPolygon);
      const isNewInsideOwn = intersectionArea / newArea > 0.95;

      if (isNewInsideOwn && !isFullyContained) {
        // New loop adds no new area → reject
        claimedPolygon = null;
        break;
      }

      if (isFullyContained) {
        // New loop fully contains own territory → deactivate old
        fullyContained.push(territory.id);
      } else {
        // Partial overlap — trim own territory where it overlaps
        const difference = turf.difference(
          turf.featureCollection([existing, claimedPolygon])
        );
        if (difference && difference.geometry.type === "Polygon") {
          partialOverlaps.push({
            id: territory.id,
            remainingPolygon: difference as Feature<Polygon>,
          });
        }
      }
    } else {
      // Foreign territory
      if (isFullyContained) {
        // New polygon fully contains foreign territory → take it
        fullyContained.push(territory.id);
      } else {
        // Check reverse: is new polygon fully inside the existing foreign territory?
        const newArea = turf.area(claimedPolygon);
        const isNewInsideExisting = intersectionArea / newArea > 0.95;

        if (isNewInsideExisting) {
          // New loop is entirely inside foreign territory → reject (trim to nothing)
          claimedPolygon = null;
          break; // No point checking further overlaps
        }

        // Partial overlap with foreign territory → trim the NEW polygon
        const trimmed = turf.difference(
          turf.featureCollection([claimedPolygon, existing])
        );
        if (trimmed && trimmed.geometry.type === "Polygon") {
          claimedPolygon = trimmed as Feature<Polygon>;
        } else if (trimmed && trimmed.geometry.type === "MultiPolygon") {
          // Foreign territory splits new loop → take the largest piece
          const polygons = trimmed.geometry.coordinates.map((coords) =>
            turf.polygon(coords)
          );
          const largest = polygons.reduce((a, b) =>
            turf.area(a) > turf.area(b) ? a : b
          );
          claimedPolygon = largest as Feature<Polygon>;
        } else {
          // difference returned null → new polygon fully covered → reject
          claimedPolygon = null;
          break;
        }
      }
    }
  }

  return { fullyContained, partialOverlaps, claimedPolygon };
}

/**
 * Check if a point (territory centroid) falls within an admin region boundary
 */
export function findContainingRegion(
  polygon: Feature<Polygon>,
  regions: Array<{ id: string; boundaryGeojson: string }>
): string | null {
  const centroid = turf.centroid(polygon);

  for (const region of regions) {
    if (!region.boundaryGeojson) continue;
    const boundary = JSON.parse(region.boundaryGeojson) as Feature<Polygon>;
    if (turf.booleanPointInPolygon(centroid, boundary)) {
      return region.id;
    }
  }

  return null;
}

/**
 * Calculate total area owned by a user in a specific region
 */
export function calculateTotalArea(
  territories: Array<{ areaSqm: number }>
): number {
  return territories.reduce((sum, t) => sum + t.areaSqm, 0);
}
