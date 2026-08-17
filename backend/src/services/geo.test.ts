import { test, describe } from "node:test";
import assert from "node:assert/strict";
import * as turf from "@turf/turf";
import type { Feature, Polygon } from "geojson";

import {
  createTerritoryPolygon,
  checkPlausibility,
  isLoopClosed,
  findOverlaps,
  computeRegionShares,
  primaryRegion,
  type CachedRegion,
  type RegionLevel,
} from "./geo";

// Alle Testgeometrien liegen als achsenparallele Rechtecke in einem Raster
// über Muhen, dort wo auch die GPX-Testwalks aufgezeichnet wurden. Eine
// Rastereinheit sind rund 76 m in der Breite und 111 m in der Höhe, jedes
// Rechteck also deutlich über der 100-m²-Grenze.
const BASE_LNG = 8.05;
const BASE_LAT = 47.33;
const UNIT = 0.001;

function box(x0: number, y0: number, x1: number, y1: number): Feature<Polygon> {
  const lng = (x: number) => BASE_LNG + x * UNIT;
  const lat = (y: number) => BASE_LAT + y * UNIT;
  return turf.polygon([
    [
      [lng(x0), lat(y0)],
      [lng(x1), lat(y0)],
      [lng(x1), lat(y1)],
      [lng(x0), lat(y1)],
      [lng(x0), lat(y0)],
    ],
  ]);
}

const ME = "user-me";
const OTHER = "user-other";

function territory(id: string, userId: string, polygon: Feature<Polygon>) {
  return { id, userId, polygonGeojson: JSON.stringify(polygon) };
}

function area(feature: Feature<Polygon>): number {
  return turf.area(feature);
}

function region(
  id: string,
  level: RegionLevel,
  boundary: Feature<Polygon>
): CachedRegion {
  return {
    id,
    name: id,
    level,
    parentId: null,
    boundary,
    bbox: turf.bbox(boundary) as [number, number, number, number],
    areaSqm: turf.area(boundary),
  };
}

describe("createTerritoryPolygon", () => {
  test("lehnt weniger als vier Punkte ab", () => {
    const ring = box(0, 0, 4, 4).geometry.coordinates[0];
    assert.equal(createTerritoryPolygon(ring.slice(0, 3)), null);
  });

  test("lehnt einen offenen Track ab", () => {
    // Gerade Linie, Start und Ende liegen rund 300 m auseinander
    const open = [
      [BASE_LNG, BASE_LAT],
      [BASE_LNG + UNIT, BASE_LAT],
      [BASE_LNG + 2 * UNIT, BASE_LAT],
      [BASE_LNG + 4 * UNIT, BASE_LAT],
    ];
    assert.equal(createTerritoryPolygon(open), null);
  });

  test("nimmt einen bereits geschlossenen Ring unverändert an", () => {
    const ring = box(0, 0, 4, 4).geometry.coordinates[0];
    const result = createTerritoryPolygon(ring);
    assert.ok(result, "Polygon erwartet");
    assert.ok(result.areaSqm > 100_000);
  });

  test("schliesst einen Track, dessen Ende nahe genug am Start liegt", () => {
    const ring = box(0, 0, 4, 4).geometry.coordinates[0];
    // Statt exakt auf dem Startpunkt zu enden, hört der Track rund 7 m
    // daneben auf — so wie ein echter GPS-Track nach einer Runde
    const nearlyClosed = [...ring.slice(0, -1), [BASE_LNG + 0.0001, BASE_LAT]];
    const result = createTerritoryPolygon(nearlyClosed);
    assert.ok(result, "Polygon erwartet");
    assert.ok(result.areaSqm > 100_000);
  });

  test("lehnt einen Track ab, dessen Ende zu weit vom Start weg ist", () => {
    const ring = box(0, 0, 4, 4).geometry.coordinates[0];
    // Ohne den schliessenden Punkt endet der Track an der vierten Ecke,
    // rund 440 m vom Start entfernt
    assert.equal(createTerritoryPolygon(ring.slice(0, -1)), null);
  });

  test("lehnt eine zu kleine Fläche ab", () => {
    // 0.00005° ≈ 4 m, also rund 16 m² und damit unter der Grenze
    const tiny = [
      [BASE_LNG, BASE_LAT],
      [BASE_LNG + 0.00005, BASE_LAT],
      [BASE_LNG + 0.00005, BASE_LAT + 0.00005],
      [BASE_LNG, BASE_LAT + 0.00005],
      [BASE_LNG, BASE_LAT],
    ];
    assert.equal(createTerritoryPolygon(tiny), null);
  });
});

