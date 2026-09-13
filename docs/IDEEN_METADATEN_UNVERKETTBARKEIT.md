<!--
SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Ideen: den Sozialgraphen am Server kleiner machen

> ## ⚠️ STATUS: IDEENSAMMLUNG — NICHT AUSGEREIFT, NICHTS ENTSCHIEDEN
>
> Dieses Dokument hält ein Gespräch zwischen Gerry und dem Linux-Claude vom
> **2026-08-23** fest. Es ist **kein Plan**, keine Zusage und keine
> Aufgabenliste. Mehrere Ideen darin sind bewusst zu Ende gedacht worden, um zu
> zeigen, **warum sie so nicht funktionieren** — wer nur die Überschriften liest,
> baut das Falsche.
>
> **Für den nächsten Agenten:** Alles unter „Ideen" ist offen. Alles unter
> „Belegte Befunde" ist an der laufenden Datenbank bzw. am Code gemessen und
> darf als Tatsache behandelt werden — mit dem üblichen Vorbehalt, dass Zahlen
> altern. Vor dem Weiterplanen bitte die Messungen wiederholen, nicht die Werte
> von hier übernehmen.

---

## Der Ausgangspunkt

Gerrys Frage: *„Wie funken nochmal die Chats bzw. Members? Könnte man darüber
nicht ein ‚Netz' bauen, wer mit wem schreibt?"* — und direkt danach die
Einordnung: **nicht als Feature gewünscht, sondern als wunder Punkt gesehen.**

Das ist die richtige Lesart. Der Inhalt ist Ende-zu-Ende verschlüsselt; der
Beziehungsgraph ist es nicht.

## Belegte Befunde

### Wo der Graph steht

```
profiles(id, username, avatar_path, identity_public_key)
chat_members(chat_id, user_id, public_key)      ← PK (chat_id, user_id) = DIE KANTE
chats(id, name, is_group, admins[], created_by)
messages(id, chat_id, sender_id, recipient_id, created_at, received_at, read_at)
                                                 ← eine Zeile PRO EMPFÄNGER
```

| Quelle | Aussage | Vorgesehene Haltbarkeit |
|---|---|---|
| `chat_members` | wer teilt einen Raum mit wem; bei `is_group=false` = ausdrückliche Paarbeziehung | unbegrenzt (funktional nötig) |
| `messages` | gerichtet, mit Zeitpunkt, Richtung, Häufigkeit | 7 Tage (`00062`) |

Eine Nachricht in eine 20er-Gruppe erzeugt **20 gerichtete Kanten**. Der Inhalt
wird bei Zustellung geleert (`mark_message_received`), die Zeile drumherum
bleibt bis zur Aufbewahrungsgrenze.

### Nutzer kommen nicht heran, Betreiber schon

RLS begrenzt die Sicht auf eigene Chats (`00005`), und `00046` schränkt sogar
`profiles` ein: sichtbar nur, wer einen Chat mit dir teilt. Grad 2 ist über die
API dicht. **Wer die Datenbank hat, hat den Graphen** — Betreiber, Backup,
beschlagnahmte Box.

### Der Fund vom 2026-08-23: die Aufbewahrung lief nie

`cron.job` enthielt genau **einen** Eintrag (`purge-dormant-accounts`, `00077`).
Es fehlten `cleanup_old_messages` (war in **keiner** Migration je eingeplant),
`delete-expired-messages` (`00014`), `cleanup-recovery-challenges` (`00050`),
`cleanup-old-media` (`00018`).

Gemessen an Prod: **4.773 Nachrichtenzeilen, älteste vom 2026-02-12**, davon
4.091 gelesen und älter als sieben Tage. 2 überfällige
Selbstzerstörungs-Nachrichten. 2,4 GB Medien, nie abgeräumt.

**Ursache:** `00014`/`00018`/`00050` prüfen
`IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')` — also „schon
installiert". War sie nicht. Kein ELSE, kein RAISE → die Migration lief grün
durch und lief nie wieder. `00077` machte es richtig (`pg_available_extensions`
+ `CREATE EXTENSION`), plante aber nur den eigenen Job ein.

> **Lehre über diesen Fall hinaus:** Ein bedingter Zweig, der bei
> Nichterfüllung schweigt, meldet Erfolg. Dasselbe Muster wie beim
> CSP-Fehlschlag („null Verstöße" hieß nur „nichts angefasst").

**→ `supabase/migrations/00081_rearm_missing_cron_jobs.sql` liegt fertig im Repo,
ist aber NICHT angewandt und NICHT committet.** Die Pipeline fährt Migrationen
beim Deploy mit; ein Commit würde sie automatisch scharf schalten. Braucht
Gerrys ausdrückliche Freigabe, davor ein Backup. Der erste Lauf holt ein halbes
Jahr auf einmal nach (siehe Kopf der Datei).

