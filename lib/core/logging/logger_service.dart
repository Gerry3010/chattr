// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';

import 'package:flutter/foundation.dart';

enum LogLevel {
  debug,
  info,
  warn,
  error,
  fatal;

  static final int lll = LogLevel.values
      .map((e) => e.name.length)
      .reduce(max.call);
}

/// A function that takes an integer and returns a string.
/// The integer represents the indentation level of the log message.
typedef MessageBuilder = String Function(int);

class LoggerService {
  static final LoggerService _instance = LoggerService._internal();

  factory LoggerService() => _instance;

  LoggerService._internal();

  /// In-memory ring buffer of recent formatted log lines, powering the hidden
  /// in-app dev log (Settings → tap the version). Always captured — even in a
  /// release/TestFlight build where console output is off — so a tester can copy
  /// a real log. Capped so it can't grow unbounded.
  static const int _bufferCap = 600;
  final List<String> _buffer = <String>[];

  /// The buffered log as one copy-pasteable string (oldest → newest).
  String get bufferedLogs => _buffer.join('\n');

  /// Number of buffered lines (for the UI).
  int get bufferedLineCount => _buffer.length;

  void clearBuffer() => _buffer.clear();

  void _addToBuffer(String line) {
    _buffer.add(line);
    if (_buffer.length > _bufferCap) {
      _buffer.removeRange(0, _buffer.length - _bufferCap);
    }
  }

  /// Log a debug message
  void debug(
    Object? message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
        bool? showRuntimeType,
  }) {
    _log(
      LogLevel.debug,
      message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      showRuntimeType: showRuntimeType
    );
  }

  /// Log an info message
  void info(
    Object? message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
        bool? showRuntimeType,
  }) {
    _log(
      LogLevel.info,
      message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      showRuntimeType: showRuntimeType
    );
  }

  /// Log a warning message
  void warning(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
        bool? showRuntimeType,
  }) {
    _log(
      LogLevel.warn,
      message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      showRuntimeType: showRuntimeType
    );
  }

  /// Log an error message
  void error(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
        bool? showRuntimeType,
  }) {
    _log(
      LogLevel.error,
      message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      showRuntimeType: showRuntimeType
    );
  }

  /// Log a fatal error message
  void fatal(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
        bool? showRuntimeType,
  }) {
    _log(
      LogLevel.fatal,
      message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      showRuntimeType: showRuntimeType
    );
  }

  void _log(
    LogLevel level,
    Object? message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    bool? showRuntimeType,
  }) {
    // Console output only in debug mode or for errors/fatal. The in-app buffer
    // (see [bufferedLogs]) is ALWAYS filled — even in a release/TestFlight build
    // where console printing is off — so the hidden dev log can surface a real,
    // copyable log to a tester.
    final toConsole =
        kDebugMode || level == LogLevel.error || level == LogLevel.fatal;

    final currentStack = StackTrace.current;
    final stackFrames = currentStack.toString().split('\n');
    final classRegex = RegExp(r'#\d+\s+(\S+).*:(\d*):');
    final callerFrame = stackFrames.firstWhere((frame) {
      final matches = classRegex.firstMatch(frame);
      return !(matches?.group(1)?.startsWith('LoggerService') ?? true);
    }, orElse: () => '');
    final callerClass = classRegex.firstMatch(callerFrame)?.group(1) ?? '';
    final callerLine = classRegex.firstMatch(callerFrame)?.group(2) ?? '';

    final timestamp = DateTime.now().toIso8601String();
    final levelStr = level.name.toUpperCase().padRight(LogLevel.lll);
    tag ??= [callerClass, callerLine].join(':');
    final tagStr = tag.isEmpty ? '' : '[$tag]';

    final emoji = kDebugMode
        ? switch (level) {
            LogLevel.debug => '🔎',
            LogLevel.info => 'ℹ️',
            LogLevel.warn => '⚠️',
            LogLevel.error => '‼️',
            LogLevel.fatal => '💀',
          }
        : '';

    showRuntimeType ??= message is Iterable || message is Map;
    final rtt = showRuntimeType ? '<${message.runtimeType}>(' : '';
    final prefixes = [emoji, timestamp, levelStr, tagStr];
    final prefix = '${prefixes.where((p) => p.isNotEmpty).join(' ')} $rtt';
    final indent = prefix.length;

    message ??= 'null';
    final messageStr = switch (message) {
      MessageBuilder() => message(indent),
      String() => message,
      int() => message.toString(),
      double() => message.toString(),
      bool() => message.toString(),
      DateTime() => message.toIso8601String(),
      Iterable() => message.join(', '),
      Map() => message.entries.map((e) => '${e.key}: ${e.value}').join(', '),
      Object() => message.toString(),
    };

    final suffix = showRuntimeType ? ')' : '';
    final logMessage = '$prefix$messageStr$suffix';

    // Always capture for the in-app buffer …
    _addToBuffer(logMessage);
    // … and print to console only when enabled for this level.
    if (toConsole) {
      debugPrint(logMessage);
    }

    // Error details, if available
    if (error != null) {
      const errorPrefix = 'Error: ';
      final errorIndent = max(indent - rtt.length - errorPrefix.length, 0);
      final errorRtt = showRuntimeType ? '<${error.runtimeType}>(' : '';
      final errorStr = '$errorRtt$error$suffix';
      final errorLine = '${' ' * errorIndent}$errorPrefix$errorStr';
      _addToBuffer(errorLine);
      if (toConsole) debugPrint(errorLine);
    }

    // Stack trace for errors and fatal
    if (stackTrace != null &&
        (level == LogLevel.error || level == LogLevel.fatal)) {
      _addToBuffer('Stack trace:\n$stackTrace');
      if (toConsole) {
        debugPrintStack(stackTrace: stackTrace, label: 'Stack trace');
      }
    }
  }

  /// Helper method to log and rethrow exceptions
  Never logAndRethrow(
    String message,
    Object error, {
    String? tag,
    StackTrace? stackTrace,
  }) {
    this.error(message, tag: tag, error: error, stackTrace: stackTrace);
    throw error;
  }

  /// Helper method to log exceptions without rethrowing
  void logException(
    String message,
    Object error, {
    String? tag,
    StackTrace? stackTrace,
  }) {
    this.error(message, tag: tag, error: error, stackTrace: stackTrace);
  }
}

