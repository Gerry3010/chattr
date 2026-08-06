-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00069: Einladungs-Nachrichten (chat_invites) — Auto-Approve mit engem Scope
-- ----------------------------------------------------------------------------
-- Ein Admin teilt eine Gruppe als NACHRICHT in einen anderen Chat; wer die
-- Einladungskarte dort antippt, tritt OHNE Admin-Zustimmung bei. Das kehrt
-- das bisherige Modell (jeder Beitritt wird genehmigt, pending_chat_members)
-- punktuell um — deshalb sind die Grenzen eng gezogen:
--
--  * **Nur Admins erstellen** eine Einladung, **nur Admins widerrufen** sie.
--  * **Nur im Zielchat gültig** (target_chat_id): Einlösen kann nur, wer
--    Mitglied des Chats ist, in den die Einladung geschickt wurde. Eine
--    weitergeleitete Einladung ist damit wertlos — der Token allein öffnet
--    keine Tür, die Mitgliedschaft im Zielchat ist der zweite Faktor.
--  * **Gruppen-Sperren gelten weiter**: wer für die Gruppe blockiert wurde
--    (pending_chat_members.blocked_at), kann auch per Einladung nicht rein —
--    beim Auto-Approve schaut ja niemand mehr drauf.
--
-- Drei SECURITY-DEFINER-Funktionen, die Mitgliedschaft schreiben — genau die
-- Klasse, in der frühere RLS-Fehler saßen. Deshalb: search_path fixiert,
-- EXECUTE nur an authenticated, und JEDE Prüfung hat einen Negativtest
-- (test/chat_invites_rls_test.dart).
--
-- Der Einladungs-INHALT (Karte im Zielchat) reist als gewöhnliche E2E-
-- verschlüsselte Nachricht (`_chattr_invite`-Envelope) — der Server sieht wie
-- immer nur Ciphertext. Diese Tabelle hält nur, was der Server zum Prüfen
-- braucht: Token, Scope, Widerrufszustand. Kein Gruppenname, kein Text.
-- ============================================================================

CREATE TABLE public.chat_invites (
  token UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Die Gruppe, in die eingeladen wird.
  chat_id UUID NOT NULL REFERENCES public.chats(id) ON DELETE CASCADE,
  -- Der Gültigkeitsbereich: NUR Mitglieder dieses Chats können einlösen.
  target_chat_id UUID NOT NULL REFERENCES public.chats(id) ON DELETE CASCADE,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at TIMESTAMPTZ,
  revoked_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.chat_invites IS
  'Auto-Approve-Einladungen (1.13): Admin erstellt, Admin widerruft, einlösbar '
  'nur von Mitgliedern des target_chat_id. Inhalt der Einladung reist E2E-'
  'verschlüsselt als Nachricht; hier liegt nur der prüfbare Zustand.';

CREATE INDEX chat_invites_chat_id_idx ON public.chat_invites (chat_id);

ALTER TABLE public.chat_invites ENABLE ROW LEVEL SECURITY;

-- Lesen: nur Admins der eingeladenen Gruppe (für die Widerrufen-Liste in der
-- Gruppeninfo). Kein INSERT/UPDATE/DELETE für niemanden — Schreiben geht
-- ausschließlich über die drei Funktionen unten.
CREATE POLICY chat_invites_select_admins ON public.chat_invites
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = chat_invites.chat_id
        AND auth.uid() = ANY (c.admins)
    )
  );

-- ----------------------------------------------------------------------------
-- create_chat_invite: Admin der Gruppe UND Mitglied des Zielchats.
-- ----------------------------------------------------------------------------
-- Die Zielchat-Mitgliedschaft ist Belt-and-Suspenders: senden könnte der
-- Admin die Karte sowieso nur in Chats, in denen er Mitglied ist — aber die
-- Funktion soll das nicht dem Client glauben müssen.
CREATE OR REPLACE FUNCTION public.create_chat_invite(
  p_chat_id UUID,
  p_target_chat_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_token UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM chats c
    WHERE c.id = p_chat_id AND auth.uid() = ANY (c.admins)
  ) THEN
    RAISE EXCEPTION 'only admins can create invites';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM chat_members cm
    WHERE cm.chat_id = p_target_chat_id AND cm.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'not a member of the target chat';
  END IF;

  INSERT INTO chat_invites (chat_id, target_chat_id, created_by)
  VALUES (p_chat_id, p_target_chat_id, auth.uid())
  RETURNING token INTO v_token;

  RETURN v_token;
END;
$$;

