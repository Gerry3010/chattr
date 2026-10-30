// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// After a recovery the old installation kept writing its keys over the new
// ones on every start (2026-10-11). decideInstallationStatus is the rule that
// lets it notice it was replaced, without ever mistaking its own pending
// rotation or a lost key for a takeover.

import 'package:chattr/features/identity/installation_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  InstallationStatus decide(String? local, String? server, String? last) =>
      decideInstallationStatus(local: local, server: server, lastPublished: last);

  test('Server trägt den eigenen Schlüssel: aktuell', () {
    expect(decide('A', 'A', 'A'), InstallationStatus.current);
    expect(decide('A', 'A', null), InstallationStatus.current);
  });

  test('noch nichts veröffentlicht: aktuell, darf veröffentlichen', () {
    expect(decide('A', null, null), InstallationStatus.current);
  });

  test('eigener Schlüssel war veröffentlicht, jetzt steht ein fremder dort: abgelöst', () {
    expect(decide('A', 'B', 'A'), InstallationStatus.superseded);
  });

  test('ohne Merker lässt sich nichts sagen (Installation von vor 1.32.2)', () {
    expect(decide('A', 'B', null), InstallationStatus.unknown);
  });

  test('eigene Rotation noch nicht am Server: kein Fremder, nur ein Rückstand', () {
    // Merker zeigt den ALTEN eigenen Schlüssel, lokal liegt schon der neue.
    expect(decide('A2', 'A1', 'A1'), InstallationStatus.unknown);
  });

  test('ohne lokalen Schlüssel wird nicht geurteilt', () {
    expect(decide(null, 'B', 'B'), InstallationStatus.unknown);
  });
}
