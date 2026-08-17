/**
 * Populate a municipality with simulated players so the map and the rankings
 * have something to show.
 *
 * Territories are placed on free ground only — the boundary minus everything
 * that is already claimed — and go through the normal claim pipeline, so
 * region shares and rankings come out exactly as they would in a real game.
 *
 * Usage:
 *   npx tsx src/scripts/seed-simulation.ts [--municipality=<id>] [--players=4]
 *                                          [--per-player=3] [--cell=350]
 *   npx tsx src/scripts/seed-simulation.ts --clean
 *
 * Simulated users carry a `sim-` google id, which is what --clean removes.
 */

import "dotenv/config";
import * as turf from "@turf/turf";
import type { Feature, MultiPolygon, Polygon, Position } from "geojson";
import { randomUUID } from "crypto";
import { eq, like, inArray } from "drizzle-orm";

import { db } from "../db";
import {
  adminRegions,
  territories,
  territoryRegions,
  rankings,
  users,
} from "../db/schema";
import { claimTerritory } from "../services/claim";

const SIM_PREFIX = "sim-";
const PLAYER_NAMES = ["Lena", "Timo", "Nora", "Jonas", "Mira", "Elia"];

function arg(name: string, fallback: string): string {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.split("=")[1] : fallback;
}

// ─── Cleanup ─────────────────────────────────────────────────

async function clean() {
  const simUsers = await db
    .select()
    .from(users)
    .where(like(users.googleId, `${SIM_PREFIX}%`))
    .all();

  if (simUsers.length === 0) {
    console.log("No simulated users found.");
    return;
  }

  const ids = simUsers.map((u) => u.id);
  const theirTerritories = await db
    .select({ id: territories.id })
    .from(territories)
    .where(inArray(territories.userId, ids))
    .all();

  if (theirTerritories.length > 0) {
    await db.delete(territoryRegions).where(
      inArray(
        territoryRegions.territoryId,
        theirTerritories.map((t) => t.id)
      )
    );
  }
  await db.delete(rankings).where(inArray(rankings.userId, ids));
  await db.delete(territories).where(inArray(territories.userId, ids));
  await db.delete(users).where(inArray(users.id, ids));

  console.log(
    `Removed ${simUsers.length} simulated players and ${theirTerritories.length} territories ` +
      `(${simUsers.map((u) => u.displayName).join(", ")}).`
  );
}

// ─── Placement ───────────────────────────────────────────────

/** Ground inside the municipality that nobody holds yet. */
async function freeGround(
  boundary: Feature<Polygon | MultiPolygon>
): Promise<Feature<Polygon | MultiPolygon>> {
  const claimed = await db
    .select()
    .from(territories)
    .where(eq(territories.active, true))
    .all();

  let free = boundary;
  for (const territory of claimed) {
    const taken = JSON.parse(territory.polygonGeojson) as Feature<Polygon>;
    if (!turf.intersect(turf.featureCollection([free as any, taken]))) continue;

    const rest = turf.difference(turf.featureCollection([free as any, taken]));
    if (!rest) throw new Error("municipality is fully claimed already");
    free = rest as Feature<Polygon | MultiPolygon>;
  }

  return free;
}

/** Square cells that lie completely on free ground. */
function freeCells(
  free: Feature<Polygon | MultiPolygon>,
  cellMeters: number
): Feature<Polygon>[] {
  const [minLng, minLat, maxLng, maxLat] = turf.bbox(free);
  const midLat = (minLat + maxLat) / 2;

  const stepLat = cellMeters / 111_320;
  const stepLng = cellMeters / (111_320 * Math.cos((midLat * Math.PI) / 180));

  // Leave a gap between neighbours so territories stay visually distinct
  const inset = 0.12;
  const cells: Feature<Polygon>[] = [];

  for (let lat = minLat; lat + stepLat <= maxLat; lat += stepLat) {
    for (let lng = minLng; lng + stepLng <= maxLng; lng += stepLng) {
      const x0 = lng + stepLng * inset;
      const x1 = lng + stepLng * (1 - inset);
      const y0 = lat + stepLat * inset;
      const y1 = lat + stepLat * (1 - inset);

      const cell = turf.polygon([
        [
          [x0, y0],
          [x1, y0],
          [x1, y1],
          [x0, y1],
          [x0, y0],
        ],
      ]);

      const overlap = turf.intersect(
        turf.featureCollection([cell, free as Feature<Polygon>])
      );
      if (!overlap) continue;

      // Only keep cells that sit fully on free ground
      if (turf.area(overlap) / turf.area(cell) > 0.995) cells.push(cell);
    }
  }

  return cells;
}

