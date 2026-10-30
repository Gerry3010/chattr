// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/whats_new/whats_new_catalog.dart';
import '../../features/whats_new/whats_new_rules.dart';
import '../../features/whats_new/whats_new_store.dart';

/// Shows the unread "new in" cards, if there are any. Marks them read only
/// when the user taps "Gelesen" on the last card — closing the app halfway
/// through means the cards come back next time, which is the honest outcome.
Future<void> showWhatsNewIfUnread(BuildContext context, WidgetRef ref) async {
  final store = ref.read(whatsNewStoreProvider);
  final versions = await store.unread();
  if (versions.isEmpty || !context.mounted) return;
  final read = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => WhatsNewDialog(versions: versions),
  );
  if (read == true) await store.markRead(versions);
}

/// A stack of cards, one per version, oldest first. "Zurück" exists only
/// where there is something to go back to — on the first card it is gone,
/// not greyed out. The last card says "Gelesen" instead of "Weiter".
class WhatsNewDialog extends StatefulWidget {
  const WhatsNewDialog({super.key, required this.versions});

  final List<String> versions;

  @override
  State<WhatsNewDialog> createState() => _WhatsNewDialogState();
}

class _WhatsNewDialogState extends State<WhatsNewDialog> {
  int _index = 0;
  bool _forward = true;

  bool get _isFirst => _index == 0;
  bool get _isLast => _index == widget.versions.length - 1;

  void _go(int delta) => setState(() {
        _forward = delta > 0;
        _index += delta;
      });

  @override
  Widget build(BuildContext context) {
    final version = widget.versions[_index];
    final entry = whatsNewCatalog[version]!;

    return PopScope(
      canPop: false,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  transitionBuilder: (child, animation) {
                    final from = Offset(_forward ? 0.15 : -0.15, 0);
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(begin: from, end: Offset.zero)
                            .animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: _Card(
                    key: ValueKey(version),
                    version: version,
                    entry: entry,
                  ),
                ),
                if (widget.versions.length > 1) ...[
                  const SizedBox(height: 20),
                  _Dots(count: widget.versions.length, active: _index),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    // Flexible on both, so large text or a long translation
                    // shortens a label instead of overflowing the card.
                    if (!_isFirst)
                      Flexible(
                        child: TextButton(
                          key: const ValueKey('whats_new_back'),
                          onPressed: () => _go(-1),
                          child: Text('whats_new.back'.tr(),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    const Spacer(),
                    Flexible(
                      flex: 2,
                      child: FilledButton(
                        key: ValueKey(
                            _isLast ? 'whats_new_done' : 'whats_new_next'),
                        onPressed: _isLast
                            ? () => Navigator.of(context).pop(true)
                            : () => _go(1),
                        child: Text(
                            (_isLast ? 'whats_new.done' : 'whats_new.next')
                                .tr(),
                            overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({super.key, required this.version, required this.entry});

  final String version;
  final WhatsNewEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'whats_new.title'.tr(args: [displayVersion(version)]),
          style: text.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        // Outlined icon in an outlined ring: the theme's primary on a faint
        // wash of the same colour, so it reads on every theme.
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.primary.withValues(alpha: 0.10),
            border: Border.all(color: scheme.primary, width: 2),
          ),
          child: Icon(entry.icon, size: 44, color: scheme.primary),
        ),
        const SizedBox(height: 24),
        Text(
          entry.headlineKey.tr(),
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          entry.bodyKey.tr(),
          style: text.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.45,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.active});

  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == active ? 18 : 7,
            height: 7,
            decoration: BoxDecoration(
              color: i == active
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}
