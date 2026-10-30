// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// IndexedDB names, mirrored in `web/firebase-messaging-sw.js`. Change both.
const String _dbName = 'chattr_push';
const String _storeName = 'render_cache';
const int _dbVersion = 1;

/// Mirror the push-render cache into IndexedDB for the service worker.
///
/// On Android the background isolate reads SharedPreferences directly. The web
/// service worker cannot: Flutter's shared_preferences is backed by
/// **localStorage**, and localStorage is unreachable from a service worker —
/// it is a synchronous, window-scoped API and a worker has no window. IndexedDB
/// is the only storage both sides can see, so the names and the localized
/// wording are written here a second time.
///
/// Best-effort throughout. Failing to mirror costs a generic notification, so
/// nothing here may throw into the caller — a browser in private mode with
/// IndexedDB disabled must not break the chat list.
Future<void> mirrorPushCacheForServiceWorker({
  required Map<String, String> names,
  required Map<String, String> templates,
}) async {
  try {
    final db = await _openDb();
    if (db == null) return;
    try {
      final tx = db.transaction(_storeName.toJS, 'readwrite');
      final store = tx.objectStore(_storeName);
      // Stored as JSON strings rather than structured-cloned maps: the service
      // worker parses them with JSON.parse either way, and a string round-trips
      // identically through both engines.
      store.put(jsonEncode(names).toJS, 'names'.toJS);
      store.put(jsonEncode(templates).toJS, 'templates'.toJS);
      await _completeTransaction(tx);
    } finally {
      db.close();
    }
  } catch (_) {
    // Deliberately swallowed — see the doc comment.
  }
}

Future<web.IDBDatabase?> _openDb() {
  final completer = Completer<web.IDBDatabase?>();
  final request = web.window.indexedDB.open(_dbName, _dbVersion);

  request.onupgradeneeded = (web.Event _) {
    final db = request.result as web.IDBDatabase;
    if (!db.objectStoreNames.contains(_storeName)) {
      db.createObjectStore(_storeName);
    }
  }.toJS;

  request.onsuccess = (web.Event _) {
    if (!completer.isCompleted) {
      completer.complete(request.result as web.IDBDatabase);
    }
  }.toJS;

  request.onerror = (web.Event _) {
    if (!completer.isCompleted) completer.complete(null);
  }.toJS;

  return completer.future;
}

Future<void> _completeTransaction(web.IDBTransaction tx) {
  final completer = Completer<void>();
  void finish() {
    if (!completer.isCompleted) completer.complete();
  }

  // Every terminal outcome resolves — an aborted mirror is not worth blocking
  // the caller on, it just means the worker keeps the previous copy.
  tx.oncomplete = (web.Event _) {
    finish();
  }.toJS;
  tx.onerror = (web.Event _) {
    finish();
  }.toJS;
  tx.onabort = (web.Event _) {
    finish();
  }.toJS;
  return completer.future;
}
