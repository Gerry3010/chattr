# Desktop E2E Testing — Driving the App from an Agent

How a Claude Code agent can **run, screenshot, and click through** the Chattr
Flutter app on this Linux desktop. Written after a live walk-through (login →
create group → open chat). The hard part on this machine is **taking
screenshots under Wayland**; the recipe below is the path that works.

> For deterministic, headless verification prefer the existing tests in `test/`
> (`flutter test`). Use this manual recipe only when you need to *see* real UI /
> click real flows. The two-user message flow is already covered headlessly by
> `test/e2e_two_users_test.dart`.

## Environment (this machine)

- **GNOME on Wayland** (`XDG_SESSION_TYPE=wayland`, compositor = Mutter).
- Screen geometry: **3440 × 1440**.
- Flutter **3.38.5** stable at `/home/gerry/flutter/bin`.
- Local Supabase stack is running (`supabase status`); `.env` points at
  `http://127.0.0.1:54321`.
- Linux desktop target is enabled; `linux/` exists.
- Installed capture/input tooling: **`import`** (ImageMagick), **`xprop`**,
  **`xrandr`**, **`xdotool`** (installed during the session). No `grim`,
  `gnome-screenshot`, `spectacle`, `xwininfo`, or `wmctrl`.

## Why screenshots are tricky here

- A normal `flutter run -d linux` launches the app as a **native Wayland
  client** → X11 tools (`import`) cannot see its window.
- The **GNOME Shell D-Bus screenshot is blocked** headlessly
  (`org.gnome.Shell.Screenshot` → `AccessDenied: Screenshot is not allowed`).
- `grim` only works on wlroots compositors, **not** GNOME/Mutter.
- `flutter run` does **not** propagate `GDK_BACKEND` to the launched binary, so
  setting it on the `flutter run` command has no effect.

**Solution:** launch the already-built **bundle binary directly** with
`GDK_BACKEND=x11`. It then runs as an **XWayland** client, gets a real X11
window, and `import -window <id>` can grab it pixel-perfect. `xdotool` drives
synthetic input into that same X11 window.

## Wenn die Eingabe nicht ankommt: den Bildschirm rendern statt klicken

Am 2026-08-21 liess sich die App zwar starten und fotografieren, aber **kein
synthetischer Klick und kein `xdotool type` erreichten sie** — `xdotool
getactivewindow` meldete durchgaengig ein fremdes Fenster, auch nach
`windowactivate --sync`, `windowraise`, `windowfocus` und `type --window`. Wer
danach weiter am Fokus schraubt, verbrennt Zeit an der Messvorrichtung statt an
der Sache.

Fuer **Layout-Fragen** (Reihenfolge, Abstaende, Zustandstexte, Symbole) gibt es
einen Weg ohne Fenster: den Bildschirm im Test-Renderer zeichnen und als PNG
ablegen. Vorlage: `test/render_chat_info.dart` — heisst absichtlich **nicht**
`*_test.dart`, laeuft also nicht in der Suite mit.

```bash
flutter test --update-goldens test/render_chat_info.dart --plain-name 'Chat-Info als Admin'
# → test/goldens/chat_info_admin.png   (gitignored)
```

Drei Dinge, ohne die das Bild nichts taugt:

1. **Echte Schrift laden**, sonst zeichnet der Test-Renderer nur Kaesten —
   `FontLoader('Roboto')` mit einer System-TTF **und** `FontLoader('MaterialIcons')`
   mit `~/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf`.
   Ohne die zweite fehlt genau das, wofuer man sich das Bild ansieht.
2. **EasyLocalization wirklich initialisieren** (`SharedPreferences.setMockInitialValues({})`
   davor, sonst `MissingPluginException`) — sonst stehen ueberall die
   Schluessel statt der deutschen Texte.
3. **Als Anker `find.byType(Scaffold)` nehmen, nicht `MaterialApp`**, und die
   Faelle **einzeln** laufen lassen. Beides hat hier je einmal ein *leeres*
   Bild erzeugt, das wie ein kaputter Bildschirm aussah und keiner war.

Was der Weg **nicht** ersetzt: echte Daten, Realtime, Uploads, Plattform-Kanaele.
Dafuer bleibt es beim Recipe unten bzw. bei `test/e2e_two_users_test.dart`.

## Recipe

### 1. Build once (slow first time — CMake/Ninja)

```bash
flutter pub get
flutter build linux --debug      # or: flutter run -d linux once, then kill it
# binary: build/linux/x64/debug/bundle/chattr
```

### 2. Launch under XWayland (run in background, persistent)

The Mutter XWayland auth file is needed for X11 tools to connect.

