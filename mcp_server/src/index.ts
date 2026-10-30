#!/usr/bin/env node
// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.

import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createServer } from './tools.js';
import { closeAll as closeRealtimeChannels } from './realtime.js';

async function main() {
  const server = createServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error('chattr-mcp-server running on stdio');

  process.on('SIGINT', async () => {
    await closeRealtimeChannels();
    await server.close();
    process.exit(0);
  });
}

main().catch((err) => {
  console.error('[Fatal]', err);
  process.exit(1);
});
