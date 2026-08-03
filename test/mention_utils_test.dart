// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/mentions/mention_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const members = [
    MentionCandidate(id: 'u1', username: 'alice'),
    MentionCandidate(id: 'u2', username: 'bob'),
    MentionCandidate(id: 'u3', username: 'bobby'),
    MentionCandidate(id: 'u4', username: 'carol_1'),
  ];

  group('activeMentionQuery', () {
    test('null when no @ before caret', () {
      expect(activeMentionQuery('hello world', 11), isNull);
    });

    test('bare @ at start', () {
      expect(activeMentionQuery('@', 1), const MentionQuery(0, ''));
    });

    test('@ after whitespace with partial query', () {
      expect(activeMentionQuery('hi @al', 6), const MentionQuery(3, 'al'));
    });

    test('@ glued to a word (email) does not match', () {
      expect(activeMentionQuery('mail@bob', 8), isNull);
    });

    test('finished mention (caret after the space) does not match', () {
      expect(activeMentionQuery('@bob ', 5), isNull);
    });

    test('only the token up to the caret is returned', () {
      // caret between 'a' and 'l' of "@alice"
      expect(activeMentionQuery('@alice', 3), const MentionQuery(0, 'al'));
    });

    test('caret out of range → null', () {
      expect(activeMentionQuery('@bob', 99), isNull);
      expect(activeMentionQuery('@bob', -1), isNull);
    });
  });

  group('filterMentionCandidates', () {
    test('empty query returns all, sorted', () {
      final r = filterMentionCandidates('', members);
      expect(r.map((c) => c.username), ['alice', 'bob', 'bobby', 'carol_1']);
    });

    test('prefix filter is case-insensitive', () {
      final r = filterMentionCandidates('BO', members);
      expect(r.map((c) => c.username), ['bob', 'bobby']);
    });

    test('no matches', () {
      expect(filterMentionCandidates('zzz', members), isEmpty);
    });
  });

  group('applyMention', () {
    test('inserts @username + trailing space and moves caret past it', () {
      final q = activeMentionQuery('hi @al', 6)!;
      final r = applyMention('hi @al', q, 6, 'alice');
      expect(r.text, 'hi @alice ');
      expect(r.cursor, 'hi @alice '.length);
    });

    test('keeps text after the caret intact', () {
      // "@bo| end" → choose bob
      final q = activeMentionQuery('@bo end', 3)!;
      final r = applyMention('@bo end', q, 3, 'bob');
      expect(r.text, '@bob  end'); // inserted "@bob " then " end"
      expect(r.cursor, '@bob '.length);
    });
  });

  group('containsMention / mentionedIds', () {
    test('standalone mention matches', () {
      expect(containsMention('hey @bob!', 'bob'), isTrue);
    });

    test('mention at start and end of text', () {
      expect(containsMention('@bob', 'bob'), isTrue);
      expect(containsMention('yo @bob', 'bob'), isTrue);
    });

    test('prefix of a longer handle is NOT matched', () {
      expect(containsMention('@bobby', 'bob'), isFalse);
      expect(containsMention('@bobby', 'bobby'), isTrue);
    });

    test('email-embedded @ is NOT a mention', () {
      expect(containsMention('mail@bob.com', 'bob'), isFalse);
    });

    test('mentionedIds resolves the right members', () {
      final ids = mentionedIds('hi @alice and @bobby, not @carol', members);
      expect(ids, {'u1', 'u3'}); // alice + bobby; "carol" != "carol_1"
    });

    test('empty username never matches', () {
      expect(containsMention('@', ''), isFalse);
    });
  });

  group('splitMentions', () {
    final names = {'alice', 'bob', 'bobby'};

    test('plain text → single non-mention segment', () {
      expect(splitMentions('hello world', names), [
        const MentionSegment('hello world', isMention: false),
      ]);
    });

    test('splits a standalone mention and coalesces plain runs', () {
      expect(splitMentions('hey @bob how are you', names), [
        const MentionSegment('hey ', isMention: false),
        const MentionSegment('@bob', isMention: true),
        const MentionSegment(' how are you', isMention: false),
      ]);
    });

    test('longest username wins (@bobby not split into @bob)', () {
      expect(splitMentions('yo @bobby!', names), [
        const MentionSegment('yo ', isMention: false),
        const MentionSegment('@bobby', isMention: true),
        const MentionSegment('!', isMention: false),
      ]);
    });

    test('multiple mentions', () {
      expect(splitMentions('@alice and @bob', names), [
        const MentionSegment('@alice', isMention: true),
        const MentionSegment(' and ', isMention: false),
        const MentionSegment('@bob', isMention: true),
      ]);
    });

    test('email-embedded @ is not a mention', () {
      expect(splitMentions('mail@bob.com', names), [
        const MentionSegment('mail@bob.com', isMention: false),
      ]);
    });

    test('unknown handle stays plain', () {
      expect(splitMentions('@stranger hi', names), [
        const MentionSegment('@stranger hi', isMention: false),
      ]);
    });
  });

  group('hasAnyMention', () {
    final names = {'alice', 'bob'};
    test('true when a member is mentioned', () {
      expect(hasAnyMention('yo @bob', names), isTrue);
    });
    test('false for no @ / unknown handle / email', () {
      expect(hasAnyMention('plain text', names), isFalse);
      expect(hasAnyMention('@nobody', names), isFalse);
      expect(hasAnyMention('a@bob.com', names), isFalse);
    });
  });

  group('mentionTargetsMe (group keywords by role)', () {
    test('@myUsername targets me', () {
      expect(mentionTargetsMe('hi @bob', 'bob', isAdmin: false), isTrue);
    });
    test('@all targets everyone', () {
      expect(mentionTargetsMe('yo @all', 'bob', isAdmin: false), isTrue);
      expect(mentionTargetsMe('yo @all', 'bob', isAdmin: true), isTrue);
    });
    test('@admins targets me only when I am admin', () {
      expect(mentionTargetsMe('@admins hey', 'bob', isAdmin: true), isTrue);
      expect(mentionTargetsMe('@admins hey', 'bob', isAdmin: false), isFalse);
    });
    test('@members targets me only when I am NOT admin', () {
      expect(mentionTargetsMe('@members hey', 'bob', isAdmin: false), isTrue);
      expect(mentionTargetsMe('@members hey', 'bob', isAdmin: true), isFalse);
    });
    test('unrelated mention / plain text → false', () {
      expect(mentionTargetsMe('@alice', 'bob', isAdmin: true), isFalse);
      expect(mentionTargetsMe('plain', 'bob', isAdmin: true), isFalse);
    });
  });

  group('memberMentionUsernames', () {
    test('1:1 chat: member usernames only, no group keywords', () {
      final set = memberMentionUsernames({'u1': 'alice', 'u2': 'bob'});
      expect(set, {'alice', 'bob'});
    });
    test('group (>2): adds @all/@admins/@members keywords', () {
      final set = memberMentionUsernames({
        'u1': 'alice',
        'u2': 'bob',
        'u3': 'carol',
      });
      expect(set, {'alice', 'bob', 'carol', 'all', 'admins', 'members'});
    });
    test('empty usernames are dropped', () {
      expect(memberMentionUsernames({'u1': '', 'u2': 'bob'}), {'bob'});
    });
  });

  group('filterMentionCandidates group-first', () {
    test('group keywords sort before members', () {
      final cands = [
        const MentionCandidate(id: 'u1', username: 'bob'),
        const MentionCandidate(id: '', username: 'members', isGroup: true),
        const MentionCandidate(id: '', username: 'all', isGroup: true),
        const MentionCandidate(id: 'u2', username: 'alice'),
      ];
      expect(filterMentionCandidates('', cands).map((c) => c.username), [
        'all', // groups first, A–Z
        'members',
        'alice', // then members A–Z
        'bob',
      ]);
    });
  });
}
