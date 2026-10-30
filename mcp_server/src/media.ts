// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Downloads + decrypts a Chattr media blob (the encrypted `.enc` object a
// `_chattr_media` message points at) and writes the plaintext to a local file
// so an agent can actually view it. Mirrors the app exactly:
//   - blob layout  [nonce(12)] ++ [ciphertext] ++ [gcm tag(16)]   (28-byte overhead)
//     — lib/core/security/message_encryption_service.dart:135-159
//   - AES-256-GCM, per-message random 32-byte key (base64 in the message JSON)
//   - optional gzip applied BEFORE encryption → gunzip AFTER decrypt, only when
//     the message JSON carries `"compression":"gzip"`
//     — lib/features/media/media_compression.dart
//   - private bucket 'media', object path <chatId>/<messageId>/<name>.enc
//     — lib/features/media/media_repository.dart

import { createDecipheriv } from 'node:crypto';
import { gunzipSync } from 'node:zlib';
import { mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { getClient } from './supabase.js';

const BUCKET = 'media';
const NONCE_LEN = 12;
const TAG_LEN = 16;

export interface FetchMediaArgs {
  path: string; // bucket-relative object path from the message JSON
  key: string; // base64 raw 32-byte AES-256 key from the message JSON
  compression?: string; // 'gzip' when the payload was gzipped; omit otherwise
  name?: string; // original filename (used for the saved file's name)
  mime?: string;
  size?: number; // original plaintext byte length (integrity check)
  out_path?: string; // override where to save the decrypted file
}

export interface FetchMediaResult {
  saved_to: string;
  bytes: number;
  mime: string | null;
  name: string | null;
  size_matches: boolean | null;
}

export async function fetchMedia(args: FetchMediaArgs): Promise<FetchMediaResult> {
  const { data, error } = await getClient().storage.from(BUCKET).download(args.path);
  if (error || !data) {
    throw new Error(
      `storage download failed for '${args.path}': ${error?.message ?? 'no data returned'}`,
    );
  }
  const blob = Buffer.from(await data.arrayBuffer());
  if (blob.length < NONCE_LEN + TAG_LEN) {
    throw new Error(`blob too small (${blob.length} bytes) — no room for nonce + tag`);
  }

  const key = Buffer.from(args.key, 'base64');
  if (key.length !== 32) {
    throw new Error(`key must base64-decode to 32 bytes (got ${key.length})`);
  }

  const iv = blob.subarray(0, NONCE_LEN);
  const tag = blob.subarray(blob.length - TAG_LEN);
  const ciphertext = blob.subarray(NONCE_LEN, blob.length - TAG_LEN);

  let plain: Buffer;
  try {
    // Pin the GCM tag length to the full 16 bytes (TAG_LEN). Without this,
    // Node accepts shorter auth tags in setAuthTag(), which weakens forgery
    // resistance. The tag is already sliced to TAG_LEN above, so this only
    // makes the guarantee explicit (and satisfies the gcm-no-tag-length SAST).
    const decipher = createDecipheriv('aes-256-gcm', key, iv, { authTagLength: TAG_LEN });
    decipher.setAuthTag(tag);
    plain = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  } catch (e) {
    throw new Error(
      `AES-256-GCM decrypt failed (wrong key or corrupt blob): ${
        e instanceof Error ? e.message : String(e)
      }`,
    );
  }

  if (args.compression === 'gzip') {
    // Bounded (CHAT-41): a few KB of gzip can unpack to gigabytes. The
    // declared size plus slack, or 1 GiB when none was given.
    const limit = args.size !== undefined ? args.size + 1024 * 1024 : 1024 ** 3;
    plain = gunzipSync(plain, { maxOutputLength: limit });
  }

  const outPath = resolveOutPath(args.out_path, args.path, args.name);
  await mkdir(path.dirname(outPath), { recursive: true, mode: 0o700 });
  // 'wx' = O_CREAT|O_EXCL: never write through an existing file or symlink.
  // A planted link (or a second fetch) fails instead of overwriting whatever
  // it points at. 0600: only this user reads the decrypted file.
  await writeFile(outPath, plain, { flag: 'wx', mode: 0o600 });

  return {
    saved_to: outPath,
    bytes: plain.length,
    mime: args.mime ?? null,
    name: args.name ?? null,
    size_matches: args.size === undefined ? null : plain.length === args.size,
  };
}

/**
 * Where decrypted media may land (CHAT-41): `<tmp>/chattr-media-<uid>/`, a
 * directory of this user's own. `out_path` used to be any absolute path: a
 * message could talk the agent into writing over `~/.bashrc` or a hook.
 * Now an out_path must stay inside this root.
 */
export function mediaRoot(): string {
  const uid = typeof process.getuid === 'function' ? process.getuid() : 'user';
  return path.join(tmpdir(), `chattr-media-${uid}`);
}

export function resolveOutPath(outPath: string | undefined, objectPath: string, name?: string): string {
  const root = mediaRoot();
  if (outPath === undefined) return defaultOutPath(objectPath, name);
  const resolved = path.resolve(root, outPath);
  if (resolved !== root && resolved.startsWith(root + path.sep)) return resolved;
  throw new Error(`out_path must stay inside ${root}`);
}

const SAFE_SEGMENT = /^[A-Za-z0-9._-]{1,128}$/;

// <chatId>/<messageId>/<name>.enc → <root>/<messageId>/<name>
function defaultOutPath(objectPath: string, name?: string): string {
  const parts = objectPath.split('/');
  const rawId = parts.length >= 2 ? parts[parts.length - 2] : 'media';
  const messageId = SAFE_SEGMENT.test(rawId) && rawId !== '..' && rawId !== '.' ? rawId : 'media';
  const rawName = name ?? (parts[parts.length - 1] ?? 'media').replace(/\.enc$/i, '');
  // basename-only, guard against path traversal from an untrusted filename
  const base = path.basename(rawName);
  const safeName = base && base !== '..' && base !== '.' ? base : 'media';
  return path.join(mediaRoot(), messageId, safeName);
}
