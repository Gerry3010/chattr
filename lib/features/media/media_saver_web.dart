// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web always downloads (never a share sheet); the UI uses this to label the
/// action button "download".
bool get mediaUsesShareSheet => false;

/// Web: trigger a browser download of the bytes via an object URL + anchor.
Future<void> saveOrShareMedia({
  required String fileName,
  required String mimeType,
  required Uint8List bytes,
}) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = fileName;
  anchor.click();
  web.URL.revokeObjectURL(url);
}

/// Web variant: [sourcePath] is a blob object URL (chunked media assembled into
/// a Blob) — trigger a browser download of it. The caller revokes the URL.
Future<void> saveOrShareMediaPath({
  required String sourcePath,
  required String fileName,
  required String mimeType,
}) async {
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = sourcePath
    ..download = fileName;
  anchor.click();
}
