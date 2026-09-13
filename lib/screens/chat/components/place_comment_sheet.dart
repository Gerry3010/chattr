// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/navigation/app_page_route.dart';
import '../../../features/places/place_envelope.dart';
import 'place_message_cards.dart';

/// The step between picking a place (or a calendar entry) and sending it:
/// shows the card the recipient will get and offers a line to go with it.
///
/// Sharing a place used to go straight to the chat picker — right for a bare
/// pin, wrong as soon as you mean something by it ("20:30 dort?"). The comment
/// rides INSIDE the envelope rather than as a second message, so it can never
/// arrive without its place or scroll away from it.
///
/// The preview is the real card, not a mock-up: what you approve here is what
/// they see. Taps are absorbed — this is a preview, not a map you can open.
///
/// Returns the body to send, or null when the user backs out.
Future<String?> showPlaceCommentSheet(
  BuildContext context, {
  required String envelope,
}) {
  return Navigator.of(context).push<String>(
    appPageRoute<String>(
      fullscreenDialog: true,
      builder: (_) => _PlaceCommentPage(envelope: envelope),
    ),
  );
}

class _PlaceCommentPage extends StatefulWidget {
  const _PlaceCommentPage({required this.envelope});

  final String envelope;

  @override
  State<_PlaceCommentPage> createState() => _PlaceCommentPageState();
}

class _PlaceCommentPageState extends State<_PlaceCommentPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The envelope with whatever was typed folded in. An empty field sends the
  /// place exactly as it arrived — the comment is an offer, not a toll.
  String _body() {
    final note = _controller.text.trim();
    final location = LocationEnvelope.tryParse(widget.envelope);
    if (location != null) return location.withNote(note).encode();
    final event = EventEnvelope.tryParse(widget.envelope);
    if (event != null) return event.withNote(note).encode();
    return widget.envelope;
  }

  Widget _preview() {
    final location = LocationEnvelope.tryParse(widget.envelope);
    if (location != null) {
      return LocationMessageCard(location: location, isOwn: true);
    }
    final event = EventEnvelope.tryParse(widget.envelope);
    if (event != null) {
      return EventMessageCard(event: event, isOwn: true);
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('places.comment_title'.tr())),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  // A preview must not act: opening the map from here would
                  // leave the compose step mid-send.
                  child: IgnorePointer(child: _preview()),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('place_comment_field'),
                      controller: _controller,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: 'places.comment_hint'.tr(),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const ValueKey('place_comment_send'),
                    icon: const Icon(Icons.send),
                    tooltip: 'chat_view.send'.tr(),
                    onPressed: () => Navigator.of(context).pop(_body()),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
