// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Two registries, both project name -> chat_id:
//
//  - Per-repo `.chattr-agents.json` at a project's repo root (committed to
//    git) — lets anyone who checks out that repo find its chat without an
//    out-of-band channel, and is the original v1 mechanism.
//  - Global `~/.claude/chattr-agents.json` — this server is registered
//    machine-wide (`claude mcp add --scope user`), so an agent can open or
//    keep writing to ANY project's chat by name regardless of which repo's
//    directory the current session happens to be in (Gerry's requirement,
//    2026-07-12: "global vermerkt, sodass ihr zu jedem Projekt einen Chat
//    aufmachen/weiterschreiben könnt").
//
// chat_id is non-secret: knowing it only allows a join *request*, which
// still needs admin approval (see chats.ts).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export interface AgentRegistryEntry {
  project: string;
  chat_id: string;
}

function repoRegistryPath(repoPath: string): string {
  return path.join(repoPath, '.chattr-agents.json');
}

function globalRegistryPath(): string {
  // Override so tests never touch the real ~/.claude/chattr-agents.json.
  return process.env.CHATTR_GLOBAL_REGISTRY_PATH ?? path.join(os.homedir(), '.claude', 'chattr-agents.json');
}

export function readRepoRegistry(repoPath: string): AgentRegistryEntry | null {
  try {
    return JSON.parse(fs.readFileSync(repoRegistryPath(repoPath), 'utf8')) as AgentRegistryEntry;
  } catch {
    return null;
  }
}

function readGlobalRegistry(): Record<string, string> {
  try {
    return JSON.parse(fs.readFileSync(globalRegistryPath(), 'utf8')) as Record<string, string>;
  } catch {
    return {};
  }
}

/** Global lookup by project name — works from any cwd. */
export function readGlobalChatId(project: string): string | null {
  return readGlobalRegistry()[project] ?? null;
}

export function writeRegistry(repoPath: string, entry: AgentRegistryEntry): void {
  fs.writeFileSync(repoRegistryPath(repoPath), JSON.stringify(entry, null, 2) + '\n', 'utf8');

  const globalPath = globalRegistryPath();
  const global = readGlobalRegistry();
  global[entry.project] = entry.chat_id;
  fs.mkdirSync(path.dirname(globalPath), { recursive: true });
  fs.writeFileSync(globalPath, JSON.stringify(global, null, 2) + '\n', { mode: 0o600 });
}

/** All known project -> chat_id mappings, global registry first (works from any cwd), repo-local as override/fallback. */
export function readRegistry(repoPath: string): AgentRegistryEntry | null {
  return readRepoRegistry(repoPath);
}
