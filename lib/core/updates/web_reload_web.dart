// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:web/web.dart' as web;

/// Reloads the page; the (already downloaded) new service-worker build
/// activates on this load.
void reloadPage() => web.window.location.reload();
