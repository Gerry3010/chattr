-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00082: Chat requests — nobody writes to you without your consent
-- ----------------------------------------------------------------------------
-- Whoever creates a chat is its admin (set_creator_as_admin), and the INSERT rule
-- on chat_members (00052) allows them to enter the second participant into a fresh
-- 1:1 — without that person being asked. Today the only brake on this is that the
-- profile view has been narrow since 00046: strangers cannot be found. But whoever
-- sits in a group with you already knows your UUID and could write to you unasked
-- right now. All that is missing is the button.
--
-- The button is being built right now (tap a member in the group → open a 1:1), so
-- consent comes first. Decided with Gerry on 2026-08-24:
--
--   1. ONE rule for everybody — the QR scan creates a request too. The
--      alternative ("a scan is consent") would mean believing the client that a
--      scan happened; the server cannot check that, so the bypass would have
--      remained.
--   2. Rejection is SILENT. The requester never learns of it — for them the
--      request stays "sent". They cannot request again.
--   3. No request text, only name and picture. Otherwise the request itself
--      becomes the channel: whoever is blocked simply sends requests with text.
--   4. Anyone whose ID one knows may be requested — not only shared groups.
--
-- CAUTION — the gate is NOT armed here yet. This migration creates the table, the
-- functions, the backfill and the notification; the lock that refuses a 1:1 chat
-- without an accepted request comes as a migration of its own, once the fleet can
-- take the new route. The other way round, shipped clients would create chats the
-- server rejects.
--
-- The profile view (00046) stays UNTOUCHED. The person being asked needs the
-- requester's name and picture in order to decide — they get those from
-- my_incoming_chat_requests(), a SECURITY DEFINER function returning exactly those
-- three fields for exactly that one person. Widening can_view_profile would have
-- had the same effect but with a larger attack surface: "send request → read
-- profile → withdraw" would have become a lookup table for every UUID passed
-- around, so precisely the enumeration 00046 closed.
-- ============================================================================

CREATE TABLE public.chat_requests (
  requester_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  target_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- Gesetzt bei Annahme ODER Ablehnung. `accepted` bleibt NULL, solange offen.
  decided_at   TIMESTAMPTZ,
  accepted     BOOLEAN,
  -- Only the requester hides a row from THEIR list; the row itself stays,
  -- because it carries the block against requesting again.
  withdrawn_at TIMESTAMPTZ,
  chat_id      UUID REFERENCES public.chats(id) ON DELETE SET NULL,
  PRIMARY KEY (requester_id, target_id),
  CHECK (requester_id <> target_id)
);

COMMENT ON TABLE public.chat_requests IS
  'Zustimmung zu einem 1:1-Chat. Der Primärschlüssel IST die Sperre gegen '
  'erneutes Anfragen nach einer Ablehnung — die Zeile bleibt stehen, statt '
  'gelöscht zu werden (dieselbe Mechanik wie pending_chat_members.blocked_at, '
  '00012). Kein Textfeld: eine Anfrage soll kein Kanal sein.';

CREATE INDEX chat_requests_target_open_idx
  ON public.chat_requests (target_id) WHERE accepted IS NULL;
CREATE INDEX chat_requests_requester_idx
  ON public.chat_requests (requester_id);

-- The primary key is DIRECTED, so a pair can have two rows — A→B and B→A. For
-- open and rejected rows that is right (that I rejected you must not stop me
-- writing to you myself later). For ACCEPTED ones it would be a contradiction:
-- two consents for one chat, which can diverge. So unique undirected exactly
-- there.
CREATE UNIQUE INDEX chat_requests_accepted_pair_idx ON public.chat_requests (
  (LEAST(requester_id::text, target_id::text)),
  (GREATEST(requester_id::text, target_id::text))
) WHERE accepted;

ALTER TABLE public.chat_requests ENABLE ROW LEVEL SECURITY;

-- Deliberately NO policy: neither SELECT nor INSERT/UPDATE/DELETE. If the
-- requester read the row directly, `accepted = false` would stand in it and the
-- silent rejection would be none. Everything runs through the functions below.

-- ============================================================================
-- Lesen
-- ============================================================================