-- ----------------------------------------------------------------------------
-- revoke_chat_invite: nur Admins der eingeladenen Gruppe. Idempotent
-- (zweimal widerrufen ist kein Fehler, der erste Zeitstempel bleibt).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.revoke_chat_invite(p_token UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_chat_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT chat_id INTO v_chat_id FROM chat_invites WHERE token = p_token;
  IF v_chat_id IS NULL THEN
    RAISE EXCEPTION 'invite not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM chats c
    WHERE c.id = v_chat_id AND auth.uid() = ANY (c.admins)
  ) THEN
    RAISE EXCEPTION 'only admins can revoke invites';
  END IF;

  UPDATE chat_invites
  SET revoked_at = NOW(), revoked_by = auth.uid()
  WHERE token = p_token AND revoked_at IS NULL;
END;
$$;

-- ----------------------------------------------------------------------------
-- redeem_chat_invite: der Auto-Approve. Prüft in dieser Reihenfolge:
--   1. Einladung existiert und ist nicht widerrufen.
--   2. Aufrufer ist Mitglied des ZIELchats (der Gültigkeitsbereich).
--   3. Aufrufer ist nicht für die Gruppe gesperrt (blocked_at).
-- Schon-Mitglied ist Erfolg, kein Fehler (die Karte zeigt „schon drin").
-- Der Einfügeweg entspricht der heutigen Admin-Genehmigung: pending-Zeile
-- weg, chat_members-Zeile mit dem mitgebrachten Public Key rein — dieselben
-- Trigger (Mitglieder-Broadcast, Schlüsseltausch) greifen unverändert.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.redeem_chat_invite(
  p_token UUID,
  p_public_key TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_invite RECORD;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT chat_id, target_chat_id, revoked_at INTO v_invite
  FROM chat_invites WHERE token = p_token;

  IF v_invite.chat_id IS NULL THEN
    RAISE EXCEPTION 'invite not found';
  END IF;
  IF v_invite.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'invite revoked';
  END IF;

  -- Der Gültigkeitsbereich: Einlösen kann nur, wer die Karte legitim sehen
  -- konnte — ein Mitglied des Chats, in den sie geschickt wurde.
  IF NOT EXISTS (
    SELECT 1 FROM chat_members cm
    WHERE cm.chat_id = v_invite.target_chat_id AND cm.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'not a member of the target chat';
  END IF;

  -- Schon drin → Erfolg (idempotent), und zwar VOR der Block-Prüfung: ein
  -- bestehendes Mitglied mit alter Sperr-Zeile soll nicht scheitern.
  IF EXISTS (
    SELECT 1 FROM chat_members cm
    WHERE cm.chat_id = v_invite.chat_id AND cm.user_id = auth.uid()
  ) THEN
    RETURN v_invite.chat_id;
  END IF;

  -- Gruppen-Sperre gilt auch hier — beim Auto-Approve prüft kein Admin mehr.
  IF EXISTS (
    SELECT 1 FROM pending_chat_members p
    WHERE p.chat_id = v_invite.chat_id
      AND p.user_id = auth.uid()
      AND p.blocked_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'blocked from this chat';
  END IF;

  IF p_public_key IS NULL OR length(p_public_key) = 0 THEN
    RAISE EXCEPTION 'public key required';
  END IF;

  -- Wie die Genehmigung heute: eventuelle pending-Anfrage aufräumen, dann
  -- Mitglied werden. Die bestehenden Trigger auf chat_members feuern normal.
  DELETE FROM pending_chat_members
  WHERE chat_id = v_invite.chat_id AND user_id = auth.uid();

  INSERT INTO chat_members (chat_id, user_id, public_key)
  VALUES (v_invite.chat_id, auth.uid(), p_public_key);

  RETURN v_invite.chat_id;
END;
$$;

-- Tabellen-Grant EXPLIZIT: neuere Supabase-Setups vergeben keine Default-
-- Grants mehr auf public (nur noch TRUNCATE/REFERENCES/TRIGGER/MAINTAIN) —
-- ohne diese Zeile wäre die RLS-Policy oben wirkungslos, weil PostgREST schon
-- am fehlenden SELECT-Grant scheitert. Auf Alt-Instanzen mit Legacy-Default-
-- ACL ist die Zeile redundant, aber nie falsch. Nur SELECT: geschrieben wird
-- ausschließlich über die SECURITY-DEFINER-Funktionen (Owner-Rechte).
GRANT SELECT ON public.chat_invites TO authenticated;

-- EXECUTE eng vergeben: nur eingeloggte Nutzer, nie anon/PUBLIC.
REVOKE EXECUTE ON FUNCTION public.create_chat_invite(uuid, uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.revoke_chat_invite(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.redeem_chat_invite(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_chat_invite(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_chat_invite(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_chat_invite(uuid, text) TO authenticated;
