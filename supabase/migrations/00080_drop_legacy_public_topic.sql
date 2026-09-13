-- ============================================================================
-- 00080: the old public realtime channel is switched off
-- ----------------------------------------------------------------------------
-- 00063 introduced the private mirror (`p:<topic>`, RLS-protected on
-- `realtime.messages`) and explicitly went ON sending to the old public topic:
-- a `private:true` subscriber does not see public broadcasts and vice versa, so
-- a hard switch-over would have muted every client not yet updated. 00063 puts
-- it in so many words: "Once the fleet is through, the legacy line is deleted
-- in `chattr_send` — one line, one migration." This is that migration.
--
-- WHAT THE OLD CHANNEL GAVE AWAY: a freshly anonymously signed-in user could
-- subscribe to `user:<stranger-uuid>` and got the complete metadata feed live —
-- chat_id, sender_id, message_id, timestamps, reply graph, reactions,
-- membership changes. The content stayed ciphertext; who writes with whom and
-- when was readable. Since 00063 this channel has only run as a fallback — it
-- went on giving that away the whole time.
--
-- FLEET: the client has subscribed to the private topic since 0640092
-- (2026-08-03, `event_bus_service.dart:119`) — months before any device
-- currently active. Released by Gerry on 2026-08-20.
--
-- THE CONSEQUENCE FOR A DEVICE OLDER THAN 3 AUGUST: it loses live delivery but
-- not the messages. Push still arrives, and on opening or on returning from the
-- background the catch-up run fetches everything (`received_at IS NULL`). It
-- gets slower, not deaf.
--
-- `chattr_send`'s signature stays unchanged, so the twelve trigger functions
-- from 00063 do NOT have to be touched.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.chattr_send(
  payload JSONB,
  event TEXT,
  topic TEXT,
  private BOOLEAN DEFAULT FALSE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  -- The private topic only. The public legacy send is gone with this migration;
  -- `private` stays as a parameter so the signature — and thereby every caller
  -- — remains unchanged.
  PERFORM realtime.send(payload, event, 'p:' || topic, TRUE);
END;
$$;

COMMENT ON FUNCTION public.chattr_send IS
  'Broadcast-Helfer mit derselben Signatur wie realtime.send. Sendet ausschliesslich auf den privaten Topic (p:<topic>); der oeffentliche Legacy-Versand wurde in 00080 entfernt.';