-- What the person being asked sees: the open requests to them, with exactly the
-- fields needed to decide. The identity key is among them so the trust shield
-- is already right in the list (whoever was verified in a group is verified
-- here too — since 1.26 the pin hangs on the key, not on the id).
CREATE OR REPLACE FUNCTION public.my_incoming_chat_requests()
RETURNS TABLE (
  requester_id        UUID,
  username            TEXT,
  avatar_path         TEXT,
  identity_public_key TEXT,
  created_at          TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT r.requester_id, p.username, p.avatar_path, p.identity_public_key,
         r.created_at
  FROM public.chat_requests r
  JOIN public.profiles p ON p.id = r.requester_id
  WHERE r.target_id = auth.uid()
    AND r.accepted IS NULL
  ORDER BY r.created_at DESC;
$$;

COMMENT ON FUNCTION public.my_incoming_chat_requests IS
  'Offene Anfragen an mich, samt Name/Bild/Identitätsschlüssel des Anfragenden '
  '— ohne dafür die Profil-Sicht (00046) zu öffnen.';

-- What the REQUESTER sees. The state is deliberately boiled down: rejected
-- looks like open. Withdrawn rows are missing entirely.
CREATE OR REPLACE FUNCTION public.my_outgoing_chat_requests()
RETURNS TABLE (
  target_id  UUID,
  state      TEXT,
  chat_id    UUID,
  created_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT r.target_id,
         CASE WHEN r.accepted THEN 'accepted' ELSE 'pending' END,
         r.chat_id,
         r.created_at
  FROM public.chat_requests r
  WHERE r.requester_id = auth.uid()
    AND r.withdrawn_at IS NULL
  ORDER BY r.created_at DESC;
$$;

COMMENT ON FUNCTION public.my_outgoing_chat_requests IS
  'Meine gesendeten Anfragen. `state` kennt nur pending/accepted — eine '
  'Ablehnung sieht aus wie eine offene Anfrage, das ist die Zusage aus '
  'Entscheidung 2 und keine Nachlässigkeit.';

-- ============================================================================
-- Writing — exclusively through here
-- ============================================================================

-- A quota against bulk requests. Guessing UUIDs is hopeless (122 bits); the
-- real vector is a list passed around.
CREATE OR REPLACE FUNCTION public.send_chat_request(p_target UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me    UUID := auth.uid();
  v_state RECORD;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;
  IF p_target = v_me THEN
    RAISE EXCEPTION 'cannot request yourself' USING ERRCODE = 'check_violation';
  END IF;

  -- A blocked relationship behaves like a success and writes nothing. Checked
  -- FIRST, before quota and existence: otherwise the error message tells the
  -- blocked party that they are blocked.
  IF public.is_blocked_pair(v_me, p_target) THEN
    RETURN;
  END IF;

  -- The opposite direction first: if the other party requested ME and I now
  -- send a request to them, both have consented — that is the chat, not a
  -- second request. (It happens in a race between two devices, and it would be
  -- absurd to keep two people waiting who have both reached out.) A rejected
  -- counter-row does NOT stand in the way: that I rejected you says nothing
  -- about whether I want to write to you.
  SELECT * INTO v_state FROM public.chat_requests
   WHERE requester_id = p_target AND target_id = v_me;
  IF FOUND THEN
    IF v_state.accepted THEN
      RAISE EXCEPTION 'chat already exists' USING ERRCODE = 'unique_violation';
    END IF;
    IF v_state.accepted IS NULL THEN
      PERFORM public.accept_chat_request(p_target);
      RETURN;
    END IF;
  END IF;

  SELECT * INTO v_state FROM public.chat_requests
   WHERE requester_id = v_me AND target_id = p_target;

  IF FOUND THEN
    IF v_state.accepted THEN
      RAISE EXCEPTION 'chat already exists' USING ERRCODE = 'unique_violation';
    END IF;
    -- Open or rejected: the call looks the same in both cases. An attempt
    -- withdrawn earlier turns up as "open" again — otherwise its absence would
    -- reveal precisely the rejection that is meant to be silent.
    UPDATE public.chat_requests SET withdrawn_at = NULL
     WHERE requester_id = v_me AND target_id = p_target;
    RETURN;
  END IF;

  -- An unknown target is reported: without that feedback a typo in an entered
  -- ID would stay invisible, and whoever has the UUID knows it exists anyway.
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_target) THEN
    RAISE EXCEPTION 'no such user' USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF (SELECT count(*) FROM public.chat_requests
       WHERE requester_id = v_me AND accepted IS NULL) >= 20 THEN
    RAISE EXCEPTION 'too many open requests' USING ERRCODE = 'check_violation';
  END IF;
  IF (SELECT count(*) FROM public.chat_requests
       WHERE requester_id = v_me AND created_at > NOW() - INTERVAL '1 hour') >= 10 THEN
    RAISE EXCEPTION 'too many requests, try later' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO public.chat_requests (requester_id, target_id)
  VALUES (v_me, p_target);
END;
$$;

-- Accepting creates the chat. This is the ONLY place a 1:1 comes into being
-- once the gate is armed — the GUC handshake below is its credential (the same
-- pattern as chattr.admin_reassign in 00030; PostgREST clients cannot set GUCs,
-- so the handshake is unreachable from the API).
CREATE OR REPLACE FUNCTION public.accept_chat_request(p_requester UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me   UUID := auth.uid();
  v_chat UUID;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  PERFORM 1 FROM public.chat_requests
   WHERE requester_id = p_requester AND target_id = v_me AND accepted IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no open request' USING ERRCODE = 'no_data_found';
  END IF;

  IF public.is_blocked_pair(v_me, p_requester) THEN
    RAISE EXCEPTION 'blocked' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO public.chats (is_group) VALUES (FALSE) RETURNING id INTO v_chat;

  PERFORM set_config('chattr.direct_grant', 'on', TRUE);
  INSERT INTO public.chat_members (chat_id, user_id)
  VALUES (v_chat, v_me), (v_chat, p_requester);
  PERFORM set_config('chattr.direct_grant', 'off', TRUE);

  UPDATE public.chat_requests
     SET accepted = TRUE, decided_at = NOW(), chat_id = v_chat
   WHERE requester_id = p_requester AND target_id = v_me;

  -- An open counter-request is settled by the same chat. If it stayed, the
  -- other party's inbox would go on showing a request from somebody they have
  -- long been writing with.
  DELETE FROM public.chat_requests
   WHERE requester_id = v_me AND target_id = p_requester AND accepted IS NULL;

  -- The requester learns of the chat as they would of any other new chat.
  PERFORM public.chattr_send(
    jsonb_build_object(
      'type', 'newChat',
      'chat_id', v_chat,
      'timestamp', NOW()
    ),
    'event',
    'user:' || p_requester,
    FALSE
  );

  RETURN v_chat;
END;
$$;

-- Rejecting sends NOTHING — no event, no push, no change the requester could
-- see.
CREATE OR REPLACE FUNCTION public.decline_chat_request(
  p_requester UUID,
  p_block     BOOLEAN DEFAULT FALSE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  UPDATE public.chat_requests
     SET accepted = FALSE, decided_at = NOW()
   WHERE requester_id = p_requester AND target_id = v_me AND accepted IS NULL;

  IF p_block THEN
    INSERT INTO public.blocked_users (blocker_id, blocked_id)
    VALUES (v_me, p_requester)
    ON CONFLICT DO NOTHING;
  END IF;
END;
$$;

-- Withdrawing. A row still undecided disappears entirely (then requesting again
-- is allowed); one already rejected is merely taken out of one's own list, so
-- the block remains. Both routes end without an error — a differing error code
-- would be exactly the disclosure decision 2 rules out.
CREATE OR REPLACE FUNCTION public.withdraw_chat_request(p_target UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  DELETE FROM public.chat_requests
   WHERE requester_id = v_me AND target_id = p_target AND accepted IS NULL;

  UPDATE public.chat_requests SET withdrawn_at = NOW()
   WHERE requester_id = v_me AND target_id = p_target AND accepted = FALSE;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.my_incoming_chat_requests()   FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.my_outgoing_chat_requests()   FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.send_chat_request(UUID)       FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.accept_chat_request(UUID)     FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.decline_chat_request(UUID, BOOLEAN) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.withdraw_chat_request(UUID)   FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.my_incoming_chat_requests()   TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_outgoing_chat_requests()   TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_chat_request(UUID)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_chat_request(UUID)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.decline_chat_request(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.withdraw_chat_request(UUID)   TO authenticated;

-- ============================================================================
-- Notification — WITHOUT names
-- ============================================================================
-- Title and body travel along ONLY for devices that cannot yet render
-- themselves: `buildFcmMessage` strips both for `device_tokens.local_render`
-- (00065) and lets only ids through via `stripToIds`. On a current device
-- `push_local_renderer.dart` builds "X would like to write to you" from that —
-- the same route as with member_request, no special case.
--
-- TRAP: a new push type without a matching `case` in the renderer is not
-- generic on Android and web but MUTE (the `default:` returns null). Whoever
-- adds a type here adds it there as well.
CREATE OR REPLACE FUNCTION public.notify_chat_request()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  function_url TEXT;
BEGIN
  PERFORM public.chattr_send(
    jsonb_build_object(
      'type', 'chatRequest',
      'timestamp', NOW()
    ),
    'event',
    'user:' || NEW.target_id,
    FALSE
  );

  function_url := COALESCE(
    current_setting('app.settings.edge_function_url', true),
    'http://kong:8000/functions/v1/send-push-notification'
  );

  BEGIN
    PERFORM net.http_post(
      url := function_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || private.get_secret('service_role_key')
      ),
      body := jsonb_build_object(
        'type', 'chat_request',
        'user_ids', ARRAY[NEW.target_id],
        'title', 'Chattr',
        'body', 'Neue Chat-Anfrage',
        'data', jsonb_build_object(
          'type', 'chat_request',
          'requester_id', NEW.requester_id::text
        )
      )
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to send chat-request push: %', SQLERRM;
  END;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_chat_request_trigger ON public.chat_requests;
CREATE TRIGGER notify_chat_request_trigger
  AFTER INSERT ON public.chat_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_chat_request();

COMMENT ON FUNCTION public.notify_chat_request IS
  'Weckt den Angefragten. Der Name reist nur zu Geräten, die noch nicht selbst '
  'rendern können; aktuelle Geräte bekommen nur die Kennung und bauen den Text '
  'lokal (push_local_renderer.dart, Fall chat_request).';

-- ============================================================================
-- Grandfathering: existing 1:1 chats count as mutually permitted
-- ----------------------------------------------------------------------------
-- Gerry, 2026-08-24: "the already existing chats are to be regarded as mutually
-- permitted". Putting that into the data rather than into an exception in the
-- code is not cosmetics: without a backfill EVERY place in the client would
-- need a "chat exists but no request — permitted anyway", and every forgotten
-- place would offer a long-standing contact "send chat request". Worse would be
-- the obvious short-circuit "no entry → just permit it": that lifts the gate
-- again.
--
-- The requester is taken to be whoever created the chat; where that is missing
-- (old rows without created_by), the smaller UUID decides — the direction is
-- mere bookkeeping anyway, both are asked.
-- ============================================================================
-- As a function of its own rather than a bare statement: that way the backfill
-- can be tested (supabase/tests/chat_requests.sql creates 1:1 chats and calls
-- it) — a statement existing only once in the migration run cannot be told
-- apart from "does nothing" on a fresh, empty state. It is repeatable (ON
-- CONFLICT DO NOTHING) and not callable by clients.
CREATE OR REPLACE FUNCTION public.backfill_direct_chat_requests()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  INSERT INTO public.chat_requests
    (requester_id, target_id, created_at, decided_at, accepted, chat_id)
  SELECT
    CASE WHEN c.created_by IN (m.a, m.b) THEN c.created_by ELSE LEAST(m.a, m.b) END,
    CASE WHEN c.created_by IN (m.a, m.b)
         THEN CASE WHEN c.created_by = m.a THEN m.b ELSE m.a END
         ELSE GREATEST(m.a, m.b) END,
    c.created_at, c.created_at, TRUE, c.id
  FROM public.chats c
  JOIN (
    -- Postgres has no min()/max() for uuid; sorted via the text form the order
    -- is the same (same hex representation, same length).
    SELECT chat_id,
           (MIN(user_id::text))::uuid AS a,
           (MAX(user_id::text))::uuid AS b
    FROM public.chat_members
    GROUP BY chat_id
    HAVING count(*) = 2
  ) m ON m.chat_id = c.id
  WHERE NOT c.is_group
    -- Check undirected, otherwise a second row in the opposite direction comes
    -- into being for a freshly accepted request: the same pair with two states.
    AND NOT EXISTS (
      SELECT 1 FROM public.chat_requests x
       WHERE (x.requester_id = m.a AND x.target_id = m.b)
          OR (x.requester_id = m.b AND x.target_id = m.a)
    )
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.backfill_direct_chat_requests()
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.backfill_direct_chat_requests IS
  'Trägt für jeden bestehenden 1:1-Chat mit zwei Mitgliedern eine angenommene '
  'Anfrage nach. Wiederholbar; nicht für Clients.';

SELECT public.backfill_direct_chat_requests();
