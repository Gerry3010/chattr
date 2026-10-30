// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../logging/logger_service.dart';

/// The maintenance switch: "no device deletes itself today."
///
/// Meant for the two moments one needs it — **before** a server deploy that
/// touches `auth.users`, and **in the middle of** an incident, when one does
/// not want to wait out the grace period from [account_gone_guard.dart] first.
///
/// **Why the address does not hang on the backend.** It would be obvious to
/// keep the flag in the database or serve it over the API — and precisely
/// wrong: the case it protects against is a broken backend. One would be asking
/// the damaged system whether it is damaged. So it lies as a **static file**
/// where the APK and its manifest already lie (`/download/`, served by Caddy
/// straight from the file system, outside the landing deploy's `rsync
/// --delete`). No Postgres, no Kong, no edge function on the way.
///
/// **A cache would be the enemy here.** Measured at the origin, Caddy dutifully
/// serves `no-cache` — only Cloudflare sits in front and replaces it with `max-
/// age=14400`. For four hours the fleet would therefore get the answer from
/// before, and because "no file" (404) looks exactly like "no maintenance", the
/// silent case would be the bad one: the switch is set and has no effect
/// anyway. Every query therefore appends a timestamp to the address
/// ([_mitZeitstempel]) — a different address, a different cache entry, so
/// always the question to the origin. That is the path that belongs to us
/// alone; a Cloudflare rule would be the second safeguard, but not one the
/// client should rely on.
///
/// **Unreachable does NOT mean "maintenance".** That is the less comfortable
/// direction, but the right one: were it the other way round, a permanently
/// wrong address — a typo, an expired certificate — would switch deletion off
/// forever and unnoticed, and a genuine remote deletion would have no effect.
/// The flag is the *deliberate* override; the *automatic* brake is the grace
/// period, and that always applies, entirely without a network.
class MaintenanceFlag {
  /// Where the flag lies. Overridable via `MAINTENANCE_URL` in the `.env`.
  ///
  /// The default is **baked in**, not empty: a flag that only takes effect with
  /// the next release does not help in the moment one needs it. Already shipped
  /// devices have to be able to reach it, otherwise it protects exactly not the
  /// fleet it is about.
  static Uri? get url {
    final raw = (dotenv.env['MAINTENANCE_URL'] ??
            'https://chattr.geraldhofbauer.net/download/maintenance.json')
        .trim();
    if (raw.isEmpty) return null;
    return Uri.tryParse(raw);
  }

  /// Is maintenance called for right now?
  ///
  /// Returns `false` on any doubt — see above.
  static Future<bool> isActive({
    http.Client? client,
    Uri? override,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final target = override ?? url;
    if (target == null) return false;
    final eigener = client == null;
    final c = client ?? http.Client();
    try {
      final res = await c.get(_mitZeitstempel(target)).timeout(timeout);
      if (res.statusCode != 200) return false;
      return parse(res.body);
    } catch (e) {
      logger.debug('Wartungsflagge nicht erreichbar ($e) — keine Wartung',
          tag: 'Maintenance');
      return false;
    } finally {
      if (eigener) c.close();
    }
  }

  /// Appends a timestamp so that no cache answers.
  ///
  /// Public, because that is precisely the point at which the switch would fail
  /// silently — and what can fail silently belongs under test.
  static Uri mitZeitstempel(Uri target) => _mitZeitstempel(target);

  static Uri _mitZeitstempel(Uri target) => target.replace(
        queryParameters: {
          ...target.queryParameters,
          // Seconds suffice: two queries in the same second are the same
          // question, and the cache stays manageable.
          't': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
        },
      );

  /// The content of the file, separate from the network, so the shape is
  /// testable.
  ///
  /// Expects `{"maintenance": true}`. Everything else — an empty body, the HTML
  /// of an error page, a missing field — means "no maintenance".
  static bool parse(String body) {
    try {
      final m = jsonDecode(body);
      return m is Map && m['maintenance'] == true;
    } catch (_) {
      return false;
    }
  }
}
