// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'media_blob_store.dart';

MediaBlobStore createMediaBlobStore() => FileMediaBlobStore();

/// Files under `<application support>/media_store/<chatId>/<messageId>/`.
/// Application support, not the temp/cache directory: the system may clear a
/// cache whenever it likes, and these files are the only copy left once the
/// server has reaped the blob.
class FileMediaBlobStore implements MediaBlobStore {
  FileMediaBlobStore({Future<Directory> Function()? baseDir})
      : _baseDir = baseDir ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _baseDir;
  Future<Directory>? _root;

  Future<Directory> _rootDir() => _root ??= () async {
        final base = await _baseDir();
        return Directory('${base.path}/media_store');
      }();

  Future<File?> _file(String path) async {
    if (!isStorableMediaPath(path)) return null;
    return File('${(await _rootDir()).path}/$path');
  }

  @override
  Future<Uint8List?> read(String path) async {
    final f = await _file(path);
    if (f == null || !f.existsSync()) return null;
    return f.readAsBytes();
  }

  @override
  Future<void> write(String path, Uint8List blob) async {
    final f = await _file(path);
    if (f == null) return;
    await f.parent.create(recursive: true);
    // Write next to it, then rename: a crash mid-write must not leave a
    // truncated file that read() would hand out as the real thing.
    final part = File('${f.path}.part');
    await part.writeAsBytes(blob, flush: true);
    await part.rename(f.path);
  }

  @override
  Future<bool> contains(String path) async =>
      (await _file(path))?.existsSync() ?? false;

  @override
  Future<void> deleteMessage(String chatId, String messageId) async {
    // Same shape check as for a single object: never delete outside the store.
    if (!isStorableMediaPath('$chatId/$messageId/media-0.enc')) return;
    final dir = Directory('${(await _rootDir()).path}/$chatId/$messageId');
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  @override
  Future<Map<String, DateTime>> storedMessages() async {
    final root = await _rootDir();
    if (!root.existsSync()) return const {};
    final out = <String, DateTime>{};
    await for (final chat in root.list()) {
      if (chat is! Directory) continue;
      await for (final msg in chat.list()) {
        if (msg is! Directory) continue;
        final chatId = chat.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final messageId = msg.uri.pathSegments.where((s) => s.isNotEmpty).last;
        out['$chatId/$messageId'] = (await msg.stat()).modified;
      }
    }
    return out;
  }

  @override
  Future<void> clear() async {
    final root = await _rootDir();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}
