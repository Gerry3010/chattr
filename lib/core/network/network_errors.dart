// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderException;
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthRetryableFetchException;

import 'device_connectivity.dart';

/// Whether [error] means "could not reach the server" rather than "the server
/// said no" (CHAT-63).
///
/// Supabase's clients wrap a dead socket in an http [ClientException] (rest,
/// storage, functions), gotrue in [AuthRetryableFetchException]. No
/// `SocketException` check by type: that lives in dart:io, which the web build
/// cannot import; the message test below catches what slips through.
bool isNetworkError(Object error) {
  final inner = error is ProviderException ? error.exception : error;
  if (inner is ClientException ||
      inner is AuthRetryableFetchException ||
      inner is TimeoutException ||
      inner is DeviceOfflineException) {
    return true;
  }
  final text = inner.toString();
  return text.contains('SocketException') ||
      text.contains('Failed host lookup') ||
      text.contains('Connection refused') ||
      text.contains('Network is unreachable') ||
      text.contains('Connection closed before');
}

/// What to tell the reader about [error]: "no connection" in words for a
/// network failure, otherwise the error itself as before.
String userFacingError(Object error) => isNetworkError(error)
    ? 'errors.no_connection'.tr()
    : 'common.error'.tr(args: ['$error']);

/// Retry policy for every provider (passed to the root ProviderScope).
///
/// Riverpod retries a failed provider ten times with growing pauses, about
/// 38 s in all. Offline that was 38 s of spinner before any word, on screens
/// like blocked users or the MCP tokens. A network error now gets two quick
/// retries, then the screen says what is wrong and offers to retry; the
/// error views retry by themselves when the connection is back. Everything
/// else keeps Riverpod's default.
Duration? chattrRetry(int retryCount, Object error) {
  if (isNetworkError(error)) {
    return retryCount < 2
        ? Duration(milliseconds: 400 * (retryCount + 1))
        : null;
  }
  return ProviderContainer.defaultRetry(retryCount, error);
}
