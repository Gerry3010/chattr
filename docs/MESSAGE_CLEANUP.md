# Message Cleanup System

## Übersicht

Chattr löscht automatisch alte Nachrichten vom Server, um Datenmüll zu vermeiden. Die Nachrichten bleiben lokal auf den Geräten erhalten, aber werden nach einer gewissen Zeit vom Server entfernt.

## Cleanup-Regeln

### 1. Gelesene Nachrichten
**Löschung nach: 7 Tagen**

Kriterium: `read_at IS NOT NULL AND read_at < NOW() - INTERVAL '7 days'`

Sobald eine Nachricht als gelesen markiert wurde (via `markAsRead()`), wird sie nach 7 Tagen automatisch vom Server gelöscht.

**Rationale:**
- User haben die Nachricht bereits gelesen und lokal gespeichert
- Kurze Aufbewahrungszeit für kürzlich gelesene Nachrichten
- Ermöglicht Read Receipts für bis zu 7 Tage

### 2. Ungelesene/Nicht empfangene Nachrichten
**Löschung nach: 30 Tagen**

Kriterium: `received_at IS NULL AND created_at < NOW() - INTERVAL '30 days'`

Nachrichten, die nie vom Empfänger abgeholt wurden, werden nach 30 Tagen gelöscht.

**Rationale:**
- Längere Aufbewahrungszeit für den Fall, dass User lange offline sind
- Verhindert unbegrenztes Anwachsen der Datenbank
- Nach 30 Tagen ist es unwahrscheinlich, dass die Nachricht noch relevant ist

## Technische Details

### Cleanup-Funktion
```sql
CREATE FUNCTION cleanup_old_messages() RETURNS INTEGER
```

Die Funktion:
- Löscht alte Nachrichten basierend auf den obigen Regeln
- Gibt die Anzahl gelöschter Nachrichten zurück
- Loggt die Ergebnisse via `RAISE NOTICE`

### Automatische Ausführung

**Schedule:** Täglich um 3:00 Uhr (UTC)
**Cron Expression:** `0 3 * * *`
**Extension:** PostgreSQL `pg_cron`

```sql
SELECT cron.schedule(
  'cleanup-old-messages',
  '0 3 * * *',
  'SELECT cleanup_old_messages();'
);
```

### Manuelle Ausführung

Falls nötig, kann die Cleanup-Funktion auch manuell ausgeführt werden:

```sql
SELECT cleanup_old_messages();
```

### Monitoring

Die Funktion gibt die Anzahl gelöschter Nachrichten zurück und loggt Details:

```
NOTICE: Message cleanup: deleted X read messages (>7 days) and Y unread messages (>30 days). Total: Z
```

Diese Logs können in den Supabase-Logs eingesehen werden.

## Lokale Entwicklung

In der lokalen Entwicklungsumgebung ist `pg_cron` möglicherweise nicht verfügbar. Die Funktion `cleanup_old_messages()` kann aber trotzdem manuell getestet werden.

## Produktion

Für Supabase-Projekte in der Cloud:
- `pg_cron` ist standardmäßig verfügbar
- Der Cron-Job wird automatisch bei der Migration erstellt
- Keine weitere Konfiguration nötig

## Datenschutz

**Wichtig:** Die Nachrichten werden nur vom **Server** gelöscht, nicht von den lokalen Geräten der User!

- ✅ Lokale Kopien bleiben erhalten (in der App's lokalem Storage)
- ✅ User behalten Zugriff auf ihre gesamte Nachrichtenhistorie
- ✅ Server speichert nur aktuelle/relevante Nachrichten für Synchronisation

## Anpassung der Zeiträume

Die Löschfristen können in der Migration `00016_add_message_cleanup.sql` angepasst werden:

```sql
-- Gelesene Nachrichten: Standard 7 Tage
WHERE read_at < NOW() - INTERVAL '7 days'

-- Ungelesene Nachrichten: Standard 30 Tage
WHERE created_at < NOW() - INTERVAL '30 days'
```

Nach Änderungen muss die Funktion neu deployed werden:
```bash
supabase db reset
# oder
supabase functions deploy
```