describe("isLoopClosed", () => {
  test("erkennt einen geschlossenen Loop", () => {
    const ring = box(0, 0, 4, 4).geometry.coordinates[0];
    assert.equal(isLoopClosed(ring), true);
  });

  test("erkennt einen offenen Track", () => {
    const ring = box(0, 0, 4, 4).geometry.coordinates[0];
    assert.equal(isLoopClosed(ring.slice(0, 3)), false);
  });
});

describe("findOverlaps", () => {
  test("ohne Überschneidung bleibt alles unangetastet", () => {
    const claim = box(0, 0, 5, 5);
    const result = findOverlaps(
      claim,
      [territory("t1", OTHER, box(20, 20, 25, 25))],
      ME
    );

    assert.deepEqual(result.fullyContained, []);
    assert.deepEqual(result.partialOverlaps, []);
    assert.ok(result.claimedPolygon);
    assert.equal(Math.round(area(result.claimedPolygon)), Math.round(area(claim)));
  });

  test("eigenes Gebiet komplett umschlossen wird deaktiviert", () => {
    const claim = box(0, 0, 10, 10);
    const result = findOverlaps(
      claim,
      [territory("eigen", ME, box(2, 2, 4, 4))],
      ME
    );

    assert.deepEqual(result.fullyContained, ["eigen"]);
    assert.deepEqual(result.partialOverlaps, []);
    assert.ok(result.claimedPolygon);
    assert.equal(Math.round(area(result.claimedPolygon)), Math.round(area(claim)));
  });

  test("eigenes Gebiet teilweise überlappt wird beschnitten", () => {
    const claim = box(0, 0, 10, 10);
    const eigen = box(8, 0, 14, 10);
    const result = findOverlaps(claim, [territory("eigen", ME, eigen)], ME);

    assert.deepEqual(result.fullyContained, []);
    assert.equal(result.partialOverlaps.length, 1);
    assert.equal(result.partialOverlaps[0].id, "eigen");

    // Der Rest ist das Stück rechts vom Claim, also ein Drittel des Originals
    const rest = area(result.partialOverlaps[0].remainingPolygon);
    assert.ok(rest < area(eigen), "Rest muss kleiner sein als vorher");
    assert.ok(Math.abs(rest / area(eigen) - 4 / 6) < 0.02);

    // Der Claim selbst bleibt in voller Grösse
    assert.ok(result.claimedPolygon);
    assert.equal(Math.round(area(result.claimedPolygon)), Math.round(area(claim)));
  });

  test("neue Schleife komplett im eigenen Gebiet wird abgelehnt", () => {
    const result = findOverlaps(
      box(2, 2, 4, 4),
      [territory("eigen", ME, box(0, 0, 10, 10))],
      ME
    );

    assert.equal(result.claimedPolygon, null);
  });

  test("fremdes Gebiet komplett umschlossen wird erobert", () => {
    const claim = box(0, 0, 10, 10);
    const result = findOverlaps(
      claim,
      [territory("fremd", OTHER, box(2, 2, 4, 4))],
      ME
    );

    assert.deepEqual(result.fullyContained, ["fremd"]);
    assert.deepEqual(result.partialOverlaps, []);
    assert.ok(result.claimedPolygon);
    assert.equal(Math.round(area(result.claimedPolygon)), Math.round(area(claim)));
  });

  test("fremdes Gebiet teilweise überlappt wird angeknabbert", () => {
    const claim = box(0, 0, 10, 10);
    const fremd = box(8, 0, 14, 10);
    const result = findOverlaps(claim, [territory("fremd", OTHER, fremd)], ME);

    // Der Claim bleibt vollständig — er wird nicht mehr beschnitten
    assert.ok(result.claimedPolygon);
    assert.equal(Math.round(area(result.claimedPolygon)), Math.round(area(claim)));

    // Stattdessen verliert das fremde Gebiet das überlappte Drittel
    assert.deepEqual(result.fullyContained, []);
    assert.equal(result.partialOverlaps.length, 1);
    assert.equal(result.partialOverlaps[0].id, "fremd");

    const rest = area(result.partialOverlaps[0].remainingPolygon);
    assert.ok(Math.abs(rest / area(fremd) - 4 / 6) < 0.02);
  });

  test("eine kleine Schleife im fremden Gebiet beisst ein Stück heraus", () => {
    const fremd = box(0, 0, 10, 10);
    const claim = box(2, 2, 4, 4);
    const result = findOverlaps(claim, [territory("fremd", OTHER, fremd)], ME);

    // Früher abgelehnt — jetzt bekommt man genau das Stück, das man umläuft
    assert.ok(result.claimedPolygon);
    assert.equal(Math.round(area(result.claimedPolygon)), Math.round(area(claim)));

    assert.deepEqual(result.fullyContained, []);
    assert.equal(result.partialOverlaps.length, 1);

    const rest = area(result.partialOverlaps[0].remainingPolygon);
    assert.ok(Math.abs(rest / (area(fremd) - area(claim)) - 1) < 0.02);
  });

  test("zerschneidet der Claim ein fremdes Gebiet, bleibt dessen grösstes Stück", () => {
    const claim = box(3, -2, 5, 12);
    const fremd = box(0, 0, 10, 10);
    const result = findOverlaps(claim, [territory("fremd", OTHER, fremd)], ME);

    assert.equal(result.partialOverlaps.length, 1);

    // Links bleiben 3 von 10 Einheiten, rechts 5 — das grössere Stück zählt
    const rest = area(result.partialOverlaps[0].remainingPolygon);
    assert.ok(Math.abs(rest / area(fremd) - 0.5) < 0.02);
  });

  test("die Reihenfolge von eigenem und fremdem Gebiet ändert nichts", () => {
    const claim = box(0, 0, 10, 10);
    const fremd = territory("fremd", OTHER, box(6, -2, 12, 12));
    const eigen = territory("eigen", ME, box(5, 0, 9, 10));

    const a = findOverlaps(claim, [fremd, eigen], ME);
    const b = findOverlaps(claim, [eigen, fremd], ME);

    assert.deepEqual(a.fullyContained.sort(), b.fullyContained.sort());
    assert.deepEqual(
      a.partialOverlaps.map((p) => p.id).sort(),
      b.partialOverlaps.map((p) => p.id).sort()
    );
    assert.equal(
      Math.round(area(a.claimedPolygon!)),
      Math.round(area(b.claimedPolygon!))
    );
  });

  test("die Reihenfolge zweier fremder Gebiete ändert nichts", () => {
    const claim = box(0, 0, 10, 10);
    const streifen = territory("streifen", OTHER, box(8, -2, 12, 12));
    const klein = territory("klein", OTHER, box(7, 4, 9, 6));

    const a = findOverlaps(claim, [streifen, klein], ME);
    const b = findOverlaps(claim, [klein, streifen], ME);

    assert.deepEqual(a.fullyContained.sort(), b.fullyContained.sort());
    assert.deepEqual(
      a.partialOverlaps.map((p) => p.id).sort(),
      b.partialOverlaps.map((p) => p.id).sort()
    );
  });

  test("mehrere Spieler verlieren gleichzeitig, was der Loop abdeckt", () => {
    const claim = box(0, 0, 10, 10);
    const result = findOverlaps(
      claim,
      [
        territory("ganz-drin", OTHER, box(2, 2, 4, 4)),
        territory("am-rand", "user-dritt", box(9, 0, 15, 10)),
        territory("eigen-drin", ME, box(6, 6, 8, 8)),
      ],
      ME
    );

    assert.deepEqual(result.fullyContained.sort(), ["eigen-drin", "ganz-drin"]);
    assert.deepEqual(
      result.partialOverlaps.map((p) => p.id),
      ["am-rand"]
    );
    assert.ok(result.claimedPolygon);
    assert.equal(Math.round(area(result.claimedPolygon)), Math.round(area(claim)));
  });
});

