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

## Convention: chat summaries (`_chattr_summarize` / `_chattr_summary`)

The app's summary sheet (MCP chats only) sends an ordinary E2E-encrypted
message whose body is a JSON envelope — an agent is not a server the app
could call, so the request travels the only way that reaches a sleeping
agent: as a message. Wire format lives in
`lib/features/summary/summary_envelope.dart`; there is no server-side
component because the server never sees plaintext.

**Request** (from the app): `{"_chattr_summarize":1, "scope":"unread"|"all"|
"since", "since":"<ISO8601>"?, "hint":"<free text>"?, "agent":"<userId>"?}`

**Reply** (from the agent): `{"_chattr_summary":1, "for":"<request
messageId>", "text":"<the summary, markdown allowed>"}` — sent as a normal
`chattr_send`; `messages.ts` detects the marker and stamps
`message_type='summary'` so the push trigger skips it (migration 00068).

Rules for an agent session that sees a request via `chattr_fetch`/`chattr_wait`:

1. **Only answer if addressed.** When `agent` is set and it is not your own
   userId (`chattr_status`), stay silent — the chat may hold several agents
   and exactly one (the user's chosen main agent) must answer. An absent
   `agent` means any agent may answer.
2. **`for` must be the request's messageId** — the sheet matches on it and
   ignores everything else.
3. **Scope**: `since` present → summarise from there. `unread` without
   `since` → summarise since the requester's own last message (the best
   available proxy for "what did I miss"). `all` → the whole history you
   have (`chattr_history`). `hint` is advisory ("nur die offenen Punkte").
4. **Answer once, promptly.** The sheet gives up after ~60 s and tells the
   user no agent session is running; a late answer is still displayed if the
   sheet is open, but don't retry or follow up in prose — the envelopes are
   machinery, invisible in every chat UI, and stray prose is not.

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
