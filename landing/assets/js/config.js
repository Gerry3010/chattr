// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Chattr landing — link configuration.
//
// FORKING CHATTR? This is the only file you need to touch for the download
// links. A platform button appears on the page ONLY when its URL below is a
// non-empty string. By default everything is empty except the source-repo link,
// so a fresh clone shows just the "Source" link and no download buttons for
// infrastructure you don't run. Fill in the platforms you actually publish.
window.CHATTR_LINKS = {
  // Source repository (footer "Source" link). Point this at YOUR fork.
  repo:          'https://github.com/Gerry3010/chattr',

  // Download / open targets — leave '' to hide that button.
  webApp:        '',   // Web-App / PWA
  androidApk:    '',   // Android APK (direct download)
  googlePlay:    '',   // Google Play
  fdroid:        '',   // F-Droid
  iosTestflight: '',   // iOS TestFlight
  iosAppStore:   '',   // iOS App Store
  macos:         '',   // macOS
  windows:       '',   // Windows
  linux:         '',   // Linux
};