describe("computeRegionShares", () => {
  const claim = box(0, 0, 10, 10);

  test("ein Gebiet innerhalb einer Gemeinde ergibt genau einen Anteil", () => {
    const shares = computeRegionShares(claim, [
      region("muhen", "municipality", box(-5, -5, 15, 15)),
    ]);

    assert.equal(shares.length, 1);
    assert.equal(shares[0].regionId, "muhen");
    assert.equal(shares[0].level, "municipality");
    assert.ok(Math.abs(shares[0].areaSqm / area(claim) - 1) < 0.001);
  });

  test("ein Gebiet über der Gemeindegrenze wird aufgeteilt", () => {
    const shares = computeRegionShares(claim, [
      region("links", "municipality", box(-5, -5, 4, 15)),
      region("rechts", "municipality", box(4, -5, 15, 15)),
    ]);

    assert.equal(shares.length, 2);

    const links = shares.find((s) => s.regionId === "links")!;
    const rechts = shares.find((s) => s.regionId === "rechts")!;

    // Die Grenze liegt bei 4 von 10, also 40 zu 60
    assert.ok(Math.abs(links.areaSqm / area(claim) - 0.4) < 0.01);
    assert.ok(Math.abs(rechts.areaSqm / area(claim) - 0.6) < 0.01);

    // und zusammen ergeben sie wieder das ganze Gebiet
    const summe = links.areaSqm + rechts.areaSqm;
    assert.ok(Math.abs(summe / area(claim) - 1) < 0.001);
  });

  test("Regionen ohne Überschneidung tauchen nicht auf", () => {
    const shares = computeRegionShares(claim, [
      region("weit weg", "municipality", box(50, 50, 60, 60)),
    ]);

    assert.deepEqual(shares, []);
  });

  test("Ebenen werden nebeneinander erfasst", () => {
    const shares = computeRegionShares(claim, [
      region("gemeinde", "municipality", box(-1, -1, 11, 11)),
      region("bezirk", "district", box(-20, -20, 20, 20)),
      region("kanton", "canton", box(-50, -50, 50, 50)),
    ]);

    assert.deepEqual(
      shares.map((s) => s.level).sort(),
      ["canton", "district", "municipality"]
    );
    // Auf jeder Ebene liegt das ganze Gebiet drin
    for (const share of shares) {
      assert.ok(Math.abs(share.areaSqm / area(claim) - 1) < 0.001);
    }
  });

  test("Splitter unterhalb der Mindestfläche fallen weg", () => {
    const shares = computeRegionShares(
      claim,
      [region("nachbar", "municipality", box(-5, -5, 4, 15))],
      // Mindestfläche über dem tatsächlichen Anteil
      area(claim)
    );

    assert.deepEqual(shares, []);
  });
});

