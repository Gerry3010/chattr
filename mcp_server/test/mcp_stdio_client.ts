// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Minimal test-only MCP stdio client: spawns the real built server as a
// child process (exactly how Claude Code would) and speaks newline-delimited
// JSON-RPC to it, so two_agent_e2e.test.ts exercises the actual transport +
// tool-registration layer, not just the underlying functions.

import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverEntry = path.join(__dirname, '../src/index.js'); // build/mcp_server/test -> build/mcp_server/src

export class McpStdioClient {
  private proc: ChildProcessWithoutNullStreams;
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: any) => void }>();
  private buffer = '';

  constructor(env: NodeJS.ProcessEnv, label: string) {
    this.proc = spawn(process.execPath, [serverEntry], {
      env: { ...process.env, ...env },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.proc.stderr.on('data', (chunk) => {
      const text = chunk.toString();
      if (!text.includes('ExperimentalWarning') && !text.includes('running on stdio')) {
        console.error(`[${label} stderr]`, text.trim());
      }
    });
    this.proc.stdout.on('data', (chunk) => this.onData(chunk.toString()));
  }

  private onData(chunk: string) {
    this.buffer += chunk;
    let idx: number;
    while ((idx = this.buffer.indexOf('\n')) !== -1) {
      const line = this.buffer.slice(0, idx).trim();
      this.buffer = this.buffer.slice(idx + 1);
      if (!line) continue;
      let msg: any;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (msg.id !== undefined && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id)!;
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
      }
    }
  }

  private send(method: string, params?: unknown, id?: number): Promise<any> | void {
    const msg: any = { jsonrpc: '2.0', method };
    if (params !== undefined) msg.params = params;
    if (id !== undefined) {
      msg.id = id;
      const p = new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
      this.proc.stdin.write(JSON.stringify(msg) + '\n');
      return p;
    }
    this.proc.stdin.write(JSON.stringify(msg) + '\n');
  }

  async initialize(): Promise<void> {
    const id = this.nextId++;
    await this.send(
      'initialize',
      {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'two-agent-e2e-test', version: '0' },
      },
      id,
    );
    this.send('notifications/initialized');
  }

  async callTool<T = any>(name: string, args: Record<string, unknown> = {}): Promise<T> {
    const id = this.nextId++;
    const result = await this.send('tools/call', { name, arguments: args }, id);
    const text = result?.content?.[0]?.text;
    if (result?.isError) {
      throw new Error(`Tool ${name} failed: ${text}`);
    }
    try {
      return JSON.parse(text) as T;
    } catch {
      return text as T;
    }
  }

  close(): void {
    this.proc.kill();
  }
}
