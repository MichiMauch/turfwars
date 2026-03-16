/**
 * Import Swiss administrative regions from geo.admin.ch REST API.
 * Imports: Country (CH) → Cantons (26) → Districts → Municipalities
 *
 * Usage: npx tsx src/scripts/import-regions.ts
 */

import "dotenv/config";
import { db } from "../db";
import { adminRegions } from "../db/schema";

const GEO_ADMIN_API =
  "https://api3.geo.admin.ch/rest/services/api/MapServer";

const LAYERS = {
  canton: "ch.swisstopo.swissboundaries3d-kanton-flaeche.fill",
  district: "ch.swisstopo.swissboundaries3d-bezirk-flaeche.fill",
  municipality: "ch.swisstopo.swissboundaries3d-gemeinde-flaeche.fill",
};

/**
 * Fetch a single feature by layer and feature ID
 */
async function fetchFeature(layer: string, featureId: number | string) {
  const url = `${GEO_ADMIN_API}/${layer}/${featureId}?geometryFormat=geojson&returnGeometry=true&sr=4326`;
  const res = await fetch(url);
  if (!res.ok) return null;
  const data = await res.json();
  return data.feature;
}

/**
 * Search features by field value
 */
async function searchFeatures(
  layer: string,
  searchField: string,
  searchText: string,
  returnGeometry = false
) {
  const url = `${GEO_ADMIN_API}/find?layer=${layer}&searchField=${searchField}&searchText=${encodeURIComponent(searchText)}&geometryFormat=geojson&returnGeometry=${returnGeometry}&sr=4326`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`API error: ${res.status}`);
  const data = await res.json();
  return data.results || [];
}

/**
 * Simplify polygon coordinates to reduce storage size
 */
function simplifyGeometry(geometry: any, maxPoints = 150): any {
  if (!geometry || !geometry.coordinates) return geometry;

  const simplifyRing = (ring: number[][]) => {
    if (ring.length <= maxPoints) return ring;
    const step = Math.ceil(ring.length / maxPoints);
    const result = [];
    for (let i = 0; i < ring.length; i += step) {
      result.push(ring[i]);
    }
    // Ensure ring is closed
    if (
      result[0][0] !== result[result.length - 1][0] ||
      result[0][1] !== result[result.length - 1][1]
    ) {
      result.push(result[0]);
    }
    return result;
  };

  if (geometry.type === "Polygon") {
    return {
      ...geometry,
      coordinates: geometry.coordinates.map(simplifyRing),
    };
  }

  if (geometry.type === "MultiPolygon") {
    return {
      ...geometry,
      coordinates: geometry.coordinates.map((polygon: number[][][]) =>
        polygon.map(simplifyRing)
      ),
    };
  }

  return geometry;
}

function toGeoJson(geometry: any): string {
  const simplified = simplifyGeometry(geometry);
  return JSON.stringify({
    type: "Feature",
    geometry: simplified,
    properties: {},
  });
}

// ─── Import Functions ────────────────────────────────────────

async function importCountry() {
  console.log("\n🇨🇭 Importing Switzerland...");
  await db
    .insert(adminRegions)
    .values({
      id: "ch",
      osmId: 51701,
      name: "Schweiz",
      level: "country",
      parentId: null,
      boundaryGeojson: null,
      countryCode: "CH",
    })
    .onConflictDoNothing();
  console.log("  ✓ Schweiz");
  return "ch";
}

async function importCantons(countryId: string) {
  console.log("\n🏔️  Importing Cantons...");
  let count = 0;

  // Swiss cantons have IDs 1-26
  for (let id = 1; id <= 26; id++) {
    try {
      const feature = await fetchFeature(LAYERS.canton, id);
      if (!feature) continue;

      const name = feature.properties.name;
      const geojson = toGeoJson(feature.geometry);

      await db
        .insert(adminRegions)
        .values({
          id: `canton-${id}`,
          osmId: id,
          name,
          level: "canton",
          parentId: countryId,
          boundaryGeojson: geojson,
          countryCode: "CH",
        })
        .onConflictDoNothing();

      count++;
      console.log(`  ✓ ${name}`);
    } catch (e) {
      console.log(`  ⚠️ Failed for canton ${id}: ${e}`);
    }
  }

  console.log(`  Total: ${count} cantons`);
}

