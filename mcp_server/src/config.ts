// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.

import dotenv from 'dotenv';
import os from 'node:os';
import path from 'node:path';

// This server is registered globally (`claude mcp add --scope user`), so it
// runs from whatever directory the current Claude Code session happens to be
// in — a plain `import 'dotenv/config'` would load (or fail to find) a
// .env relative to that CWD instead. Load from a fixed, well-known location
// instead: ~/.claude/chattr-agent.env. Values already set in the actual
// process environment (e.g. via `-e` flags on the mcp add registration) take
// precedence — dotenv never overwrites an existing process.env var.
dotenv.config({ path: path.join(os.homedir(), '.claude', 'chattr-agent.env') });

/**
 * CHATTR_AGENT_PROFILE namespaces the state dir (session, per-chat keys,
 * local store) so multiple agent identities can run on the same machine —
 * used for local two-agent E2E testing, and lets one machine host more than
 * one agent account if that's ever useful. Defaults to a single "default"
 * profile, matching the plan's "one account per machine".
 */
const profile = process.env.CHATTR_AGENT_PROFILE ?? 'default';

export const config = {
  supabaseUrl: process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321',
  supabaseAnonKey: process.env.SUPABASE_ANON_KEY ?? '',
  /** Username stamped on first chattr_init; convention: suffix "-claude" so agent accounts are recognizable/auto-approvable. */
  agentUsername: process.env.AGENT_USERNAME,
  /** MCP token minted by the human owner's app — required to bind newly-created project chats. */
  mcpToken: process.env.MCP_TOKEN,
  stateDir: process.env.CHATTR_AGENT_STATE_DIR ?? path.join(os.homedir(), '.config', 'chattr-agent', profile),
  profile,
};