describe("primaryRegion", () => {
  const shares = [
    { regionId: "klein", level: "municipality" as const, areaSqm: 100 },
    { regionId: "gross", level: "municipality" as const, areaSqm: 900 },
    { regionId: "bezirk", level: "district" as const, areaSqm: 1000 },
  ];

  test("nimmt die Region mit dem grössten Anteil auf der Ebene", () => {
    assert.equal(primaryRegion(shares, "municipality"), "gross");
    assert.equal(primaryRegion(shares, "district"), "bezirk");
  });

  test("gibt null zurück, wenn die Ebene fehlt", () => {
    assert.equal(primaryRegion(shares, "country"), null);
  });
});

describe("createTerritoryPolygon bei sich kreuzenden Tracks", () => {
  test("eine Achterschleife verliert ihre Fläche nicht mehr", () => {
    // Die beiden Ecken über Kreuz verbunden — turf.area allein ergibt hier 0,
    // weil die Hälften gegenläufig sind
    const acht = [
      [BASE_LNG, BASE_LAT],
      [BASE_LNG + 2 * UNIT, BASE_LAT],
      [BASE_LNG, BASE_LAT + 2 * UNIT],
      [BASE_LNG + 2 * UNIT, BASE_LAT + 2 * UNIT],
      [BASE_LNG, BASE_LAT],
    ];

    assert.equal(Math.round(turf.area(turf.polygon([acht]))), 0);

    const result = createTerritoryPolygon(acht);
    assert.ok(result, "Polygon erwartet");

    // Übrig bleibt eine der beiden dreieckigen Schlaufen — bei dieser
    // Ausdehnung rund 8400 m², jedenfalls weit über der 100-m²-Grenze
    assert.ok(
      result.areaSqm > 5_000,
      `nur ${result.areaSqm.toFixed(0)} m² übrig`
    );
  });

  test("ein sauberes Rechteck bleibt unverändert", () => {
    const ring = box(0, 0, 4, 4).geometry.coordinates[0];
    const result = createTerritoryPolygon(ring);
    assert.ok(result);
    assert.equal(
      Math.round(result.areaSqm),
      Math.round(area(box(0, 0, 4, 4)))
    );
  });
});

