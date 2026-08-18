/**
 * Add the bounding box columns and their index to a database that already
 * holds data.
 *
 * The repo has no migrations folder — schema.ts is the source of truth and a
 * fresh database comes from drizzle-kit push. This script exists so the change
 * can be applied to an existing database without running a full schema diff
 * over it.
 *
 * Additive and safe to run more than once: columns that exist are skipped and
 * the index is created with IF NOT EXISTS. Nothing is dropped or rewritten.
 * Run backfill-territory-bbox.ts afterwards to fill the columns for the rows
 * that are already there.
 *
 * Usage: npx tsx src/scripts/add-territory-bbox-columns.ts
 */

import "dotenv/config";
import { createClient } from "@libsql/client";

async function main() {
  const client = createClient({
    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,
  });

  const info = await client.execute("PRAGMA table_info(territories)");
  const have = new Set(info.rows.map((r) => String(r.name)));

  for (const col of ["min_lng", "min_lat", "max_lng", "max_lat"]) {
    if (have.has(col)) {
      console.log(`= ${col} already there`);
      continue;
    }
    await client.execute(`ALTER TABLE territories ADD COLUMN ${col} real`);
    console.log(`+ ${col}`);
  }

  await client.execute(
    "CREATE INDEX IF NOT EXISTS territories_bbox_idx ON territories (min_lng, min_lat)"
  );
  console.log("+ territories_bbox_idx");

  const after = await client.execute("PRAGMA table_info(territories)");
  console.log("columns now:", after.rows.map((r) => r.name).join(", "));
}

main();
