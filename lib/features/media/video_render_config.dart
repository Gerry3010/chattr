// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;

/// Whether media_kit should render video with SOFTWARE decoding
/// (`VideoControllerConfiguration(enableHardwareAcceleration: false)`).
///
/// Software everywhere **except iOS**:
///  • **Linux/XWayland desktop:** the hardware GL path renders a blank/blue
///    texture (decoded frames never composite) → software is mandatory.
///  • **iOS:** the SOFTWARE renderer hits a libmpv `mp_image_crop` assertion for
///    certain clip dimensions → `SIGABRT` (whole-app crash while previewing/
///    sending such a video). iOS composites via Metal, so hardware acceleration
///    renders cleanly and avoids the assert.
///  • **Android / macOS / Windows / web:** unchanged software rendering — no
///    crash reported there, and flipping them would need per-platform re-verify.
///
/// Every media_kit `VideoController` in the app must derive its
/// `enableHardwareAcceleration` from this single source so the platform matrix
/// stays consistent (`enableHardwareAcceleration: !useSoftwareVideoRendering`).
bool get useSoftwareVideoRendering =>
    !(!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);
