// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/security/security_providers.dart';

/// The skin tone the picker uses for all emoji with skin-tone variants.
///
/// Empty means "none" — then the yellow default stands, and that is also the
/// preset: a skin tone is a statement about one's own person, and nobody should
/// have one assigned unasked.
///
/// The package can do skin tones only **per emoji** and only via a long press;
/// the choice there applies to that one grab and is gone again after the next
/// opening. So whoever wants to send 👍 in their skin tone long-presses every
/// time. Hence the choice lives here — made once, it applies to the whole grid
/// and across restarts. The long press remains regardless: for the individual
/// case in which it should be a different tone.
final skinToneProvider =
    StateNotifierProvider<SkinToneController, String>((ref) {
  return SkinToneController(ref.read(secureStorageProvider));
});

/// Stores the chosen skin tone and keeps it across restarts.
class SkinToneController extends StateNotifier<String> {
  static const _storageKey = 'emoji_skin_tone_v1';

  final FlutterSecureStorage _storage;

  /// Starts without a skin tone and loads the stored one afterwards.
  SkinToneController(this._storage) : super('') {
    _init();
  }

  Future<void> _init() async {
    final raw = await _storage.read(key: _storageKey);
    // Accept only known modifiers. A value from a future version we do not know
    // would otherwise be appended as a character to every emoji and produce
    // nothing but broken reactions.
    if (mounted && raw != null && SkinTone.values.contains(raw)) {
      state = raw;
    }
  }

  /// Setzt den Hautton; leerer String = keiner (gelb).
  Future<void> setTone(String tone) async {
    final valid = SkinTone.values.contains(tone) ? tone : '';
    await _storage.write(key: _storageKey, value: valid);
    state = valid;
  }
}
