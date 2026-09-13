// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Self-mention: "I am meant" has to be distinguishable from "somebody is
// meant".
//
// Until now `@name`, `@all`, `@admins` and `@members` were all highlighted the
// same. In a group with traffic that means: the reader has to read every
// marking to find out whether it concerns them.
//
// The most important test in this file is the counter-check right at the
// bottom: the chat-list marker (`mentionTargetsMe`) and the highlight in the
// bubble (`splitMentions`) answer the same question and have to give the same
// answer. A dot in the list without a coloured spot in the chat sends the
// reader searching.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/mentions/mention_utils.dart';

void main() {
  // A group: three names, so the keywords apply too.
  final gruppe = memberMentionUsernames({
    'id-bob': 'bob',
    'id-alice': 'alice',
    'id-carol': 'carol',
  });

  group('selfMentionTokens', () {
    test('als einfaches Mitglied: eigener Name, @all, @members', () {
      expect(
        selfMentionTokens('bob', isAdmin: false),
        {'bob', mentionAll, mentionMembers},
      );
    });

    test('as an admin it is @admins instead of @members', () {
      expect(
        selfMentionTokens('bob', isAdmin: true),
        {'bob', mentionAll, mentionAdmins},
      );
    });

    test('without a resolved name only the keywords remain', () {
      // The name may be missing while the profile is not yet loaded — then no
      // empty token may arise that matches every "@".
      final t = selfMentionTokens('', isAdmin: false);
      expect(t, {mentionAll, mentionMembers});
      expect(t.contains(''), isFalse);
    });
  });

  group('splitMentions markiert, was mich meint', () {
    final ich = selfMentionTokens('bob', isAdmin: false);

    test('my name is marked as "means me"', () {
      expect(splitMentions('hey @bob', gruppe, selfTokens: ich), [
        const MentionSegment('hey ', isMention: false),
        const MentionSegment('@bob', isMention: true, targetsMe: true),
      ]);
    });

    test('the name of another member stays an ordinary mention', () {
      expect(splitMentions('hey @alice', gruppe, selfTokens: ich), [
        const MentionSegment('hey ', isMention: false),
        const MentionSegment('@alice', isMention: true),
      ]);
    });

    test('both in one message — only mine is highlighted', () {
      expect(splitMentions('@alice @bob', gruppe, selfTokens: ich), [
        const MentionSegment('@alice', isMention: true),
        const MentionSegment(' ', isMention: false),
        const MentionSegment('@bob', isMention: true, targetsMe: true),
      ]);
    });

    test('@all meint mich', () {
      expect(
        splitMentions('@all', gruppe, selfTokens: ich).single,
        const MentionSegment('@all', isMention: true, targetsMe: true),
      );
    });

    test('@members means me, @admins does not — I am no admin', () {
      expect(
        splitMentions('@members', gruppe, selfTokens: ich).single.targetsMe,
        isTrue,
      );
      expect(
        splitMentions('@admins', gruppe, selfTokens: ich).single.targetsMe,
        isFalse,
      );
    });

    test('as an admin exactly that is reversed', () {
      final alsAdmin = selfMentionTokens('bob', isAdmin: true);
      expect(
        splitMentions('@admins', gruppe, selfTokens: alsAdmin).single.targetsMe,
        isTrue,
      );
      expect(
        splitMentions('@members', gruppe, selfTokens: alsAdmin)
            .single
            .targetsMe,
        isFalse,
      );
    });

    test('without selfTokens nothing is highlighted (messages I wrote)', () {
      // A message I wrote myself does not mean me — even when "@all" is in it.
      // The bubble then gets an empty set.
      final segs = splitMentions('@all @bob', gruppe);
      expect(segs.where((s) => s.isMention), isNotEmpty);
      expect(segs.any((s) => s.targetsMe), isFalse);
    });

    test('@bob does not mark along when @bobby is there', () {
      final mitBobby = memberMentionUsernames({
        'id-bob': 'bob',
        'id-bobby': 'bobby',
        'id-alice': 'alice',
      });
      expect(splitMentions('yo @bobby', mitBobby, selfTokens: ich), [
        const MentionSegment('yo ', isMention: false),
        const MentionSegment('@bobby', isMention: true),
      ]);
    });

    test('an e-mail address containing my name is not a mention', () {
      expect(
        splitMentions('schreib mir: mail@bob.com', gruppe, selfTokens: ich),
        [const MentionSegment('schreib mir: mail@bob.com', isMention: false)],
      );
    });
  });

  group('the chat decides what counts as a mention at all', () {
    test('@all in a two-person conversation stays ordinary text', () {
      // `memberMentionUsernames` only takes the keywords in from three
      // participants upwards. A self token that does not apply in the chat must
      // produce no highlight — otherwise "write @all your wishes down" would
      // light up in a 1:1 for no reason.
      final asPair = memberMentionUsernames({
        'id-bob': 'bob',
        'id-alice': 'alice',
      });
      expect(asPair.contains(mentionAll), isFalse);

      final segs = splitMentions(
        'sag @all bescheid',
        asPair,
        selfTokens: selfMentionTokens('bob', isAdmin: false),
      );
      expect(segs.any((s) => s.isMention), isFalse);

      // A KNOWN divergence, deliberately NOT checked here: the chat-list marker
      // does not know the participant count and sets a dot on "@all" in a two-
      // person conversation too. So it shows something where the bubble
      // highlights nothing — the harmless direction (the reader finds the
      // message anyway). The clean fix would be to have the keyword apply only
      // from three participants there as well; for that it would first have to
      // be settled whether `Chat.isGroup` is reliably false (the default is
      // true).
      expect(mentionTargetsMe('sag @all bescheid', 'bob', isAdmin: false),
          isTrue);
    });

    test('your own name applies in a two-person conversation too', () {
      final asPair = memberMentionUsernames({
        'id-bob': 'bob',
        'id-alice': 'alice',
      });
      expect(
        splitMentions(
          '@bob?',
          asPair,
          selfTokens: selfMentionTokens('bob', isAdmin: false),
        ).first.targetsMe,
        isTrue,
      );
    });
  });

  group('counter-check: the list and the bubble say the same thing', () {
    // Both now derive from `selfMentionTokens`. This test pins down that they
    // do not drift apart: where the chat list sets an @ marking, something has
    // to be highlighted in the bubble too.
    const texte = [
      'hey @bob',
      'hey @alice',
      '@all zusammen',
      '@members aufgepasst',
      '@admins aufgepasst',
      'ganz ohne',
      'mail@bob.com',
      '@alice und @bob',
    ];

    for (final istAdmin in [false, true]) {
      for (final text in texte) {
        test('„$text" (Admin: $istAdmin)', () {
          final fromList = mentionTargetsMe(text, 'bob', isAdmin: istAdmin);
          final fromBubble = splitMentions(
            text,
            gruppe,
            selfTokens: selfMentionTokens('bob', isAdmin: istAdmin),
          ).any((s) => s.targetsMe);
          expect(
            fromBubble,
            fromList,
            reason: 'the chat-list marker and the highlight contradict each other',
          );
        });
      }
    }
  });
}