```bash
export DISPLAY=:0
export XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.*   # glob; resolve to the real file
cd build/linux/x64/debug/bundle
GDK_BACKEND=x11 ./chattr > /tmp/chattr_x11.log 2>&1 &
```

> Start this with the agent's **background** Bash mode (`run_in_background`), not
> a foreground `&` — a foreground `&` job is killed when the Bash call returns.

### 3. Find the window id (no xwininfo needed)

```bash
xdotool search --name '^chattr$'           # numeric id
# or enumerate all X11 windows:
xprop -root _NET_CLIENT_LIST                # then xprop -id <id> WM_NAME
```

### 4. Move the window fully on-screen, then click via ABSOLUTE coords

The window can spawn partially off-screen; off-screen pixels aren't clickable
even though `import` still captures the full window pixmap. Move it to a known
origin first and compute absolute screen coords yourself.

```bash
WID=$(xdotool search --name '^chattr$' | head -1)
xdotool windowmove "$WID" 40 40            # origin now (40,40)
xdotool windowactivate --sync "$WID"
# click a control at window-relative (rx,ry):
xdotool mousemove $((40+rx)) $((40+ry)) click 1
```

`xdotool mousemove --window <id> rx ry` did **not** map cleanly here — use
absolute coords (`window_origin + relative`) instead.

### 5. Screenshot the window

```bash
import -window "$WID" /tmp/shot.png        # captures the full frame incl. titlebar
```

Then `Read` the PNG to actually see it.

> **Agent: delete each screenshot immediately after you've read/transcribed it,
> and don't keep it in mind.** Screenshots are large and stay in the context
> window, burning tokens for the rest of the session. Capture → `Read` →
> describe what matters in one line → `rm /tmp/shot.png`. Reuse a single
> filename (e.g. always `/tmp/shot.png`) and overwrite it; never accumulate
> `shot1.png`, `shot2.png`, …

### Reusable helpers

```bash
export DISPLAY=:0 XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.<resolve>
WID=$(xdotool search --name '^chattr$' | head -1)
shot()   { import -window "$WID" "/tmp/$1.png"; }
aclick() { xdotool windowactivate --sync "$WID"; \
           xdotool mousemove $((40+$1)) $((40+$2)) click 1; }   # window at origin 40,40
```

### Typing quirks

- Use plain `xdotool type --delay 60 "text"`. After clicking a field, type goes
  to the X11-focused window — no `--window` needed (Flutter ignores synthetic
  `XSendEvent`).
- **`_` (underscore) is mis-typed as `?`** with this keymap. Avoid underscores
  (and likely other shifted symbols) in typed test data, or send the keysym
  explicitly: `xdotool key underscore`.
- `Return` submits text fields / sends messages.

## Reference coordinates (window at origin 40,40, size 1328×815)

Window-relative pixel positions observed in the default window size:

| Screen | Control | rel (x, y) |
|---|---|---|
| Login | Username field | 664, 480 |
| Login | "Anonym anmelden" button | 664, 554 |
| Home | "Neuer Chat" FAB | 1217, 744 |
| Neuer-Chat dialog | "Gruppenchat erstellen" | 655, 464 |
| Group form | "Gruppenname" field | 664, 208 |
| Group form | "Gruppe erstellen" | 664, 294 |
| Chat list | first chat row | 664, 155 |
| Chat view | message input | ~200, 751 |

Re-verify with a screenshot after each click; coordinates shift if the window
is resized.

## Behavioural findings from the live run

- **Anonymous login works.** Typing a username + "Anonym anmelden" creates a
  user and lands on the chat list. Logs: `GlobalMessageHandler initialized for
  user <uuid>`.
- **`Failed to register FCM token / FCM token is null` is EXPECTED on desktop**
  — there is no Firebase Messaging on Linux. Not a bug; ignore it.
- **Group chat creation works end-to-end** (`ChatsLocalRepository.saveChat`
  + remote insert, green "Gruppenchat erstellt" snackbar, row appears).
- **The message input is DISABLED when a group has only 1 member** — you can't
  message yourself. To exercise the send/encrypt/realtime path you need a second
  participant (the headless `test/e2e_two_users_test.dart` does this).
- **1:1 chats are created by scanning another user's QR code** ("Neuer Chat →
  QR-Code scannen"), which needs a second device + camera — **not solo-drivable**
  on desktop. The home app-bar also has a "show my QR" action.
- **i18n gap:** the empty-chat state shows **"No message"** and **"Reload"** in
  English while the rest of the UI is German. Worth fixing in translations.

## Cleanup

```bash
pkill -f 'build/linux/x64/debug/bundle/chattr'
```