/**
 * Give each player a cluster of neighbouring cells.
 *
 * Cluster sizes taper off from `perPlayer` downwards, otherwise every player
 * ends up with identical area and the ranking has nothing to say.
 */
function assignClusters(
  cells: Feature<Polygon>[],
  players: number,
  perPlayer: number
): Feature<Polygon>[][] {
  const centres = cells.map((c) => turf.centroid(c));
  const used = new Set<number>();
  const clusters: Feature<Polygon>[][] = [];

  for (let player = 0; player < players; player++) {
    // Spread the seeds across the available cells instead of picking at random
    let seed = Math.floor((player * cells.length) / players);
    while (used.has(seed) && seed < cells.length) seed++;
    if (seed >= cells.length) break;

    const size = Math.max(1, perPlayer - player);
    const byDistance = cells
      .map((_, index) => index)
      .filter((index) => !used.has(index))
      .sort(
        (a, b) =>
          turf.distance(centres[seed], centres[a]) -
          turf.distance(centres[seed], centres[b])
      )
      .slice(0, size);

    byDistance.forEach((index) => used.add(index));
    clusters.push(byDistance.map((index) => cells[index]));
  }

  return clusters;
}

// ─── Main ────────────────────────────────────────────────────

async function seed() {
  const municipalityId = arg("municipality", "municipality-4009");
  const players = Math.min(parseInt(arg("players", "4")), PLAYER_NAMES.length);
  const perPlayer = parseInt(arg("per-player", "3"));
  const cellMeters = parseInt(arg("cell", "350"));

  const municipality = await db
    .select()
    .from(adminRegions)
    .where(eq(adminRegions.id, municipalityId))
    .get();

  if (!municipality?.boundaryGeojson) {
    throw new Error(`${municipalityId} has no boundary`);
  }

  const boundary = JSON.parse(municipality.boundaryGeojson) as Feature<
    Polygon | MultiPolygon
  >;
  console.log(
    `${municipality.name}: ${(turf.area(boundary) / 1e6).toFixed(2)} km²`
  );

  const free = await freeGround(boundary);
  console.log(
    `Free ground: ${(turf.area(free) / 1e6).toFixed(2)} km² ` +
      `(${((turf.area(free) / turf.area(boundary)) * 100).toFixed(0)}%)`
  );

  const cells = freeCells(free, cellMeters);
  console.log(`${cells.length} placeable cells of ${cellMeters} m\n`);

  if (cells.length < players) {
    throw new Error("not enough free ground — try a smaller --cell");
  }

  const clusters = assignClusters(cells, players, perPlayer);

  for (const [index, cluster] of clusters.entries()) {
    const name = PLAYER_NAMES[index];
    const googleId = `${SIM_PREFIX}${name.toLowerCase()}`;

    let user = await db
      .select()
      .from(users)
      .where(eq(users.googleId, googleId))
      .get();

    if (!user) {
      const created = {
        id: randomUUID(),
        googleId,
        displayName: name,
        avatarUrl: null,
      };
      await db.insert(users).values(created);
      user = { ...created, createdAt: new Date() };
    }

    let claimed = 0;
    let areaSqm = 0;

    for (const cell of cluster) {
      const ring = cell.geometry.coordinates[0] as Position[];
      const result = await claimTerritory(user.id, ring, {
        distanceM: turf.length(turf.polygonToLine(cell), { units: "meters" }),
        trackPointCount: ring.length,
      });

      if (result.ok) {
        claimed++;
        areaSqm += result.territory.areaSqm;
      } else {
        console.log(`  ${name}: rejected — ${result.error}`);
      }
    }

    console.log(
      `${name}: ${claimed} territories, ${(areaSqm / 1e6).toFixed(3)} km²`
    );
  }
}

async function main() {
  if (process.argv.includes("--clean")) {
    await clean();
    return;
  }
  await seed();
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
