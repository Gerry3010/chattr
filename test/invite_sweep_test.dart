// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Two bugs Gerry found on 2026-08-09, both in the invitation UI.
//
//  * An invitation that had already been redeemed stayed in "active invitations"
//    offering to revoke a spent token — in a 1:1 target chat that is every
//    invitation, the moment the invited person joins.
//  * A media/album/invite bubble from a perfectly signed sender announced
//    "not signed — authorship unverified".
//
// The second is the more dangerous of the two: the marker exists to be
// believed, and showing it on the overwhelming majority of messages teaches
// people to scroll past the one that matters.

import 'package:chattr/features/invites/invites_controller.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:flutter_test/flutter_test.dart';

ChatInvite _invite(String token, String targetChatId) => ChatInvite(
      token: token,
      chatId: 'group',
      targetChatId: targetChatId,
      createdAt: DateTime.utc(2026, 8, 9),
    );

void main() {
  group('fulfilledInviteTokens', () {
    test('a 1:1 invitation is spent once the invited person joined', () {
      // Gerry's screenshot: SeB stands under "Mitglieder" AND under "Aktive
      // Einladungen".
      final spent = fulfilledInviteTokens(
        chatId: 'group',
        active: [_invite('t1', 'direct-seb')],
        membersByChat: {
          'group': {'gerry', 'seb'},
          'direct-seb': {'gerry', 'seb'},
        },
      );
      expect(spent, {'t1'});
    });

    test('it stays while the invited person has not joined', () {
      final spent = fulfilledInviteTokens(
        chatId: 'group',
        active: [_invite('t1', 'direct-seb')],
        membersByChat: {
          'group': {'gerry'},
          'direct-seb': {'gerry', 'seb'},
        },
      );
      expect(spent, isEmpty);
    });

    test('a group target stays until the LAST member has joined', () {
      Set<String> sweep(Set<String> groupMembers) => fulfilledInviteTokens(
            chatId: 'group',
            active: [_invite('t1', 'other-group')],
            membersByChat: {
              'group': groupMembers,
              'other-group': {'gerry', 'seb', 'david'},
            },
          );
      expect(sweep({'gerry', 'seb'}), isEmpty);
      expect(sweep({'gerry', 'seb', 'david'}), {'t1'});
    });

    test('an invisible target chat is never swept', () {
      // A co-admin can invite into a chat we are not in; RLS then hands us no
      // member rows at all. Reading that as "everyone joined" would revoke a
      // live invitation behind the admin's back — the exact opposite of the
      // fix. This is the case behind the "04eceb3b" row in the screenshot.
      final spent = fulfilledInviteTokens(
        chatId: 'group',
        active: [_invite('t1', 'chat-we-cannot-see')],
        membersByChat: {
          'group': {'gerry', 'seb'},
        },
      );
      expect(spent, isEmpty);
    });

    test('nothing is swept when our own membership is unknown', () {
      // Same reasoning from the other side: without the group's member list
      // "every target member is in the group" is vacuously true for an empty
      // group, which would retire every invitation at once.
      expect(
        fulfilledInviteTokens(
          chatId: 'group',
          active: [_invite('t1', 'direct-seb')],
          membersByChat: {
            'direct-seb': {'gerry', 'seb'},
          },
        ),
        isEmpty,
      );
    });

    test('an already revoked invitation is not swept again', () {
      final revoked = ChatInvite(
        token: 't1',
        chatId: 'group',
        targetChatId: 'direct-seb',
        createdAt: DateTime.utc(2026, 8, 9),
        revokedAt: DateTime.utc(2026, 8, 10),
      );
      expect(
        fulfilledInviteTokens(
          chatId: 'group',
          active: [revoked],
          membersByChat: {
            'group': {'gerry', 'seb'},
            'direct-seb': {'gerry', 'seb'},
          },
        ),
        isEmpty,
      );
    });
  });

  group('sigStatusWarns — the marker only fires on a real finding', () {
    test('a checked signature is silent', () {
      // The regression: `update[sig_status]` is set for EVERY verified message,
      // 'valid' included, and the structured bubbles drew a marker for anything
      // non-null. Every signed photo therefore claimed unproven authorship.
      expect(sigStatusWarns('valid'), isFalse);
    });

    test('a wrong signature warns', () {
      expect(sigStatusWarns('invalid'), isTrue);
    });

    test('a missing signature in a v4+ envelope warns', () {
      expect(sigStatusWarns('unsigned'), isTrue);
    });

    test('nothing to check is silent', () {
      expect(sigStatusWarns(null), isFalse);
      expect(sigStatusWarns(''), isFalse);
    });

    test('an unknown status is silent rather than a false alarm', () {
      // Fail-safe direction: a status this build does not know must not be
      // rendered as an accusation.
      expect(sigStatusWarns('something_new'), isFalse);
    });
  });
}