// Global logger instance
final logger = LoggerService();

void testLogger() {
  final messages = [
    'Message 1',
    'Message 2',
    'Message 3',
    'Message 4',
    'Message 5',
];
  final ml = messages.length;
  final e = 'No error';
  logger.debug('Messages: $ml', error: e, showRuntimeType: true);
  logger.info('Messages: $ml', error: e, showRuntimeType: true);
  logger.warning('Messages: $ml', error: e, showRuntimeType: true);
  logger.error('Messages: $ml', error: e, showRuntimeType: true);
  logger.fatal('Messages: $ml', error: e, showRuntimeType: true);
  logger.debug('Messages: $ml', showRuntimeType: true);
  logger.info('Messages: $ml', showRuntimeType: true);
  logger.warning('Messages: $ml', showRuntimeType: true);
  logger.error('Messages: $ml', showRuntimeType: true);
  logger.fatal('Messages: $ml', showRuntimeType: true);

  logger.debug('Messages: $ml', error: e, showRuntimeType: false);
  logger.info('Messages: $ml', error: e, showRuntimeType: false);
  logger.warning('Messages: $ml', error: e, showRuntimeType: false);
  logger.error('Messages: $ml', error: e, showRuntimeType: false);
  logger.fatal('Messages: $ml', error: e, showRuntimeType: false);
  logger.debug('Messages: $ml', showRuntimeType: false);
  logger.info('Messages: $ml', showRuntimeType: false);
  logger.warning('Messages: $ml', showRuntimeType: false);
  logger.error('Messages: $ml', showRuntimeType: false);
  logger.fatal('Messages: $ml', showRuntimeType: false);
}