import Flutter
import UIKit
import Firebase
import FirebaseMessaging
import PushKit
import CallKit
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate {
  private static let appGroupId = "group.net.geraldhofbauer.chattr"
  /// Mirror of the names table the message pushes use — the Notification Service
  /// Extension writes it (`PushCacheChannel` → key `push_render_names`), and a
  /// VoIP wake looks the caller's name up from the same place, offline.
  private static let namesKey = "push_render_names"

  /// Held strongly for the whole app lifetime — a PKPushRegistry that is let go
  /// stops delivering VoIP pushes, and with them every call to a closed app.
  private var voipRegistry: PKPushRegistry?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()
    GeneratedPluginRegistrant.register(with: self)

    // App-lock unlock shim (audit M6/M7): one LAContext for both the challenge
    // prompt and the gated content-key read, so the unlock is a single Face ID.
    if let controller = window?.rootViewController as? FlutterViewController {
      AppLockChannel.register(with: controller.binaryMessenger)

      // Native gallery video picker (chattr/ios_media) — guarantees a local file
      // path for iCloud/HEVC clips that file_picker/image_picker can't materialize
      // (deterministic PhotoKit download, no third-party dependency). The Dart side
      // falls back to image_picker if this channel is absent, so registration is
      // additive.
      if #available(iOS 14.0, *) {
        ICloudMediaChannel.register(with: controller.binaryMessenger, presenter: controller)
      }

      // QuickShare (Item 5): donate INSendMessageIntent on each send so recent
      // Chattr contacts appear in the system share-sheet suggestion row. The Dart
      // side gates donation behind the user's setting; registration is additive.
      ShareSuggestionsChannel.register(with: controller.binaryMessenger)

      // Clipboard probe: prompt-free "is something pasteable?" check so the
      // composer paste affordance no longer triggers the iOS 16+ paste banner on
      // every menu open. The Dart side falls back to SystemClipboard.read() where
      // this channel is absent (Android/desktop); registration is additive.
      ClipboardProbeChannel.register(with: controller.binaryMessenger)

      // Push ohne Klartext (Stufe 2): mirror the id→name cache + localized
      // templates into the App Group so the Notification Service Extension can
      // render "New message from X" locally from an id-only push. The Dart side
      // calls this whenever the cache changes; registration is additive.
      PushCacheChannel.register(with: controller.binaryMessenger)
    }

    // Request notification permissions
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
      let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
      UNUserNotificationCenter.current().requestAuthorization(
        options: authOptions,
        completionHandler: { _, _ in }
      )
    } else {
      let settings: UIUserNotificationSettings =
        UIUserNotificationSettings(types: [.alert, .badge, .sound], categories: nil)
      application.registerUserNotificationSettings(settings)
    }

    application.registerForRemoteNotifications()

    // Calls that ring a CLOSED app (stage 3, 00088). PushKit delivers a VoIP
    // push to native code here; we hand it to flutter_callkit_incoming, which
    // reports the CallKit call and forwards accept/decline to Dart over its
    // event channel (`call_system_ui.dart` / `call_system_bridge.dart`). The
    // VoIP token is mirrored to Dart via `setDevicePushTokenVoIP`, which the
    // bridge saves to `device_tokens` as platform `ios_voip`.
    let voip = PKPushRegistry(queue: .main)
    voip.delegate = self
    voip.desiredPushTypes = [.voIP]
    self.voipRegistry = voip

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // FirebaseAppDelegateProxyEnabled is false (no swizzling), so we must forward
  // the raw APNs token to Firebase ourselves — and tell it which APNs environment
  // the token belongs to. Getting this wrong is fatal: a dev-signed build gets a
  // *sandbox* token, but if FCM delivers to *production* APNs, Apple rejects it
  // with `403 BadEnvironmentKeyInToken` and the push silently never arrives.
  //
  // We do NOT trust Firebase's `.unknown` auto-detect nor a `#if DEBUG` split:
  // both effectively key off the DEBUG compiler flag, so a *Profile* build
  // (release-mode, dev-signed → sandbox token) is misdetected as production.
  // Instead we read the real `aps-environment` from the embedded provisioning
  // profile at runtime and set the type explicitly. Correct for every case:
  // Debug/Profile/dev Release → development → .sandbox; TestFlight → production
  // → .prod.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data
  ) {
    let type = Self.apnsTokenType()
    NSLog("[chattr] APNs token registered, forwarding to FCM as %@",
          type == .prod ? "prod" : "sandbox")
    Messaging.messaging().setAPNSToken(deviceToken, type: type)
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
  }

  // MARK: - PushKit (VoIP) — stage 3 incoming calls to a closed app

  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate credentials: PKPushCredentials,
    for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    NSLog("[chattr] VoIP push token updated")
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didInvalidatePushTokenFor type: PKPushType
  ) {
    guard type == .voIP else { return }
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    // iOS 13+: EVERY VoIP push MUST report an incoming call to CallKit before
    // `completion()` returns, or iOS terminates the app and, after repeats,
    // stops delivering VoIP pushes entirely. So every path below reports a call
    // and always calls completion exactly once.
    guard type == .voIP, let plugin = SwiftFlutterCallkitIncomingPlugin.sharedInstance else {
      completion()
      return
    }

    // Server payload (00088): { aps: {}, chattr: { type, chat_id, signal_id } }.
    // Ids only — the caller's name is looked up locally from the App Group.
    let chattr = (payload.dictionaryPayload["chattr"] as? [String: Any]) ?? [:]
    let pushType = chattr["type"] as? String ?? ""
    let chatId = chattr["chat_id"] as? String ?? ""
    let rawSignalId = chattr["signal_id"] as? String ?? ""
    let signalId = rawSignalId.isEmpty ? UUID().uuidString : rawSignalId

    if pushType == "call_cancel" {
      // The caller gave up before this device answered. We still have to report
      // a call to satisfy the iOS-13 rule; reporting then ending immediately
      // dismisses the call the invite already showed.
      //
      // TODO(server, coordinate with linux-claude): ideally do NOT send
      // call_cancel over the VoIP path on iOS — a cancel that only ends a call
      // fights the "every VoIP push reports a call" rule. Better: let the shown
      // CallKit call time out (ringTimeout), or deliver the cancel off VoIP.
      let data = callkitData(signalId: signalId, chatId: chatId, name: nil)
      plugin.showCallkitIncoming(data, fromPushKit: true) {
        plugin.endAllCalls()
        completion()
      }
      return
    }

    // call_invite (and, defensively, any unknown type — we must report a call
    // for every VoIP push, so an unknown type still rings rather than risking
    // termination).
    let name = Self.callerName(forChatId: chatId)
    let data = callkitData(signalId: signalId, chatId: chatId, name: name)
    plugin.showCallkitIncoming(data, fromPushKit: true) {
      completion()
    }
  }

  /// Builds the CallKit description for one incoming audio call. Used for every
  /// VoIP push, the foreground case included: iOS requires each one to report a
  /// call, so CallKit rings (and takes the audio session) even while Chattr is
  /// open — the Dart in-app ringer must stand down when a CallKit call for the
  /// same signal is active. Mirrors the
  /// Dart `incomingCallParams` (call_system_ui.dart) so a call rung natively
  /// looks the same as one rung from the Dart layer: audio only, one call group,
  /// the signal id as the CallKit id, and chat_id/signal_id in `extra` so the
  /// accept/decline event carries them back to the controller.
  private func callkitData(
    signalId: String,
    chatId: String,
    name: String?
  ) -> flutter_callkit_incoming.Data {
    let caller = (name?.isEmpty == false) ? name! : "Chattr"
    let data = flutter_callkit_incoming.Data(
      id: signalId, nameCaller: caller, handle: "", type: 0)
    data.appName = "Chattr"
    data.duration = 45000 // matches call_rules.dart ringTimeout
    data.extra = ["chat_id": chatId, "signal_id": signalId]
    data.handleType = "generic"
    data.supportsVideo = false
    data.maximumCallGroups = 1
    data.maximumCallsPerCallGroup = 1
    data.supportsDTMF = false
    data.supportsHolding = false
    data.supportsGrouping = false
    data.supportsUngrouping = false
    // Our own ring (ios/Runner/call_ring.caf, converted from assets/sounds/
    // call_ring.wav) instead of the system ringtone. CallKit looks it up by name
    // in the main bundle and caps it at 30 s; the 4 s loop is built to repeat
    // seamlessly. The plugin applies it to the CXProviderConfiguration it
    // rebuilds for every reported call, so every report must carry it.
    data.ringtonePath = "call_ring.caf"
    // Phone app Recents (CHAT-38): a setting, mirrored into the App Group by
    // the Dart side. Absent (never changed) means listed, CallKit's default.
    data.includesCallsInRecents =
      UserDefaults(suiteName: Self.appGroupId)?
        .object(forKey: PushCacheChannel.callsInRecentsKey) as? Bool ?? true
    return data
  }

  /// A cached chat/caller name from the App Group, or nil when absent or empty —
  /// then the call rings as "Chattr". Tolerant of a corrupt/half-written cache
  /// (degrades to nil), mirroring the Notification Service Extension's decoder.
  private static func callerName(forChatId chatId: String) -> String? {
    guard
      !chatId.isEmpty,
      let defaults = UserDefaults(suiteName: appGroupId),
      let raw = defaults.string(forKey: namesKey),
      let data = raw.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let name = obj[chatId] as? String,
      !name.isEmpty
    else { return nil }
    return name
  }

  /// Reads `aps-environment` from the embedded provisioning profile to pick the
  /// APNs environment. Falls back to `.prod` when no profile is embedded, which
  /// is the App Store case (always production).
  private static func apnsTokenType() -> MessagingAPNSTokenType {
    #if targetEnvironment(simulator)
    return .sandbox
    #else
    guard
      let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Foundation.Data(contentsOf: url),
      let raw = String(data: data, encoding: .isoLatin1),
      let keyRange = raw.range(of: "aps-environment")
    else {
      return .prod
    }
    let tail = raw[keyRange.upperBound...]
    let dev = tail.range(of: "development")
    let prod = tail.range(of: "production")
    switch (dev, prod) {
    case let (d?, p?): return d.lowerBound < p.lowerBound ? .sandbox : .prod
    case (_?, nil): return .sandbox
    case (nil, _?): return .prod
    default: return .prod
    }
    #endif
  }
}
