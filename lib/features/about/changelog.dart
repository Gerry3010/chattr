// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/services.dart' show rootBundle;

/// One released version from `CHANGELOG.md`.
class ChangelogRelease {
  /// e.g. `1.12.0` — the text between the brackets of `## [1.12.0] - 2026-08-03`.
  final String version;

  /// e.g. `2026-08-03`, or null for an entry without a date (`## [Unreleased]`).
  final String? date;

  /// Everything under the heading, as markdown.
  final String body;

  const ChangelogRelease({
    required this.version,
    required this.date,
    required this.body,
  });

  bool get isUnreleased => version.toLowerCase() == 'unreleased';
}

/// `## [1.12.0] - 2026-08-03` / `## [Unreleased]`
///
/// Only horizontal whitespace (`[ \t]`), NEVER `\s`: `\s` swallows line breaks,
/// so with a heading without a date the optional date part collected the first
/// line of the running text as the "date" — and the entry thereby lost its
/// first change. A test pins that down.
final _headingPattern = RegExp(
  r'^##[ \t]+\[([^\]]+)\][ \t]*(?:-[ \t]*(.+?))?[ \t]*$',
  multiLine: true,
);

/// Parses a Keep-a-Changelog document into its releases, newest first
/// (i.e. document order — CHANGELOG.md is maintained newest-first).
///
/// An `## [Unreleased]` section with no content is dropped: it is a maintenance
/// marker, not something to show a user. One WITH content is kept — if we have
/// written down unreleased changes, hiding them would be the odd choice.
List<ChangelogRelease> parseChangelog(String markdown) {
  final matches = _headingPattern.allMatches(markdown).toList();
  final out = <ChangelogRelease>[];

  for (var i = 0; i < matches.length; i++) {
    final m = matches[i];
    final end = i + 1 < matches.length ? matches[i + 1].start : markdown.length;
    final body = markdown.substring(m.end, end).trim();
    final release = ChangelogRelease(
      version: m.group(1)!.trim(),
      date: m.group(2)?.trim(),
      body: body,
    );
    if (release.isUnreleased && body.isEmpty) continue;
    out.add(release);
  }
  return out;
}

/// Loads the changelog that ships **with this build**.
///
/// Deliberately a bundled asset rather than a fetch from the repository: the
/// public mirror only updates when a snapshot is published, so a fetched
/// changelog can describe a different version than the one the user is running
/// — exactly backwards for a "what's new" screen. The bundled copy always
/// matches the installed build, works offline, and doesn't tell a third party
/// that someone opened Chattr's changelog.
///
/// What an *available update* brings is a separate question, answered by the
/// update banner's `changelog_url`.
Future<List<ChangelogRelease>> loadBundledChangelog() async =>
    parseChangelog(await rootBundle.loadString('CHANGELOG.md'));
