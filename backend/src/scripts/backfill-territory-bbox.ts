/**
 * Fill min_lng/min_lat/max_lng/max_lat for territories that predate those
 * columns, so the viewport filter in GET /territories can rely on them.
 *
 * Safe to run more than once — a box is recomputed from the stored polygon,
 * never derived from the previous box. Touches only the four columns.
 *
 * Usage: npx tsx src/scripts/backfill-territory-bbox.ts [--all]
 *   --all  also recompute rows that already have a box
 */

import "dotenv/config";
import { eq, isNull } from "drizzle-orm";

import { db } from "../db";
import { territories } from "../db/schema";
import { bboxColumns } from "../services/claim";

async function main() {
  const all = process.argv.includes("--all");

  const rows = await db
    .select({ id: territories.id, polygonGeojson: territories.polygonGeojson })
    .from(territories)
    .where(all ? undefined : isNull(territories.minLng))
    .all();

  console.log(
    `${rows.length} territories to process${all ? " (--all)" : " without a box"}`
  );

  let done = 0;
  let failed = 0;

  for (const row of rows) {
    try {
      const polygon = JSON.parse(row.polygonGeojson);
      await db
        .update(territories)
        .set(bboxColumns(polygon))
        .where(eq(territories.id, row.id));
      done++;
    } catch (e) {
      // A row with an unreadable polygon keeps its null box, which the route
      // treats as "always visible". Loud, but not a reason to stop the run.
      failed++;
      console.error(`  ${row.id}: ${e instanceof Error ? e.message : e}`);
    }
  }

  console.log(`${done} updated, ${failed} failed`);
  if (failed > 0) process.exitCode = 1;
}

main();
