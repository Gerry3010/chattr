// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/logging/logger_service.dart';

/// Hidden developer log — reached by tapping the version footer in Settings
/// seven times. Surfaces [LoggerService]'s in-memory ring buffer (filled even
/// in release/TestFlight builds) as a copy-/shareable text so a tester can hand
/// over a real log without a wired-up device. Deliberately NOT localized: this
/// is a dev/diagnostics surface.
class DevLogScreen extends StatefulWidget {
  const DevLogScreen({super.key});

  @override
  State<DevLogScreen> createState() => _DevLogScreenState();
}

class _DevLogScreenState extends State<DevLogScreen> {
  final ScrollController _scroll = ScrollController();
  PackageInfo? _info;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _info = i);
    });
    // Jump to the newest lines once laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToEnd() {
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  }

  /// A short header so a pasted log carries app/version/platform context.
  String _header() {
    final v = _info == null ? '?' : '${_info!.version}+${_info!.buildNumber}';
    final mode = kReleaseMode
        ? 'release'
        : kProfileMode
            ? 'profile'
            : 'debug';
    return 'Chattr $v · ${defaultTargetPlatform.name} · $mode · '
        '${logger.bufferedLineCount} lines';
  }

  String _fullLog() => '${_header()}\n${'─' * 32}\n${logger.bufferedLogs}';

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _fullLog()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Log kopiert')),
    );
  }

  Future<void> _share() async {
    await SharePlus.instance.share(
      ShareParams(text: _fullLog(), subject: 'Chattr Dev Log'),
    );
  }

  void _clear() {
    logger.clearBuffer();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final log = logger.bufferedLogs;
    final empty = log.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dev Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Aktualisieren',
            onPressed: () {
              setState(() {});
              WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Kopieren',
            onPressed: empty ? null : _copy,
          ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Teilen',
            onPressed: empty ? null : _share,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Leeren',
            onPressed: empty ? null : _clear,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Text(
              _header(),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: empty
                ? Center(
                    child: Text(
                      'Noch keine Log-Einträge',
                      style: TextStyle(color: theme.colorScheme.outline),
                    ),
                  )
                : Scrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        log,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
