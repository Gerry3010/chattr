// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui';

import 'package:json_annotation/json_annotation.dart';

part 'chat_model.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class Chat {
  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime insertedAt; // Local-only: when chat was first inserted locally
  final String? createdBy;
  final String? name; // Optional name for group chats
  final String? description; // Optional group description / topic
  final String? avatarPath; // Optional group avatar object path (bucket group-avatars, 00055)
  final List<String> admins;
  final bool isGroup;
  final DateTime? lastMessageAt; // Timestamp of last message in chat
  final int unreadCount; // Number of unread messages
  final int? messageTtlSeconds; // Disappearing-messages TTL; null = disabled
  final bool isMcp; // True once an MCP agent has bound this chat to an owner (migration 00038)
  final String? mcpOwnerId; // The human user this MCP chat is bound to; null for normal chats

  /// Local-only (#3): chat pinned to the top of the ChatList. Lives in the
  /// encrypted local blob; the server never sees it, so `fromJson` on server
  /// data defaults it to false (JsonKey below) and the refresh-merge preserves
  /// the local value.
  @JsonKey(defaultValue: false)
  final bool isPinned;

  /// Local-only: when this chat was last opened. Replaces the server's
  /// `chat_members.last_read_at` — the unread count is derived from it against
  /// the local message store, so the server no longer needs to record when the
  /// user opened which chat. Lives in the encrypted local blob (like
  /// [isPinned]); server data never carries it, and the refresh-merge preserves
  /// the local value.
  final DateTime? lastReadAt;

  Chat({
    required this.id,
    required this.createdAt,
    DateTime? updatedAt,
    DateTime? insertedAt,
    this.createdBy,
    this.name,
    this.description,
    this.avatarPath,
    this.admins = const [],
    this.isGroup = true,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.messageTtlSeconds,
    this.isMcp = false,
    this.mcpOwnerId,
    this.isPinned = false,
    this.lastReadAt,
  }) : updatedAt = updatedAt ?? createdAt,
       insertedAt = insertedAt ?? createdAt;

  factory Chat.fromJson(Map<String, dynamic> json) => _$ChatFromJson(json);

  Map<String, dynamic> toJson() => _$ChatToJson(this);

  /// Computed property for sorting chats — the SAME expression the ChatList row
  /// displays (`lastMessageAt ?? createdAt`), so a chat never sorts by one
  /// instant while showing another. (Previously fell back to the local-only
  /// `insertedAt`, which diverges from the displayed `createdAt` for message-
  /// less chats → visible mis-sort. `insertedAt` stays for the local
  /// create-grace filter, just not for sort.)
  DateTime get sortDate => lastMessageAt ?? createdAt;

  /// Create copy with updated fields
  Chat copyWith({
    DateTime? updatedAt,
    DateTime? insertedAt,
    String? createdBy,
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    List<String>? admins,
    bool? isGroup,
    DateTime? lastMessageAt,
    int? unreadCount,
    int? messageTtlSeconds,
    bool clearMessageTtl = false,
    bool clearDescription = false,
    bool? isMcp,
    String? mcpOwnerId,
    bool? isPinned,
    DateTime? lastReadAt,
  }) {
    return Chat(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      insertedAt: insertedAt ?? this.insertedAt,
      createdBy: createdBy ?? this.createdBy,
      name: name ?? this.name,
      description:
          clearDescription ? null : (description ?? this.description),
      avatarPath: clearAvatar ? null : (avatarPath ?? this.avatarPath),
      admins: admins ?? this.admins,
      isGroup: isGroup ?? this.isGroup,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      unreadCount: unreadCount ?? this.unreadCount,
      messageTtlSeconds:
          clearMessageTtl ? null : (messageTtlSeconds ?? this.messageTtlSeconds),
      isMcp: isMcp ?? this.isMcp,
      mcpOwnerId: mcpOwnerId ?? this.mcpOwnerId,
      isPinned: isPinned ?? this.isPinned,
      lastReadAt: lastReadAt ?? this.lastReadAt,
    );
  }

  /// Check if a user is an admin
  bool isAdmin(String userId) {
    return admins.contains(userId);
  }

  Color get color {
    final cId = id.trim().split('-');
    // final intValue = (cId.fold(0, (prev, element) => prev + int.parse(element, radix: 16)) / (2^64)).floor();

    // final r = intValue & 0xFF;
    // final g = (intValue >> 8) & 0xFF;
    // final b = (intValue >> 16) & 0xFF;

    final intValues = cId.map((e) => int.parse(e, radix: 16)).toList();
    // final sum = intValues.reduce((value, element) => value + element);
    final first = intValues.removeAt(0);
    final last = intValues.removeLast();
    // final sumFL = first + last;

    var [rawR, rawG, rawB] = [
      intValues.removeAt(0),
      intValues.removeAt(0),
      intValues.removeAt(0),
    ];
    final rgbSum = [
      rawR,
      rawG,
      rawB,
    ].reduce((value, element) => value + element);

    final orders = [
      [rawR, rawG, rawB],
      [rawG, rawB, rawR],
      [rawB, rawR, rawG],
      [rawB, rawG, rawR],
      [rawG, rawR, rawB],
      [rawR, rawB, rawG],
    ];

    final orderIndex = (last - first) % orders.length;
    final order = orders[orderIndex];

    // logger.debug('Order: $orderIndex, $order', tag: chat.id);

    [rawR, rawG, rawB] = order;

    // final r = (((sum - sumFL) * rawR) / ((sum - sumFL) * 255)).floor();
    // final g = (((sum - sumFL) * rawG * 2) / ((sum - sumFL) * 255)).floor();
    // final b = (((sum - sumFL) * rawB) / ((sum - sumFL) * 255)).floor();
    // final r = ((rawR + rgbSum / rawR) * rgbSum / ((sum - sumFL) * 255)).floor();
    // final g = ((rawG + rgbSum / rawG) * rgbSum / ((sum - sumFL) * 255)).floor();
    // final b = ((rawB + rgbSum / rawB) * rgbSum / ((sum - sumFL) * 255)).floor();

    // String fd(num val, {int decimals = 2, int integerWidth = 3, String padding = ' '}) {
    //   final integerPart = val.toInt();
    //   final integerPartStr = integerPart.toString().padLeft(integerWidth, padding);
    //   final decimalPart = (val - integerPart).toStringAsFixed(decimals).split('.')[1];
    //   return '$integerPartStr.$decimalPart';
    // }

    // double getAdaptedColor(int rawColor, {required String label}) {
    //   final adaptionVal = rawColor / (rgbSum - rawColor * 2);
    //   final adaptedColor = rawColor * adaptionVal;
    //   final resultingColor = 255 * (adaptedColor / rgbSum);
    //   logger.debug('Adapted color for $label: ${fd(rawColor)} / ${fd(adaptionVal)} => ${fd(adaptedColor)} => ${fd(resultingColor)}', tag: chat.id);
    //   return resultingColor;
    // }

    // final r = (127.5 + ((255 - getAdaptedColor(rawR, label: "R")))).floor();
    // final g = (127.5 + ((255 - getAdaptedColor(rawG, label: "G")))).floor();
    // final b = (127.5 + ((255 - getAdaptedColor(rawB, label: "B")))).floor();
    // final adaptedR = getAdaptedColor(rawR, label: "R");
    // final adaptedG = getAdaptedColor(rawG, label: "G");
    // final adaptedB = getAdaptedColor(rawB, label: "B");
    final adaptedR = 51 + 204 * (rawR / rgbSum);
    final adaptedG = 51 + 204 * (rawG / rgbSum);
    final adaptedB = 51 + 204 * (rawB / rgbSum);

    // final adaptedSum = adaptedR + adaptedG + adaptedB;

    final r = adaptedR.floor();
    final g = adaptedG.floor();
    final b = adaptedB.floor();

    // final adaptedAvg = adaptedSum / 3;
    // final r = ((adaptedR + ((adaptedR - adaptedAvg) / ((adaptedSum - adaptedR) / adaptedAvg)) / 2)).floor();
    // final g = ((adaptedG + ((adaptedG - adaptedAvg) / ((adaptedSum - adaptedG) / adaptedAvg)) / 2)).floor();
    // final b = ((adaptedB + ((adaptedB - adaptedAvg) / ((adaptedSum - adaptedB) / adaptedAvg)) / 2)).floor();

    // final r = ((adaptedSum / 3 + ((adaptedR - adaptedSum / 3) / 0.75))).floor();
    // final g = ((adaptedSum / 3 + ((adaptedG - adaptedSum / 3) / 0.75))).floor();
    // final b = ((adaptedSum / 3 + ((adaptedB - adaptedSum / 3) / 0.75))).floor();

    final color = Color.fromARGB(255, r, g, b);
    return color;
  }
}
