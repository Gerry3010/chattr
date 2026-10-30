// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show Platform;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../important_people_controller.dart';

/// The "important" switch for ONE person.
///
/// It stands in the profile sheet and on the person screen — both show the same
/// person, so there must not be two switches in different positions. The same
/// lesson as with the sound row: where two screens build the same thing, they
/// drift.
///
/// **Only visible where it does something.** The urgency arises in the iOS
/// notification extension. On Android the channel is already on high importance
/// anyway, in the browser the level does not exist — a switch that does nothing
/// there would be a promise nobody keeps. Better not to show it at all than to
/// label it wrongly.
///
/// Applies to agent accounts (`is_agent`) too: they write not only on request
/// but also of their own accord (status, the result of a job) — and a message
/// like that can be exactly the one meant to get through the focus. Whoever
/// wants to raise a voice decides that themselves, independently of the kind of
/// account.
class ImportantPersonTile extends ConsumerWidget {
  final String userId;

  const ImportantPersonTile({super.key, required this.userId});

  /// Does this platform have an urgency level to raise at all?
  ///
  /// Overridable for the test — `Platform` cannot be set.
  @visibleForTesting
  static bool Function() supported =
      () => !kIsWeb && Platform.isIOS;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!supported()) return const SizedBox.shrink();

    final wichtig = ref.watch(isImportantPersonProvider(userId));

    return SwitchListTile(
      secondary: Icon(
        wichtig ? Icons.priority_high : Icons.notifications_none,
        color: wichtig ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text('important_people.title'.tr()),
      subtitle: Text('important_people.explainer'.tr()),
      value: wichtig,
      onChanged: (_) =>
          ref.read(importantPeopleProvider.notifier).toggle(userId),
    );
  }
}
