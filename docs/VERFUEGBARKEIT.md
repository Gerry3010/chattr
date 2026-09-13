<!--
SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Ausfälle: sichtbar machen, dann überleben

Plan aus zwei Teilen, die getrennt nutzbar sind:

**A. Statusanzeige** — im Ausfall sagen, *was* nicht geht, *seit wann* und *wo
die Grenze liegt* (bei uns, beim Hoster, in deinem Netz).
**B. Zweiter Standort** — ein heißer Spiegel bei einem anderen Hoster, auf den
die App selbst umschaltet.

Teil A hat den weitaus besseren Ertrag pro Aufwand und geht zuerst.

---

## Anlass

Am **21.08.2026** war das Backend über Stunden weg. Ping 100 % Verlust, Ports
22/80/443 tot, während github.com und cloudflare.com in ~0,1 s antworteten.
Ursache laut netcup-status.de: **Netzstörung am Standort Wien**, in Bearbeitung.
Nichts an unserer Seite war kaputt, und nichts an unserer Seite hätte helfen
können — nicht einmal das Hoster-Panel kam an die Maschine.

Drei Lücken, die der Tag gezeigt hat:

1. **Niemand konnte es sehen.** Wer die App öffnete, sah ein Banner „Server
   nicht erreichbar" — richtig, aber ohne Grund und ohne Dauer. Von außen war
   nicht unterscheidbar, ob wir etwas kaputtgemacht hatten.
2. **Die Diagnose lief von Hand.** Ping, Portscan, Kontrollhosts, Statusseite
   des Hosters — alles nachträglich, alles einmalig, nichts davon aufgezeichnet.
3. **Es gab keinen zweiten Ort.** Der Ausfall dauerte exakt so lange wie die
   Störung des Hosters.

Hinzu kommt eine vierte, die der Tag nur gestreift hat: **die Sicherungen liegen
auf derselben Maschine** (`~/backups/` auf nc-chattr). Eine Sicherung, die mit
dem Original stirbt, ist keine.

---

## Was es schon gibt (nicht neu bauen)

| Baustein | Wo | Kann |
|---|---|---|
| Reconnect mit Backoff + Jitter | `event_bus_service.dart:183` | ~1s, 2s, 4s … 30s, ein Reconnect gleichzeitig |
| Verbindungszustand | `ServerConnection` (`connected`/`reconnecting`/`unreachable`) | `reconnecting` bleibt bewusst unsichtbar |
| Offline-Banner | `server_offline_banner.dart`, eingehängt in Chatliste + Chat | sagt „Server weg, deine Daten sind da" |
| Aufhol-Lauf nach Drop | `onResubscribed` | keine Lücke nach Reconnect |
| Proxy überlebt sich selbst | `harden-caddy-availability.sh` | `Restart=always`, Admin-API auf Unix-Socket |
| Health-Endpunkte | `/auth/v1/health`, `/realtime/v1/api/tenants/realtime-dev/health` | in `04-verify.sh` bereits benutzt |

Der Teil, der fehlt, ist nicht die Erkennung — es ist die **Aussage**: Das
Banner weiß, dass nichts durchkommt, aber nicht *warum*, und es kann „unser
Server ist weg" nicht von „dein WLAN ist weg" unterscheiden.

---

# Teil A · Statusanzeige

## Prinzip 1: Die Anzeige darf nicht auf dem liegen, worüber sie berichtet

Eine Statusseite auf nc-chattr wäre am 21.08. mit ausgefallen — und zwar genau
in der Minute, in der sie gebraucht wurde. Dasselbe gilt für den Beobachter, der
misst. Beides gehört woandershin.

**Zuhause der Statusseite: ein Cloudflare Worker + KV auf der bestehenden
chattr.at-Zone.** Kostenlos, global erreichbar, unabhängig von jedem unserer
Hoster — und, entscheidend: **nicht im Datenpfad**. Cloudflare sieht dabei kein
Nutzerverkehr, keine Chats, keine Konten, sondern liefert eine statische
Aussage über Dienstverfügbarkeit aus. Das ist der Grund, warum diese Entscheidung
nicht mit der Entscheidung gegen Cloudflare *vor der API* kollidiert: Dort ginge
es um die Verbindungs-Metadaten jedes Nutzers, hier um eine Datei mit fünf
Zeilen Zustand.

> Wer das auch nicht will, kann die Seite stattdessen auf die IONOS-Box legen —
> zweiter Hoster, gleicher Zweck, nur ohne Anycast. Der Rest des Plans ändert
> sich dadurch nicht.