### Was ein Umbau anfassen müsste

| Fakt | Beleg |
|---|---|
| Der AAD bindet `chatId ‖ senderId ‖ messageId` | `lib/core/crypto/message_context.dart:40-44` |
| Ein Ed25519-Identitätsschlüssel **pro Konto**, in jedem Chat | `00047_profiles_identity_public_key` |
| Avatar hängt am Konto | `profiles.avatar_path` (`00015`) |
| `recipient_id` ist FK auf `auth.users` mit `ON DELETE CASCADE` | `00001_initial_schema.sql:99` |
| Flotten-Versionen messbar | `fleet_app_versions()` (`00076`) |

---

## Ideen (offen, unbewertet)

### Idee 1 — Pseudonyme IDs pro Chat

Gerrys Vorschlag: `hash(user_id, chat_id, secret)`, damit derselbe Mensch in
fünf Chats wie fünf verschiedene aussieht. Ziel ist **nicht** Verstecken,
sondern **Unverkettbarkeit** — aus einem Graphen werden unverbundene Räume.

**Vier Dinge würden es heute aushebeln:**

1. **Der Identitätsschlüssel.** Ein Ed25519-Schlüssel pro Konto signiert in
   *jedem* Chat die KEM-Bindung. Derselbe öffentliche Schlüssel überall = ein
   perfekter Verketter. Und er ist kein Versehen: Er existiert, damit „einmal
   verifiziert" auch im sechsten Chat gilt. **Wiedererkennbarkeit und
   Unverkettbarkeit sind direkte Gegner.** Beides zusammen ginge nur mit
   anonymen Berechtigungsnachweisen (blinde Signaturen, Richtung Privacy Pass).
2. **Zustellung braucht die Abbildung.** „Pseudonym → Gerät" muss existieren,
   sonst kein Push.
3. **Der Datenverkehr verkettet, was die Tabelle trennt.** Eine Sitzung, eine
   IP, holt für alle Pseudonyme ab.
4. **Name und Bild** (siehe Idee 2).

**Nicht abwärtskompatibel:** Der AAD bindet `senderId` → neue Umschlag-Version →
Rollout-Gate. Und solange ein ausgelieferter Client echte IDs braucht, muss die
Abbildung existieren; existiert sie, ist nichts gewonnen.

**Zusätzlich:** Ein Pseudonym kann kein FK sein. Ohne
`recipient_id → auth.users ON DELETE CASCADE` reißt ein gelöschtes Konto seine
Zeilen nicht mehr mit → Waisen bleiben unbegrenzt liegen. Eine Änderung, die
Metadaten reduzieren soll, würde dauerhafte Metadaten **erzeugen** — dieselbe
Ironie wie bei den Lesebestätigungen in `00062`.

### Idee 2 — Anzeige-Identität verschlüsseln (Name + Bild pro Chat)

Der Server hielte dann einen Graphen aus **UUIDs statt aus Namen und
Gesichtern**. Kein Umschlag-Bruch — das ist die Profil-Ebene, nicht das
Nachrichtenprotokoll. **Nach der Einschätzung im Gespräch das beste Verhältnis
von Wirkung zu Aufwand nach `00081`.**

Gerrys eigener Einwand dazu war richtig und geht noch weiter — Avatare lassen
sich nicht einfach duplizieren:

- **Gleiche Bytes verketten.** N Kopien = derselbe Hash. Also je Kopie eigener
  Schlüssel und eigener Zufalls-IV.
- **Dann verkettet die Größe.** Ein 84,3-KB-Bild ist überall 84,3 KB — dasselbe
  Problem, das bei Nachrichten die 256er-Auffüllung löst
  (`lib/core/crypto/envelope_padding.dart`). Avatare bräuchten dasselbe Raster.
- **Dann verkettet die Zeit.** Bildwechsel = N Objekte ändern sich in derselben
  Sekunde. Dagegen hilft nur zufälliges Verteilen über Stunden — was heißt, dass
  das neue Bild bei manchen erst morgen ankommt.
- **Der Benutzername verkettet genauso.** Wer überall „Gerry" heißt, ist überall
  verkettet.

### Idee 3 — Sealed Sender

Absenderkennung verschlüsselt in den Umschlag, der Server sieht nur „an X".
Entwertet die **gerichteten** Kanten in `messages`. `chat_members` bleibt.
Großes Stück; Folgen für Push, Zustellstatus und Missbrauchsabwehr.

**Wichtig für die Erwartung:** Der Empfänger ist die Richtung, die *nicht* geht.
Der Server muss zustellen — er muss wissen, wohin. Verstecken lässt sich der
Absender, nicht der Empfänger.

