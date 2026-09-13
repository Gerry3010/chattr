// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Renders the hero download buttons + the footer source link from
// window.CHATTR_LINKS (see config.js). A button appears ONLY when its URL is a
// non-empty string, so an unconfigured platform simply doesn't show.
(function () {
  'use strict';
  var L = window.CHATTR_LINKS || {};

  // [configKey, label] in display order; the first configured one gets primary styling.
  var PLATFORMS = [
    ['webApp', 'Web-App öffnen'],
    ['androidApk', 'Android-APK'],
    ['googlePlay', 'Google Play'],
    ['fdroid', 'F-Droid'],
    ['iosTestflight', 'iOS TestFlight'],
    ['iosAppStore', 'App Store'],
    ['macos', 'macOS'],
    ['windows', 'Windows'],
    ['linux', 'Linux']
  ];

  function btn(href, label, primary, external) {
    var a = document.createElement('a');
    a.href = href;
    a.className = 'cta-button' + (primary ? '' : ' cta-secondary');
    a.textContent = label;
    if (external) { a.target = '_blank'; a.rel = 'noopener'; }
    return a;
  }

  var host = document.getElementById('heroActions');
  if (host) {
    var made = 0;
    PLATFORMS.forEach(function (p) {
      var url = L[p[0]];
      if (typeof url === 'string' && url.trim()) {
        host.appendChild(btn(url.trim(), p[1], made === 0, /^https?:/i.test(url)));
        made++;
      }
    });
    // No download links configured → offer the source repo as the CTA so the
    // hero is never empty (the default state of a fresh fork).
    if (!made && L.repo) {
      host.appendChild(btn(L.repo, 'Quellcode auf GitHub ↗', true, true));
    }
  }

  // Footer source link.
  var repoEl = document.getElementById('repoLink');
  if (repoEl) {
    if (L.repo) { repoEl.href = L.repo; } else { repoEl.style.display = 'none'; }
  }
})();
