// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The row survives restarts, and what it does with a broken store is the part
// worth pinning down: whatever goes wrong, the answer is the row everyone
// knows. A sheet with five buttons, or none, is worse than an order that is a
// little out of date.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/reactions/reaction_usage_controller.dart';
import 'package:chattr/features/reactions/reaction_usage_rules.dart';

const _key = 'reaction_usage_v1';

/// The iOS keychain while the phone is locked: the first read fails.
class _GesperrtBeimStart extends FlutterSecureStorage {
  _GesperrtBeimStart();

  var gesperrt = true;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (gesperrt) {
      throw PlatformException(code: '-25308', message: 'interaction not allowed');
    }
    return super.read(key: key);
  }
}
const _daumen = '\u{1F44D}';
const _beten = '\u{1F64F}';

final _jetzt = DateTime.utc(2026, 9, 24);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<ReactionUsageController> geladen() async {
    final c = ReactionUsageController(
      const FlutterSecureStorage(),
      now: () => _jetzt,
    );
    await Future<void>.delayed(Duration.zero);
    return c;
  }

  String abgelegt(List<String> order, Map<String, double> counts,
          {DateTime? gealtertAm}) =>
      jsonEncode({
        'order': order,
        'counts': counts,
        'agedAt': (gealtertAm ?? _jetzt).toIso8601String(),
      });

  test('ohne Ablage steht die gewohnte Reihe', () async {
    final c = await geladen();
    expect(c.state.order, quickReactionEmojis);
  });

  test('die Reihenfolge ueberlebt den Neustart', () async {
    final erste = await geladen();
    for (var i = 0; i < 16; i++) {
      await erste.note(_daumen);
    }
    expect(erste.state.order.first, _daumen);

    final zweite = await geladen();
    expect(zweite.state.order.first, _daumen);
  });

  test('eine unleserliche Ablage faellt auf die gewohnte Reihe zurueck',
      () async {
    FlutterSecureStorage.setMockInitialValues({_key: 'kein json'});
    final c = await geladen();
    expect(c.state.order, quickReactionEmojis);
  });

  test('eine Reihe der falschen Laenge wird verworfen', () async {
    // Sonst haette das Blatt eine Luecke oder einen Ueberlauf — und zwar
    // dauerhaft, weil nichts sie je wieder auf sechs braechte.
    FlutterSecureStorage.setMockInitialValues({
      _key: abgelegt([_daumen, _beten], {_daumen: 9, _beten: 9}),
    });
    final c = await geladen();
    expect(c.state.order, quickReactionEmojis);
  });

  test('beim Laden wird nachgealtert', () async {
    // Sonst traegt die Reihe nach einer langen Pause noch das Gewicht von
    // damals und reagiert auf den ersten Tap so, als waere nichts gewesen.
    FlutterSecureStorage.setMockInitialValues({
      _key: abgelegt(
        quickReactionEmojis,
        {for (final e in quickReactionEmojis) e: 100},
        gealtertAm: _jetzt.subtract(const Duration(days: 30)),
      ),
    });
    final c = await geladen();
    expect(c.state.weightOf(quickReactionEmojis.first), closeTo(50, 0.001));
  });

  test('ein zurueckgenommenes Emoji zaehlt nicht mit', () async {
    // Der Controller kennt nur `note`; das Gate sitzt im Adapter. Hier wird
    // festgehalten, dass `note` wirklich nur hebt — wer es spaeter auch beim
    // Entfernen aufruft, schiebt ausgerechnet den Fehlgriff nach vorne.
    final c = await geladen();
    final vorher = c.state.weightOf(_daumen);
    await c.note(_daumen);
    expect(c.state.weightOf(_daumen), vorher + 1);
  });

  test('gesperrter Schlüsselbund beim Start: nichts überschrieben, später addiert',
      () async {
    // 2026-10-22: Ein Start im Hintergrund (VoIP-Push, Telefon gesperrt) las
    // die Reihe nicht, und die nächste Reaktion speicherte „Start + 1“ über
    // alles, was bisher gezählt war.
    const ablage = FlutterSecureStorage();
    await ablage.write(
      key: _key,
      value: abgelegt(quickReactionEmojis, {
        ...ReactionUsage.seed(quickReactionEmojis, _jetzt).counts,
        _beten: 2.0,
      }),
    );
    final speicher = _GesperrtBeimStart();
    final rueckkehr = StreamController<void>.broadcast();
    addTearDown(rueckkehr.close);
    final c = ReactionUsageController(
      speicher,
      now: () => _jetzt,
      resumes: rueckkehr.stream,
    );
    await Future<void>.delayed(Duration.zero);

    await c.note(_beten);
    final roh = await ablage.read(key: _key);
    expect((jsonDecode(roh!) as Map)['counts'][_beten], 2.0,
        reason: 'solange nichts gelesen ist, wird nichts geschrieben');

    speicher.gesperrt = false;
    rueckkehr.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(c.state.weightOf(_beten), 3.0, reason: 'gespeichert 2 + die neue 1');
    expect(c.state.order.last, _beten, reason: 'drei Mal: auf die Reihe');
    final danach = jsonDecode((await ablage.read(key: _key))!) as Map;
    expect(danach['counts'][_beten], 3.0);
  });
}
