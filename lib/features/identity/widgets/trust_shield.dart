// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../identity_verification_controller.dart';
import '../identity_verification_repository.dart';

/// Aussehen des Vertrauens-Zustands: Symbol, Farbe, Beschriftung.
typedef TrustAppearance = ({IconData icon, Color color, String label});

/// The ONE place that translates a trust state into icon and colour.
///
/// Before, the same mapping stood three times in the code — as an IconButton in
/// the header, as a chip in the profile sheet, as a badge in the member list —
/// and the three could drift apart without anyone noticing. With a trust
/// indicator that is exactly the dangerous kind of fault: two surfaces claiming
/// different things about the same person.
TrustAppearance trustAppearanceFor(IdentityVerificationState state) {
  return switch (state) {
    IdentityVerificationState.verified => (
        icon: Icons.verified_user,
        color: Colors.green,
        label: 'identity.state_verified'.tr(),
      ),
    IdentityVerificationState.changed => (
        icon: Icons.gpp_bad,
        color: Colors.red,
        label: 'identity.state_changed'.tr(),
      ),
    IdentityVerificationState.unknown => (
        icon: Icons.shield_outlined,
        color: Colors.grey,
        label: 'identity.state_unknown'.tr(),
      ),
    IdentityVerificationState.unverified => (
        icon: Icons.shield_outlined,
        color: Colors.grey,
        label: 'identity.state_unverified'.tr(),
      ),
  };
}

/// The same for the chat-wide summary. "Changed" beats "verified": a single
/// changed key has to colour the whole chat red, otherwise the warning
/// disappears behind the majority.
TrustAppearance trustAppearanceForSummary(ChatVerificationSummary v) {
  if (v.anyChanged) return trustAppearanceFor(IdentityVerificationState.changed);
  if (v.allVerified) {
    return trustAppearanceFor(IdentityVerificationState.verified);
  }
  return trustAppearanceFor(IdentityVerificationState.unverified);
}

/// Kleines Schild neben einem Namen (Mitgliederliste).
class TrustShieldIcon extends StatelessWidget {
  final TrustAppearance appearance;
  final double size;
  final VoidCallback? onTap;

  const TrustShieldIcon({
    super.key,
    required this.appearance,
    this.size = 18,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final icon = Icon(appearance.icon, size: size, color: appearance.color);
    if (onTap == null) return icon;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      // Without a label a coloured shield is mute to screen readers.
      child: Semantics(label: appearance.label, child: icon),
    );
  }
}

/// Symbol + Beschriftung in einer Zeile (Profil-Sheet, Info-Kopf).
class TrustStatusChip extends StatelessWidget {
  final TrustAppearance appearance;

  const TrustStatusChip({super.key, required this.appearance});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(appearance.icon, size: 16, color: appearance.color),
        const SizedBox(width: 6),
        Text(
          appearance.label,
          style: TextStyle(color: appearance.color, fontSize: 13),
        ),
      ],
    );
  }
}
