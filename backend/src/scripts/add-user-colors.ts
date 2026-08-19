/**
 * Add the users.color column to a database that already holds data, and give
 * every existing player a starting colour.
 *
 * The repo has no migrations folder — schema.ts is the source of truth and a
 * fresh database comes from drizzle-kit push. This script exists so the change
 * can be applied to an existing database without running a full schema diff
 * over it.
 *
 * Additive and safe to run more than once: an existing column is skipped and
 * only rows without a colour are filled. Nobody's chosen colour is overwritten.
 *
 * Usage: npx tsx src/scripts/add-user-colors.ts
 */

import "dotenv/config";
import { createClient } from "@libsql/client";

import { defaultColorFor } from "../services/colors";

async function main() {
  const client = createClient({
    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,
  });

  const info = await client.execute("PRAGMA table_info(users)");
  const have = new Set(info.rows.map((r) => String(r.name)));

  if (have.has("color")) {
    console.log("= color already there");
  } else {
    await client.execute("ALTER TABLE users ADD COLUMN color text");
    console.log("+ color");
  }

  const missing = await client.execute(
    "SELECT id FROM users WHERE color IS NULL"
  );
  console.log(`${missing.rows.length} players without a colour`);

  for (const row of missing.rows) {
    const id = String(row.id);
    await client.execute({
      sql: "UPDATE users SET color = ? WHERE id = ?",
      args: [defaultColorFor(id), id],
    });
  }

  const check = await client.execute(
    "SELECT color, count(*) AS n FROM users GROUP BY color ORDER BY n DESC"
  );
  console.log("colours in use:");
  for (const row of check.rows) console.log(`  ${row.color}: ${row.n}`);
}

main();
