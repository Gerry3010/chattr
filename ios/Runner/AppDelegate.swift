import Flutter
import UIKit
import Firebase
import FirebaseMessaging

@main
@objc class AppDelegate: FlutterAppDelegate {
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
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
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

  /// Reads `aps-environment` from the embedded provisioning profile to pick the
  /// APNs environment. Falls back to `.prod` when no profile is embedded, which
  /// is the App Store case (always production).
  private static func apnsTokenType() -> MessagingAPNSTokenType {
    #if targetEnvironment(simulator)
    return .sandbox
    #else
    guard
      let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url),
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
