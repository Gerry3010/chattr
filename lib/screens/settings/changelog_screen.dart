// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../features/about/changelog.dart';
import '../chat/components/safe_markdown.dart';

/// "Was ist neu" — the bundled CHANGELOG.md, one expandable card per release.
///
/// The version this build actually is gets expanded on open and marked, so the
/// first thing you see is what changed in what you are running.
class ChangelogScreen extends StatefulWidget {
  const ChangelogScreen({super.key});

  @override
  State<ChangelogScreen> createState() => _ChangelogScreenState();
}

class _ChangelogScreenState extends State<ChangelogScreen> {
  late final Future<(List<ChangelogRelease>, String)> _data = _load();

  Future<(List<ChangelogRelease>, String)> _load() async {
    final releases = await loadBundledChangelog();
    final info = await PackageInfo.fromPlatform();
    return (releases, info.version);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('settings.about.changelog'.tr())),
      body: FutureBuilder<(List<ChangelogRelease>, String)>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || snapshot.data == null) {
            return Center(child: Text('settings.about.changelog_error'.tr()));
          }
          final (releases, currentVersion) = snapshot.data!;
          if (releases.isEmpty) {
            return Center(child: Text('settings.about.changelog_error'.tr()));
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: releases.length,
            itemBuilder: (context, i) {
              final r = releases[i];
              final isCurrent = r.version == currentVersion;
              return Card(
                margin:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ExpansionTile(
                  // Open the running version by default; otherwise the newest
                  // entry, so the screen never opens fully collapsed.
                  initiallyExpanded: isCurrent || (i == 0 && !releases.any(
                      (e) => e.version == currentVersion)),
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          r.isUnreleased
                              ? 'settings.about.unreleased'.tr()
                              : r.version,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'settings.about.installed'.tr(),
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: r.date == null ? null : Text(r.date!),
                  childrenPadding:
                      const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SafeMarkdown(
                      data: r.body,
                      textColor: scheme.onSurface,
                      linkColor: scheme.primary,
                      fontSize: 14,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
