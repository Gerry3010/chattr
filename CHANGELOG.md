# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.0.0/),
und dieses Projekt folgt [Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

### Fixed
- 🗑️ **Bearbeitete Nachrichten bleiben nicht mehr auf dem Server liegen** (Backend 1.5.1) — wurde eine Nachricht **nach** der Zustellung bearbeitet, blieb ihr verschlüsselter Text dauerhaft auf dem Server, statt wie versprochen sofort nach dem Abholen gelöscht zu werden. Die App hatte immer korrekt gehandelt und das Löschen angefordert; der Server lehnte es ab, weil er die Nachricht schon als zugestellt kannte. Betroffene Altbestände wurden mitgelöscht

## [1.14.0] - 2026-08-06

### Added
- 🔑 **Identitätsschlüssel neu erstellen** — verliert ein Gerät seinen Identitätsschlüssel (etwa weil der Android-Schlüsselspeicher ihn verworfen hat), konnte man bisher nichts tun: Die App erzeugt bewusst **keinen** stillen Ersatz, weil das bei allen Kontakten unerklärt die Sicherheitsnummer umdrehen würde. Genau deshalb gibt es jetzt im Verifizierungs-Fenster einen ausdrücklichen Knopf dafür — mit einer Nachfrage, die vorher sagt, was passiert: Alle Kontakte müssen dich danach neu verifizieren. Der bisherige Knopf „Jetzt veröffentlichen" führte in diesem Fall in eine Sackgasse, die wie Abhilfe aussah

### Fixed
- ✍️ **Unsignierte Nachrichten sind jetzt erkennbar.** Kann ein Absender-Gerät nicht signieren, verschickt es trotzdem — die Nachricht ist weiterhin Ende-zu-Ende verschlüsselt, aber **niemand kann nachweisen, dass sie wirklich von ihm stammt**. Bisher rutschte das lautlos durch, weil es genauso behandelt wurde wie eine alte Nachricht aus der Zeit vor den Signaturen. Jetzt sagt die Blase es. Bewusst mit einem **eigenen** Zeichen: „Signatur ungültig" (Fälschungsverdacht) und „nicht signiert" (Gerät kann nicht signieren) sind zwei verschiedene Aussagen, und ein gemeinsames Warnsymbol erzieht nur dazu, beide zu übersehen. Ältere Nachrichten von vor der Signatur-Einführung bleiben unmarkiert

## [1.13.0] - 2026-08-05

### Added
- 🤖 **Chat-Zusammenfassung durch den Agenten** — in MCP-Chats fasst dir der Agent auf Knopfdruck zusammen, was du verpasst hast: ungelesen, alles oder seit einem Datum. Das Ergebnis erscheint nur in einem eigenen Fenster, nie im Verlauf, und löst keine Benachrichtigung aus. Anfrage und Antwort reisen Ende-zu-Ende verschlüsselt — der Server liest nie mit, deshalb gibt es den Knopf auch nur dort, wo ein Agent ohnehin Mitglied ist. Läuft gerade keine Agenten-Sitzung, sagt die App das ehrlich, statt endlos zu laden
- ✉️ **Gruppen-Einladung als Nachricht** — wer eine Gruppe verwaltet, kann sie als Einladungskarte in einen anderen Chat schicken. Ein Tipp auf die Karte tritt sofort bei, ohne dass noch jemand zustimmen muss. Die Einladung gilt **nur in dem Chat, in den sie geschickt wurde** — weitergeleitet ist sie wertlos — und lässt sich jederzeit in der Gruppeninfo zurückziehen. Erstellen und Zurückziehen können nur Verwalter, für die Gruppe Gesperrte bleiben draußen
- 👥 **Agenten-Sektion in der Gruppeninfo** — KI-Agenten und Menschen stehen jetzt getrennt in der Mitgliederliste. Über den Stern wählst du den **Hauptagenten** — genau einen pro Chat; an ihn geht die Zusammenfassung

### Fixed
- 📖 **Ungelesen-Zähler blieb nach dem Verlassen eines Chats manchmal stehen** — jetzt ist beim Rausgehen wirklich alles gelesen
- ⬇️ **Ein Chat öffnet an der ersten ungelesenen Nachricht** statt am Ende — mit dem „Ungelesene Nachrichten"-Trennstrich als Anker

## [1.12.4] - 2026-08-05

### Added
- 🔕 **Benachrichtigungen ohne Klartext (Android)** — der Server schickt an Android-Geräte keine Chat- und Absendernamen mehr an Googles Push-Dienst, sondern nur noch IDs. Die Benachrichtigung sieht aus wie immer, weil dein Gerät sie selbst zusammensetzt. Auf iOS bleibt vorerst alles wie bisher, dort braucht es dafür eine eigene Systemerweiterung
- 📷 **„… hat ein Foto gesendet"** statt „Neue Nachricht", auch bei Video, Audio und Dateien. Dafür erfährt der Push-Dienst die grobe Kategorie — abschaltbar unter Einstellungen → Sicherheit, mit Erklärung, standardmäßig an
- 🎬 **Startbildschirm** statt weißem Aufblitzen beim Öffnen — hell und dunkel passend zum Systemdesign

### Fixed
- 🔔 **Android hatte gar keine Benachrichtigungen mehr** — die Einrichtung scheiterte beim Start an einem Symbol, das es unter dem angegebenen Namen nicht gab. Dazu ein eigenes Benachrichtigungs-Symbol, denn Android zeichnet diese als Silhouette
- 🔗 **Geteilte Links** öffnen mit zwei Leerzeilen darüber und dem Cursor ganz oben, damit man etwas dazuschreiben kann, ohne erst am Link vorbeizumanövrieren

### Changed
- ℹ️ Die Erklärungen der Privatsphäre-Schalter stehen jetzt hinter einem Info-Symbol statt als Kleingedrucktes unter jedem Schalter


## [1.12.3] - 2026-08-04

### Fixed
- 🔔 **Android bekam gar keine Benachrichtigungen mehr** — die Einrichtung scheiterte beim Start an einem Icon, das es unter dem angegebenen Namen nicht gab. Betroffen war alles Lokale, inklusive der Hinweise, die die App selbst anzeigt. Dazu ein eigenes Benachrichtigungs-Symbol: Android zeichnet diese Symbole als Silhouette, das App-Icon wäre ein weißer Fleck geworden
- 📷 **Vorschauen zeigen „Foto" statt des Dateinamens** — in Antwort-Zitaten, Suchtreffern, Favoriten und Hinweisen stand bisher `IMG_20260804.jpg`. Bei mehreren Medien mit Anzahl, ein Bildtext gewinnt immer
- 📡 **„Server nicht erreichbar"** erscheint jetzt sichtbar, wenn die Verbindung zum Server abreißt — mit dem Hinweis, dass die eigenen Nachrichten auf dem Gerät liegen und vollständig da sind. Vorher wurde die App einfach still, was sich anfühlte wie Datenverlust
- 🛡️ Der **Bildschirmschutz** stand in den Einstellungen auf allen Geräten, funktioniert aber nur unter Android. Er erscheint jetzt nur noch dort
- 🐛 Ein Fehler beim schnellen Verlassen eines Chats wurde als „Chat konnte nicht geladen werden" protokolliert, obwohl nur der Bildschirm früher geschlossen wurde als der Abruf fertig war


## [1.12.2] - 2026-08-04

### Fixed
- 💬 **Systemhinweise** („X ist beigetreten", Schlüsselwechsel, Selbstzerstörung) sitzen jetzt wirklich mittig — sie waren um den Platz des Profilbilds nach rechts verschoben, und je nach Position im Verlauf unterschiedlich weit
- ↔️ Ein Systemhinweis ließ sich zum Antworten wischen, abschicken ließ sich die Antwort dann aber nicht. Sie sind jetzt nicht mehr wischbar — passend dazu, dass sie sich auch nie lange drücken ließen
- 🕐 „nach **1 Woche**" statt „nach 1 Wochen" — dasselbe galt für Stunde, Tag, Minute und Sekunde, in der Auswahl wie im Hinweis

## [1.12.1] - 2026-08-03

### Added
- ⬇️ **Neuer Bereich „Über" in den Einstellungen**: manuelle Update-Prüfung (Android und Web), „Was ist neu" und ein Link zur Website. Die Update-Prüfung erscheint nur dort, wo es auch einen Update-Kanal gibt — auf iOS übernimmt das der App Store
- 📄 **Changelog in der App**: alle Versionen zum Aufklappen, die installierte ist markiert. Der Text liegt in der App selbst, wird also nicht nachgeladen und passt immer zur laufenden Version

### Fixed
- 📝 **Der Changelog war unvollständig**: **21 Versionen** fehlten — 16 davon zwischen 1.2.0 und 1.11.0, also ausgerechnet die Zeit mit Alben, Medienbearbeitung, Bild-in-Bild-Video, großen Dateien und der App-Sperre, dazu fünf frühe 1.1.x-Ausgaben. Alle aus dem Verlauf nachgetragen; aufgefallen ist es erst, als der Changelog in der App sichtbar wurde

## [1.12.0] - 2026-08-03

### Added
- ⏳ **Selbstzerstörung wird jetzt angekündigt**: schaltet jemand die selbstzerstörenden Nachrichten ein oder aus, sehen das alle im Chat als Systemnachricht („Gerry hat die Selbstzerstörung nach 5 Minuten aktiviert"). Bisher änderte sich die Regel für alle, ohne dass es außer der Person selbst irgendwer erfahren konnte. Die Dauer wird als reine Zahl übertragen und auf jedem Gerät in dessen eigener Sprache formuliert
- 🎨 **Systemnachrichten haben Zustände**: statt einer einheitlich grauen Zeile jetzt getönt und mit Symbol — beigetreten/zugelassen grün, verlassen/befördert neutral, **entfernt / neue Schlüssel erzeugt / Selbstzerstörung deaktiviert** gelb (also genau die, die man wirklich lesen sollte), nicht entschlüsselbar rot

### Changed
- 👍 **Reaktionen in 1:1-Chats ohne Profilbilder**: bei zwei möglichen Personen sagt der Kreis neben dem Emoji nichts, was das Emoji nicht schon sagt. Stattdessen erscheint eine Zahl — und die auch erst, wenn beide reagiert haben. In Gruppen bleibt alles wie bisher (Fork p22)

### Fixed
- 💬 Eine Systemnachricht, die diese App-Version noch nicht kennt, zeigt nicht mehr ihren technischen Rohtext (`{action: ...}`) im Chat; eine, die sich nicht entschlüsseln ließ, sagt das jetzt, statt leer zu bleiben

## [1.11.3] - 2026-08-03

### Security & Datenschutz
- 🔒 **Echtzeit-Kanäle sind jetzt privat**: der Benachrichtigungskanal eines Nutzers war öffentlich — wer eine Nutzer-ID kannte, konnte dessen Metadaten-Strom live mitlesen (welcher Chat, wer schreibt, wann; Inhalte blieben verschlüsselt). Der Kanal ist jetzt an das eigene Konto gebunden. *Übergangsweise wird noch zusätzlich auf den alten Kanal gesendet, damit ältere App-Versionen weiterlaufen — dieser Rest wird abgeschaltet, sobald alle aktualisiert haben.*
- 📷 **Profil- und Gruppenbilder werden von Metadaten befreit** (EXIF/GPS): Chat-Medien wurden schon bereinigt, Avatare nicht — sie landeten mit Aufnahmeort, Gerätemodell und Aufnahmezeit im öffentlich lesbaren Bildspeicher. Betrifft besonders direkt mit der Kamera aufgenommene Gruppenbilder
- 🗑️ **Nachrichten-Metadaten verschwinden endlich vollständig**: bei abgeschalteten Lesebestätigungen blieb die (inhaltslose) Datenzeile bisher dauerhaft liegen — ausgerechnet die Datenschutz-Einstellung erzeugte also mehr bleibende Spuren. Jetzt werden sie wie gelesene Nachrichten nach 7 Tagen entfernt
- 💬 Zitat-Vorschau und der darin gespeicherte Absendername werden beim Zustellen mitgelöscht (bisher blieb der Name im Klartext stehen)
- 😀 Reaktionen zu gelöschten Nachrichten werden aufgeräumt (sie überlebten bisher die Nachricht, auf die sie sich bezogen)
- 🧾 Server-Protokolle enthalten keine Nutzdaten mehr: Chat-Namen, Absendernamen, Empfängerlisten und Push-Gerätekennungen wurden mitgeschrieben und dauerhaft gespeichert

### Infrastruktur
- Zugriffsprotokoll des API-Gateways abgeschaltet (es enthielt Chat- und Empfänger-IDs in den Anfrage-URLs) und interne Dienste nur noch lokal erreichbar; Härtungs-Skript `scripts/netcup/harden-log-metadata.sh` (Standard: Trockenlauf)

## [1.11.2] - 2026-08-02

### Fixed
- 📋 iOS: Beim Öffnen des Nachrichtenfeld-Menüs erscheint nicht mehr jedes Mal der Einfügen-Hinweis („Chattr möchte aus … einfügen"). Ob etwas Einfügbares in der Zwischenablage liegt, wird jetzt geprüft, **ohne** den Inhalt zu lesen — der Hinweis kommt nur noch, wenn du tatsächlich auf „Einfügen" tippst. Android/Desktop/Web unverändert

## [1.11.1] - 2026-08-02

### Fixed
- 🎨 Avatar-Initialen jetzt wirklich überall gleich: derselbe Nutzer bekommt auf allen Flächen denselben Buchstaben in derselben Farbe und derselben relativen Größe. Die Buchstabenfarbe wird konsistent nach WCAG-Kontrast gewählt (Chat-Liste, Chat-Kopfleiste, Profil-Sheet, Chat-Details, Nachrichtenkreise, Reaktionen) — vorher zeichnete die Chat-Kopfleiste nach einer anderen Regel als der Rest
- 🔠 Initiale skaliert mit dem Avatar (vorher winziger Buchstabe in großen Kreisen, z. B. Profil-Sheet und Chat-Details)
- ♿ Gruppen-Icon und der Platzhalter-Avatar unaufgelöster 1:1-Chats werden ebenfalls kontrastiert gezeichnet (vorher fixes Weiß bzw. Theme-Default — auf hellen Paletten-Farbtönen kaum lesbar)

## [1.11.0] - 2026-08-02

### Added
- 📤 **Multi-Send beim Teilen & Weiterleiten**: mehrere Chats auswählbar (Checkbox-Picker); geteilter Text/Link ist vor dem Senden bearbeitbar, Medien laufen durch das Caption-Sheet
- ↪️ **„Zum Chat"**-Button nach dem Weiterleiten (bei einem Ziel)
- 🖥️ **PiP-Vollbild**: Maximize/Restore-Button am schwebenden Videofenster (media_kit + YouTube)

### Fixed
- 🔒 App-Lock: Entsperr-Screen verrät die Mindestlänge nicht mehr (Hint nur noch im Setup); Mindestlänge zusätzlich im Controller erzwungen
- 🏷️ @-Mentions werden in Nachrichten-Bubbles zuverlässig hervorgehoben (auch zusammen mit Links — Vorschau-Karte bleibt)
- ✍️ Composer: Reply-/Edit-Banner wird nicht mehr von mehrzeiligen Entwürfen überdeckt (Fork p20); Anhang-Button bleibt beim Tippen sichtbar
- 🎨 Avatar-Farben endlich konsistent: EINE identitätsgebundene Farbe pro Nutzer auf allen Flächen (Chat-Liste, Header, Nachrichten-Kreise, Reaktionen, Teilen-Sheet, Vollbild) + einheitliche Initialen
- 🔢 Ungelesen-Badge flackert nicht mehr zwischen altem und neuem Stand beim App-Wechsel
- 🛡️ Verifizierung: kein Endlos-Spinner mehr (Timeout + Isolate), eigener Identitätsschlüssel wird beim Öffnen von Verifizierung/QR selbstheilend (re)veröffentlicht, „Jetzt veröffentlichen"-Button, klare Meldung bei ausstehender Chat-Anfrage
- 📎 Datei-/Videoversand überlebt das Verlassen des Chats (kein Abbruch/Fehler mehr)
- 📷 iOS-Fotos kommen in korrekter Ausrichtung an (EXIF-Orientation wird vor dem Metadaten-Strip in die Pixel gebacken); Bilder >16 MB werden ebenfalls von EXIF/GPS befreit
- 🎬 Inline-YouTube-Player zeichnet nicht mehr über die Chat-Kopfleiste
- 🌐 Landing-Logo rendert wieder in iOS Safari (defekte SVG-Filter entfernt)

### Infrastruktur & Rechtliches
- **AGPL-3.0-Lizenzierung**: LICENSE + SPDX-Header projektweit
- **Wöchentliche Security-Scan-Pipeline**: Semgrep (SAST) + Trivy (Deps) + govulncheck (Go-CVEs) + OWASP ZAP (DAST gegen Staging) → pipepush-Benachrichtigung
- **Persistentes Staging-Environment** (eigener isolierter Supabase-Stack auf dem VPS)
- Landing: ehrliche Open-Source-Formulierung „Open Source (AGPL-3.0)" (Landing 1.1.2)

## [1.10.0] - 2026-07-27

### Added
- 🔄 **Automatische Updates für Android**: Die App merkt selbst, wenn eine neuere Version bereitsteht, lädt sie herunter, prüft ihre Prüfsumme und übergibt sie dem System-Installer. Bis dahin musste man die APK von Hand suchen
- 🌐 Neue Website unter **chattr.at** — mit den echten Ablaufdiagrammen der App statt Screenshots

### Infrastruktur
- Die Android-App wird jetzt automatisch bei jedem Release gebaut und veröffentlicht (vorher von Hand)
- Vorbereitung des öffentlichen Quellcode-Spiegels: automatische Bereinigung privater Konfiguration, Secret-Scanning, `SECURITY.md`
- Die Datenbank-Oberfläche des Servers ist nicht mehr standardmäßig erreichbar

## [1.9.2] - 2026-07-26

### Added
- ⬇️ **„Nach unten"-Knopf** im Chat, der zum neuesten Beitrag springt

### Fixed
- Der Knopf reagierte in 1.9.1 nicht auf Tippen — der Druck ging durch ihn hindurch

## [1.9.1] - 2026-07-26

### Fixed
- 🕐 Chats, in denen du zuletzt selbst geschrieben hast, rutschten in der Liste auf „gestern" und damit nach unten — gezählt wurden nur empfangene Nachrichten

## [1.9.0] - 2026-07-26

### Added
- 🎬 **Schwebendes Videofenster (Bild-in-Bild)**: Ein Video läuft weiter, während du scrollst oder in einen anderen Chat wechselst; das Fenster lässt sich in eine Ecke schieben und wieder andocken. Auch für Reddit-Videos
- 📎 **Große Dateien** werden jetzt stückweise verschlüsselt und hochgeladen — vorher konnte ein großes Video die App zum Absturz bringen, weil Datei und Chiffrat gleichzeitig im Speicher lagen. Gilt jetzt für alle Dateitypen, nicht nur Videos
- 📄 Nicht darstellbare Dateien zeigen eine Dateikarte, ohne vorher entschlüsselt zu werden

### Changed
- 🗑️ **Medien verschwinden früher vom Server**: Ein Blob wird gelöscht, sobald ihn alle Empfänger geladen haben — unabhängig davon, ob Lesebestätigungen aktiv sind

### Fixed
- 📅 Die Datumsangaben in der Chatliste richten sich nach echten Kalendertagen statt nach rollierenden 24 Stunden
- Einheitliche Avatarfarben in Mitgliederlisten und Zeitstempel-Ansichten; lesbarere Admin- und „Du"-Markierungen

## [1.8.2] - 2026-07-25

### Added
- 🔎 **Sprung zur Nachricht**: Aus Favoriten oder der Suche direkt zur Originalnachricht — inklusive kurzer Hervorhebung. Ältere Nachrichten werden dabei automatisch nachgeladen
- ✍️ Die Markdown-Leiste lässt sich global ein- und ausschalten

### Fixed
- Absturz und Einfrieren beim Springen zu weit zurückliegenden Nachrichten (u. a. bei Alben mit unterschiedlich hohen Bildern)
- Gruppenbild-Ansicht und Kamera-Option im Bildauswähler

## [1.8.1] - 2026-07-25

### Added
- ⭐ **Favoriten-Markierung** direkt an der Nachricht sichtbar
- Gruppenname und -beschreibung lassen sich wiederholt bearbeiten (vorher wurde jede weitere Änderung stillschweigend verworfen)

### Fixed
- Banner bei Beitrittsfreigaben erscheint sofort; Gruppenbild wird nach dem Wechsel nicht mehr aus dem Zwischenspeicher gezeigt

## [1.8.0] - 2026-07-25

### Added
- 👥 **Gruppen-Chatbilder**
- 📌 **Chats anpinnen** und **Nachrichten favorisieren**
- 🔍 **Durchsuchbares Teilen-Fenster** — Chats filtern statt scrollen
- 🖼️ Ganze Alben teilen; Text aus dem Eingabefeld wird als Bildunterschrift übernommen
- Überarbeitete Gruppeninfo

### Fixed
- Ein gerade gesendeter Chat springt zuverlässig nach oben, auch wenn die Uhr des Geräts abweicht

## [1.7.0] - 2026-07-23

### Added
- 🎞️ **Videovorschaubilder** — das Titelbild statt einer grauen Fläche, auch in der Album-Kachel
- 🔢 **Verlässliches App-Symbol-Abzeichen**: Die Zahl auf dem App-Symbol stimmt jetzt auch, während die App geschlossen ist
- 📱 iOS bündelt Benachrichtigungen desselben Chats, statt sie einzeln zu stapeln
- 🔑 Hinweisbanner mit Reparaturknopf, wenn ein Chat-Schlüssel verloren ging
- 🖼️ Bilder melden ihre echten Maße mit — das Flackern beim Scrollen durch die Galerie ist weg
- 👤 1:1-Chats zeigen das Bild des Gegenübers in der Kopfzeile, antippbar

### Fixed
- 📹 Absturz beim Senden von Videos auf iOS und beim Wegscrollen eines laufenden Videos
- Videos füllen den Vollbildmodus und bleiben trotzdem wischbar; die Drehung bleibt beim Zuschneiden erhalten
- Die Ungelesen-Zahl hängt nicht mehr an der Lesebestätigung (Geisterzahlen)
- Spürbar flüssigere Emoji-Auswahl

## [1.6.0] - 2026-07-21

### Added
- 🖌️ **Medien vor dem Senden bearbeiten**: Bildeditor, Video zuschneiden, Ton entfernen
- 🖼️ **Alben**: Mehrere Bilder und Videos als eine Nachricht — mit Karussell und Vollbildgalerie
- 👤 Antippbare Profilbilder öffnen ein Profil- und Kontaktfenster

### Fixed
- Ablaufdiagramme auf der Website sind wieder lesbar und fehlerfrei

## [1.5.4] - 2026-07-19

### Fixed
- 🔐 **Android verlor beim Kaltstart seine Chat-Schlüssel** und meldete den Gegenübern fälschlich einen Schlüsselwechsel
- Der Entsperrdialog erschien nicht mehr doppelt und schlug beim Kaltstart nicht mehr grundlos fehl
- Inline-Emojis auf ein angenehmeres Maß zurückgenommen (1,4× war am Gerät zu groß)

## [1.5.3] - 2026-07-19

### Added
- 😀 Emojis im Fließtext werden größer dargestellt

### Fixed
- Das Profilbild des Gegenübers erscheint auch in der Hauptliste

### Sicherheit
- Androids automatisches App-Backup ist abgeschaltet — es hätte lokale Daten außer Haus gegeben

## [1.5.2] - 2026-07-18

### Added
- 🆘 **Rettungsbildschirm**, wenn der sichere Schlüsselspeicher unlesbar ist — statt stillschweigendem Datenverlust
- 👤 Profilbilder anderer Nutzer erscheinen überall in der App

### Fixed
- 🔐 **Kein stilles Löschen von Schlüsseln mehr**: Bei einem Lesefehler wird der Schlüsselspeicher nicht mehr zurückgesetzt. Genau das hatte Konten ausgesperrt
- In einem 1:1-Chat sind beide Seiten gleichberechtigt

## [1.5.1] - 2026-07-18

### Added
- 🔔 Benachrichtigungsbanner auf jedem Bildschirm, mit deutlicherem Rückmeldeimpuls
- ✋ Freundlicher Hinweis „Schlüssel noch nicht bereit" statt einer technischen Fehlermeldung
- Hinweis mit Direktsprung, wenn du zu einem Chat hinzugefügt wurdest

### Fixed
- 📶 **Die Verbindung stellt sich selbst wieder her**, wenn sie unbemerkt abreißt, und holt Verpasstes nach
- Ein frisch per QR-Code hinzugefügter Kontakt ist sofort anschreibbar
- Beim Hochscrollen erschienen ältere Nachrichten in falscher Reihenfolge

## [1.5.0] - 2026-07-17

### Sicherheit
- 🔒 **Weitergabe-Sicherheit (Forward Secrecy)**: Jede Nachricht wird mit einem Einwegschlüssel verpackt, der nach dem Entschlüsseln gelöscht wird. Ein aufgezeichnetes Chiffrat bleibt damit auch dann unlesbar, wenn das Gerät später in falsche Hände gerät
- 📱 **App-Sperre** (freiwillig): Die App lässt sich beim Verlassen sperren und per Biometrie oder Code wieder öffnen
- 🎨 Die Avatarfarbe ist an die Identität gebunden — ein Nachahmer bekommt eine andere Farbe
- Die Wiederherstellungs-Phrase ist beim Anzeigen abgeschirmt und wird aus der Zwischenablage gelöscht; der verborgene Entwicklerprotokoll-Bereich verlangt eine erneute Anmeldung

### Fixed
- Die Nachrichtendetails aktualisieren sich live statt einzufrieren
- Ein Schlüsselwechsel wird nur noch gemeldet, wenn wirklich einer stattfand

## [1.4.0] - 2026-07-16

### Sicherheit
- ✅ **Kontakte überprüfen**: Jedes Konto hat einen langlebigen Identitätsschlüssel, der alle Chat-Schlüssel signiert. Kontakte lassen sich per QR-Code oder Sicherheitsnummer bestätigen; ändert sich etwas, warnt die App
- 📨 **Nachrichten sind signiert** und fest an ihren Chat gebunden — eine Nachricht lässt sich nicht in einen anderen Chat verpflanzen, und ein Herabstufen der Verschlüsselung wird abgelehnt
- 📷 **Aufnahmedaten werden entfernt**: Bilder verlieren vor dem Senden Ort, Gerät und Aufnahmezeit
- 🔑 Chat-Schlüssel sind an das Gerät gebunden, Medien liegen unter nichtssagenden Namen
- Profilabfragen und die Link-Vorschau wurden gegen Missbrauch abgesichert; mehrere Datenbankfunktionen sind nicht mehr öffentlich aufrufbar

### Fixed
- Formatierter Text zeigte in seltenen Fällen technische Zeichenfolgen (`&quot;`)
- Die Formatierungsleiste kommt mit Kombinationen aus fett und kursiv zurecht und zeigt an, was gerade aktiv ist

## [1.3.0] - 2026-07-15

### Added
- ✍️ **Formatierung in Nachrichten** (fett, kursiv, Listen, Zitate, Code) samt Werkzeugleiste und Vorschau
- 🔕 **Lesebestätigungen abschaltbar** — wechselseitig: Wer sie ausschaltet, sieht auch die der anderen nicht
- 📍 **Trennlinie „ungelesene Nachrichten"** an der richtigen Stelle
- 🕐 **Wischen zeigt Zeitstempel**: In die Gegenrichtung wischen blendet Zugestellt- und Gelesen-Zeiten ein
- 📋 Eigene offene Beitrittsanfragen sind sichtbar

### Fixed
- 📱 Android-Absturz auf Geräten mit 16-KB-Speicherseiten
- Das Antippen einer Benachrichtigung landet zuverlässig im richtigen Chat
- Bei KI-Agenten-Chats ist der Besitzer des Zugangs alleiniger Administrator

## [1.2.0] - 2026-07-13

### Release Notes
Post-Quantum-Verschlüsselung (X25519 + ML-KEM-768), E2E-Medien (Foto/Video/Audio/Dateien), Recovery-Phrase + Backup-Datei, MCP-Agent-Chats, Nachrichten-Aktionen (Reaktionen mit Push, Antworten, Weiterleiten, Bearbeiten, Zurückrufen, Timer), Blockieren, Username ändern, Link-Vorschauen mit Popup-Player, Android-Share-Target — plus zahlreiche Fixes.

### Added
- 🔐 **Post-Quantum-Hybrid-Verschlüsselung**: X25519 + ML-KEM-768 (KEM/DEM) ersetzt RSA-2048; jede Nachricht einzeln pro Empfänger verschlüsselt
- 📎 **E2E-Medien**: Fotos, Videos, Audio & Dateien (privater Bucket, clientseitig verschlüsselt); Inline-Bild/Audio/Video-Player; gzip vor Verschlüsselung; Composer-Paste (Ctrl/Cmd+V)
- 🔑 **Recovery-Phrase** (BIP39 → Ed25519 Challenge-Response) + **Backup-Datei** zum Identitäts-Restore
- 🤖 **MCP-Agent-Chats**: token-gebundene Owner-Sichtbarkeit, globale Registrierung, cross-project Chat-Registry, Realtime-`chattr_wait`
- 💬 **Nachrichten-Aktionen**: einheitliches Menü, Reaktionen (mit Push + Wer-hat-reagiert-Sheet), Antworten, Weiterleiten, Bearbeiten, „Für alle löschen", selbstzerstörende Timer, Enter-to-send
- 🧑 Username/Anzeigename ändern; Token-Revoke entzieht Agenten den Chat-Zugriff
- 🚫 Nutzer blockieren (1:1, DB-durchgesetzt); server-seitiges Chat-Mute mit Datum/Zeit
- 🔗 Rich-Link-Vorschauen (YouTube/Reddit-Thumbnails + og:image) + In-App-Popup-Player
- 📥 Android-Share-Target (Text & Dateien empfangen)
- 🖼️ Avatare, Screenshot-Schutz (Android), Chat-Beschreibung, QR-Manual-Join, Key-Rotation
- 🌐 Landing „Technik"-Sektion (alle App-Flows als Mermaid-Diagramme)

### Fixed
- Zeitstempel in Geräte-Lokalzeit (Transport/Storage bleibt UTC); zwei Server-Write-Offset-Bugs
- System-Nachrichten (Hybrid-KEM) wiederhergestellt + konsistente Formatierung; Key-Rotation angekündigt
- Resync von Nachrichten & Unread-Badges bei App-Resume; Share-Target-Dispose-Crash
- Link-Preview: offener SSRF-Proxy geschlossen (In-Function-Auth-Gate)
- i18n: chatview-Package-Strings lokalisiert; grammatikalisch korrekte deutsche Labels

### Security
- **Post-Quantum-sichere** Ende-zu-Ende-Verschlüsselung (X25519 + ML-KEM-768) ersetzt RSA-2048
- Link-Preview-Edge-Function: SSRF-Guard + In-Function-JWT-Gate (self-hosted Runtime verifiziert keine JWTs)

## [1.1.7] - 2026-07-12

### Added
- 😀 Push-Benachrichtigung bei einer Reaktion auf deine Nachricht

### Fixed
- Systemnachrichten („X ist beigetreten", Schlüsselwechsel) werden wieder zugestellt
- Das Fenster „wer hat reagiert" war im dunklen Modus unlesbar und zeigte keine Namen
- Kein falsches „Lädt …" mehr über Systemhinweisen; Absturz beim Schließen behoben

## [1.1.6] - 2026-07-11

### Fixed
- Aus einer anderen App geteilte Inhalte kamen nicht an, wenn Chattr dabei in den Hintergrund ging

## [1.1.5] - 2026-07-11

### Sicherheit
- 🔒 Die Link-Vorschau war ein offener Zugang, über den sich fremde Adressen abrufen ließen — jetzt mit Zugangsprüfung und Schutz gegen Zugriffe auf interne Netze

### Added
- Ablaufdiagramme auf der Website ausklappbar; stabiler Download-Link für die Android-App

## [1.1.4] - 2026-07-11

### Added
- ▶️ **Eingebauter Videoplayer** für YouTube- und Reddit-Links, ohne die App zu verlassen
- 📎 Dateien werden vor der Verschlüsselung komprimiert; Medien werden vom Server gelöscht, sobald alle sie gelesen haben

## [1.1.3] - 2026-07-11

### Added
- 🚫 **Nutzer blockieren** in 1:1-Chats — serverseitig durchgesetzt, keine App kann es umgehen
- 📤 **Teilen an Chattr**: Texte und Dateien aus anderen Android-Apps direkt in einen Chat
- 📷 **Kamera** direkt im Anhang-Menü
- ✏️ **Entwürfe bleiben erhalten**, pro Chat
- 🔗 Reichere Link-Vorschauen mit Vorschaubild
- 📦 Obergrenze für Uploads auf 500 MB angehoben
- Die App-Version steht in den Einstellungen

### Fixed
- Antippen einer Benachrichtigung öffnet den Chat; im Vordergrund erscheinen keine System-Banner mehr
- Der Benachrichtigungston respektiert den Lautlos-Modus und unterbricht keine laufende Wiedergabe
- Antwort-Zitate sind für Empfänger lesbar; eine unbekannte Reaktion killt nicht mehr den ganzen Stapel
- In 1:1-Chats gibt es keine sinnlosen Admin-Aktionen mehr

## [1.1.2] - 2026-07-10

### Release Notes
Dark-Mode-Wallpaper (Matrix/Ozean/Sonnenuntergang/Königlich/Rose); Chat-Fixes: Membership-Banner flackert nicht mehr, Message-Grouping mit korrektem Bubble-Einzug und Absendername pro Gruppe


## [1.1.1] - 2026-07-10

### Release Notes
Android-Fix (Biometrie/FlutterFragmentActivity: Chats+Messages entschlüsseln jetzt), 5 neue Light-Themes mit Foto-Wallpapern, QR-Manual-Join-Fixes, Push-Token-Persistenz


## [1.1.0] - 2026-07-10

### Release Notes
Unified message menu with quick reactions, reply/forward/edit/unsend fixes, reaction priming, honest chat delete, compact link previews, timed per-chat mute with date/time picker, QR manual code entry, theme-aware reply views, web push de-duplication (data-only FCM), upload retry + size guard, PWA auto-updater


### Added
- Versioning-System für alle Komponenten (Client, Backend, Landing Page)
- Version-Kompatibilitätsprüfung zwischen Client und Backend
- Automatisierte Release- und Version-Bump-Scripts
- Supabase Version-Tracking Tabelle

## [1.0.0] - 2026-04-04

### Added
- 🔐 End-to-end Verschlüsselung mit RSA-2048
- 🔑 Anonyme Authentifizierung (kein Email erforderlich)
- 🗑️ Automatische Nachrichtenbereinigung nach dem Lesen
- 💬 Echtzeit-Messaging mit Gruppen- und Einzelchats
- 👥 Admin-System mit Mitgliederverwaltung
- ✓ Lesebestätigungen für Nachrichten
- 📱 QR-Code Sharing für Kontakte und Chats
- 🌍 Multi-Language Support (Deutsch/Englisch)
- 🔔 Push-Benachrichtigungen (FCM)
- 🔄 Offline-Support mit lokaler verschlüsselter Speicherung
- 📊 Chat-Metadaten (Unread Counts, Last Message)
- 🗨️ System-Nachrichten für Membership-Events

### Security
- RSA-2048 Verschlüsselung für alle Nachrichten
- Verschlüsselter lokaler SQLite-Speicher
- Row Level Security (RLS) für alle Supabase-Tabellen
- Sichere Key-Verwaltung mit flutter_secure_storage

### Infrastructure
- Flutter 3.10.4+ App (Android, iOS, Web, Desktop)
- Supabase Backend mit Realtime
- Docker-basierte Supabase-Entwicklungsumgebung
- Bitbucket Pipelines CI/CD
- VPS Deployment mit rsync
