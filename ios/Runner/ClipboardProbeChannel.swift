// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Flutter
import UIKit

/// Prompt-free clipboard type probe.
///
/// The composer paste menu wants to know *whether* something pasteable is on
/// the clipboard (to show/enable the paste affordance) — it does NOT need the
/// content until the user actually taps "paste". The Dart side used to answer
/// this by calling `SystemClipboard.read()`, which reads the *content* and
/// therefore triggers the iOS 16+ transparency banner ("Chattr would like to
/// paste from X") on every menu open.
///
/// `UIPasteboard`'s `hasStrings` / `hasImages` / `hasURLs` properties report
/// only the *presence* of a content type, never the content itself, and are
/// documented as prompt-free — no banner, regardless of the per-app "Paste from
/// Other Apps" setting (which defaults to "Ask"). This channel exposes exactly
/// that.
///
/// The actual paste (when the user taps "paste") still reads content and may
/// show the banner once — that is expected and user-initiated. Only the
/// proactive menu-open *probe* moves to this prompt-free path.
///
/// Registration is additive: the Dart side falls back to `read()` on platforms
/// where this channel is absent (Android/desktop).
enum ClipboardProbeChannel {
  static let channelName = "net.geraldhofbauer.chattr/clipboard_probe"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "probe":
        let pb = UIPasteboard.general
        // These are presence-only checks; none of them expose content, so none
        // of them trigger the paste transparency banner.
        let hasText = pb.hasStrings
        let hasImage = pb.hasImages
        let hasUrl = pb.hasURLs
        result([
          "hasText": hasText,
          "hasImage": hasImage,
          "hasUrl": hasUrl,
          "hasAny": hasText || hasImage || hasUrl,
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
