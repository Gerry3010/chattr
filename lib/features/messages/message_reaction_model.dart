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

/// Removes [userId] from [summaries] — one emoji when [reaction] is given, all
/// of that user's reactions when it is null.
///
/// Pure, so the optimistic update in `ChatReactionsController` can be tested
/// without a database: the controller paints this result immediately and lets
/// the server refetch confirm it. A summary that loses its last reactor is
/// dropped rather than kept at zero — the UI renders one pill per summary, and
/// a pill reading "0" is worse than no pill.
///
/// [count] is decremented rather than derived from `userIds.length`: a pre-00035
/// backend sends an empty `userIds`, and in that case the count is all we have.
List<ReactionSummary> withoutUserReaction(
  List<ReactionSummary> summaries,
  String userId, [
  String? reaction,
]) {
  final result = <ReactionSummary>[];
  for (final summary in summaries) {
    final affected = reaction == null || summary.reaction == reaction;
    if (!affected || !summary.userIds.contains(userId)) {
      // Not ours to touch. `userReacted` alone is not enough to act on: with an
      // empty `userIds` we cannot tell WHICH id to drop, so leave it be.
      result.add(summary);
      continue;
    }
    final remaining = summary.userIds.where((id) => id != userId).toList();
    final count = summary.count - 1;
    if (count <= 0) continue;
    result.add(summary.copyWith(
      count: count,
      userReacted: false,
      userIds: remaining,
    ));
  }
  return result;
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
