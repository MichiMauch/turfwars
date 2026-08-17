import * as turf from "@turf/turf";
import type { Position } from "geojson";

/**
 * How much of a walk followed a mapped road or path.
 *
 * This is shown, not enforced. Walking off-path in forest and on pasture is
 * legal in Switzerland (ZGB Art. 699) and is exactly what this game should
 * encourage — so a low share is information, not an offence.
 *
 * The data is swissTLM3D "Strassen und Wege" from geo.admin.ch. Its identify
 * endpoint caps at roughly 200 features per call, so the network is fetched in
 * small tiles and cached; whole-track bounding boxes would silently truncate.
 */

const LAYER = "ch.swisstopo.swisstlm3d-strassen";
const TILE_DEGREES = 0.005;
/** Roughly GPS accuracy plus the width of a road. */
const TOLERANCE_M = 25;
/** Enough to characterise a walk without grinding through 6000 fixes. */
const MAX_SAMPLES = 200;
/** Tiles are grown by this much so a way just outside still counts. */
const TILE_MARGIN = 0.0005;

/** Coordinates of every way line in a tile. */
const tileCache = new Map<string, Position[][]>();

function tileKey(lng: number, lat: number): string {
  return `${Math.floor(lng / TILE_DEGREES)}:${Math.floor(lat / TILE_DEGREES)}`;
}

async function loadTile(key: string): Promise<Position[][] | null> {
  const cached = tileCache.get(key);
  if (cached) return cached;

  const [tx, ty] = key.split(":").map(Number);
  const bbox = [
    tx * TILE_DEGREES - TILE_MARGIN,
    ty * TILE_DEGREES - TILE_MARGIN,
    (tx + 1) * TILE_DEGREES + TILE_MARGIN,
    (ty + 1) * TILE_DEGREES + TILE_MARGIN,
  ].join(",");

  const url =
    `https://api3.geo.admin.ch/rest/services/api/MapServer/identify` +
    `?geometry=${bbox}&geometryType=esriGeometryEnvelope&layers=all:${LAYER}` +
    `&mapExtent=${bbox}&imageDisplay=500,500,96&tolerance=0` +
    `&returnGeometry=true&geometryFormat=geojson&sr=4326`;

  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(15000) });
    if (!response.ok) return null;

    const data = (await response.json()) as {
      results?: Array<{ geometry?: { type: string; coordinates: unknown } }>;
    };

    const lines: Position[][] = [];
    for (const feature of data.results ?? []) {
      const geometry = feature.geometry;
      if (!geometry) continue;

      if (geometry.type === "LineString") {
        lines.push(geometry.coordinates as Position[]);
      } else if (geometry.type === "MultiLineString") {
        lines.push(...(geometry.coordinates as Position[][]));
      }
    }

    tileCache.set(key, lines);
    return lines;
  } catch {
    // Never cache a failure — the next claim should try again
    return null;
  }
}

/** Evenly spaced sample of a track, first and last point kept. */
function sample(track: Position[], count: number): Position[] {
  if (track.length <= count) return track;

  const step = (track.length - 1) / (count - 1);
  const picked: Position[] = [];
  for (let i = 0; i < count; i++) picked.push(track[Math.round(i * step)]);
  return picked;
}

/**
 * Share of the track within {@link TOLERANCE_M} of a mapped way, 0–100.
 * Returns null when the network could not be loaded — better no number than
 * a wrong one that reads as "walked through a field".
 */
export async function pathShare(
  track: Position[],
  deadlineMs = 5000
): Promise<number | null> {
  if (track.length < 2) return null;

  const samples = sample(track, MAX_SAMPLES);
  const tiles = new Map<string, Position[][]>();
  const giveUpAt = Date.now() + deadlineMs;

  for (const key of new Set(samples.map((p) => tileKey(p[0], p[1])))) {
    // A nice-to-have number must never hold up a claim
    if (Date.now() > giveUpAt) return null;

    const lines = await loadTile(key);
    if (lines === null) return null;
    tiles.set(key, lines);
  }

  let onPath = 0;

  for (const position of samples) {
    const point = turf.point(position);
    const lines = tiles.get(tileKey(position[0], position[1])) ?? [];

    for (const line of lines) {
      if (line.length < 2) continue;
      const distance = turf.pointToLineDistance(point, turf.lineString(line), {
        units: "meters",
      });
      if (distance <= TOLERANCE_M) {
        onPath++;
        break;
      }
    }
  }

  return (onPath / samples.length) * 100;
}
