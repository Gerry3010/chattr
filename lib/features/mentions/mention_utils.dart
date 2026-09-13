// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pure @-mention helpers (1.10): detect the active mention token being typed,
/// filter group members for the typeahead, insert a chosen mention, and resolve
/// which members a finished message mentions. No Flutter/Supabase dependency, so
/// it is fully unit-testable (`test/mention_utils_test.dart`).
///
/// Encoding is deliberately text-based: a mention is the literal `@<username>`
/// in the message text (Chattr usernames are unique handles). The sender
/// resolves those tokens to member ids at send time (for the push signal), and
/// the same match drives the in-bubble highlight — nothing extra is stored in
/// the message body.
library;

/// Special group-mention keywords, typed as `@all` / `@admins` / `@members`.
/// Fixed (non-localized) tokens so a mention resolves the same across locales.
const String mentionAll = 'all';
const String mentionAdmins = 'admins';
const String mentionMembers = 'members';

/// Reaches the agent accounts in the chat (`profiles.is_agent`). A group can
/// hold several — the Linux and the Mac agent sit in the same one — and
/// addressing "whichever of you handles this" needed a word of its own; the
/// alternative was naming every agent by hand or using `@all` and pulling the
/// humans in too.
const String mentionAgents = 'agents';

/// All group-mention keywords, for highlighting.
///
/// Every keyword is recognised in every group, exactly like `@admins` is
/// recognised by people who are not admins. Whether one MEANS you is a separate
/// question, answered by [selfMentionTokens].
const Set<String> groupMentionTokens = {
  mentionAll,
  mentionAdmins,
  mentionMembers,
  mentionAgents,
};

/// A suggestion in the @-typeahead: a group member, or a group keyword
/// (`@all`/`@admins`/`@members`). Member display uses the app's
/// `UserAvatar(userId:)`, so only id + username live here.
class MentionCandidate {
  /// Member user id; empty for a group keyword.
  final String id;

  /// The handle inserted after `@` (a username, or `all`/`admins`/`members`).
  final String username;

  /// Whether this is a group keyword (`@all`/`@admins`/`@members`).
  final bool isGroup;

  const MentionCandidate({
    required this.id,
    required this.username,
    this.isGroup = false,
  });
}

/// An in-progress mention token at the caret: [start] is the index of the `@`,
/// [query] is the (possibly empty) text typed after it up to the caret.
class MentionQuery {
  final int start;
  final String query;

  const MentionQuery(this.start, this.query);

  @override
  bool operator ==(Object other) =>
      other is MentionQuery && other.start == start && other.query == query;

  @override
  int get hashCode => Object.hash(start, query);

  @override
  String toString() => 'MentionQuery(start: $start, query: "$query")';
}

/// Characters allowed inside a username token after `@` (Chattr handles:
/// letters, digits, underscore, dot, dash).
final RegExp _handleChar = RegExp(r'[A-Za-z0-9_.\-]');

bool _isBoundaryBefore(String text, int atIndex) =>
    atIndex == 0 || text[atIndex - 1].trim().isEmpty;

/// Detects an active `@`-mention token ending at [cursor] within [text], or null
/// when the caret is not inside one.
///
/// A token starts at an `@` that sits at the start of the text or right after
/// whitespace, and runs to the caret containing only handle characters — so
/// `foo@bar` (email) and an already-finished `@bob ` (caret after the space) do
/// not match, but `@`, `@bo`, `hi @al` do.
MentionQuery? activeMentionQuery(String text, int cursor) {
  if (cursor < 0 || cursor > text.length) return null;
  var i = cursor - 1;
  while (i >= 0) {
    final ch = text[i];
    if (ch == '@') {
      if (_isBoundaryBefore(text, i)) {
        return MentionQuery(i, text.substring(i + 1, cursor));
      }
      return null; // '@' glued to a preceding word (e.g. an email) — not a mention
    }
    if (!_handleChar.hasMatch(ch)) {
      return null; // whitespace/punctuation → no token
    }
    i--;
  }
  return null;
}

/// Members whose username starts with [query] (case-insensitive), sorted by
/// username. An empty query returns all candidates (sorted).
List<MentionCandidate> filterMentionCandidates(
  String query,
  List<MentionCandidate> candidates,
) {
  final q = query.toLowerCase();
  final matches =
      candidates.where((c) => c.username.toLowerCase().startsWith(q)).toList()
        ..sort((a, b) {
          // Group keywords (@all/@admins/@members) first, then members A–Z.
          if (a.isGroup != b.isGroup) return a.isGroup ? -1 : 1;
          return a.username.toLowerCase().compareTo(b.username.toLowerCase());
        });
  return matches;
}

/// Replaces the token described by [query] (from `query.start` up to [cursor])
/// with `@username ` and returns the new text plus the caret position after the
/// inserted trailing space.
({String text, int cursor}) applyMention(
  String text,
  MentionQuery query,
  int cursor,
  String username,
) {
  final before = text.substring(0, query.start);
  final after = text.substring(cursor);
  final insert = '@$username ';
  return (text: '$before$insert$after', cursor: (before + insert).length);
}

/// The usernames that count as mention targets in a chat: every non-empty
/// member username plus, in groups (>2 participants), the `@all`/`@admins`/
/// `@members` keywords. Single source for both the bubble-routing decision
/// (custom builder vs. plain text bubble) and the highlight itself.
Set<String> memberMentionUsernames(Map<String, String> usernames) => {
  ...usernames.values.where((u) => u.isNotEmpty),
  if (usernames.length > 2) ...groupMentionTokens,
};

