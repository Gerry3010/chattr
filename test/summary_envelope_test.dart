// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The summary protocol travels as an ordinary encrypted message, so the parser
// is the only thing standing between "machine plumbing" and "a bubble in the
// user's chat". These tests care mostly about the failure directions.

import 'package:chattr/features/summary/summary_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SummaryRequest', () {
    test('round-trips through the wire format', () {
      final t = DateTime.utc(2026, 8, 5, 11, 30);
      final decoded = SummaryRequest.tryParse(
        SummaryRequest(scope: SummaryScope.since, since: t, hint: 'kurz')
            .encode(),
      );
      expect(decoded, isNotNull);
      expect(decoded!.scope, SummaryScope.since);
      expect(decoded.since, t);
      expect(decoded.hint, 'kurz');
    });

    test('omits what was not set, instead of writing nulls', () {
      final json = const SummaryRequest(scope: SummaryScope.unread).toJson();
      expect(json.containsKey('since'), isFalse);
      expect(json.containsKey('hint'), isFalse);
      expect(json.containsKey('agent'), isFalse);
    });

    test('carries the addressed agent — and its absence means "any agent"', () {
      // Without an addressee every agent in the chat would answer at once;
      // the field is what makes "the main agent" a real concept on the wire.
      final addressed = SummaryRequest.tryParse(
        const SummaryRequest(scope: SummaryScope.unread, agent: 'agent-1')
            .encode(),
      );
      expect(addressed!.agent, 'agent-1');

      final open = SummaryRequest.tryParse(
        const SummaryRequest(scope: SummaryScope.unread).encode(),
      );
      expect(open!.agent, isNull);
    });

    test('an unknown scope falls back to unread, not to everything', () {
      // Getting this backwards would dump a whole chat history on someone
      // because a newer client sent a scope this build has never heard of.
      expect(SummaryScopeX.fromWire('something-new'), SummaryScope.unread);
      expect(SummaryScopeX.fromWire(null), SummaryScope.unread);
    });
  });

  group('SummaryReply', () {
    test('round-trips', () {
      final decoded =
          SummaryReply.tryParse(const SummaryReply(forRequestId: 'm1', text: 'Kurz.').encode());
      expect(decoded!.forRequestId, 'm1');
      expect(decoded.text, 'Kurz.');
    });

    test('a reply without text or without a request id is not a reply', () {
      expect(SummaryReply.tryParse('{"_chattr_summary":1,"for":"m1"}'), isNull);
      expect(SummaryReply.tryParse('{"_chattr_summary":1,"text":"x"}'), isNull);
    });
  });

  group('what must NOT be mistaken for machinery', () {
    test('ordinary messages are left alone', () {
      for (final body in [
        'Hallo!',
        '',
        '{"nicht":"unsers"}',
        '{"_chattr_media":1,"media_type":"image"}',
      ]) {
        expect(isSummaryEnvelope(body), isFalse, reason: body);
        expect(SummaryRequest.tryParse(body), isNull, reason: body);
        expect(SummaryReply.tryParse(body), isNull, reason: body);
      }
      expect(isSummaryEnvelope(null), isFalse);
    });

    test('a message that merely TALKS about the marker stays a message', () {
      // Someone pasting the protocol into the chat must not vanish from it.
      const chat = 'Der Marker heisst _chattr_summarize, oder?';
      expect(isSummaryEnvelope(chat), isFalse);
    });

    test('broken JSON carrying the marker degrades to a normal message', () {
      expect(isSummaryEnvelope('{"_chattr_summarize":1, kaputt'), isFalse);
    });
  });

  test('both directions are recognised as machinery', () {
    expect(
      isSummaryEnvelope(const SummaryRequest(scope: SummaryScope.all).encode()),
      isTrue,
    );
    expect(
      isSummaryEnvelope(
          const SummaryReply(forRequestId: 'm1', text: 'x').encode()),
      isTrue,
    );
  });
}
