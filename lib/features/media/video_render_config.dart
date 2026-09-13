// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;

/// Whether media_kit should render video with SOFTWARE decoding
/// (`VideoControllerConfiguration(enableHardwareAcceleration: false)`).
///
/// Software everywhere **except iOS and Android**: • **Linux/XWayland
/// desktop:** the hardware GL path renders a blank/blue texture (decoded frames
/// never composite) → software is mandatory. • **iOS:** the SOFTWARE renderer
/// hits a libmpv `mp_image_crop` assertion for certain clip dimensions →
/// `SIGABRT` (whole-app crash while previewing/ sending such a video). iOS
/// composites via Metal, so hardware acceleration renders cleanly and avoids
/// the assert. • **Android (1.27):** this is where the stutter hung. On Android
/// this switch controls not only the drawing but the decoding too: `false` sets
/// `hwdec: 'no'` in media_kit, and then H.264/HEVC runs entirely on the phone's
/// CPU. With a 1080p60 or 4K clip that is not enough, and playback stalls. It
/// was never an Android decision: the switch comes from the Linux/XWayland
/// workaround and had stood wholesale for everything but iOS ever since.
/// media_kit forces software rendering itself in the emulator anyway, so the
/// route there stays open. • **macOS / Windows / web:** unchanged software
/// rendering — no crash reported there, and flipping them would need per-
/// platform re-verify.
///
/// Every media_kit `VideoController` in the app must derive its
/// `enableHardwareAcceleration` from this single source so the platform matrix
/// stays consistent (`enableHardwareAcceleration: !useSoftwareVideoRendering`).
bool get useSoftwareVideoRendering =>
    !(!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android));
