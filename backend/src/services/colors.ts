/**
 * The colours a player can carry on the map.
 *
 * A fixed set rather than a free picker: two players otherwise land on nearly
 * the same shade, and plenty of colours are unreadable over map tiles. The
 * server is the only authority on what is valid — a colour arriving from a
 * client is checked against this list and refused otherwise.
 *
 * The app keeps its own copy for the picker (app/lib/utils/player_colors.dart).
 * If the two drift, the server rejects the unknown value; wrong, but loudly.
 */
export const PLAYER_COLORS = [
  "#E53935", // red
  "#D81B60", // pink
  "#8E24AA", // purple
  "#5E35B1", // deep purple
  "#3949AB", // indigo
  "#1E88E5", // blue
  "#00ACC1", // cyan
  "#00897B", // teal
  "#43A047", // green
  "#F9A825", // amber
  "#FB8C00", // orange
  "#6D4C41", // brown
] as const;

export type PlayerColor = (typeof PLAYER_COLORS)[number];

export function isPlayerColor(value: unknown): value is PlayerColor {
  return (
    typeof value === "string" &&
    (PLAYER_COLORS as readonly string[]).includes(value)
  );
}

/**
 * A starting colour for a player, derived from their id.
 *
 * Stable and spread out, so everyone is distinguishable from their very first
 * territory without having chosen anything. It is written to the row rather
 * than derived on read — otherwise a player could never move away from a
 * colour they dislike, which is the whole point of letting them pick.
 */
export function defaultColorFor(userId: string): PlayerColor {
  // FNV-1a. Any stable hash does; this one is short and has no dependencies.
  let hash = 0x811c9dc5;
  for (let i = 0; i < userId.length; i++) {
    hash ^= userId.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return PLAYER_COLORS[hash % PLAYER_COLORS.length];
}
