/**
 * Build the country boundary from the cantons already in the database.
 *
 * The original import left `boundary_geojson` null for Switzerland, so
 * territories never got a country-level share or ranking. Deriving it from
 * the cantons keeps the levels consistent with each other: whatever lies in
 * a canton lies in the country, and the shares add up.
 *
 * Usage: npx tsx src/scripts/import-country-boundary.ts
 */

import "dotenv/config";
import * as turf from "@turf/turf";
import type { Feature, MultiPolygon, Polygon } from "geojson";
import { eq } from "drizzle-orm";

import { db } from "../db";
import { adminRegions } from "../db/schema";

/**
 * The cantons are already simplified to roughly 150 points each, so their
 * union is coarse enough on its own — simplifying further only loses area.
 * This ceiling exists to catch a runaway geometry, not to shrink a normal one.
 */
const TARGET_POINTS = 8000;

function pointCount(feature: Feature<Polygon | MultiPolygon>): number {
  const polygons =
    feature.geometry.type === "MultiPolygon"
      ? feature.geometry.coordinates
      : [feature.geometry.coordinates];

  return polygons.reduce(
    (sum, rings) => sum + rings.reduce((s, ring) => s + ring.length, 0),
    0
  );
}

async function main() {
  const cantons = await db
    .select()
    .from(adminRegions)
    .where(eq(adminRegions.level, "canton"))
    .all();

  const boundaries = cantons
    .filter((c) => c.boundaryGeojson)
    .map((c) => JSON.parse(c.boundaryGeojson!) as Feature<Polygon | MultiPolygon>);

  console.log(`${boundaries.length} of ${cantons.length} cantons have a boundary`);
  if (boundaries.length === 0) throw new Error("no canton boundaries to merge");

  let merged = boundaries[0];
  for (const [index, boundary] of boundaries.slice(1).entries()) {
    const union = turf.union(turf.featureCollection([merged, boundary] as any));
    if (!union) throw new Error(`union failed at canton ${index + 2}`);
    merged = union as Feature<Polygon | MultiPolygon>;
  }

  console.log(
    `Merged: ${merged.geometry.type}, ${pointCount(merged)} points, ` +
      `${(turf.area(merged) / 1e6).toFixed(0)} km²`
  );

  // Simplify until the geometry is small enough to store comfortably
  let simplified = merged;
  let tolerance = 0.0001;
  while (pointCount(simplified) > TARGET_POINTS && tolerance < 0.05) {
    simplified = turf.simplify(merged, {
      tolerance,
      highQuality: false,
    }) as Feature<Polygon | MultiPolygon>;
    tolerance *= 1.6;
  }

  const areaSqKm = turf.area(simplified) / 1e6;
  console.log(
    `Simplified: ${pointCount(simplified)} points, ${areaSqKm.toFixed(0)} km² ` +
      `(Switzerland is about 41'285 km²)`
  );

  const geojson = JSON.stringify({
    type: "Feature",
    geometry: simplified.geometry,
    properties: {},
  });

  const updated = await db
    .update(adminRegions)
    .set({ boundaryGeojson: geojson })
    .where(eq(adminRegions.level, "country"))
    .run();

  console.log(
    `Stored ${(geojson.length / 1024).toFixed(0)} KB on ${updated.rowsAffected} country row(s).`
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
