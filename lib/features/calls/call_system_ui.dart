// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';
import '../push_notifications/push_render_cache.dart';
import 'calls_in_recents_setting.dart';

/// Calls that ring a CLOSED app (stage 3, 00088).
///
/// A push wakes the device with ids only — {type, chat_id, signal_id}, never
/// a caller or a name. The device shows the system's incoming-call UI
/// (CallKit on iOS, a full-screen call notification on Android) with the name
/// it looks up itself, from the same table the message pushes use. Only when
/// the user accepts does the app fetch the sealed invite
/// (`fetch_call_invite`), open it and answer.
///
/// iOS reaches here through PushKit in native code (Mac-Claude's side); this
/// file covers what Dart does on both platforms.

const String callInvitePush = 'call_invite';
const String callCancelPush = 'call_cancel';

bool isCallPushData(Map<String, dynamic> data) =>
    data['type'] == callInvitePush || data['type'] == callCancelPush;

/// Whether this platform has a system call UI at all. Web and desktop ring
/// only while open (stage 1), so the plugin must never be touched there.
bool get systemCallUiSupported =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Runs in the FCM background isolate (Android): show the system call UI for
/// an invite, take it down for a cancel. No Riverpod here — only plugins and
/// SharedPreferences.
Future<void> handleCallPushInBackground(Map<String, dynamic> data) async {
  final chatId = data['chat_id'] as String?;
  if (data['type'] == callCancelPush) {
    // One call at a time on this device; the caller gave up on it.
    await FlutterCallkitIncoming.endAllCalls();
    return;
  }
  final signalId = data['signal_id'] as String?;
  if (chatId == null || signalId == null) return;
  final names = (await PushRenderCache.read()).names;
  await FlutterCallkitIncoming.showCallkitIncoming(
    incomingCallParams(
      signalId: signalId,
      chatId: chatId,
      callerName: names[chatId],
      listInRecents: await CallsInRecentsController.read(),
    ),
  );
}

/// The system UI's description of one incoming call. The id IS the signal id,
/// so accept/decline lead straight back to the invite on the server.
CallKitParams incomingCallParams({
  required String signalId,
  required String chatId,
  String? callerName,
  bool listInRecents = true,
}) {
  final german = !kIsWeb && Platform.localeName.startsWith('de');
  return CallKitParams(
    id: signalId,
    nameCaller: (callerName == null || callerName.isEmpty) ? 'Chattr' : callerName,
    appName: 'Chattr',
    handle: '',
    type: 0, // audio
    // Same as the in-app ring timeout (call_rules.dart ringTimeout).
    duration: 45000,
    extra: <String, dynamic>{'chat_id': chatId, 'signal_id': signalId},
    // Our own ongoing-call notification (CallForegroundService.kt) covers
    // every call, also those taken in the app; the plugin's would be a
    // second one, in English, for some calls only.
    callingNotification: const NotificationParams(showNotification: false),
    android: AndroidParams(
      isCustomNotification: true,
      isShowLogo: false,
      // android/app/src/main/res/raw/call_ring.wav — the same tone as in-app.
      ringtonePath: 'call_ring',
      backgroundColor: '#12151A',
      actionColor: '#4CAF50',
      textAccept: german ? 'Annehmen' : 'Accept',
      textDecline: german ? 'Ablehnen' : 'Decline',
      incomingCallNotificationChannelName:
          german ? 'Eingehende Anrufe' : 'Incoming calls',
      isShowFullLockedScreen: true,
    ),
    ios: IOSParams(
      // Phone app Recents (CHAT-38, a setting). AppDelegate.swift sets the
      // same for calls rung straight from the VoIP push.
      includesCallsInRecents: listInRecents,
      // ios/Runner/call_ring.caf — CallKit rebuilds its configuration on
      // every call, so a call reported without this would put the next one
      // back on the system ringtone.
      ringtonePath: 'call_ring.caf',
      handleType: 'generic',
      supportsVideo: false,
      maximumCallGroups: 1,
      maximumCallsPerCallGroup: 1,
      supportsDTMF: false,
      supportsHolding: false,
      supportsGrouping: false,
      supportsUngrouping: false,
    ),
  );
}