## Prinzip 2: Zwei Beobachter, sonst misst man sich selbst

Ein einzelner Prüfer, der ausfällt, sieht aus wie ein Ausfall des Dienstes.
Deshalb **zwei unabhängige Beobachtungspunkte**:

- **Beobachter 1** — Cloudflare Worker mit Cron-Auslöser, alle 60 s. Kann nur
  HTTP (`fetch`), dafür von überall.
- **Beobachter 2** — ein kleines Skript auf der **IONOS-Box** (dem künftigen
  Standby), alle 60 s per systemd-Timer. Kann zusätzlich ICMP und rohe
  TCP-Verbindungen — und genau das trennt „Maschine weg" von „Dienst kaputt".

Beide schreiben ihr Ergebnis in denselben KV-Schlüssel.

> ⚠ **Nicht bei jedem Durchlauf schreiben.** Das kostenlose KV-Kontingent
> erlaubt rund **1.000 Schreibvorgänge pro Tag**; ein Minutentakt macht 1.440
> und läuft nach knapp 17 Stunden in die Wand — leise, und ausgerechnet dann
> steht die Statusseite auf altem Stand. Also: **nur bei Zustandswechsel
> schreiben**, dazu ein Lebenszeichen zur vollen Stunde. Damit bleibt der
> Verbrauch zweistellig, und die Seite kann zusätzlich anzeigen, wie alt ihre
> eigene Messung ist — eine Statusseite, die ihre eigene Frische verschweigt,
> ist im Ausfall wertlos.

Die Seite zeigt, **wie
viele Beobachter** ein Problem sehen. „2 von 2 sehen die API nicht" ist eine
Aussage; „ich sehe sie nicht" ist eine Vermutung.

## Prinzip 3: Die Fehlergrenze wird gemessen, der Verursacher benannt

Der automatische Teil ermittelt keine Schuld, sondern **wo die Kette abreißt**.
Das ist beweisbar, und daraus folgt die Zuordnung fast von selbst:

| ICMP | :443 | `/auth/v1/health` | Realtime | Schluss | Anzeige |
|:---:|:---:|:---:|:---:|---|---|
| ✗ | ✗ | ✗ | ✗ | Maschine nicht im Netz | **Nicht bei uns** — Hoster oder Weg dorthin |
| ✓ | ✗ | ✗ | ✗ | Proxy antwortet nicht | **Bei uns** — Reverse Proxy |
| ✓ | ✓ | ✗ | ✗ | HTTP ja, API nein | **Bei uns** — Backend-Dienste |
| ✓ | ✓ | ✓ | ✗ | nur Echtzeit tot | **Bei uns** — Realtime; Senden geht, Zustellung stockt |
| ✓ | ✓ | ✓ | ✓ | von außen alles gesund | **Bei dir** — Netz oder Gerät |

Die letzte Zeile ist die, die heute fehlt und die den Nutzern am meisten bringt:
Sie beendet die Frage „liegt's an mir?", ohne dass jemand raten muss.

**Was der Automatismus NICHT sagen darf:** „netcup ist schuld". Gemessen ist nur
„unterhalb unserer Dienste". Für den Namen gibt es zwei ehrliche Wege:

1. **Fremdmeldung als Hinweis.** Ein Abruf von `netcup-status.de` (und, wenn
   IONOS dazukommt, deren Statusseite) alle paar Minuten. Ergebnis wird
   **als Zitat mit Quelle und Link** gezeigt, nie als eigene Feststellung.
   Bricht das Auslesen, fehlt der Hinweis — nicht die Seite.
2. **Ein Satz von Hand.** Ein geschützter Endpunkt, auf den Gerry oder ein Agent
   eine Zeile schreibt: *„Ursache: Netzstörung netcup Wien, seit 01:40, Quelle: …"*.
   Am 21.08. hätte das binnen Minuten dagestanden.

Der Unterschied bleibt auf der Seite sichtbar: **gemessen** (mit Zeitstempel und
Beobachterzahl) gegen **gemeldet** (mit Quelle). Dieselbe Regel wie beim
CSP-Fehlschlag — eine Messung, die nur einen Teil abdeckt, darf nicht als
vollständige Aussage auftreten.

## Das Datenformat

Ein Dokument, `https://status.chattr.at/status.json`, `Cache-Control: no-store`,
CORS offen, keine Cookies, `Referrer-Policy: no-referrer`:

