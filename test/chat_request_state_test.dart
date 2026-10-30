// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Which row a group member's profile sheet offers — "open chat", "accept
// request", "request pending" or "send chat request". The branching is
// deliberately a pure function: were it inside the widget, the case that really
// hurts (chat there AND request row there) could not be checked — and the app
// would offer to request somebody one has long been writing with.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/chat_requests/chat_request_model.dart';

const _me = 'me';
const _peer = 'peer';

IncomingChatRequest _incoming(String from) => (
      requesterId: from,
      username: 'wer-auch-immer',
      avatarPath: null,
      identityPublicKey: null,
      createdAt: DateTime(2026, 8, 24),
    );

OutgoingChatRequest _outgoing(String to, {String state = 'pending', String? chatId}) => (
      targetId: to,
      state: state,
      chatId: chatId,
      createdAt: DateTime(2026, 8, 24),
    );

ChatRequestStatus _status({
  String? existingChatId,
  List<IncomingChatRequest> incoming = const [],
  List<OutgoingChatRequest> outgoing = const [],
  String peerId = _peer,
}) =>
    chatRequestStatusFor(
      peerId: peerId,
      myId: _me,
      existingChatId: existingChatId,
      incoming: incoming,
      outgoing: outgoing,
    );

void main() {
  test('nothing pending: request', () {
    expect(_status().state, ChatRequestState.none);
  });

  test('er hat mich angefragt: annehmen', () {
    expect(
      _status(incoming: [_incoming(_peer)]).state,
      ChatRequestState.incoming,
    );
  });

  test('ich habe angefragt: warten', () {
    expect(
      _status(outgoing: [_outgoing(_peer)]).state,
      ChatRequestState.outgoing,
    );
  });

  test('an existing chat: open, with an id', () {
    final s = _status(existingChatId: 'c1');
    expect(s.state, ChatRequestState.chatExists);
    expect(s.chatId, 'c1');
  });

  test('an accepted request counts as a chat, even without a server answer', () {
    // The special case after accepting: the chat is there, but `findDirectChat`
    // has not run yet (or the network stayed silent).
    final s = _status(outgoing: [_outgoing(_peer, state: 'accepted', chatId: 'c2')]);
    expect(s.state, ChatRequestState.chatExists);
    expect(s.chatId, 'c2');
  });

  test('a chat beats every request row — in BOTH directions', () {
    // Exactly the case the order is fixed for: both requested each other in the
    // same moment, the server made a chat out of it — and one row is still
    // lying around. "Send request" would be wrong here, and visibly wrong.
    expect(
      _status(existingChatId: 'c1', incoming: [_incoming(_peer)]).state,
      ChatRequestState.chatExists,
    );
    expect(
      _status(existingChatId: 'c1', outgoing: [_outgoing(_peer)]).state,
      ChatRequestState.chatExists,
    );
  });

  test('incoming beats outgoing', () {
    // Both rows open: accepting is the shorter route to the same destination
    // and needs no second consent from the other party.
    expect(
      _status(
        incoming: [_incoming(_peer)],
        outgoing: [_outgoing(_peer)],
      ).state,
      ChatRequestState.incoming,
    );
  });

  test('requests to other people do not interfere', () {
    expect(
      _status(
        incoming: [_incoming('jemand-anderer')],
        outgoing: [_outgoing('noch-jemand')],
      ).state,
      ChatRequestState.none,
    );
  });

  test('I myself get no row at all', () {
    expect(_status(peerId: _me).state, ChatRequestState.self);
  });

  test('rejected looks like open — that is the promise, not a fault',
      () {
    // The server boils a rejection down to `pending` (00082). The client must
    // not make anything else of it; offering "request again" would be exactly
    // the disclosure there is not supposed to be.
    expect(
      _status(outgoing: [_outgoing(_peer)]).state,
      ChatRequestState.outgoing,
    );
  });
}