/// Ids of every candidate whose `@username` appears in [text] as a standalone
/// mention (boundary before the `@`, and a non-handle char or end after the
/// username — so `@bob` is not matched inside `@bobby` or an email).
Set<String> mentionedIds(String text, List<MentionCandidate> candidates) {
  final ids = <String>{};
  for (final c in candidates) {
    if (containsMention(text, c.username)) ids.add(c.id);
  }
  return ids;
}

/// A run of message text for highlighting: [text], whether it is a standalone
/// `@username` mention of a known member, and whether that mention means the
/// reader ([targetsMe]).
///
/// [targetsMe] is what separates „jemand ist gemeint" from „ich bin gemeint" —
/// without it every mention in a busy group looks equally urgent.
class MentionSegment {
  final String text;
  final bool isMention;

  /// True only for a mention that resolves to the reader — their own handle or
  /// the group keyword for their role. Always false on non-mention runs.
  final bool targetsMe;

  const MentionSegment(
    this.text, {
    required this.isMention,
    this.targetsMe = false,
  });

  @override
  bool operator ==(Object other) =>
      other is MentionSegment &&
      other.text == text &&
      other.isMention == isMention &&
      other.targetsMe == targetsMe;

  @override
  int get hashCode => Object.hash(text, isMention, targetsMe);

  @override
  String toString() =>
      'MentionSegment("$text", mention: $isMention, me: $targetsMe)';
}

/// Splits [text] into consecutive runs, marking each standalone `@username`
/// (username present in [usernames]) as a mention; plain text between mentions
/// is coalesced. Longer usernames match first so `@bobby` is not split into
/// `@bob` + `by`. Used to highlight mentions in rendered message text.
///
/// [selfTokens] (see [selfMentionTokens]) marks the subset that means the
/// reader, so the renderer can set those apart. A token listed there but not in
/// [usernames] stays unmarked — the chat decides what counts as a mention at
/// all, `@all` in a 1:1 chat is just text.
List<MentionSegment> splitMentions(
  String text,
  Set<String> usernames, {
  Set<String> selfTokens = const {},
}) {
  if (text.isEmpty) return const [];
  if (usernames.isEmpty || !text.contains('@')) {
    return [MentionSegment(text, isMention: false)];
  }
  final sorted = usernames.where((u) => u.isNotEmpty).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final out = <MentionSegment>[];
  final plain = StringBuffer();
  void flushPlain() {
    if (plain.isNotEmpty) {
      out.add(MentionSegment(plain.toString(), isMention: false));
      plain.clear();
    }
  }

  var i = 0;
  while (i < text.length) {
    if (text[i] == '@' && _isBoundaryBefore(text, i)) {
      String? hit;
      for (final u in sorted) {
        final needle = '@$u';
        if (text.startsWith(needle, i)) {
          final endIdx = i + needle.length;
          if (endIdx >= text.length || !_handleChar.hasMatch(text[endIdx])) {
            hit = u;
            break;
          }
        }
      }
      if (hit != null) {
        flushPlain();
        out.add(MentionSegment(
          '@$hit',
          isMention: true,
          targetsMe: selfTokens.contains(hit),
        ));
        i += hit.length + 1;
        continue;
      }
    }
    plain.write(text[i]);
    i++;
  }
  flushPlain();
  return out;
}

/// Whether [text] contains a standalone `@username` mention of any of
/// [usernames]. Cheap gate for routing/highlight decisions.
bool hasAnyMention(String text, Set<String> usernames) {
  if (!text.contains('@')) return false;
  for (final u in usernames) {
    if (containsMention(text, u)) return true;
  }
  return false;
}

/// The tokens that mean „you" for one reader in one chat: their own handle,
/// `@all`, the group keyword for their role (`@admins` when [isAdmin], else
/// `@members`), and `@agents` for an agent account ([isAgent]).
///
/// Single source for both consumers — the chat-list @-marker
/// ([mentionTargetsMe]) and the in-bubble highlight ([splitMentions]). They
/// used to answer „bin ich gemeint?" separately, which is exactly the kind of
/// pair that drifts: a marker in the list with nothing highlighted in the chat
/// sends the reader hunting.
Set<String> selfMentionTokens(
  String myUsername, {
  required bool isAdmin,
  bool isAgent = false,
}) => {
  if (myUsername.isNotEmpty) myUsername,
  mentionAll,
  isAdmin ? mentionAdmins : mentionMembers,
  // Orthogonal to the role: an agent can be admin or not, and `@agents` means
  // it either way.
  if (isAgent) mentionAgents,
};

/// Whether [text] contains a mention that targets the current user — either
/// `@myUsername`, `@all`, the group keyword for their role (`@admins` when
/// [isAdmin], else `@members`), or `@agents` when [isAgent]. Drives the
/// chat-list marker + (later) push.
bool mentionTargetsMe(
  String text,
  String myUsername, {
  required bool isAdmin,
  bool isAgent = false,
}) {
  if (!text.contains('@')) return false;
  return hasAnyMention(
    text,
    selfMentionTokens(myUsername, isAdmin: isAdmin, isAgent: isAgent),
  );
}

/// Whether [text] contains a standalone `@username` mention.
bool containsMention(String text, String username) {
  if (username.isEmpty) return false;
  final needle = '@$username';
  var from = 0;
  while (true) {
    final idx = text.indexOf(needle, from);
    if (idx < 0) return false;
    final boundaryBefore = _isBoundaryBefore(text, idx);
    final endIdx = idx + needle.length;
    final boundaryAfter =
        endIdx >= text.length || !_handleChar.hasMatch(text[endIdx]);
    if (boundaryBefore && boundaryAfter) return true;
    from = idx + 1;
  }
}
