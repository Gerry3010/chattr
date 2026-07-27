import Flutter
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers

/// Native gallery video picker that guarantees a LOCAL file path even for
/// iCloud "Optimize Storage" / HEVC clips.
///
/// Why this exists: both `file_picker` and `image_picker` resolve a picked video
/// through PHPicker's `NSItemProvider.loadFileRepresentation`, which throws
/// "Cannot load representation of type public.movie / public.mpeg-4" when the clip
/// isn't materialized on-device yet (iCloud). We instead resolve the picked asset
/// to a `PHAsset` and stream its original video resource to a temp file via
/// `PHAssetResourceManager` with `isNetworkAccessAllowed = true`, which forces the
/// iCloud download deterministically — first try, no re-encode. Pure Apple
/// frameworks, no third-party dependency (deliberate: E2E-privacy supply chain).
///
/// Contract (agreed with the Dart side, `chattr/ios_media`):
///   • `pickGalleryVideo` (args: `{ maxBytes: Int? }`)
///       → success: `{ path, name, sizeBytes, mime, durationMs }`
///       → user cancel: `nil`
///       → `FlutterError` codes: `no_permission`, `icloud_failed`, `too_large`
///   • EventChannel `chattr/ios_media/progress` → `Double` 0…1 during download
///
/// The returned `path` lives in `NSTemporaryDirectory()`; the Dart side owns
/// deletion after the upload (temp-dir auto-purge is the safety net).
@available(iOS 14.0, *)
final class ICloudMediaChannel: NSObject {
  private static let methodChannelName = "chattr/ios_media"
  private static let progressChannelName = "chattr/ios_media/progress"

  /// Held for the app lifetime; the channel handlers reference us weakly.
  private static var retained: ICloudMediaChannel?

  private weak var presenter: UIViewController?
  private var progressSink: FlutterEventSink?

  // Single in-flight pick.
  private var pendingResult: FlutterResult?
  private var maxBytes: Int64?
  private var didComplete = false

  static func register(with messenger: FlutterBinaryMessenger, presenter: UIViewController) {
    let instance = ICloudMediaChannel()
    instance.presenter = presenter
    let method = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    method.setMethodCallHandler { [weak instance] call, result in
      instance?.handle(call, result: result)
    }
    FlutterEventChannel(name: progressChannelName, binaryMessenger: messenger)
      .setStreamHandler(instance)
    retained = instance
  }

  // MARK: - Method dispatch

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickGalleryVideo":
      guard pendingResult == nil else {
        result(FlutterError(code: "busy",
                            message: "A video pick is already in progress.", details: nil))
        return
      }
      let args = call.arguments as? [String: Any]
      maxBytes = (args?["maxBytes"] as? NSNumber)?.int64Value
      pendingResult = result
      didComplete = false
      ensureAuthorizationThenPick()
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Completion helpers (always deliver on the main thread, exactly once)

  private func finish(map: [String: Any]?) {
    guard !didComplete, let result = pendingResult else { return }
    didComplete = true
    pendingResult = nil
    DispatchQueue.main.async { result(map) }
  }

  private func fail(_ code: String, _ message: String) {
    guard !didComplete, let result = pendingResult else { return }
    didComplete = true
    pendingResult = nil
    DispatchQueue.main.async { result(FlutterError(code: code, message: message, details: nil)) }
  }

  private func emitProgress(_ value: Double) {
    guard let sink = progressSink else { return }
    DispatchQueue.main.async { sink(value) }
  }

  // MARK: - Authorization + picker

