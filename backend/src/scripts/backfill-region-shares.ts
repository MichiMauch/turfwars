/**
 * Fill territory_regions for territories that predate it, then rebuild every
 * ranking from the region splits.
 *
 * Safe to run more than once — each territory's shares are replaced, not added.
 *
 * Usage: npx tsx src/scripts/backfill-region-shares.ts
 */

import "dotenv/config";
import type { Feature, Polygon } from "geojson";

import { db } from "../db";
import { territories, territoryRegions, rankings } from "../db/schema";
import { eq } from "drizzle-orm";
import { writeRegionShares, recomputeRankings } from "../services/claim";
import { primaryRegion } from "../services/geo";

async function main() {
  const active = await db
    .select()
    .from(territories)
    .where(eq(territories.active, true))
    .all();

  console.log(`${active.length} active territories`);

  const affected = new Set<`${string}|${string}`>();
  let failed = 0;

  for (const [index, territory] of active.entries()) {
    let polygon: Feature<Polygon>;
    try {
      polygon = JSON.parse(territory.polygonGeojson) as Feature<Polygon>;
    } catch {
      console.warn(`  ${territory.id}: unreadable geometry, skipped`);
      failed++;
      continue;
    }

    const shares = await writeRegionShares(territory.id, polygon);

    // Keep the denormalised columns in step with the splits
    await db
      .update(territories)
      .set({
        municipalityId: primaryRegion(shares, "municipality"),
        districtId: primaryRegion(shares, "district"),
        cantonId: primaryRegion(shares, "canton"),
        countryId: primaryRegion(shares, "country"),
      })
      .where(eq(territories.id, territory.id));

    for (const share of shares) {
      affected.add(`${territory.userId}|${share.regionId}`);
    }

    const regionNames = shares
      .filter((s) => s.level === "municipality")
      .map((s) => s.regionId)
      .join(", ");
    console.log(
      `  [${index + 1}/${active.length}] ${territory.id}: ${shares.length} regions` +
        (regionNames ? ` (${regionNames})` : " — outside every boundary")
    );
  }

  // Old rankings were computed by centroid; drop them so nothing stale survives
  await db.delete(rankings);
  console.log(`Rebuilding ${affected.size} user/region totals`);
  await recomputeRankings(affected);

  const remaining = await db.select().from(territoryRegions).all();
  console.log(
    `Done. ${remaining.length} region shares, ${failed} territories skipped.`
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
