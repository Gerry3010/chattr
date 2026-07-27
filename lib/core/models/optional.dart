// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

class Optional<T> {
  final T? value;

  Optional(this.value);

  factory Optional.empty([T? value]) => Optional<T>(null);

  factory Optional.ofNullable(T? value) => Optional(value);

  static Optional<T>? orNull<T>(T? value) => value == null ? null : Optional(value);

  bool get isNil => value == null;

// static T? getOptional(Optional<T>? encryptedContent) => encryptedContent != null ? encryptedContent.value : this.encryptedContent;
}

extension OptionalExtension<T> on Optional<T>? {
  T? get(T? fallback) {
    if (this == null) {
      return fallback;
    }
    return this?.value;
  }
}
