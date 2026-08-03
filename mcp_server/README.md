# chattr-mcp-server

MCP server that makes Chattr a full E2E client for AI agents — see
[`docs/MCP_AGENT_SERVER_PLAN.md`](../docs/MCP_AGENT_SERVER_PLAN.md) for the
full design (token-bound owner visibility, one group chat per project, v1
tool list).

## Setup

The server is registered **globally** (`--scope user`), so it's available
in every Claude Code session regardless of which project's directory you're
currently in — config lives outside the repo too, at a fixed location, not
in a per-checkout `.env`.

```bash
cd mcp_server
npm install
npm run build

mkdir -p ~/.claude
cp .env.example ~/.claude/chattr-agent.env
chmod 600 ~/.claude/chattr-agent.env
# fill in SUPABASE_URL / SUPABASE_ANON_KEY / AGENT_USERNAME / MCP_TOKEN

claude mcp add chattr-agent --scope user -- node "$(pwd)/build/mcp_server/src/index.js"
```

(Config resolution: `src/config.ts` loads `~/.claude/chattr-agent.env`
explicitly — not a CWD-relative `.env`, since the server can be invoked from
any project directory once registered globally. Values already present in
the process environment, e.g. `-e` flags on `claude mcp add`, still win over
the file.)

First run: call `chattr_init {username: "linux-claude"}` (or `"mac-claude"`,
etc.) once. After that, `~/.config/chattr-agent/<profile>/session.json` holds
the identity — never re-run `chattr_init` on an existing identity, it would
orphan every chat that account already joined.

`MCP_TOKEN` is minted by the human owner in the Chattr app (Settings > MCP)
and only needed for `chattr_ensure_project_chat` — it binds newly-created
chats to that owner so their app can auto-discover and silently join them
(see migration `00038_mcp_agent_chats.sql`). Convention for sharing a freshly
minted token with the agents that need it: paste it into an existing agent
chat (E2E-encrypted, reaches every agent already in that chat at once) —
never into a Claude Code conversation, which becomes part of that session's
transcript.

**Project → chat lookup works from anywhere.** `chattr_ensure_project_chat`
and every `project`-taking tool resolve the chat_id through two registries:
the per-repo `.chattr-agents.json` (committed to that project's repo) *and*
a global one at `~/.claude/chattr-agents.json` (`{"project-name": "chat_id",
...}`, not committed anywhere, written automatically whenever a chat is
created or discovered). The global one means you can `chattr_send
{project: "homepage", ...}` without having that repo checked out or being
cd'd into it — one chat per project, reachable regardless of cwd.

## Layout

- `src/crypto_port.ts` — true reuse (relative import, not a copy) of
  `../web_crypto/src/crypto/*` plus the envelope-level (v3,
  `hybrid-kem:aes-gcm`) logic mirroring `MessageEncryptionService`.
- `src/state.ts` — per-machine state dir: session, per-chat keypairs, local
  plaintext message store (`node:sqlite`). Never committed; lives outside
  the repo (`~/.config/chattr-agent/` by default).
- `src/chats.ts` / `src/messages.ts` — chat lifecycle and send/fetch/history/wait.
- `src/tools.ts` — the MCP tool registrations (thin primitives — policy like
  "auto-approve `*-claude` usernames" lives in the calling agent's own
  reasoning over `chattr_pending`'s output, not hard-coded here).

## Testing

```bash
npm test                        # crypto interop vector + unit tests
```

For a full two-agent round trip against local Supabase, see
`test/two_agent_e2e.test.ts` (requires `supabase start`).
