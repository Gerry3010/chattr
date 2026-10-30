// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';
import '../../core/supabase/supabase_client_provider.dart';
import 'call_media.dart';
import 'call_relay_setting.dart';

/// The user wants calls through the relay only, and there is no relay to
/// use. Falling back to a direct call would break that promise silently.
class CallRelayUnavailable implements Exception {
  const CallRelayUnavailable();
}

/// Builds the [CallIceConfig] for one call: our STUN/TURN with fresh
/// credentials from `get_call_ice_servers` (00086), plus any development
/// servers from `.env`, plus the relay-only setting.
///
/// Fetched per call, not cached: the TURN credentials expire, and a server
/// that is down right now should not decide the next call too.
class CallIceConfigLoader {
  CallIceConfigLoader(this._ref);

  final Ref _ref;

  Future<CallIceConfig> load({
    required String chatId,
    required String peerId,
  }) async {
    final relayOnly = await _ref
        .read(callRelayOnlyProvider.notifier)
        .resolvedValue();

    var fromServer = const <Map<String, dynamic>>[];
    try {
      final raw = await _ref
          .read(supabaseClientProvider)
          .rpc<dynamic>(
            'get_call_ice_servers',
            params: {'p_chat_id': chatId, 'p_peer': peerId},
          );
      fromServer = parseIceServers(raw);
    } catch (e) {
      // Without the server's list a call still connects on the same network
      // — better than not ringing at all. Relay-only is decided below.
      logger.warning('ICE servers unavailable: $e', tag: 'Calls');
    }

    final servers = [...fromServer, ...callIceServers()];
    if (relayOnly && !servers.any(_isUsableTurn)) {
      throw const CallRelayUnavailable();
    }
    return CallIceConfig(servers: servers, relayOnly: relayOnly);
  }
}

/// Parses the RPC result. Anything malformed is dropped entry by entry —
/// one odd entry must not cost the call its relay.
List<Map<String, dynamic>> parseIceServers(Object? raw) {
  if (raw is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final urls = e['urls'];
    if (urls is! List || urls.isEmpty || urls.any((u) => u is! String)) {
      continue;
    }
    out.add({
      'urls': List<String>.from(urls),
      if (e['username'] is String) 'username': e['username'],
      if (e['credential'] is String) 'credential': e['credential'],
    });
  }
  return out;
}

bool _isUsableTurn(Map<String, dynamic> s) {
  final urls = s['urls'];
  final list = urls is List ? urls : [urls];
  return s['credential'] is String &&
      list.any(
        (u) => u is String && (u.startsWith('turn:') || u.startsWith('turns:')),
      );
}

final callIceConfigLoaderProvider = Provider<CallIceConfigLoader>(
  CallIceConfigLoader.new,
);
