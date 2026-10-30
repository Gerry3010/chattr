// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Integration tests against the LOCAL Supabase stack (self-skip when absent)
// for migration 00069 (chat_invites): the invitation message's auto-approve
// is the first join path where NO admin looks at the joiner — so every single
// server-side check gets a NEGATIVE test here. Three SECURITY DEFINER
// functions writing membership are exactly the class where earlier RLS bugs
// lived; "the button is hidden in the UI" is not a security property.
//
//   flutter test test/chat_invites_rls_test.dart
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

void main() {
  const url = 'http://127.0.0.1:54321';
  const anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

  test('00069: create/revoke/redeem enforce every boundary server-side',
      () async {
    // alice: admin of the invited group G, member of target chat T.
    // bob:   member of T, NOT in G — the legitimate redeemer.
    // carol: member of T, but BLOCKED from G — must stay out.
    // mallory: total stranger — must not redeem, revoke or list.
    final alice = SupabaseClient(url, anonKey);
    final bob = SupabaseClient(url, anonKey);
    final carol = SupabaseClient(url, anonKey);
    final mallory = SupabaseClient(url, anonKey);
    final String aId, bId, cId, mId;
    try {
      aId = (await alice.auth.signInAnonymously()).user!.id;
      bId = (await bob.auth.signInAnonymously()).user!.id;
      cId = (await carol.auth.signInAnonymously()).user!.id;
      mId = (await mallory.auth.signInAnonymously()).user!.id;
    } on SocketException {
      markTestSkipped('local Supabase not reachable at $url');
      return;
    } catch (e) {
      markTestSkipped('Supabase auth unavailable: $e');
      return;
    }

    final suffix = const Uuid().v4().substring(0, 8);
    await alice.from('profiles').insert({'id': aId, 'username': 'a_$suffix'});
    await bob.from('profiles').insert({'id': bId, 'username': 'b_$suffix'});
    await carol.from('profiles').insert({'id': cId, 'username': 'c_$suffix'});
    await mallory.from('profiles').insert({'id': mId, 'username': 'm_$suffix'});

    // Group G — alice is its (trigger-set) admin and only member.
    final groupId = ((await alice
        .from('chats')
        .insert({'name': 'invite_g_$suffix'})
        .select()
        .single()))['id'] as String;
    await alice
        .from('chat_members')
        .insert({'chat_id': groupId, 'user_id': aId, 'public_key': 'k'});

    // Target chat T — alice created it; bob and carol are members.
    final targetId = ((await alice
        .from('chats')
        .insert({'name': 'invite_t_$suffix'})
        .select()
        .single()))['id'] as String;
    for (final id in [aId, bId, cId]) {
      await alice
          .from('chat_members')
          .insert({'chat_id': targetId, 'user_id': id, 'public_key': 'k'});
    }

    // carol is blocked from G (a blocked join request) — the auto-approve
    // must honour that; nobody reviews the join anymore.
    await carol.from('pending_chat_members').insert(
        {'chat_id': groupId, 'user_id': cId, 'public_key': 'k'});
    await alice
        .from('pending_chat_members')
        .update({'blocked_at': DateTime.now().toUtc().toIso8601String()})
        .eq('chat_id', groupId)
        .eq('user_id', cId);

    // --- create -------------------------------------------------------------
    // Non-admin of G must not mint an invite — even as a member of T.
    await expectLater(
      bob.rpc<dynamic>('create_chat_invite',
          params: {'p_chat_id': groupId, 'p_target_chat_id': targetId}),
      throwsA(isA<PostgrestException>()),
      reason: 'only group admins may create invites',
    );
    // Admin of G, but NOT a member of the target chat: also rejected.
    final foreignChatId = ((await bob
        .from('chats')
        .insert({'name': 'invite_f_$suffix'})
        .select()
        .single()))['id'] as String;
    await bob
        .from('chat_members')
        .insert({'chat_id': foreignChatId, 'user_id': bId, 'public_key': 'k'});
    await expectLater(
      alice.rpc<dynamic>('create_chat_invite',
          params: {'p_chat_id': groupId, 'p_target_chat_id': foreignChatId}),
      throwsA(isA<PostgrestException>()),
      reason: 'inviter must be a member of the target chat',
    );
    // The legitimate case.
    final token = await alice.rpc<dynamic>('create_chat_invite',
        params: {'p_chat_id': groupId, 'p_target_chat_id': targetId}) as String;
    expect(token, isNotEmpty);

    // --- visibility ---------------------------------------------------------
    // Only admins of G see the invite row (revoke UI); bob sees nothing.
    final bobSees = await bob.from('chat_invites').select() as List<dynamic>;
    expect(bobSees, isEmpty, reason: 'non-admins must not list invites');
    final aliceSees =
        await alice.from('chat_invites').select().eq('chat_id', groupId)
            as List<dynamic>;
    expect(aliceSees, hasLength(1));

    // --- redeem -------------------------------------------------------------
    // A stranger holding the token: the token alone is not a door key.
    await expectLater(
      mallory.rpc<dynamic>('redeem_chat_invite',
          params: {'p_token': token, 'p_public_key': 'mk'}),
      throwsA(isA<PostgrestException>()),
      reason: 'invite is only valid inside the target chat',
    );
    // A blocked user, even as a target-chat member: stays out.
    await expectLater(
      carol.rpc<dynamic>('redeem_chat_invite',
          params: {'p_token': token, 'p_public_key': 'ck'}),
      throwsA(isA<PostgrestException>()),
      reason: 'a group block must survive the auto-approve',
    );
    // The legitimate redeemer.
    final joined = await bob.rpc<dynamic>('redeem_chat_invite',
        params: {'p_token': token, 'p_public_key': 'bk'}) as String;
    expect(joined, groupId);
    final membership = await alice
        .from('chat_members')
        .select()
        .eq('chat_id', groupId)
        .eq('user_id', bId) as List<dynamic>;
    expect(membership, hasLength(1), reason: 'redeem must create membership');
    // Redeeming again is success, not an error (the card says "already in").
    final again = await bob.rpc<dynamic>('redeem_chat_invite',
        params: {'p_token': token, 'p_public_key': 'bk'}) as String;
    expect(again, groupId);

    // --- revoke -------------------------------------------------------------
    // bob is now a MEMBER of G — but still not an admin, so still no revoke.
    await expectLater(
      bob.rpc<dynamic>('revoke_chat_invite', params: {'p_token': token}),
      throwsA(isA<PostgrestException>()),
      reason: 'only group admins may revoke',
    );
    await alice.rpc<dynamic>('revoke_chat_invite', params: {'p_token': token});
    // After revocation nobody redeems — not even a target-chat member.
    await carol
        .from('pending_chat_members')
        .delete()
        .eq('chat_id', groupId)
        .eq('user_id', cId); // unblock carol: the failure must now be the revocation
    await expectLater(
      carol.rpc<dynamic>('redeem_chat_invite',
          params: {'p_token': token, 'p_public_key': 'ck'}),
      throwsA(isA<PostgrestException>()),
      reason: 'a revoked invite is dead',
    );

    // --- unauthenticated ----------------------------------------------------
    final anon = SupabaseClient(url, anonKey); // never signed in
    await expectLater(
      anon.rpc<dynamic>('redeem_chat_invite',
          params: {'p_token': token, 'p_public_key': 'x'}),
      throwsA(isA<PostgrestException>()),
      reason: 'anon must not execute the invite functions at all',
    );

    await alice.auth.signOut();
    await bob.auth.signOut();
    await carol.auth.signOut();
    await mallory.auth.signOut();
  });

  test('00071: an invitation retires itself once nobody is left to redeem it',
      () async {
    // The client-side sweep (1.18.2) can only see target chats WE are in. A
    // co-admin inviting through a chat we cannot see leaves the invitation
    // standing forever — Gerry's case: SeB invited David through their 1:1,
    // David joined, the row stayed. Only the server sees both memberships.
    final alice = SupabaseClient(url, anonKey);
    final bob = SupabaseClient(url, anonKey);
    final carol = SupabaseClient(url, anonKey);
    final String aId, bId, cId;
    try {
      aId = (await alice.auth.signInAnonymously()).user!.id;
      bId = (await bob.auth.signInAnonymously()).user!.id;
      cId = (await carol.auth.signInAnonymously()).user!.id;
    } on SocketException {
      markTestSkipped('local Supabase not reachable at $url');
      return;
    } catch (e) {
      markTestSkipped('Supabase auth unavailable: $e');
      return;
    }

    final suffix = const Uuid().v4().substring(0, 8);
    await alice.from('profiles').insert({'id': aId, 'username': 'ra_$suffix'});
    await bob.from('profiles').insert({'id': bId, 'username': 'rb_$suffix'});
    await carol.from('profiles').insert({'id': cId, 'username': 'rc_$suffix'});

    Future<String> newChat(SupabaseClient by, String name) async =>
        ((await by.from('chats').insert({'name': name}).select().single()))['id']
            as String;
    Future<void> addMember(SupabaseClient by, String chat, String user) async =>
        by.from('chat_members')
            .insert({'chat_id': chat, 'user_id': user, 'public_key': 'k'});
    Future<Map<String, dynamic>> inviteRow(String token) async =>
        (await alice.from('chat_invites').select().eq('token', token).single());

    final groupId = await newChat(alice, 'retire_g_$suffix');
    await addMember(alice, groupId, aId);

    // ── Case 1: a 1:1 target chat — the invitation is spent the moment the
    // invited person joins, and must retire itself.
    final oneToOne = await newChat(alice, 'retire_t1_$suffix');
    await addMember(alice, oneToOne, aId);
    await addMember(alice, oneToOne, bId);

    final spentToken = await alice.rpc<dynamic>('create_chat_invite',
        params: {'p_chat_id': groupId, 'p_target_chat_id': oneToOne}) as String;
    expect((await inviteRow(spentToken))['revoked_at'], isNull,
        reason: 'freshly minted invitations are active');

    await bob.rpc<dynamic>('redeem_chat_invite',
        params: {'p_token': spentToken, 'p_public_key': 'bk'});
    expect((await inviteRow(spentToken))['revoked_at'], isNotNull,
        reason: 'nobody in the target chat is left outside the group');
    // Consumption is not an admin decision — the two must stay tellable apart.
    expect((await inviteRow(spentToken))['revoked_by'], isNull);

    // ── Case 2: a group target where someone has NOT joined — the invitation
    // is still useful and must survive. This is the regression to fear: a rule
    // that retires too eagerly silently kills live invitations.
    final groupTarget = await newChat(alice, 'retire_t2_$suffix');
    for (final id in [aId, bId, cId]) {
      await addMember(alice, groupTarget, id);
    }
    final liveToken = await alice.rpc<dynamic>('create_chat_invite', params: {
      'p_chat_id': groupId,
      'p_target_chat_id': groupTarget,
    }) as String;
    // bob is already in the group from case 1; carol is not.
    await bob.rpc<dynamic>('redeem_chat_invite',
        params: {'p_token': liveToken, 'p_public_key': 'bk'});
    expect((await inviteRow(liveToken))['revoked_at'], isNull,
        reason: 'carol can still redeem it — this invitation is not spent');

    // ...and it retires exactly when the LAST one joins.
    await carol.rpc<dynamic>('redeem_chat_invite',
        params: {'p_token': liveToken, 'p_public_key': 'ck'});
    expect((await inviteRow(liveToken))['revoked_at'], isNotNull,
        reason: 'the last outstanding member joined');

    // ── A retired invitation is dead like any other revoked one.
    final dave = SupabaseClient(url, anonKey);
    final dId = (await dave.auth.signInAnonymously()).user!.id;
    await dave.from('profiles').insert({'id': dId, 'username': 'rd_$suffix'});
    await addMember(alice, groupTarget, dId);
    await expectLater(
      dave.rpc<dynamic>('redeem_chat_invite',
          params: {'p_token': liveToken, 'p_public_key': 'dk'}),
      throwsA(isA<PostgrestException>()),
      reason: 'retiring must be a real revocation, not a display trick',
    );

    // ── The helper is not an entry point of its own: a logged-in stranger
    // must not be able to probe tokens with it.
    await expectLater(
      bob.rpc<dynamic>('retire_invite_if_fulfilled',
          params: {'p_token': spentToken}),
      throwsA(isA<PostgrestException>()),
      reason: 'retire_invite_if_fulfilled is internal to redeem',
    );

    await alice.auth.signOut();
    await bob.auth.signOut();
    await carol.auth.signOut();
    await dave.auth.signOut();
  });
}
