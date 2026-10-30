-- 00051: Broadcast a `memberKeyRegistered` event when a member first registers
-- their per-chat public key (NULL → value).
--
-- A member's per-chat key is written by their OWN client a beat after they join
-- (E2E: only they hold the private half). The only trigger on that UPDATE —
-- `notify_key_rotation` (00036) — deliberately stays SILENT on NULL→key (it only
-- announces a real rotation, value→different value). So co-members never learned
-- the key had landed, and a sender who tried to send in that window got "No
-- member keys" and had to reload the app (#116).
--
-- This adds the missing live signal: when a member's public_key goes NULL→value,
-- broadcast `memberKeyRegistered` to every OTHER member on their `user:<id>`
-- channel, so the sender can refresh and send without a reload. The client also
-- has a short send-time retry (belt), but this closes the case where the peer
-- registers after that window.
--
-- MCP auto-approve joins (00039/00044) INSERT with public_key already set, so no
-- NULL→value UPDATE fires for them — correct, they need no signal. The
-- registration branch here is mutually exclusive with 00036's rotation branch
-- (NULL→value vs value→different-value), so a registration never emits a false
-- `keys_rotated`.

CREATE OR REPLACE FUNCTION broadcast_member_key_registered()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
  member_record RECORD;
BEGIN
  -- Only the FIRST registration (NULL → value).
  IF NOT (OLD.public_key IS NULL AND NEW.public_key IS NOT NULL) THEN
    RETURN NEW;
  END IF;

  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE chat_id = NEW.chat_id
      AND user_id <> NEW.user_id
  LOOP
    PERFORM realtime.send(
      jsonb_build_object(
        'type', 'memberKeyRegistered',
        'chat_id', NEW.chat_id,
        'user_id', NEW.user_id,
        'timestamp', NOW()
      ),
      'event',
      'user:' || member_record.user_id,
      FALSE
    );
  END LOOP;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION broadcast_member_key_registered IS
  'Broadcasts memberKeyRegistered to co-members when a member first registers their per-chat public key (NULL->value), so a sender can send without reloading (#116). Mutually exclusive with notify_key_rotation (which handles value->value rotations).';

DROP TRIGGER IF EXISTS broadcast_member_key_registered_trigger ON chat_members;
CREATE TRIGGER broadcast_member_key_registered_trigger
  AFTER UPDATE OF public_key ON chat_members
  FOR EACH ROW
  EXECUTE FUNCTION broadcast_member_key_registered();
