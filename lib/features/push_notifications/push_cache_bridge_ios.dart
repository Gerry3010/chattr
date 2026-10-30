// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Mirror the push-render cache into the iOS **App Group** container, so the
/// Notification Service Extension can read it.
///
/// **Why a second copy at all.** The extension is its own process. It cannot see
/// the app's normal `NSUserDefaults` — only the suite shared through the App
/// Group `group.net.geraldhofbauer.chattr` (which already exists for the Share
/// Extension). Same shape of problem as the web service worker, which is why
/// that one gets its own IndexedDB mirror: whoever renders the notification must
/// be able to reach the names.
///
/// **Contract with the native side** (`PushCacheChannel.swift`, Mac-Claude):
/// one method `mirror`, two arguments, both JSON strings — `names` is
/// `{id: displayName}` for chats AND users, `templates` is the localized
/// wording. The extension reads them back from
/// `UserDefaults(suiteName:)` under the same two keys.
///
/// Best-effort throughout: until the channel exists this throws
/// `MissingPluginException`, which is caught here. The cost of a missing mirror
/// is a generic notification, never a missing one — and never a broken chat
/// list, which is what an exception escaping into the caller would risk.
const MethodChannel _channel =
    MethodChannel('net.geraldhofbauer.chattr/push_cache');

/// Key the extension reads the name table from.
const String pushCacheNamesKey = 'push_render_names';

/// Key the extension reads the localized wording from.
const String pushCacheTemplatesKey = 'push_render_templates';

/// Key the extension reads the unread BASE from — see
/// [mirrorUnreadTotalForAppGroup].
const String pushUnreadTotalKey = 'push_unread_total';

/// Key the extension reads the important-senders list from — see
/// [mirrorImportantSendersForAppGroup].
const String pushImportantSendersKey = 'push_important_senders';

Future<void> mirrorPushCacheForAppGroup({
  required Map<String, String> names,
  required Map<String, String> templates,
}) async {
  try {
    await _channel.invokeMethod<void>('mirror', {
      pushCacheNamesKey: jsonEncode(names),
      pushCacheTemplatesKey: jsonEncode(templates),
    });
  } on MissingPluginException {
    // The native channel is not in this build yet. Expected until the
    // Notification Service Extension ships; nothing to report.
  } catch (_) {
    // Deliberately swallowed — see the doc comment.
  }
}

/// Publish the device's exact unread total into the App Group, so the
/// Notification Service Extension can set the app-icon badge itself.
///
/// **Why the extension needs a number from us at all.** While the app is
/// backgrounded on iOS the badge comes from the push's `aps.badge`, which the
/// server derives from `chat_members.last_read_at` — the one remaining
/// server-side record of *when you opened which chat*. Removing that record is
/// the point of this exercise, so the number has to come from somewhere else.
///
/// **Why not read the local database instead.** The extension is its own
/// process and can only reach the App Group container; the message database
/// lives in the app's own container (`DatabaseService`, via
/// `getDatabasesPath()`). Moving it into the group would mean relocating the
/// ONLY surviving copy of every message — the server forgot them on delivery.
/// A botched move is not a display glitch, it is the whole history. Not a
/// trade worth making for an icon number.
///
/// **So: base plus deliveries.** We publish the exact count; the extension
/// reads it, adds the pushes it renders, and writes the raised value back so
/// several in a row stack. Every time the app is opened this republishes the
/// truth, which re-seeds the base.
///
/// **What that costs, honestly:** iOS drops pushes (throttling, low power).
/// Each dropped one leaves the badge one too low until the app is next opened.
/// It never runs too HIGH, which is the direction that would nag you about
/// messages that are not there.
///
/// iOS only — Android and web never used `aps.badge`, and neither has a second
/// process that renders notifications from our own data.
Future<void> mirrorUnreadTotalForAppGroup(int total) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
  try {
    // Negative would be nonsense to a badge; clamp rather than trust callers.
    await _channel.invokeMethod<void>('unreadTotal', {
      pushUnreadTotalKey: total < 0 ? 0 : total,
    });
  } on MissingPluginException {
    // The native side is not in this build yet — expected until the extension
    // ships. The server still supplies `aps.badge` in the meantime.
  } catch (_) {
    // Deliberately swallowed — a stale badge must never break the chat list.
  }
}

/// Publish the ids of people the user marked as important, so the Notification
/// Service Extension can deliver THEIR messages as time-sensitive.
///
/// **Why the decision is made over here and not on the server.** The server
/// could simply stamp the urgency into the push. It would then hold a list of
/// the people who matter most to you, keyed to your account — the ranking of
/// your relationships, readable straight out of a table. So the server keeps
/// treating everyone alike and the extension, which is already decrypting the
/// message to render it, sorts it out locally. Same reasoning as the per-chat
/// sound (`chat_sound_controller.dart`); this one just has higher stakes.
///
/// Goes through the SAME `mirror` method as the name table: its handler leaves
/// keys it was not given untouched, so passing this one alone will not clear
/// the others. iOS only — Android's channel already sits at high importance, so
/// there is nothing for a mark to raise, and the web has no second process.
Future<void> mirrorImportantSendersForAppGroup(Set<String> senderIds) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
  try {
    await _channel.invokeMethod<void>('mirror', {
      // Sorted so an unchanged set writes an unchanged string — the extension
      // does not care, but a diff in a bug report should mean something.
      pushImportantSendersKey: jsonEncode(senderIds.toList()..sort()),
    });
  } on MissingPluginException {
    // The native side does not know this key yet (Mac-Claude, 1.26.2). Until
    // then nobody is urgent, which is the harmless direction.
  } catch (_) {
    // Deliberately swallowed — see the file's doc comment.
  }
}

/// Key for "list Chattr calls in the Phone app's Recents" — see
/// [mirrorCallsInRecentsForAppGroup]. Must match `callsInRecentsKey`
/// (PushCacheChannel.swift) and the read in AppDelegate.swift.
const String pushCallsInRecentsKey = 'calls_in_recents';

/// Publish the Recents setting (CHAT-38) into the App Group. An incoming call
/// on iOS is reported to CallKit natively, straight from the VoIP push, before
/// any Dart runs, so the setting has to be where AppDelegate can read it.
/// Goes through `mirror`, whose handler leaves the other keys alone.
Future<void> mirrorCallsInRecentsForAppGroup(bool enabled) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
  try {
    await _channel
        .invokeMethod<void>('mirror', {pushCallsInRecentsKey: enabled});
  } on MissingPluginException {
    // Native side not in this build: CallKit keeps its default (listed).
  } catch (_) {
    // Deliberately swallowed — see the file's doc comment.
  }
}

/// Removes the name table, wording, unread total and important senders from
/// the App Group (CHAT-38). Called on logout/wipe: the names are a plaintext
/// social graph and must not outlive the account on the device. Settings such
/// as [pushCallsInRecentsKey] belong to the device and stay.
Future<void> clearPushCacheForAppGroup() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
  try {
    await _channel.invokeMethod<void>('clear');
  } on MissingPluginException {
    // Native side not in this build yet.
  } catch (_) {
    // Deliberately swallowed — a logout must not fail on this.
  }
}
