import * as turf from "@turf/turf";
import type { Feature, Polygon, MultiPolygon, Position } from "geojson";
import { db } from "../db";
import { adminRegions } from "../db/schema";
import { eq } from "drizzle-orm";

const MIN_AREA_SQM = 100;
const LOOP_CLOSE_DISTANCE_M = 20;

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
 * Check if a GPS track forms a closed loop (start/end within 20m)
 */
export function isLoopClosed(coordinates: Position[]): boolean {
  if (coordinates.length < 4) return false; // Need at least 4 points for a polygon
  const start = turf.point(coordinates[0]);
  const end = turf.point(coordinates[coordinates.length - 1]);
  const distance = turf.distance(start, end, { units: "meters" });
  return distance <= LOOP_CLOSE_DISTANCE_M;
}

/**
 * Create a polygon from GPS coordinates and validate it
 */
export function createTerritoryPolygon(
  coordinates: Position[]
): ClaimResult | null {
  if (!isLoopClosed(coordinates)) return null;

  // Close the ring (first point = last point for valid GeoJSON)
  const ring = [...coordinates, coordinates[0]];

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
 * Returns IDs of territories that are fully contained by the new polygon
 * and territories that partially overlap.
 */
export function findOverlaps(
  newPolygon: Feature<Polygon>,
  existingTerritories: Array<{ id: string; polygonGeojson: string }>
): {
  fullyContained: string[];
  partialOverlaps: Array<{ id: string; remainingPolygon: Feature<Polygon> }>;
} {
  const fullyContained: string[] = [];
  const partialOverlaps: Array<{
    id: string;
    remainingPolygon: Feature<Polygon>;
  }> = [];

  for (const territory of existingTerritories) {
    const existing = JSON.parse(territory.polygonGeojson) as Feature<Polygon>;

    // Check if new polygon fully contains the existing one
    const intersection = turf.intersect(
      turf.featureCollection([newPolygon, existing])
    );

    if (!intersection) continue; // No overlap

    const existingArea = turf.area(existing);
    const intersectionArea = turf.area(intersection);

    // If intersection is ~100% of existing area, it's fully contained
    if (intersectionArea / existingArea > 0.95) {
      fullyContained.push(territory.id);
    } else {
      // Partial overlap: cut the overlapping part from existing territory
      const difference = turf.difference(
        turf.featureCollection([existing, newPolygon])
      );
      if (difference && difference.geometry.type === "Polygon") {
        partialOverlaps.push({
          id: territory.id,
          remainingPolygon: difference as Feature<Polygon>,
        });
      }
    }
  }

  return { fullyContained, partialOverlaps };
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
