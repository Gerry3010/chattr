# Links the prebuilt native hybrid-KEM crypto (X25519 + ML-KEM-768) into the
# macOS Runner target. Build it first with `./native/build.sh apple`.
#
# The Go-exported C symbols (pb_*) are resolved at runtime by the Dart side via
# DynamicLibrary.process() (see lib/core/crypto/ml_kem_ffi.dart). Nothing in
# Swift/ObjC references them, so we -force_load the static archive directly onto
# the Runner link line — this both links the objects and keeps the exported
# symbols in the binary (CocoaPods does not link static-lib xcframeworks on its
# own under use_frameworks!).
Pod::Spec.new do |s|
  s.name             = 'chattr_crypto'
  s.version          = '1.0.0'
  s.summary          = 'Native hybrid X25519 + ML-KEM-768 KEM for Chattr (dart:ffi).'
  s.description      = 'Prebuilt Go c-archive bundled as an xcframework, linked statically into the app and called via dart:ffi.'
  s.homepage         = 'https://geraldhofbauer.net'
  s.license          = { :type => 'AGPL-3.0' }
  s.author           = { 'Gerald Hofbauer' => 'info@geraldhofbauer.net' }
  s.source           = { :path => '.' }
  s.platform         = :osx, '10.15'

  # Keeps the pod non-empty (headers/module) so CocoaPods applies the xcconfig below.
  s.vendored_frameworks = '../native/build/apple/chattr_crypto.xcframework'

  # -force_load links the static archive; -export_dynamic keeps the pb_* symbols
  # in the executable's dynamic symbol table so DynamicLibrary.process() (dlsym)
  # can resolve them in RELEASE too (a release executable exports nothing by default).
  s.user_target_xcconfig = {
    'CHATTR_CRYPTO_LIB' => '$(SRCROOT)/../native/build/apple/chattr_crypto.xcframework/macos-arm64_x86_64/libchattr_crypto.a',
    'OTHER_LDFLAGS'     => '$(inherited) -force_load $(CHATTR_CRYPTO_LIB) -Wl,-export_dynamic'
  }
end
