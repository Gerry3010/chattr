// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Flutter
import Intents
import UIKit

/// QuickShare — iOS Share-Sheet Sharing-Suggestions (Item 5).
///
/// Donates an `INSendMessageIntent` interaction each time the user sends a
/// message, so the recipient / conversation surfaces in the **system share-sheet
/// suggestion row** (the people row at the top) and in Siri Suggestions.
///
/// Why a MethodChannel and not the App-Group file: these donations are consumed
/// by iOS at the OS level from the **main app process**. The Chattr Share
/// Extension (a separate process) is NOT involved in the suggestion row, so the
/// App-Group container — which the extension needs for *incoming* shares — is the
/// wrong transport here. The donation must run in-app, at send time.
///
/// Privacy: donations live in the on-device `INInteraction` store and drive local
/// suggestions only. There is no message content in the donation (we pass
/// `content: nil`); only the recipient's display name + a stable opaque id +
/// optional avatar. `deleteAll` wipes the store — the Dart side calls it on
/// logout and whenever the user turns the feature off, and gates `donateSend`
/// behind that setting. So nothing is donated unless the user opted in.
enum ShareSuggestionsChannel {
  static let channelName = "net.geraldhofbauer.chattr/share_suggestions"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "donateSend":
        donateSend(args: call.arguments as? [String: Any], result: result)
      case "deleteAll":
        INInteraction.deleteAll { error in result(error == nil) }
      case "deleteConversations":
        let ids = (call.arguments as? [String: Any])?["conversationIds"] as? [String] ?? []
        if ids.isEmpty { result(true); return }
        INInteraction.delete(with: ids) { error in result(error == nil) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// args: {
  ///   conversationId: String (stable chat id — dedupe key + continuation id),
  ///   conversationName: String? (group title; omit/nil for 1:1),
  ///   isGroup: Bool?,
  ///   conversationImagePath: String? (the GROUP's own picture as a local file;
  ///     omit for 1:1 or a group without a picture),
  ///   recipients: [{ id: String, displayName: String, avatarPath: String? }]
  /// }
  private static func donateSend(args: [String: Any]?, result: @escaping FlutterResult) {
    guard
      let args = args,
      let conversationId = args["conversationId"] as? String,
      let rawRecipients = args["recipients"] as? [[String: Any]],
      !rawRecipients.isEmpty
    else {
      result(FlutterError(code: "bad_args",
                          message: "conversationId + non-empty recipients required",
                          details: nil))
      return
    }

    let recipients: [INPerson] = rawRecipients.compactMap { r in
      guard let id = r["id"] as? String, let name = r["displayName"] as? String else { return nil }
      let handle = INPersonHandle(value: id, type: .unknown)
      var image: INImage?
      if let path = r["avatarPath"] as? String,
         let data = FileManager.default.contents(atPath: path) {
        image = INImage(imageData: data)
      }
      return INPerson(
        personHandle: handle,
        nameComponents: nil,
        displayName: name,
        image: image,
        contactIdentifier: nil,
        customIdentifier: id
      )
    }
    guard !recipients.isEmpty else {
      result(FlutterError(code: "bad_args", message: "no valid recipients", details: nil))
      return
    }

    let isGroup = (args["isGroup"] as? Bool) ?? (recipients.count > 1)
    let groupName = args["conversationName"] as? String
    let speakableGroup = (isGroup ? groupName : nil).map { INSpeakableString(spokenPhrase: $0) }

    let intent = INSendMessageIntent(
      recipients: recipients,
      outgoingMessageType: .outgoingMessageText,
      content: nil, // never donate message content (privacy)
      speakableGroupName: speakableGroup,
      conversationIdentifier: conversationId,
      serviceName: "Chattr",
      sender: nil,
      attachments: nil
    )

    // A group thread shows its own avatar in the suggestion; a 1:1 uses the
    // recipient's INPerson image automatically. Prefer the group's OWN picture
    // (`conversationImagePath`, filled by ShareSuggestionAvatarCache) over the
    // first member's face — the latter is only a fallback for a group without a
    // picture. Absent key → fall back; never a group icon that is someone's face
    // by accident.
    if speakableGroup != nil {
      let groupImage: INImage?
      if let path = args["conversationImagePath"] as? String,
         let data = FileManager.default.contents(atPath: path) {
        groupImage = INImage(imageData: data)
      } else {
        groupImage = recipients.first?.image
      }
      if let groupImage = groupImage {
        intent.setImage(groupImage, forParameterNamed: \.speakableGroupName)
      }
    }

    let interaction = INInteraction(intent: intent, response: nil)
    // Stable identifier → re-donating the same chat updates (not duplicates) it.
    interaction.identifier = conversationId
    interaction.direction = .outgoing
    interaction.donate { error in
      if let error = error {
        NSLog("[chattr] share-suggestion donate failed: %@", error.localizedDescription)
        result(false)
      } else {
        NSLog("[chattr] share-suggestion donated %d recipient(s) ok (conv=%@)",
              recipients.count, conversationId)
        result(true)
      }
    }
  }
}
