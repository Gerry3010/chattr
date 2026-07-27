# Mac-Claude: iOS Push-Entitlement + TestFlight (Arbeitspaket)

_Stand 2026-07-06, erstellt von Linux-Claude (Lead). Branch-Regel: Feature-Branch
(`fix/…` oder `feat/…`) + PR gegen **main**. CI-Dateien (`codemagic.yaml`,
`bitbucket-pipelines.yml`) NUR nach expliziter Gerry-Freigabe anfassen._

---

## 📨 UPDATE 2026-07-07 — Linux-Claude → Mac-Claude (bitte zuerst lesen)

Danke für den Handoff in `docs/PUSH_DELIVERY_DEBUG.md` (PR #11, gemergt). Ich hab
die **Server-Kette gegen Live-Prod-Logs verifiziert — sie ist 100% korrekt**:
`FCM_SERVICE_ACCOUNT` present, OAuth-Token wird gemintet, Edge-Function getriggert,
Device-Token gefunden, FCM→APNs geforwardet. Deine gerankten Verdächtigen
(FCM-Secret, `edge_function_url`, `device_tokens`) sind **alle fein** — nicht
weiter untersuchen.

**Der echte Fehler ist Apple-seitig (dein Scope):**

```json
"ApnsError": { "statusCode": 403, "reason": "BadEnvironmentKeyInToken" }
```

= **APNs Sandbox/Production-Mismatch.** Gerrys iPhone läuft mit einem
**Debug/Profile-Build** → `Runner.entitlements` → `aps-environment: development`
→ **Sandbox**-Token. FCM stellt an **Production**-APNs zu → 403. Der `.p8`-Key ist
gültig, das Entitlement ist gesetzt — nur die Umgebung passt nicht.

**→ Deine konkrete nächste Aufgabe:**

1. **Push aus einem TestFlight-(Release-)Build testen, NICHT aus dem Xcode-Debug-
   Build.** Release signt mit `RunnerRelease.entitlements` (`aps-environment:
   production`) → Prod-APNs-Token → matcht FCM. Ein Debug/Profile-Build auf dem
   Gerät wird Push **immer** mit `BadEnvironmentKeyInToken` failen. (Das ist der
   reale Weg — TestFlight ist eh Task 6 unten.)
2. **Optional, falls du auch Dev-Builds pushbar willst:** unter `#if DEBUG` den
   APNs-Token als **Sandbox** an Firebase forwarden —
   `Messaging.messaging().setAPNSToken(deviceToken, type: .sandbox)` (bzw.
   `.unknown` zum Auto-Detect) in `didRegisterForRemoteNotificationsWithDeviceToken`.
   Nötig, weil `FirebaseAppDelegateProxyEnabled=false` (kein Swizzling).

**Status Tasks 1–3 unten:** Entitlements existieren bereits
(`Runner.entitlements` = development / `RunnerRelease.entitlements` = production),
`aps-environment` gesetzt, `.p8` laut deinem Handoff in Firebase hinterlegt →
erledigt. Fokus jetzt auf **Task 6 (TestFlight)** + Push-Verifikation dort.
Backend braucht **keine** Änderung.

---

## Kontext

Der komplette Push-Stack (Client-Token-Registrierung, DB-Trigger, Edge Function
mit FCM-v1-Service-Account-Auth) ist gemergt und auf Web verifiziert. iOS ist
fast build-ready: `Info.plist` hat alle Usage-Strings + `UIBackgroundModes`
(remote-notification), `GoogleService-Info.plist` (Projekt `your-firebase-project`) liegt
in `ios/Runner/`, der AppDelegate ruft `FirebaseApp.configure()` +
`registerForRemoteNotifications()`, Signing-Team `ND9MT2PP6B`, Bundle-ID
`net.geraldhofbauer.chattr`. **Das App-Icon (Icon-Composer-Format) ist bereits
auf Gerrys iPhone verifiziert — nicht anfassen.**

**Der eine Blocker: es gibt KEIN Push-Entitlement.** Keine `.entitlements`-Datei,
kein `CODE_SIGN_ENTITLEMENTS` im pbxproj, kein `aps-environment` → `getToken()`
liefert auf echten Geräten null.

## Aufgaben (in Reihenfolge)

1. **Push-Capability:** In Xcode dem Runner-Target „Push Notifications"
   hinzufügen → erzeugt `ios/Runner/Runner.entitlements` mit `aps-environment`
   und setzt `CODE_SIGN_ENTITLEMENTS`. Committen.
2. **APNs-Key:** APNs Auth Key (.p8) im Apple Developer Portal erzeugen und in
   der Firebase Console (Projekt `your-firebase-project` → Cloud Messaging) hinterlegen.
3. **Token-Forwarding verifizieren:** `Info.plist` setzt
   `FirebaseAppDelegateProxyEnabled=false` (kein Swizzling!). Prüfen, ob der
   APNs-Token FCM erreicht — falls `getToken()` null bleibt, in
   `AppDelegate.swift` manuell `didRegisterForRemoteNotificationsWithDeviceToken`
   implementieren und `Messaging.messaging().apnsToken` setzen.
4. **Nativer Crypto-Pod:** `./native/build.sh apple` ausführen, dann
   `pod install` — der lokale Pod `chattr_crypto` (X25519 + ML-KEM-768) muss
   für Device-arm64 bauen.
5. **Erster Gerätetest:** Debug-Build auf Gerrys iPhone; Push end-to-end
   (Nachricht von zweitem Account → Banner). Testhelfer:
   `~/Sync-Projekte/Chattr2/send-test-push.sh` (bei Gerry am Linux-Rechner).
6. **TestFlight:** App-Store-Connect-Record anlegen, Distribution-Signing,
   Archive + Upload.
7. **(Nur nach Gerry-Freigabe)** iOS-Lane in `codemagic.yaml` — die bestehende
   `android-internal`-Lane ist das Template (Crypto-Build, Secrets, Publish).
8. **(Später, low-prio) macOS-Push:** `GoogleService-Info.plist` für macOS,
   `FirebaseApp.configure()` im macOS-AppDelegate, `aps-environment` in beide
   macOS-Entitlements.

## Frisch relevant (Dep-Upgrade 2026-07, bereits auf main)

Flutter-SDK ≥ 3.44 / Dart ≥ 3.12 nötig (pubspec `sdk: >=3.12.0`). Major-Bumps
mit nativer iOS-Seite, die beim Gerätetest mit-verifiziert werden sollen:
`firebase_messaging` 16.4, `flutter_local_notifications` 22, `local_auth` 3
(FaceID), `file_picker` 11, `share_plus` 12, `record` 7, `media_kit_video` 2,
`mobile_scanner` 7. Nach dem Checkout einmal `pod install --repo-update`.
Codegen-Hinweis: `dart run build_runner build --delete-conflicting-outputs
--force-jit` (AOT-Build-Script kollidiert mit Native-Asset-Hooks).
