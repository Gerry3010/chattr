# Mac-Claude: Notifications verschwinden nie + permanenter 1-Badge (Arbeitspaket)

_Stand 2026-07-11, erstellt von Linux-Claude (Lead) auf Gerrys Anweisung („gibt das
Mac Claude einfach"). Branch-Regel: Feature-Branch (`fix/…`) + PR gegen **main**.
Gerry hat für dieses Paket explizit freigegeben, dass du die nötigen **Shared-Dart-
Dateien** (fcm_service, push_notifications_provider, pubspec) anfasst — bleib
trotzdem minimal-invasiv. Edge-Function-DEPLOY macht weiterhin Linux-Claude (Gate);
den TS-Code darfst du ändern._

## Symptome (von Gerry, iOS-TestFlight-Build)

1. Zugestellte Push-Notifications **verschwinden nie** aus dem Notification
   Center — sie akkumulieren, auch nachdem die Nachrichten längst in der App
   gelesen wurden. (Android unklar, vermutlich gleich.)
2. Das App-Icon zeigt **permanent einen 1-Badge**, selbst wenn alle
   Notifications manuell gelöscht wurden.

## Root-Cause-Analyse (schon erledigt, nicht neu untersuchen)

- **Badge:** `supabase/functions/send-push-notification/index.ts:199` hardcodet
  `apns.payload.aps = { sound: "default", badge: 1 }` — jeder Push setzt den
  Badge auf literal `1`, und **nichts setzt ihn je zurück**. Daher „permanent 1".
- **Akkumulieren:** Es gibt keinerlei Cleanup-Aufruf. Nirgends im Client wird
  `removeAllDeliveredNotifications` (iOS) / `notificationManager.cancelAll()`
  (Android) aufgerufen — weder beim App-Resume noch beim Chat-Öffnen.
- Relevante bestehende Bausteine:
  - `lib/core/lifecycle/app_lifecycle_service.dart` — broadcastet ein
    `onResume`-Signal (gefeuert von `AppLockGate`). **Der richtige Hook.**
  - `lib/features/push_notifications/fcm_service.dart` — hält die
    `FlutterLocalNotificationsPlugin`-Instanz (`_localNotifications`).
    `cancelAll()` mappt auf iOS auf `removeAllPendingNotificationRequests` +
    `removeAllDeliveredNotifications` und räumt dort auch die vom System
    dargestellten **FCM-Remote-Notifications** der App weg; auf Android räumt
    `notificationManager.cancelAll()` ebenfalls die FCM-Tray-Einträge.
  - `lib/features/push_notifications/push_notifications_provider.dart` →
    `PushNotificationsManager._wireSession()` — läuft genau 1× pro Session,
    guter Ort fürs Verdrahten des Resume-Listeners (braucht dann einen
    `Ref`/Provider-Zugriff auf `appLifecycleServiceProvider` — Provider wird
    aktuell mit `ref.read(...)`-Konstruktorargumenten gebaut, einfach den
    Service mitreichen).

## Aufgaben

1. **Cleanup beim Resume (+ einmalig beim Start):** Beim `onResume`-Signal (und
   einmal nach Init) `FCMService.clearDeliveredNotifications()` aufrufen — neue
   Methode, die `_localNotifications.cancelAll()` ausführt (try/catch,
   best-effort, nur mobile). Damit verschwinden alle zugestellten Banner,
   sobald der User die App öffnet. Kein per-Chat-Feingranular nötig (v1).
2. **Badge zurücksetzen:** iOS-Badge beim selben Cleanup auf 0. Empfohlen:
   Dependency `app_badge_plus` (klein, maintained) → `AppBadgePlus.updateBadge(0)`
   in `clearDeliveredNotifications()` (iOS/Android guard, try/catch). Wenn du
   eine schlankere native Lösung bevorzugst (z. B. `UNUserNotificationCenter
   setBadgeCount:` via MethodChannel im Runner), auch ok — dein Call als
   Apple-Dev.
3. **Edge Function:** In `send-push-notification/index.ts` das hartkodierte
   `badge: 1` **entfernen** (kein Badge-Feld senden — der Server kennt den
   Unread-Count nicht, ein falscher statischer Wert ist schlechter als keiner).
   Den geänderten TS-Code in den PR packen; **Deploy übernehme ich** (Gate).
4. **iOS-Verifikation (TestFlight):** Push empfangen → App öffnen → Banner im
   Notification Center weg + Badge weg; mehrere Pushes → alle weg nach Resume.
   Bitte im PR-Body dokumentieren.

## Kontext: was sich hier gerade parallel ändert (nicht wundern / kein Konflikt)

Auf `main` laufen gerade meine Commits der Bugfix-Runde (Foreground-Banner
abgeschaltet via `setForegroundNotificationPresentationOptions(alert:false,
sound:false)` + `_handleForegroundMessage` zeigt keine lokale Notification mehr;
`activeChatProvider` unterdrückt In-App-Banner für den offenen Chat). Dein
Cleanup ergänzt das für den **Background-Fall** — bitte auf aktuellem `main`
aufsetzen.

— Linux-Claude
