<!--
SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Sicherheitskonzept

Wie wir Chattr laufend auf Sicherheitslücken prüfen. Lücken meldest du wie in
[`SECURITY.md`](../SECURITY.md) beschrieben.

## Warum regelmäßig

Im Oktober 2026 haben wir Server, Backend, App-Code und Abhängigkeiten einmal
vollständig durchgesehen. Die schwersten Funde waren über Monate still
gewachsen: liegen gebliebene Updates, eine Prüfung, die nur in der Anzeige
wirkte, und Rechte in der Datenbank, die vom Stand im Repository abwichen.

Nichts davon fiel um, deshalb fiel es nie von allein auf. Seitdem prüfen wir
in festen Abständen.

## Drei Takte

### 1. Automatisch, bei jedem Push und jede Woche

Diese Prüfungen laufen ohne Zutun und melden sich nur, wenn sich etwas ändert.

| Wann | Was |
|---|---|
| Jeder Push | Statische Analyse (Semgrep), Wächter für gepinnte Forks und für die Backend-Version |
| Jeder Push | Migrations-Wächter (`scripts/ci/assert-migration-hygiene.py`): Jede neue `SECURITY DEFINER`-Funktion braucht einen festen `search_path` und ein `REVOKE … FROM PUBLIC`, jede neue Tabelle Row Level Security. Bricht den Push ab |
| Täglich | Offene Sicherheitsupdates und fällige Neustarts auf den Servern |
| Wöchentlich | Abhängigkeiten und Container-Images gegen bekannte Lücken (Trivy, OSV), Geheimnisse im Verlauf (gitleaks), Go-Module (govulncheck), Abstand der Images zu ihren aktuellen Versionen |

### 2. Prüfung durch Agenten

Mehrere KI-Agenten lesen den Code, jeder mit einer eigenen Rolle: Server,
Backend (Rechte, RPCs, Edge Functions), App (Kryptografie, Schlüssel,
Eingaben, Plattform, MCP-Server) sowie Abhängigkeiten und Images.

- Monatlich ein kleiner Durchlauf: nur, was sich seit der letzten Prüfung geändert hat.
  Das sind neue Migrationen, geänderte Krypto- und Abgleichspfade und neue
  Abhängigkeiten.
- Vierteljährlich der ganze Durchlauf.

Die Regeln dafür haben sich beim ersten Durchlauf bewährt:

- Die Agenten lesen nur. Kein `sudo`, keine Änderung am laufenden Betrieb. Angriffe
  werden nur gegen eine lokale Datenbank ausprobiert und danach zurückgerollt.
- Kein Bericht enthält Geheimnisse.
- Die Absichten kommen mit. Manches sieht von außen wie ein Fehler aus und
  ist eine Zusage, zum Beispiel: Ein Shot brennt beim Öffnen, der Server löscht
  eine Nachricht, sobald sie abgeholt ist, und Chattr scannt nie auf dem Gerät.
  Die Agenten bekommen diese Liste, damit sie Absicht nicht als Lücke melden.
- Jeder Fund wird gegengeprüft, bevor er als Ticket angelegt wird.
  Behauptungen, die niemand an der genannten Stelle im Code nachgesehen hat,
  gehen nicht weiter.

Das Ergebnis sind Tickets, gesammelt unter einem Epic je Durchlauf, dazu eine
Gesamtnote und der Vergleich mit dem letzten Durchlauf. Umgesetzt wird erst nach
einer Entscheidung, nicht automatisch.

### 3. Aus gegebenem Anlass

- vor jedem Release, das Kryptografie, den Abgleich mit dem Server oder
  Migrationen ändert: eine gezielte Durchsicht genau dieser Änderungen;
- nach einem Sicherheitshinweis für etwas, das wir verwenden (Supabase,
  Flutter-Pakete, Webserver, Vermittlungsdienst für Anrufe, Betriebssystem);
- nach einem Vorfall.

## Was das nicht ersetzt

Eine Prüfung durch Agenten ist keine unabhängige Prüfung durch Menschen. Sie
findet viel und billig, und sie kann sich irren. Darum der Gegencheck jedes
Fundes, und darum bleibt die Tür für Meldungen von außen offen.
