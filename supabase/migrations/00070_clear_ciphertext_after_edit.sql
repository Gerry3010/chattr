-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00070: Bearbeitete Nachrichten wieder löschbar machen
-- ----------------------------------------------------------------------------
-- Gefunden am 2026-08-06 auf Prod: 17 Nachrichten lagen MIT Inhalt auf dem
-- Server, obwohl längst zugestellt. Alle 17 hatten `edited_at` gesetzt — 100 %
-- Übereinstimmung, keine Ausnahme.
--
-- **Die Mechanik.** `mark_message_received()` leerte den Inhalt nur unter
-- `received_at IS NULL`. Beim Bearbeiten schreibt der Absender neuen
-- Chiffretext in die Zeile (Policy „Senders can update their messages"); ist
-- sie da bereits zugestellt, steht `received_at` schon, und die Löschung greift
-- **nie wieder**. Der neue Text bleibt dauerhaft liegen.
--
-- **Der Client macht bereits alles richtig.** `global_message_handler` holt die
-- bearbeitete Zeile, entschlüsselt, speichert lokal und ruft danach
-- ausdrücklich `markAsReceived` auf, um den Server wieder zu leeren („Re-clear
-- the server ciphertext now that we've consumed the new content", seit
-- 2026-06-21). Genau dieser zweite Aufruf lief ins `IF NOT FOUND` und warf
-- „Message not found or already received". Der Fehler sitzt allein hier.
--
-- Das widerspricht der öffentlichen Zusage „zugestellt = gelöscht"
-- (Blogbeitrag „Der Server vergisst"), deshalb wird zusätzlich der Bestand
-- nachgeräumt — siehe Begründung unten.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.mark_message_received(
  p_message_id UUID,
  p_chat_id    UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
-- Neu: fixierter search_path. Die Funktion hatte bisher keinen — bei einer
-- SECURITY-DEFINER-Funktion ist das die Standard-Härtung (wie in 00069).
SET search_path = 'public', 'pg_temp'
AS $function$
BEGIN
  UPDATE messages
  SET
    -- Der Zustellzeitpunkt bleibt der ERSTE. Ein Edit ist keine neue
    -- Zustellung — würde die Zeit vorrücken, spränge beim Absender der
    -- Zustell-Haken auf einen späteren Zeitpunkt, obwohl die Nachricht längst
    -- angekommen war.
    received_at = COALESCE(received_at, NOW()),
    encrypted_content = '',
    -- Zugestellt: der Empfänger hat das entschlüsselte Zitat lokal liegen,
    -- serverseitig braucht das niemand mehr.
    reply_to_preview = NULL,
    reply_to_sender_name = NULL
  WHERE id = p_message_id
    AND chat_id = p_chat_id
    AND recipient_id = auth.uid()
    -- Bisher nur `received_at IS NULL`. Der zweite Fall ist der Edit: schon
    -- zugestellt, aber es liegt wieder Inhalt da, den der Client gerade
    -- verbraucht hat. Ein doppelter Aufruf auf einer bereits geleerten Zeile
    -- trifft weiterhin nichts und wirft wie bisher.
    AND (received_at IS NULL OR encrypted_content <> '');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Message not found or already received';
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.mark_message_received(UUID, UUID) IS
  'Zustellung quittieren und den Chiffretext serverseitig löschen. Greift auch '
  'ein ZWEITES Mal, wenn eine bereits zugestellte Nachricht bearbeitet wurde '
  'und dadurch wieder Inhalt trägt (00070) — sonst bliebe der neue Text für '
  'immer liegen. Der Zustellzeitpunkt bleibt dabei der erste.';

-- ----------------------------------------------------------------------------
-- Bestand nachräumen.
--
-- Sicher, weil der Client den Inhalt nachweislich schon hat: Der Re-Clear-Pfad
-- im Client existiert seit 2026-06-21, die älteste betroffene Zeile stammt vom
-- 2026-07-14. Jede dieser Zeilen ist also den Weg „holen → entschlüsseln →
-- LOKAL SPEICHERN → markAsReceived" gegangen; der Client bricht vor dem
-- markAsReceived ab, wenn das lokale Speichern fehlschlägt. Gescheitert ist
-- nur der letzte Schritt, und zwar an der Bedingung, die diese Migration
-- korrigiert.
--
-- Bewusst NICHT über `mark_message_received` gelöst (das braucht `auth.uid()`
-- des jeweiligen Empfängers), sondern direkt — es ist ein einmaliges
-- Aufräumen dessen, was ohnehin hätte gelöscht sein müssen.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  geraeumt INTEGER;
BEGIN
  UPDATE public.messages
  SET encrypted_content = '',
      reply_to_preview = NULL,
      reply_to_sender_name = NULL
  WHERE received_at IS NOT NULL
    AND encrypted_content <> '';
  GET DIAGNOSTICS geraeumt = ROW_COUNT;
  RAISE NOTICE '00070: % zugestellte Zeilen nachtraeglich geleert', geraeumt;
END $$;
