-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- Fix a false "keys rotated" security alarm on every v3→v4 upgrade
-- (audit follow-up 2026-07-16, found live on the first real iOS upgrade).
--
-- notify_key_rotation() guarded on the WHOLE public_key JSON
-- (OLD.public_key = NEW.public_key). But the P0 trust layer re-registers the
-- SAME per-chat KEM key with an added identity signature, i.e. the blob goes
-- {"x":…,"m":…} → {"x":…,"m":…,"s":…}. Same key material, extra field → the
-- whole-JSON compare saw a difference and fired `keys_rotated`, which peers
-- render as a "keys rotated / possible compromise" warning. Firing that on a
-- routine signature addition is alarm fatigue — exactly wrong for an E2E app.
--
-- A REAL rotation is a change to the KEM key material: the X25519 pubkey ("x")
-- or the ML-KEM pubkey ("m"). The signature ("s") is not key material. So
-- compare only x and m; adding/replacing "s" alone is silent. This is the same
-- discriminator used to verify the M5 keychain migration held (x‖m hash).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.notify_key_rotation()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  username_text TEXT;
BEGIN
  -- Initial registration (NULL → key) is never a rotation.
  IF OLD.public_key IS NULL OR NEW.public_key IS NULL THEN
    RETURN NEW;
  END IF;

  -- Only the KEM key material (x25519 'x' + ml-kem 'm') defines a rotation.
  -- If both are unchanged, only the identity signature 's' (or nothing) moved
  -- — a v3→v4 upgrade, not a rotation — so stay silent.
  IF (OLD.public_key::json->>'x') IS NOT DISTINCT FROM (NEW.public_key::json->>'x')
     AND (OLD.public_key::json->>'m') IS NOT DISTINCT FROM (NEW.public_key::json->>'m') THEN
    RETURN NEW;
  END IF;

  SELECT username INTO username_text FROM profiles WHERE id = NEW.user_id;

  PERFORM insert_system_message(
    NEW.chat_id,
    'keys_rotated',
    NEW.user_id,
    COALESCE(username_text, 'A user')
  );

  RETURN NEW;
END;
$function$;
