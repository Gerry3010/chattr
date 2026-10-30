// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Compares "1.32.0"-style versions number by number. As strings, "1.10.0"
/// would sort before "1.9.0" and the cards would come in the wrong order.
/// Anything after a "+" or "-" (build, pre-release) is ignored.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .split(RegExp('[+-]'))
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// The cards still to show, oldest first: in the catalog, not yet marked as
/// read, and not newer than the installed app — a card must never announce
/// something this build does not have yet.
List<String> unreadWhatsNew({
  required Iterable<String> catalogVersions,
  required Set<String> seen,
  required String installed,
}) {
  final out = [
    for (final v in catalogVersions)
      if (!seen.contains(v) && compareVersions(v, installed) <= 0) v,
  ]..sort(compareVersions);
  return out;
}

/// "1.32.0" → "1.32", "1.32.1" stays. The title reads "Neu in 1.32"; a
/// trailing ".0" adds nothing a person wants to read.
String displayVersion(String v) =>
    v.endsWith('.0') && v.split('.').length == 3
        ? v.substring(0, v.length - 2)
        : v;