describe("checkPlausibility", () => {
  /** Ein Ring mit realistischem Punktabstand entlang der Kanten. */
  function walkedRing(x0: number, y0: number, x1: number, y1: number) {
    const corners = box(x0, y0, x1, y1).geometry.coordinates[0];
    const dense: number[][] = [];
    for (let i = 0; i < corners.length - 1; i++) {
      const [ax, ay] = corners[i];
      const [bx, by] = corners[i + 1];
      for (let step = 0; step < 40; step++) {
        const t = step / 40;
        dense.push([ax + (bx - ax) * t, ay + (by - ay) * t]);
      }
    }
    dense.push(corners[0]);
    return turf.polygon([dense]);
  }

  test("ein gemütlich gelaufener Loop geht durch", () => {
    const polygon = walkedRing(0, 0, 2, 2);
    const umfang = turf.length(turf.polygonToLine(polygon), { units: "meters" });

    const result = checkPlausibility(polygon, {
      distanceM: umfang * 1.1,
      durationSec: (umfang / 1.4).toFixed(0) as unknown as number * 1,
    });

    assert.deepEqual(result, { ok: true });
  });

  test("vier Ecken um ein halbes Dorf sind kein Track", () => {
    const result = checkPlausibility(box(0, 0, 20, 20), {
      distanceM: 100000,
      durationSec: 100000,
    });

    assert.equal(result.ok, false);
    assert.match((result as { reason: string }).reason, /recorded points/);
  });

  test("genug Punkte, aber kilometerweit auseinander, zählt auch nicht", () => {
    // 16 Punkte gleichmässig auf dem Rand eines sehr grossen Rechtecks
    const corners = box(0, 0, 30, 30).geometry.coordinates[0];
    const sparse: number[][] = [];
    for (let i = 0; i < corners.length - 1; i++) {
      const [ax, ay] = corners[i];
      const [bx, by] = corners[i + 1];
      for (let step = 0; step < 4; step++) {
        const t = step / 4;
        sparse.push([ax + (bx - ax) * t, ay + (by - ay) * t]);
      }
    }
    sparse.push(corners[0]);

    const result = checkPlausibility(turf.polygon([sparse]), {
      distanceM: 100000,
      durationSec: 100000,
    });

    assert.equal(result.ok, false);
    assert.match((result as { reason: string }).reason, /coarse/);
  });

  test("ohne Dauer kein Claim", () => {
    const polygon = walkedRing(0, 0, 2, 2);
    const result = checkPlausibility(polygon, { distanceM: 1000 });

    assert.equal(result.ok, false);
    assert.match((result as { reason: string }).reason, /duration/);
  });

  test("weniger gelaufen als beansprucht wird abgelehnt", () => {
    const polygon = walkedRing(0, 0, 2, 2);
    const result = checkPlausibility(polygon, {
      distanceM: 50,
      durationSec: 3600,
    });

    assert.equal(result.ok, false);
    assert.match((result as { reason: string }).reason, /shorter/);
  });

  test("mit dem Auto abgefahren wird abgelehnt", () => {
    const polygon = walkedRing(0, 0, 2, 2);
    const umfang = turf.length(turf.polygonToLine(polygon), { units: "meters" });

    const result = checkPlausibility(polygon, {
      distanceM: umfang,
      durationSec: 30,
    });

    assert.equal(result.ok, false);
    assert.match((result as { reason: string }).reason, /km\/h/);
  });
});
