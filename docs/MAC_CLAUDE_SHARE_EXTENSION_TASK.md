# Mac-Claude: iOS Share Extension für share_handler (Arbeitspaket)

_Stand 2026-07-11, erstellt von Linux-Claude (Lead). Branch-Regel: Feature-Branch
(`feat/…`) + PR gegen **main**._

## Kontext

Chattr ist jetzt Android-seitig ein **Share-Target**: Text/Bilder/Videos/Audio/
Dateien aus fremden Apps landen über `share_handler` (pub.dev) in einem
Chat-Picker und werden über die normale Encrypt-Pipeline verschickt. Die
Dart-Seite ist komplett fertig und cross-platform:

- `lib/features/share_target/share_target_listener.dart` — lauscht auf
  `ShareHandlerPlatform.instance.getInitialSharedMedia()` (Cold Start) +
  `sharedMediaStream` (warm), puffert bis Auth ready + App-Lock offen, öffnet
  den Chat-Picker, schickt via `sendMessage`/`sendMediaMessage`.
- `android/app/src/main/AndroidManifest.xml` — `ACTION_SEND` +
  `ACTION_SEND_MULTIPLE` Intent-Filter als Vorlage.
- Dependency: `share_handler: ^0.0.25` (bereits in pubspec.yaml).

**Was fehlt (dein Scope): das iOS-Share-Extension-Target.** Ohne Extension
taucht Chattr auf iOS nicht im Share-Sheet auf; die Dart-Seite braucht dafür
KEINE Änderung.

## Aufgaben (Doku: share_handler README, Abschnitt iOS)

1. **App Group** anlegen/aktivieren: z. B. `group.com.<bundle>.chattr` —
   in BEIDEN Targets (Runner + Extension) unter Signing & Capabilities.
2. **Share Extension Target** in Xcode anlegen (Template „Share Extension"),
   Bundle-Id `<runner-bundle-id>.ShareExtension`.
3. Extension auf `share_handler_ios`'s `ShareViewController` umstellen
   (Subclass; das Plugin liefert die Basisklasse — siehe README: Podfile-Target
   für die Extension mit `share_handler_ios_models` bzw. den dokumentierten
   Imports).
4. **Info.plist der Extension**: `NSExtensionActivationRule` für Text, URLs,
   Bilder, Videos und generische Dateien (alle Typen erlaubt, Chattr nimmt
   `*/*`). Beispiel-Keys: `NSExtensionActivationSupportsText`,
   `...WebURLWithMaxCount`, `...ImageWithMaxCount`, `...MovieWithMaxCount`,
   `...FileWithMaxCount` (z. B. je 10).
5. **Runner-Seite**: App-Group-Id auch dort setzen; share_handler nutzt sie für
   die Übergabe (UserDefaults/Container).
6. **TestFlight-Build + Gerätetest**: Foto aus der Fotos-App an Chattr teilen →
   Picker erscheint (nach FaceID-Unlock, falls App-Lock an) → im Zielchat
   verschlüsselt ankommen (zweites Gerät gegenprüfen). Cold Start (App gekillt)
   UND warm testen. Ergebnis in den PR-Body.

## Achtung

- pubspec/Dart NICHT anfassen — alles Nötige ist auf main.
- Der TestFlight-Build enthält auch weitere native Änderungen dieser Runde
  (image_picker für den Kamera-Button) — ein Build deckt beides ab.
- Gerätechecks, die in diesem Build gleich mitgetestet werden können:
  Stummschalter respektiert den Notification-Chime (neu), keine
  Foreground-Banner mehr, Push-Tap öffnet den Chat (nach Prod-Migration 00029),
  Kamera-Kachel im Büroklammer-Menü.

— Linux-Claude
