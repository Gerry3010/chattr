// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:freezed_annotation/freezed_annotation.dart';

part 'message_reaction_model.freezed.dart';
part 'message_reaction_model.g.dart';

/// Message Reaction Model
///
/// Represents an emoji reaction on a message
@freezed
abstract class MessageReactionModel with _$MessageReactionModel {
  const factory MessageReactionModel({
    required String id,
    @JsonKey(name: 'message_id') required String messageId,
    @JsonKey(name: 'user_id') required String userId,
    required String reaction,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _MessageReactionModel;

  factory MessageReactionModel.fromJson(Map<String, dynamic> json) =>
      _$MessageReactionModelFromJson(json);
}

/// Reaction Summary Model
///
/// Aggregated reaction data for a message
@freezed
abstract class ReactionSummary with _$ReactionSummary {
  const factory ReactionSummary({
    required String reaction,
    required int count,
    @JsonKey(name: 'user_reacted') required bool userReacted,
    // Who reacted (reaction order). chatview's "who reacted" sheet lists
    // these ids; empty for payloads from a pre-00035 backend.
    @JsonKey(name: 'user_ids') @Default(<String>[]) List<String> userIds,
  }) = _ReactionSummary;

  factory ReactionSummary.fromJson(Map<String, dynamic> json) =>
      _$ReactionSummaryFromJson(json);
}

/// Reaction User Model
///
/// User who reacted with a specific emoji
@freezed
abstract class ReactionUser with _$ReactionUser {
  const factory ReactionUser({
    @JsonKey(name: 'user_id') required String userId,
    required String username,
    @JsonKey(name: 'created_at') required DateTime createdAt,
  }) = _ReactionUser;

  factory ReactionUser.fromJson(Map<String, dynamic> json) =>
      _$ReactionUserFromJson(json);
}