```json
{
  "stand": "2026-08-21T02:14:00Z",
  "gesamt": "stoerung",
  "dienste": [
    { "name": "api",      "zustand": "aus",   "seit": "2026-08-21T01:38:00Z",
      "beobachter": { "gesamt": 2, "sehen_problem": 2 } },
    { "name": "realtime", "zustand": "aus",   "seit": "2026-08-21T01:38:00Z" },
    { "name": "web",      "zustand": "aus",   "seit": "2026-08-21T01:38:00Z" },
    { "name": "landing",  "zustand": "aus",   "seit": "2026-08-21T01:38:00Z" },
    { "name": "updates",  "zustand": "aus",   "seit": "2026-08-21T01:38:00Z" }
  ],
  "grenze": "unterhalb-unserer-dienste",
  "zuordnung": { "art": "gemeldet", "wer": "netcup",
                 "text": "Netzstörung am Standort Wien",
                 "quelle": "https://www.netcup-status.de", "stand": "…" },
  "hinweis": "Deine Nachrichten liegen auf deinem Gerät und sind nicht betroffen."
}
```

`grenze` ist maschinenlesbar, `zuordnung.text` menschenlesbar. Der `hinweis` ist
kein Beiwerk: Bei einem verschlüsselten Messenger ist die erste Angst nicht
„der Dienst ist weg", sondern „mein Verlauf ist weg".

## Wo das auftaucht

1. **Statusseite** `status.chattr.at` — eine Seite, Live-Aktualisierung alle
   30 s, Verlauf der letzten 90 Tage als Streifen pro Dienst. Kein Login.
2. **Leiste auf chattr.at** — nur bei Störung, sonst nichts. Holt dieselbe
   Datei, keine zweite Wahrheit.
3. **Das bestehende App-Banner bekommt einen Grund.** Und zwar so, dass es
   nichts kostet, solange alles läuft: Die App fragt die Statusdatei
   **ausschließlich dann** ab, wenn `ServerConnection` auf `unreachable`
   springt. Aus „Server nicht erreichbar" wird dann eine der drei Aussagen:

   | Statusdatei sagt | Banner sagt |
   |---|---|
   | Störung, Grenze unterhalb unserer Dienste | „Beim Hoster liegt eine Störung vor (seit 01:38)." + Link |
   | Störung, Grenze bei uns | „Wir haben eine Störung. Wir arbeiten daran." + Link |
   | alles gesund | „Wir sind erreichbar — es sieht nach deinem Netz aus." |
   | Datei selbst nicht erreichbar | heutiger Text unverändert |

   Die dritte Zeile ist der eigentliche Gewinn und schließt Punkt 2 aus
   `backlog-server-offline-indicator` — ohne ein zusätzliches Paket wie
   `connectivity_plus` und ohne einen neuen Endpunkt auf unserer Seite.

**Datenschutz-Abwägung, offen benannt:** Diese Abfrage verrät Cloudflare, dass
eine bestimmte IP gerade eine Chattr-App laufen hat — allerdings nur im
Störungsfall, ohne Kennung, ohne Cookie, als einfaches GET einer statischen
Datei. Der Gegenwert ist, dass die App im Ausfall nicht mehr lügt oder schweigt.
Wer das nicht will, soll es abschalten können: ein Schalter in den Einstellungen,
Vorgabe **an**, bei „aus" bleibt der heutige Text stehen.

## Aufwand Teil A

| Stück | Aufwand |
|---|---|
| Worker + KV + Cron, fünf Prüfungen | ½ Tag |
| Zweiter Beobachter auf IONOS (Skript + Timer) | 2 h |
| Statusseite (eine Datei, kein Framework) | ½ Tag |
| Endpunkt + Ablauf für den Satz von Hand | 2 h |
| Leiste auf chattr.at | 2 h |
| App: Grund im Banner + Einstellung + Übersetzungen + Tests | ½ Tag |

---

# Teil B · Zweiter Standort

## Was „Load Balancer über zwei Hoster" hier nicht sein kann

Der klassische Lastverteiler — beide Seiten aktiv, Verkehr wandert hin und her —
ist für diesen Stapel nicht erreichbar, ohne entweder die Richtigkeit oder das
Versprechen aufzugeben:

- **Postgres hat einen Schreiber.** Zwei aktive Schreiber brauchen Multi-Master.
  Bei einem Server, der Chiffrat **nach Zustellung löscht**, ist eine
  auseinandergelaufene Historie nicht zusammenführbar: Was auf der einen Seite
  zugestellt und gelöscht wurde, existiert auf der anderen noch — und umgekehrt.