### Idee 4 — Absenderkennung bei Zustellung nullen (ungeprüft)

Würde das Fenster für die gerichtete Kante von sieben Tagen auf Minuten drücken.
**Offen:** Hängt der Zustell-/Lesestatus für den Absender an `sender_id`?
`get_sent_message_status` (`00042`) arbeitet über eine clientseitige
Wasserlinie — das wäre der erste Ort zum Nachsehen. Kleiner Aufwand, wenn es
trägt.

---

## Übergangsmechanik: Gate, nicht Doppelschreiben

Gerrys Vorschlag war eine Übergangsversion, die eine Zeit lang **in beide**
Strukturen schreibt (`messages` + `messages_v2`), bis alle einer Gruppe
aktualisiert haben.

**Für ein Feature ist das goldrichtig. Für eine Unverkettbarkeits-Änderung hebt
es sich selbst auf:** Liegt dieselbe Nachricht gleichzeitig mit echter und mit
pseudonymer Kennung vor, verbunden über dieselbe `message_id`, dann **ist die
Übergangstabelle die Zuordnungstabelle**. Ein Join genügt. Und der Übergang
dauert Monate (TestFlight, seitlich geladene APKs, Nie-Aktualisierer) — man legt
also freiwillig einen Stein von Rosetta an.

**Die Form, die trägt:** nicht zeitlich überlappen, sondern **pro Chat atomar
umschalten**. Jedes Mitglied meldet seine Fähigkeit; ein Chat bleibt vollständig
alt, bis **alle** umschalten können, dann kippt er vollständig. Keine Nachricht
existiert je in zwei Gestalten. Genau so lief das v3→v4-Gate.
Preis: ein langer Schwanz — dagegen hilft nur `min_supported_build` im
Updater-Manifest, also erzwungenes Update mit Frist. **Produktentscheidung.**

**Keine zweite Tabelle.** An `messages` hängen achtzig Migrationen voller
Invarianten (Quittungen, Reaktionen, `media_downloads`, Push-Trigger, drei
Aufbewahrungsregeln, Selbstzerstörung). Eine Parallelstruktur hieße, das alles
eine Zeit lang doppelt zu haben — dort wohnen die Fehler der Sorte „Nachricht
verschwindet spurlos", die dieses Projekt schon einmal hatte.

---

## Ausdrücklich verworfen

| Idee | Warum nicht |
|---|---|
| **„Netz"-Ansicht als Feature** | Gerry will es *nicht* als Feature. Möglich wäre ohnehin nur Grad 1 (eigene Chats + deren Mitglieder) — das zeigt die App schon. Grad 2 ist genau die Abfrage, die nie gebaut werden darf. Signalwert verheerend. |
| **Doppelschreiben in `messages_v2`** | Liefert die Zuordnung, die man abschaffen will. |
| **Zweite Nachrichtentabelle** | Doppelte Invarianten; FK/CASCADE nicht abbildbar. |
| **Empfänger verstecken** | Nicht möglich, solange der Server zustellt und Push existiert. |

## Vorgeschlagene Reihenfolge (unbestätigt)

1. **`00081`** — dem Graphen das Gedächtnis nehmen. *Wartet auf Gerrys Freigabe.*
2. **Anzeige-Identität verschlüsseln** — aus Namen und Gesichtern werden UUIDs.
3. **Sealed Sender** — gerichtete Kanten weg.
4. **Erst dann** Pseudonyme, falls dann noch etwas übrig ist, das den Aufwand trägt.

## Offene Fragen für den nächsten Agenten

- Hängt der Zustellstatus an `sender_id`? (Idee 4, kleiner Aufwand, ungeprüft)
- Hat **Staging** dieselbe Cron-Lücke? Vermutlich ja, nie geprüft.
- Wie misst man „alle Mitglieder eines Chats können v2"? `fleet_app_versions()`
  liefert die Flotte, nicht die Fähigkeit pro Mitglied — es fehlt eine Spalte
  oder eine Ableitung aus `device_app_version`.
- Ist erzwungenes Update (`min_supported_build`) als Werkzeug akzeptabel? Ohne
  das gibt es kein Gate, das je vollständig schließt.
- Was kostet die Avatar-Auffüllung wirklich? Bei Nachrichten war das Raster 256
  Zeichen — bei Bildern reden wir über andere Größenordnungen.

## Ehrlich zum Schluss

Die stärkste erreichbare Aussage ist nicht „es gibt keinen Graphen", sondern
**„er ist klein, kurzlebig und namenlos"**. Ein Server, der zustellen muss,
weiß, an wen. Alles hier zielt darauf, wie wenig er sonst noch weiß und wie
schnell er es vergisst.
