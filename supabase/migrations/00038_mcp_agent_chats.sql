-- ============================================================================
-- 00038: MCP agent chats — token-bound owner visibility
-- ----------------------------------------------------------------------------
-- Lets an MCP agent client (a headless Chattr account acting on behalf of an
-- AI agent) bind a group chat it created to a human owner, so that owner's
-- app can automatically discover and join it — no QR scan needed.
--
-- E2E constraint: the server never holds plaintext, so "visibility" cannot be
-- granted here — only *discovery*. The owner's app still has to become a real
-- encryption member (generate a per-chat keypair, go through the existing
-- pending_chat_members / approve flow) before it can decrypt anything. This
-- migration only adds:
--   (a) is_mcp / mcp_owner_id flags on chats,
--   (b) a per-user mcp_tokens table (hash only — plaintext is shown once,
--       client-side, right after minting),
--   (c) mint_mcp_token / revoke_mcp_token / bind_mcp_chat RPCs so an anon-key
--       MCP client (no service role) can mint nothing itself but bind a chat
--       it already belongs to using a token minted by the owner's app,
--   (d) an RLS carve-out so the owner can SELECT (discover) an MCP chat
--       bound to them before they've joined it,
--   (e) get_user_chats_with_metadata threading the two new columns through so
--       the app can tell an already-joined MCP chat apart from a normal one.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ============================================================================
-- PART 1: chats flags
-- ============================================================================

ALTER TABLE chats ADD COLUMN IF NOT EXISTS is_mcp BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE chats ADD COLUMN IF NOT EXISTS mcp_owner_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;

COMMENT ON COLUMN chats.is_mcp IS 'True once an MCP agent has bound this chat to a human owner via bind_mcp_chat(). Client segregates these into a separate "MCP-Chats" list.';
COMMENT ON COLUMN chats.mcp_owner_id IS 'The human user this MCP chat is bound to (set by bind_mcp_chat). That user''s app auto-joins on discovery; only they get RLS visibility pre-join.';

-- ============================================================================
-- PART 2: mcp_tokens — hash-only, minted/revoked exclusively via RPC below
-- ============================================================================

CREATE TABLE IF NOT EXISTS mcp_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  label TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at TIMESTAMPTZ
);

COMMENT ON TABLE mcp_tokens IS 'MCP agent tokens minted by a user. Only the SHA-256 hash is stored — the plaintext secret is returned once by mint_mcp_token() and never persisted server-side.';

ALTER TABLE mcp_tokens ENABLE ROW LEVEL SECURITY;

-- Owners can see their own token metadata (never the hash) to manage/revoke.
CREATE POLICY "Owners can view own mcp tokens"
ON mcp_tokens FOR SELECT
TO authenticated
USING (auth.uid() = owner_id);

-- No direct INSERT/UPDATE/DELETE policy: minting and revoking only happen via
-- the SECURITY DEFINER RPCs below, so a client can never write token_hash
-- directly or forge a token for another owner.

-- ============================================================================
-- PART 3: RPCs
-- ============================================================================

CREATE OR REPLACE FUNCTION mint_mcp_token(p_label TEXT DEFAULT NULL)
RETURNS TEXT
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_secret TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_secret := encode(gen_random_bytes(32), 'base64');

  INSERT INTO mcp_tokens (owner_id, token_hash, label)
  VALUES (auth.uid(), encode(digest(v_secret, 'sha256'), 'hex'), p_label);

  RETURN v_secret;
END;
$$;

COMMENT ON FUNCTION mint_mcp_token IS 'Mints a new MCP agent token for the calling user. Returns the plaintext secret ONCE — copy it into the MCP client config, it cannot be retrieved again.';