async function importDistricts() {
  console.log("\n🗺️  Importing Districts (Bezirke)...");

  // Search for all districts using common letters to find them all
  const allIds = new Set<number>();
  const searchLetters = "abcdefghijklmnopqrstuvwxyz".split("");

  for (const letter of searchLetters) {
    try {
      const results = await searchFeatures(
        LAYERS.district,
        "name",
        letter,
        false
      );
      for (const r of results) {
        allIds.add(r.id);
      }
    } catch {
      // ignore
    }
  }

  console.log(`  Found ${allIds.size} unique districts`);

  let count = 0;
  for (const id of allIds) {
    try {
      const feature = await fetchFeature(LAYERS.district, id);
      if (!feature) continue;

      const name = feature.properties.name;
      const geojson = toGeoJson(feature.geometry);

      // Find parent canton (district IDs: first 1-2 digits = canton ID)
      const cantonId = Math.floor(id / 100);

      await db
        .insert(adminRegions)
        .values({
          id: `district-${id}`,
          osmId: id,
          name,
          level: "district",
          parentId: `canton-${cantonId}`,
          boundaryGeojson: geojson,
          countryCode: "CH",
        })
        .onConflictDoNothing();

      count++;
      if (count % 20 === 0) console.log(`  ... ${count} districts imported`);
    } catch (e) {
      console.log(`  ⚠️ Failed for district ${id}: ${e}`);
    }
  }

  console.log(`  Total: ${count} districts`);
}

async function importMunicipalities() {
  console.log("\n🏘️  Importing Municipalities (Gemeinden)...");
  console.log("  Scanning BFS numbers 1-7000...");

  const kantonMap: Record<string, number> = {
    ZH: 1, BE: 2, LU: 3, UR: 4, SZ: 5, OW: 6, NW: 7, GL: 8,
    ZG: 9, FR: 10, SO: 11, BS: 12, BL: 13, SH: 14, AR: 15,
    AI: 16, SG: 17, GR: 18, AG: 19, TG: 20, TI: 21, VD: 22,
    VS: 23, NE: 24, GE: 25, JU: 26,
  };

  let count = 0;
  let notFound = 0;

  // Batch requests: fetch 10 in parallel
  const BATCH_SIZE = 10;

  for (let start = 1; start <= 7000; start += BATCH_SIZE) {
    const promises = [];
    for (let id = start; id < start + BATCH_SIZE && id <= 7000; id++) {
      promises.push(
        fetchFeature(LAYERS.municipality, id)
          .then((feature) => ({ id, feature }))
          .catch(() => ({ id, feature: null }))
      );
    }

    const results = await Promise.all(promises);

    for (const { id, feature } of results) {
      if (!feature) {
        notFound++;
        continue;
      }

      // Only current municipalities
      if (feature.properties.is_current_jahr !== true) continue;

      const gemname = feature.properties.gemname;
      const kanton = feature.properties.kanton;
      const cantonNum = kantonMap[kanton];
      const geojson = toGeoJson(feature.geometry);

      try {
        await db
          .insert(adminRegions)
          .values({
            id: `municipality-${id}`,
            osmId: id,
            name: gemname,
            level: "municipality",
            parentId: cantonNum ? `canton-${cantonNum}` : null,
            boundaryGeojson: geojson,
            countryCode: "CH",
          })
          .onConflictDoNothing();
        count++;
      } catch {
        // already exists
      }
    }

    if (start % 500 === 1) {
      console.log(`  ... scanned ${start}-${start + BATCH_SIZE - 1}, found ${count} municipalities so far`);
    }
  }

  console.log(`  Total: ${count} municipalities`);
}

// ─── Main ────────────────────────────────────────────────────

async function main() {
  console.log("🌍 Starting geo.admin.ch import for Switzerland\n");

  try {
    const countryId = await importCountry();
    await importCantons(countryId);
    await importDistricts();
    await importMunicipalities();

    // Count results (without loading geojson to avoid response too large)
    const counts = await db
      .select({ level: adminRegions.level })
      .from(adminRegions)
      .all();
    const byLevel = counts.reduce(
      (acc, r) => {
        acc[r.level] = (acc[r.level] || 0) + 1;
        return acc;
      },
      {} as Record<string, number>
    );
    console.log(`\n✅ Import complete!`);
    console.log(`   Countries: ${byLevel.country || 0}`);
    console.log(`   Cantons: ${byLevel.canton || 0}`);
    console.log(`   Districts: ${byLevel.district || 0}`);
    console.log(`   Municipalities: ${byLevel.municipality || 0}`);
    console.log(`   Total: ${counts.length}`);
  } catch (e) {
    console.error("❌ Import failed:", e);
    process.exit(1);
  }
}

main();
