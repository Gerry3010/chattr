// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../media_attachment.dart';

/// Visual treatment for a non-media file in a chat bubble: a distinctive
/// colored icon plus a short, human-readable type label (the lightweight
/// "document preview"). Driven off the attachment's MIME type with an
/// extension fallback, so it works on every platform with no native deps.
class FileTypeVisual {
  final IconData icon;
  final Color color;
  final String label;

  const FileTypeVisual(this.icon, this.color, this.label);

  static FileTypeVisual of(MediaAttachment att) =>
      forFile(att.name, att.mime);

  /// Same as [of] but from a raw name + MIME — used by the pre-send caption
  /// preview, where no [MediaAttachment] exists yet.
  static FileTypeVisual forFile(String name, String mimeType) {
    final mime = mimeType.toLowerCase();
    final ext = _ext(name);

    // PDF
    if (mime == 'application/pdf' || ext == 'pdf') {
      return const FileTypeVisual(Icons.picture_as_pdf, Color(0xFFE53935), 'PDF');
    }
    // Word / documents
    if (mime.contains('word') ||
        const {'doc', 'docx', 'odt', 'rtf', 'pages'}.contains(ext)) {
      return const FileTypeVisual(Icons.description, Color(0xFF1E88E5), 'Document');
    }
    // Spreadsheets
    if (mime.contains('sheet') ||
        mime.contains('excel') ||
        const {'xls', 'xlsx', 'ods', 'csv', 'numbers'}.contains(ext)) {
      return const FileTypeVisual(Icons.table_chart, Color(0xFF43A047), 'Spreadsheet');
    }
    // Presentations
    if (mime.contains('presentation') ||
        mime.contains('powerpoint') ||
        const {'ppt', 'pptx', 'odp', 'key'}.contains(ext)) {
      return const FileTypeVisual(Icons.slideshow, Color(0xFFFB8C00), 'Presentation');
    }
    // Archives
    if (mime.contains('zip') ||
        mime.contains('compressed') ||
        mime.contains('tar') ||
        const {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'}.contains(ext)) {
      return const FileTypeVisual(Icons.folder_zip, Color(0xFF8D6E63), 'Archive');
    }
    // Code / markup
    if (const {
      'json', 'xml', 'html', 'htm', 'js', 'ts', 'dart', 'py', 'java',
      'kt', 'go', 'rs', 'c', 'cpp', 'h', 'sh', 'yaml', 'yml', 'sql', 'css'
    }.contains(ext)) {
      return const FileTypeVisual(Icons.code, Color(0xFF00897B), 'Code');
    }
    // Plain text
    if (mime.startsWith('text/') ||
        const {'txt', 'md', 'log'}.contains(ext)) {
      return const FileTypeVisual(Icons.article, Color(0xFF607D8B), 'Text');
    }
    // Fallback
    final upper = ext.toUpperCase();
    return FileTypeVisual(
      Icons.insert_drive_file,
      const Color(0xFF757575),
      upper.isEmpty ? 'File' : upper,
    );
  }

  static String _ext(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }
}