CREATE OR REPLACE FUNCTION revoke_mcp_token(p_token_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE mcp_tokens
  SET revoked_at = NOW()
  WHERE id = p_token_id
    AND owner_id = auth.uid()
    AND revoked_at IS NULL;
END;
$$;

COMMENT ON FUNCTION revoke_mcp_token IS 'Revokes one of the caller''s own MCP tokens. Already-bound chats are unaffected (binding is a one-time stamp, not a live check).';

CREATE OR REPLACE FUNCTION bind_mcp_chat(p_chat_id UUID, p_token TEXT)
RETURNS UUID
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_owner_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Caller (the agent) must already be a member of the chat it's binding —
  -- normally true because it just created it via the regular createChat path.
  IF NOT EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = p_chat_id
      AND chat_members.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not a member of chat %', p_chat_id;
  END IF;

  SELECT owner_id INTO v_owner_id
  FROM mcp_tokens
  WHERE token_hash = encode(digest(p_token, 'sha256'), 'hex')
    AND revoked_at IS NULL;

  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Invalid or revoked MCP token';
  END IF;

  UPDATE chats
  SET is_mcp = true, mcp_owner_id = v_owner_id
  WHERE id = p_chat_id;

  RETURN v_owner_id;
END;
$$;

COMMENT ON FUNCTION bind_mcp_chat IS 'Binds a chat the caller (an agent) already belongs to, to the human owner of the given MCP token — flags is_mcp and stamps mcp_owner_id so the owner''s app can auto-discover + auto-join it. Returns the owner id so the agent can auto-approve their join request.';

-- ============================================================================
-- PART 4: RLS — owner discovery before joining
-- ============================================================================

DROP POLICY IF EXISTS "Members can view their chats" ON chats;
CREATE POLICY "Members can view their chats"
ON chats FOR SELECT
TO authenticated
USING (
  -- User is a member of the chat
  EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = chats.id
    AND chat_members.user_id = auth.uid()
  )
  -- OR user is an admin of the chat
  OR auth.uid() = ANY(chats.admins)
  -- OR user is the bound owner of an MCP chat they haven't joined yet
  OR chats.mcp_owner_id = auth.uid()
);

COMMENT ON POLICY "Members can view their chats" ON chats IS 'Members can view chats they belong to. MCP owners can additionally discover (but not yet decrypt — no chat_members row means no message rows are theirs) chats bound to them, so their app can auto-join.';

-- ============================================================================
-- PART 5: get_user_chats_with_metadata — thread is_mcp / mcp_owner_id through
-- ============================================================================

DROP FUNCTION IF EXISTS get_user_chats_with_metadata(uuid[]);

CREATE OR REPLACE FUNCTION get_user_chats_with_metadata(p_chat_ids uuid[] DEFAULT NULL::uuid[])
RETURNS TABLE(
  id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  created_by uuid,
  name text,
  description text,
  admins text[],
  is_group boolean,
  message_ttl_seconds integer,
  last_message_at timestamptz,
  unread_count bigint,
  is_mcp boolean,
  mcp_owner_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    c.created_at,
    c.updated_at,
    c.created_by,
    c.name,
    c.description,
    c.admins::text[],
    c.is_group,
    c.message_ttl_seconds,
    (
      SELECT MAX(m.created_at)
      FROM messages m
      WHERE m.chat_id = c.id
        AND m.recipient_id = auth.uid()
    ) AS last_message_at,
    (
      SELECT COUNT(*)
      FROM messages m
      WHERE m.chat_id = c.id
        AND m.recipient_id = auth.uid()
        AND m.read_at IS NULL
    ) AS unread_count,
    c.is_mcp,
    c.mcp_owner_id
  FROM chats c
  INNER JOIN chat_members cm ON cm.chat_id = c.id
  WHERE cm.user_id = auth.uid()
    AND (p_chat_ids IS NULL OR c.id = ANY(p_chat_ids));
END;
$$;

-- Note: this RPC only returns chats the caller has already JOINED (INNER JOIN
-- chat_members). Pre-join MCP-chat discovery for the auto-join reconciler
-- goes straight against `chats` (RLS from PART 4 covers it), not through here.

NOTIFY pgrst, 'reload schema';
