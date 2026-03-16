import * as turf from "@turf/turf";
import type { Feature, Polygon, Position } from "geojson";

const MIN_AREA_SQM = 100;
const LOOP_CLOSE_DISTANCE_M = 20;

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
