# Links the prebuilt native hybrid-KEM crypto (X25519 + ML-KEM-768) into the
# iOS Runner target. Build it first with `./native/build.sh apple`.
#
# The Go-exported C symbols (pb_*) are resolved at runtime by the Dart side via
# DynamicLibrary.process() (see lib/core/crypto/ml_kem_ffi.dart). Nothing in
# Swift/ObjC references them, so we -force_load the static archive directly onto
# the Runner link line — this both links the objects and keeps the exported
# symbols in the binary (CocoaPods does not link static-lib xcframeworks on its
# own under use_frameworks!). The slice differs for device vs simulator.
Pod::Spec.new do |s|
  s.name             = 'chattr_crypto'
  s.version          = '1.0.0'
  s.summary          = 'Native hybrid X25519 + ML-KEM-768 KEM for Chattr (dart:ffi).'
  s.description      = 'Prebuilt Go c-archive bundled as an xcframework, linked statically into the app and called via dart:ffi.'
  s.homepage         = 'https://geraldhofbauer.net'
  s.license          = { :type => 'AGPL-3.0' }
  s.author           = { 'Gerald Hofbauer' => 'info@geraldhofbauer.net' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '13.0'

  # Keeps the pod non-empty (headers/module) so CocoaPods applies the xcconfig below.
  s.vendored_frameworks = '../native/build/apple/chattr_crypto.xcframework'

  # -force_load links the static archive; -export_dynamic keeps the pb_* symbols
  # in the executable's dynamic symbol table so DynamicLibrary.process() (dlsym)
  # can resolve them in RELEASE too. (In Debug the code lives in a .dylib that
  # exports them anyway; a release executable exports nothing by default.)
  #
  # STRIP_STYLE = non-global is REQUIRED for archive / App Store (TestFlight)
  # builds: those set DEPLOYMENT_POSTPROCESSING=YES, which runs `strip` on the
  # final executable. The default (STRIP_STYLE=all) removes the pb_* symbols
  # even though -export_dynamic put them in the dynamic table, so dlsym fails at
  # runtime with "symbol not found" (only surfaces on the first non-referenced
  # call — e.g. ML-KEM data-key generation when sending a file; cached chat keys
  # still work). `non-global` strips only local symbols and keeps the global
  # exported pb_* symbols. A plain `flutter build ios --release` does not strip
  # (no DEPLOYMENT_POSTPROCESSING), which is why the dev build worked.
  s.user_target_xcconfig = {
    'CHATTR_CRYPTO_LIB[sdk=iphoneos*]'        => '$(SRCROOT)/../native/build/apple/chattr_crypto.xcframework/ios-arm64/libchattr_crypto.a',
    'CHATTR_CRYPTO_LIB[sdk=iphonesimulator*]' => '$(SRCROOT)/../native/build/apple/chattr_crypto.xcframework/ios-arm64_x86_64-simulator/libchattr_crypto.a',
    'OTHER_LDFLAGS'                           => '$(inherited) -force_load $(CHATTR_CRYPTO_LIB) -Wl,-export_dynamic',
    'STRIP_STYLE'                             => 'non-global'
  }
end