/// What the controller needs from the system UI. An interface so tests run
/// without the plugin.
abstract class CallSystemUi {
  /// Takes the system call UI for [signalId] down (accepted in-app, or the
  /// call is over).
  Future<void> end(String signalId);

  /// Whether the system UI rings even while the app is open. True on iOS:
  /// PushKit wakes the app for every invite, foreground or not, and the app
  /// MUST report each one to CallKit — which then owns the audio session, so
  /// an in-app ringtone on top is silenced (or doubled).
  bool get ringsInForeground;

  /// Whether the system UI currently shows the call [signalId].
  Future<bool> isShowing(String signalId);
}

class _PluginCallSystemUi implements CallSystemUi {
  const _PluginCallSystemUi();

  @override
  Future<void> end(String signalId) async {
    if (!systemCallUiSupported) return;
    try {
      await FlutterCallkitIncoming.endCall(signalId);
    } catch (e) {
      logger.warning('Could not end system call: $e', tag: 'Calls');
    }
  }

  @override
  bool get ringsInForeground => !kIsWeb && Platform.isIOS;

  @override
  Future<bool> isShowing(String signalId) async {
    if (!systemCallUiSupported) return false;
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      return calls
          .any((c) => c.id == signalId || c.extra?['signal_id'] == signalId);
    } catch (e) {
      logger.warning('activeCalls failed: $e', tag: 'Calls');
      return false;
    }
  }
}

final callSystemUiProvider =
    Provider<CallSystemUi>((_) => const _PluginCallSystemUi());

/// Accept/decline taps from the system UI, as the app sees them.
sealed class SystemCallAction {
  const SystemCallAction(this.signalId, this.chatId);
  final String signalId;
  final String chatId;
}

class SystemCallAccepted extends SystemCallAction {
  const SystemCallAccepted(super.signalId, super.chatId);
}

class SystemCallDeclined extends SystemCallAction {
  const SystemCallDeclined(super.signalId, super.chatId);
}

/// Ended in the system UI after it was taken (CallKit, a headset, Telecom).
class SystemCallEnded extends SystemCallAction {
  const SystemCallEnded(super.signalId, super.chatId);
}

/// Turns a plugin event into an action, or null for everything we ignore.
SystemCallAction? systemCallActionFrom(CallEvent? event) {
  final CallKitParams params;
  final SystemCallAction Function(String signalId, String chatId) make;
  switch (event) {
    case CallEventActionCallAccept(:final callKitParams):
      params = callKitParams;
      make = SystemCallAccepted.new;
    case CallEventActionCallDecline(:final callKitParams):
      params = callKitParams;
      make = SystemCallDeclined.new;
    case CallEventActionCallEnded(:final callKitParams):
      params = callKitParams;
      make = SystemCallEnded.new;
    default:
      return null;
  }
  final extra = params.extra ?? const <String, dynamic>{};
  final signalId = (extra['signal_id'] as String?) ?? params.id;
  final chatId = extra['chat_id'] as String?;
  if (chatId == null) return null;
  return make(signalId, chatId);
}

/// The app's stream of system-UI actions — plus, at start, a call the user
/// already accepted while the app was still closed (Android launches the app
/// on accept; the event fired before anyone listened).
Stream<SystemCallAction> systemCallActions() async* {
  if (!systemCallUiSupported) return;
  try {
    for (final call in await FlutterCallkitIncoming.activeCalls()) {
      if (!call.isAccepted) continue;
      final chatId = call.extra?['chat_id'] as String?;
      if (chatId != null) {
        yield SystemCallAccepted(
            (call.extra?['signal_id'] as String?) ?? call.id, chatId);
      }
    }
  } catch (e) {
    logger.warning('activeCalls failed: $e', tag: 'Calls');
  }
  await for (final event in FlutterCallkitIncoming.onEvent) {
    final action = systemCallActionFrom(event);
    if (action != null) yield action;
  }
}

/// iOS only: the PushKit token, for `device_tokens` as platform 'ios_voip'.
Future<String?> voipPushToken() async {
  if (kIsWeb || !Platform.isIOS) return null;
  try {
    final token = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
    return (token is String && token.isNotEmpty) ? token : null;
  } catch (e) {
    logger.warning('VoIP token unavailable: $e', tag: 'Calls');
    return null;
  }
}
