import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "crypto";

import {
  PLAYER_COLORS,
  defaultColorFor,
  isPlayerColor,
} from "./colors";

describe("Spielerfarben", () => {
  test("die Palette hat nur gültige Hex-Werte und keine Doppel", () => {
    for (const color of PLAYER_COLORS) {
      assert.match(color, /^#[0-9A-F]{6}$/);
    }
    assert.equal(new Set(PLAYER_COLORS).size, PLAYER_COLORS.length);
  });

  test("die Startfarbe ist stabil für dieselbe ID", () => {
    const id = randomUUID();
    assert.equal(defaultColorFor(id), defaultColorFor(id));
  });

  test("die Startfarbe liegt immer in der Palette", () => {
    for (let i = 0; i < 500; i++) {
      assert.ok(isPlayerColor(defaultColorFor(randomUUID())));
    }
  });

  test("die Startfarben verteilen sich über die ganze Palette", () => {
    const seen = new Set<string>();
    for (let i = 0; i < 2000; i++) seen.add(defaultColorFor(randomUUID()));
    // Sonst säßen alle Spieler auf derselben Farbe und der ganze Zweck wäre weg.
    assert.equal(seen.size, PLAYER_COLORS.length);
  });

  test("alles ausserhalb der Palette wird abgelehnt", () => {
    for (const value of [
      "#000000",
      "#e53935", // kleingeschrieben ist nicht dasselbe wie die Palette
      "red",
      "",
      null,
      undefined,
      42,
      { color: "#E53935" },
    ]) {
      assert.equal(isPlayerColor(value), false, `${JSON.stringify(value)}`);
    }
  });

  test("Palettenwerte werden angenommen", () => {
    for (const color of PLAYER_COLORS) assert.ok(isPlayerColor(color));
  });
});