- **Storage und Realtime sind ebenso zustandsbehaftet.** Medien sind Dateien auf
  der Platte, mit erweiterten Attributen; Realtime hält offene Verbindungen und
  Mandantenzustand.
- **Ein gemeinsamer Eingang wäre ein Dritter im Datenpfad** — genau das, was
  bewusst ausgeschlossen wurde.

Also: **aktiv/passiv mit heißem Spiegel und clientseitigem Umschalten.**

Was das billiger macht als anderswo: **Der Server ist nicht das Archiv.** Die
Geräte halten den entschlüsselten Verlauf; der Server hält Chiffrat bis zur
Zustellung. Das Ziel ist deshalb nicht „nie ein Byte verlieren", sondern
„weiter annehmen und zustellen".

## Geteilt oder gespiegelt?

**Gespiegelt.** Eine *geteilte* Datenbank steht wieder auf einer Maschine — mit
ihr sterben dann beide Standorte, nur mit mehr Teilen dazwischen als heute. Dazu
liefe jede einzelne Abfrage über den Tunnel; Supabase macht viele kleine
Abfragen pro Anfrage, und die Verzögerung addiert sich sichtbar.

Physische Streaming-Replikation dagegen macht **denselben Cluster**, aus dem WAL
nachgespielt: Konten, Vertrauensbindungen, Mitgliedschaften, Zähler — alles
identisch, weil es dieselben Bytes sind, nicht weil jemand es abgleicht.
Rückstand üblicherweise unter einer Sekunde. „Ident" ist damit eine Eigenschaft
des Verfahrens, keine Aufgabe.

**Aber:** Ein Spiegel ist **schreibgeschützt**, bis er befördert wird. Er kann
Last nicht mittragen, er kann nur übernehmen. Und **Medien liegen nicht in der
Datenbank** — die brauchen einen zweiten Weg.

## Aufbau

```
   nc-chattr (Wien, primär)                IONOS (Standby)
   ┌──────────────────────┐   WireGuard   ┌──────────────────────┐
   │ Postgres  (rw)       │ ────────────► │ Postgres  (ro)       │
   │ Storage /volumes     │ ─ rsync -aX ─►│ Storage /volumes     │
   │ Caddy, Kong, Realtime│               │ derselbe Stapel, aus │
   │ api.chattr…          │               │ api2.chattr…         │
   └──────────────────────┘               └──────────────────────┘
              ▲                                      ▲
              └────────── Client wählt selbst ───────┘
                     (Liste + /status/role)
```

1. **WireGuard-Tunnel** zwischen beiden Boxen. Replikation gehört nicht im
   Klartext ins Internet, und der Tunnel spart das Aufbohren der Firewall für
   Postgres.
2. **Streaming-Replikation**, gleiches Abbild `supabase/postgres:15.8.1.085`,
   eigener Replikations-Slot.
   ⚠ **Slot mit `max_slot_wal_keep_size` begrenzen.** Ein stehengebliebener
   Standby lässt sonst das WAL auf dem **Primär** wachsen, bis dessen Platte
   voll ist — die Hochverfügbarkeit legt dann den Betrieb lahm, den sie
   schützen soll.
3. **Medien per `rsync -aX` im Takt** (z. B. alle 5 min).
   ⚠ **`-X` ist nicht optional.** Supabase-Storage legt seine Objekt-Metadaten
   als erweiterte Attribute (`user.supabase.*`) ab; ohne sie wirft storage-api
   bei **jedem** Objekt 500 „ENODATA" — die Dateien sind da und trotzdem
   unbrauchbar. Genau dieser Fehler ist beim Netcup-Umzug passiert.
4. **Geheimnisse identisch.** `.env` 1:1 (JWT_SECRET, ANON_KEY,
   SERVICE_ROLE_KEY, POSTGRES_PASSWORD) — neu erzeugen heißt Totalausfall, weil
   Anon-Key und URL in jeden Client eingebacken sind.
   ⚠ **Der pgsodium-Schlüssel muss mit.** Vault-Geheimnisse sind mit einem
   maschinenlokalen Schlüssel verschlüsselt. Fehlt der auf dem Standby, wirft
   `private.get_secret('service_role_key')` nach der Beförderung „invalid
   ciphertext" — und der Push-Trigger schluckt das still im EXCEPTION-Handler.
   Ergebnis: **Nachrichten kommen an, Pushes nicht**, ohne eine einzige
   Fehlermeldung. Beim Umzug hat genau das Stunden gekostet.
