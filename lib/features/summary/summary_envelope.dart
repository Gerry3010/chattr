// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The wire format for asking an agent to summarise a chat, and for its answer.
///
/// **Why this is a message and not an API call.** An MCP agent is not a server
/// the app can call. It sleeps and is woken by a new message on the chat's
/// realtime channel. So the request travels the way everything else travels:
/// as an ordinary end-to-end encrypted message with a machine-readable body,
/// exactly like media envelopes (`_chattr_media`) do today.
///
/// That choice is not just convenience. The obvious alternative — summarising
/// server-side in an edge function — would require the server to see plaintext,
/// which is the one thing Chattr promises it never does. Routing this through
/// the agent keeps the summary as encrypted as the conversation it describes.
///
/// **The cost, stated plainly:** an answer only comes if an agent session is
/// actually running. There is no delivery guarantee and no timeout the protocol
/// can enforce. The UI has to say "no answer yet" rather than spin forever.
library;

import 'dart:convert';

/// A request sent BY the app TO the chat's main agent.
class SummaryRequest {
  static const String marker = '_chattr_summarize';

  /// What to cover. Kept as a small closed set so an agent can act on it
  /// without parsing prose.
  final SummaryScope scope;

  /// Only for [SummaryScope.since] — the point to summarise from.
  final DateTime? since;

  /// Optional free text from the user ("nur die offenen Punkte"). Advisory.
  final String? hint;

  /// User id of the agent this request is addressed to (the chat's main
  /// agent). A chat can hold several agents, and the message itself reaches
  /// every member — without an addressee, ALL of them would answer and the
  /// sheet would show whichever reply happened to arrive first. Convention:
  /// an agent that is not the addressee stays silent. Null means "any agent
  /// may answer" — the pre-selection fallback for chats with a single agent.
  final String? agent;

  const SummaryRequest({required this.scope, this.since, this.hint, this.agent});

  Map<String, dynamic> toJson() => {
        marker: 1,
        'scope': scope.wire,
        if (since != null) 'since': since!.toUtc().toIso8601String(),
        if (hint != null && hint!.isNotEmpty) 'hint': hint,
        if (agent != null) 'agent': agent,
      };

  String encode() => jsonEncode(toJson());

  static SummaryRequest? tryParse(String? body) {
    if (body == null || body.isEmpty || !body.contains(marker)) return null;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json[marker] == null) return null;
      final rawSince = json['since'] as String?;
      return SummaryRequest(
        scope: SummaryScopeX.fromWire(json['scope'] as String?),
        since: rawSince == null ? null : DateTime.tryParse(rawSince),
        hint: json['hint'] as String?,
        agent: json['agent'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The agent's answer.
class SummaryReply {
  static const String marker = '_chattr_summary';

  /// Message id of the [SummaryRequest] this answers. Lets the app match an
  /// answer to the request it is waiting on, instead of showing whichever
  /// summary arrives last.
  final String forRequestId;

  final String text;

  const SummaryReply({required this.forRequestId, required this.text});

  Map<String, dynamic> toJson() => {
        marker: 1,
        'for': forRequestId,
        'text': text,
      };

  String encode() => jsonEncode(toJson());

  static SummaryReply? tryParse(String? body) {
    if (body == null || body.isEmpty || !body.contains(marker)) return null;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json[marker] == null) return null;
      final text = json['text'];
      final forId = json['for'];
      if (text is! String || forId is! String) return null;
      return SummaryReply(forRequestId: forId, text: text);
    } catch (_) {
      return null;
    }
  }
}

enum SummaryScope {
  /// Everything the user has not read yet. The default, and the one Gerry
  /// actually asked for ("Überblick ohne Scrollen").
  unread,

  /// The whole conversation.
  all,

  /// From an explicit point in time.
  since,
}

extension SummaryScopeX on SummaryScope {
  String get wire => switch (this) {
        SummaryScope.unread => 'unread',
        SummaryScope.all => 'all',
        SummaryScope.since => 'since',
      };

  static SummaryScope fromWire(String? wire) => switch (wire) {
        'all' => SummaryScope.all,
        'since' => SummaryScope.since,
        // Unknown or missing falls back to the narrowest useful answer rather
        // than dumping the entire history on someone.
        _ => SummaryScope.unread,
      };
}

/// True when a decrypted body is summary machinery rather than something a
/// person wrote.
///
/// Both directions must be filtered at every place that treats a message as
/// conversation: the bubble list, the unread count, the chat-list preview and
/// the push notification. A request the user never typed showing up as their
/// own message — or an agent's answer arriving as a push at 3am — would be the
/// feature announcing its own plumbing.
bool isSummaryEnvelope(String? body) =>
    SummaryRequest.tryParse(body) != null || SummaryReply.tryParse(body) != null;