  private func ensureAuthorizationThenPick() {
    switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
    case .authorized, .limited:
      presentPicker()
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
        guard let self = self else { return }
        if status == .authorized || status == .limited {
          self.presentPicker()
        } else {
          self.fail("no_permission", "Photo library access is required to send videos.")
        }
      }
    default:
      fail("no_permission", "Photo library access is denied. Enable it in Settings.")
    }
  }

  private func presentPicker() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard let presenter = self.presenter else {
        self.fail("icloud_failed", "No view controller available to present the picker.")
        return
      }
      var config = PHPickerConfiguration(photoLibrary: .shared())
      config.filter = .videos
      config.selectionLimit = 1
      config.preferredAssetRepresentationMode = .current
      let picker = PHPickerViewController(configuration: config)
      picker.delegate = self
      presenter.present(picker, animated: true)
    }
  }

  // MARK: - Materialization (stream the original resource, force iCloud download)

  private func materialize(assetId: String) {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject
    else {
      // Most common under `.limited` access, where a PHPicker pick isn't in the
      // app's limited selection. Full access resolves it.
      fail("icloud_failed", "Picked video could not be resolved (try allowing full photo access).")
      return
    }

    let resources = PHAssetResource.assetResources(for: asset)
    guard let resource = resources.first(where: { $0.type == .fullSizeVideo })
            ?? resources.first(where: { $0.type == .video })
            ?? resources.first(where: { $0.type == .pairedVideo }) else {
      fail("icloud_failed", "No video resource found for the picked asset.")
      return
    }

    let mime = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "video/mp4"
    let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension
      ?? { let e = (resource.originalFilename as NSString).pathExtension; return e.isEmpty ? "mov" : e }()
    let name = resource.originalFilename
    let durationMs = Int((asset.duration * 1000).rounded())

    let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("chattr_vid_\(UUID().uuidString).\(ext)")

    guard FileManager.default.createFile(atPath: tmpURL.path, contents: nil),
          let handle = try? FileHandle(forWritingTo: tmpURL) else {
      fail("icloud_failed", "Could not create the temp file.")
      return
    }

    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    options.progressHandler = { [weak self] progress in
      self?.emitProgress(progress)
    }

    let limit = maxBytes
    var written: Int64 = 0
    var aborted = false
    var requestID: PHAssetResourceDataRequestID = 0

    requestID = PHAssetResourceManager.default().requestData(
      for: resource,
      options: options,
      dataReceivedHandler: { [weak self] data in
        if aborted { return }
        // Early-abort before we ever spill a multi-GB clip to disk.
        if let limit = limit, written + Int64(data.count) > limit {
          aborted = true
          PHAssetResourceManager.default().cancelDataRequest(requestID)
          try? handle.close()
          try? FileManager.default.removeItem(at: tmpURL)
          self?.fail("too_large", "Video exceeds the maximum size.")
          return
        }
        written += Int64(data.count)
        try? handle.write(contentsOf: data)
      },
      completionHandler: { [weak self] error in
        guard let self = self else { return }
        if aborted { return } // `too_large` already delivered
        try? handle.close()
        if let error = error {
          try? FileManager.default.removeItem(at: tmpURL)
          self.fail("icloud_failed", "iCloud download failed: \(error.localizedDescription)")
          return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: tmpURL.path)
        let finalSize = (attrs?[.size] as? NSNumber)?.int64Value ?? written
        if let limit = self.maxBytes, finalSize > limit {
          try? FileManager.default.removeItem(at: tmpURL)
          self.fail("too_large", "Video exceeds the maximum size.")
          return
        }
        self.emitProgress(1.0)
        self.finish(map: [
          "path": tmpURL.path,
          "name": name,
          // Both keys on purpose: the Dart bridge has referred to the size field
          // as `size` and `sizeBytes` in different messages; sending both removes
          // any chance of a silent null-size mismatch.
          "size": finalSize,
          "sizeBytes": finalSize,
          "mime": mime,
          "durationMs": durationMs,
        ])
      }
    )
  }
}

// MARK: - PHPickerViewControllerDelegate

@available(iOS 14.0, *)
extension ICloudMediaChannel: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let assetId = results.first?.assetIdentifier else {
      if results.isEmpty {
        finish(map: nil) // user cancelled
      } else {
        fail("no_permission", "Could not resolve the picked video (no library access).")
      }
      return
    }
    materialize(assetId: assetId)
  }
}

// MARK: - FlutterStreamHandler (progress)

@available(iOS 14.0, *)
extension ICloudMediaChannel: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    progressSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    progressSink = nil
    return nil
  }
}