5. **Deploys gehen an beide.** Ein Standby mit altem Schema ist beim
   Umschalten schlimmer als keiner. Die Pipeline bekommt einen zweiten
   Deploy-Schritt; schlägt er fehl, ist der Bau **gelb**, nicht grün.

## Umschalten

**Kein automatisches Befördern.** Ein Netzriss zwischen den Standorten sieht von
jeder Seite aus wie „der andere ist tot"; automatisch befördert entsteht daraus
die eine Lage, aus der es kein Zurück gibt.

Stattdessen `promote.sh` mit Sicherung nach vorn:

1. Prüft von **zwei** Beobachtungspunkten (denselben wie Teil A), dass der
   Primär wirklich nicht antwortet — **verweigert den Dienst**, wenn er antwortet.
2. Befördert den Standby, schaltet Schreibzugriff frei.
3. Setzt die Rolle im Health-Endpunkt: `/status/role` → `primaer`.
4. Schreibt den Satz auf die Statusseite.
5. Sperrt den alten Primär gegen versehentliches Hochfahren (Stack-Autostart
   aus), damit die Rückkehr ein bewusster Schritt bleibt.

**Der Client wählt selbst.** `SUPABASE_URL` wird zu einer Liste. Regel:

- Primär versuchen. Antwortet er, fertig.
- Sonst der Reihe nach `/status/role` der übrigen Hosts fragen.
- **Nur einen Host benutzen, der sich selbst `primaer` nennt.** Ein Schreibversuch
  gegen den Spiegel ergibt sonst wirre Fehler statt einer klaren Aussage.
- Sagt keiner `primaer` → heutiges Verhalten, Banner mit Grund aus Teil A.

Das wirkt für Bauten, die die Liste kennen. Bestandsgeräte hängen weiter am
DNS-Eintrag — deshalb bleibt die TTL niedrig, und der A-Record wandert beim
Befördern mit. Das ist kein zweiter Mechanismus, sondern der einzige, den alte
Bauten haben.

## Was der Standby nicht löst

- **Medien der letzten Minuten** können fehlen (Takt des `rsync`). Eine
  Nachricht geht dabei nicht verloren, ein Download kann fehlschlagen.
- **Offene Echtzeit-Verbindungen** reißen. Der Aufhol-Lauf nach dem Reconnect
  fängt das ab — das Verfahren gibt es bereits.
- **Ein Fehler, den wir selbst ausliefern**, wandert auf den Standby mit. Gegen
  eine kaputte Migration hilft Hochverfügbarkeit nichts, nur Sicherungen.

---

# Reihenfolge

| Stufe | Inhalt | Aufwand | Löst |
|---|---|---|---|
| **0** | Sicherungen **weg von der Box** (IONOS oder Objektspeicher), täglich, Rückspielen einmal geübt | 2 h | Die Lücke, die heute am teuersten wäre |
| **1** | Teil A vollständig: Beobachter, Statusseite, Grund im Banner | ~2,5 Tage | Den eigentlichen Schmerz vom 21.08. |
| **2** | Standby aufbauen: WireGuard, Replikation, `rsync -aX`, Geheimnisse, zweiter Deploy-Schritt | ~2 Tage | Ausfall des Hosters wird überlebbar |
| **3** | `promote.sh` + `/status/role` + **eine echte Übung** | 1 Tag | Aus „vorhanden" wird „funktioniert" |
| **4** | Client-Hostliste in der App | ½ Tag | Umschalten ohne DNS-Warten (ab diesem Bau) |
| — | **Aktiv/Aktiv** | — | **Bewusst nicht.** Siehe oben. |

Stufe 0 und 1 lohnen unabhängig davon, ob 2–4 je kommen. Stufe 3 ohne Übung ist
wertlos: Ein Umschaltverfahren, das nie gelaufen ist, existiert nicht.

# Prüfen

- **Teil A:** Auf der Staging-Box den Stapel absichtlich stoppen → Seite muss
  binnen 2 Minuten „aus" zeigen, mit Grenze „bei uns". Danach nur Caddy stoppen
  → Grenze muss auf „Proxy" springen. Beobachter 2 abschalten → Seite muss
  „1 von 2" zeigen und trotzdem eine Aussage treffen.
- **Teil B:** Beförderung auf Staging üben, mit Stoppuhr. Danach ein Gerät, das
  die Hostliste kennt, gegen den beförderten Standby: senden, empfangen, Medien,
  **Push**. Push ist der Punkt, an dem die pgsodium-Falle zuschlägt — und der
  einzige, der ohne gezielte Prüfung still bleibt.
