---
name: reset-db
description: Turf Wars Datenbank leeren (Territories deaktivieren, Rankings loeschen). Aktivieren bei "DB leeren", "reset DB", "Datenbank zuruecksetzen", "alle Territories loeschen".
user_invocable: true
---

# Turf Wars DB Reset

Setzt die Turf Wars Produktionsdatenbank zurueck: deaktiviert alle Territories und loescht alle Rankings.

## Verbindung

- **DB**: Turso (LibSQL) at `libsql://turf-wars-netnode-ag.turso.io`
- **Credentials**: `backend/.env` (`TURSO_DATABASE_URL`, `TURSO_AUTH_TOKEN`)

## Ausfuehrung

1. Lese die Credentials aus `backend/.env`
2. Fuehre folgendes Script aus:

```bash
cd <project-root>/backend && \
source <(grep -E '^TURSO_' .env | sed 's/^/export /') && \
npx tsx -e "
import { createClient } from '@libsql/client';
const client = createClient({ url: process.env.TURSO_DATABASE_URL!, authToken: process.env.TURSO_AUTH_TOKEN });
async function main() {
  const before = await client.execute('SELECT count(*) as n FROM territories WHERE active = 1');
  console.log('Active territories before:', before.rows[0].n);
  await client.execute('UPDATE territories SET active = 0');
  await client.execute('DELETE FROM rankings');
  const after = await client.execute('SELECT count(*) as n FROM territories WHERE active = 1');
  console.log('Active territories after:', after.rows[0].n);
  console.log('Rankings cleared');
}
main();
"
```

3. Zeige dem User das Ergebnis (wie viele Territories deaktiviert wurden)

## Wichtig

- Nur `active = 0` setzen, nicht loeschen (Historie bleibt erhalten)
- Rankings komplett loeschen (werden beim naechsten Claim neu berechnet)
- Keine Bestaetigung noetig — der User hat den Skill explizit aufgerufen

## Was der Skill bewusst nicht anfasst

- `territory_regions` bleibt stehen. Die Zeilen haengen an den Territories und
  werden bei jeder Auswertung ueber `territories.active` gefiltert, sind nach
  dem Deaktivieren also wirkungslos. Beim Loeschen von Territories muessen sie
  dagegen zuerst weg (Fremdschluessel).
- `admin_regions` niemals loeschen. Darin stecken die 2275 importierten
  Schweizer Regionen samt der aus den Kantonen gebauten Landesgrenze; ein
  Neuimport dauert Stunden. Ohne sie gibt es weder Gemeinde-Erkennung noch
  Ranglisten.
- User-Accounts bleiben erhalten. Simulierte Spieler tragen eine `sim-`
  Google-ID und werden stattdessen mit
  `npx tsx src/scripts/seed-simulation.ts --clean` entfernt.
