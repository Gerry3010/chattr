# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.0.0/),
und dieses Projekt folgt [Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

## [1.33.0] - 2026-10-30

Ein Update für schlechtes oder gar kein Netz: Ohne Verbindung zeigt Chattr deine Chats weiter mit Namen, Bildern und Verlauf, und eine Nachricht, die nicht rausgeht, bleibt stehen, bis du sie erneut sendest. Dazu kommen viele Fehlerbehebungen und eine Runde Sicherheit und Stabilität, in der App und am Server.

### Added
- ⏱️ **Deine Nachricht steht sofort im Chat.** Bisher erschien sie erst, wenn der Server sie angenommen hatte, und ohne Netz kam sie gar nicht, nur der Text zurück ins Eingabefeld. Jetzt steht die Blase beim Tippen auf Senden da, mit einer Uhr, bis sie draußen ist. Geht sie nicht raus, zeigt ein rotes Zeichen neben ihr, dass sie nur auf diesem Gerät liegt. Ein Tipp darauf bietet „Erneut senden“ und „Verwerfen“. Eine nicht gesendete Nachricht übersteht auch einen Neustart der App, und wenn du sie später sendest, bekommt sie die Uhrzeit, zu der sie wirklich rausgeht
- 👆 **Doppeltippen tut jetzt etwas.** Auf einem Foto oder Video setzt es eine Reaktion, ❤️ wenn du nichts anderes einstellst, und ein zweites Doppeltippen nimmt sie zurück. Auf einer Textnachricht öffnet es die Textauswahl, dort markierst du einen Teil oder kopierst alles. Welches Emoji das Doppeltippen setzt, wählst du unter Einstellungen → Chats & Medien
- 👥 **In Gruppen reagierst du über die Reaktions-Pille mit.** Steht unter einer Nachricht nur eine Sorte Reaktion, setzt ein Tipp auf die Pille dieselbe, ein zweiter nimmt deine wieder weg. Bei mehreren Sorten und in Einzelchats zeigt der Tipp wie bisher, wer reagiert hat
- 📞 **iPhone: Chattr-Anrufe lassen sich aus der Anrufliste heraushalten.** Bisher standen sie dort immer mit dem Chatnamen und gingen über iCloud auf deine anderen Apple-Geräte. Unter Einstellungen → Anrufe kannst du das abschalten

### Changed
- ⚙️ **Die Einstellungen sind gegliedert.** Statt einer langen Liste gibt es jetzt Gruppen mit eigenen Seiten: Benachrichtigungen, Chats & Medien, Anrufe, Privatsphäre, Sicherheit sowie Backup & Wiederherstellung

### Fixed
- 👍 **Eine Reaktion auf deine eigene Nachricht lässt sich wieder zurücknehmen.** Weder das „x“ noch das Wegwischen taten etwas: Der Server ließ dich deine eigene Reaktion dort gar nicht sehen, weil er Nachrichten nur dem Empfänger zeigt, und löschte deshalb nichts, ohne einen Fehler zu melden. Das gilt auch für ältere App-Versionen, sobald der Server aktualisiert ist
- 🔒 **Eine Nachricht, die dein Gerät nicht öffnen kann, zeigt wieder den Hinweis „Nachricht nicht lesbar“.** In Einzel- und Gruppenchats stand stattdessen eine Zeile Code in der Blase, etwa nach einer Wiederherstellung auf einem neuen Gerät. Bei Nachrichten, die eine neuere App-Version brauchen, war es genauso
- 👍 **Deine letzte Reaktion zurückzunehmen schließt nicht mehr den Chat.** Das Fenster „Reaktionen“ schloss sich nach dem Entfernen selbst, und weil danach noch mehrere Aktualisierungen kamen, schloss es gleich den Chat mit. Jetzt schließt es sich genau einmal
- 💬 **Ohne Netz zeigt ein Chat sofort seinen Verlauf.** Beim Öffnen fragte Chattr zuerst den Server nach verpassten Nachrichten und zeigte den Verlauf erst danach, obwohl alles auf dem Gerät lag. Ohne Netz dauerte diese Frage so lange, bis das Handy aufgab, und so lange blieb der Chat leer. Jetzt wartet er höchstens anderthalb Sekunden auf den Server, und weiß das Handy schon, dass es offline ist, gar nicht
- 📶 **Kein leerer Streifen mehr zwischen Hinweis und Kopfleiste im Chat.** Stand oben „Server nicht erreichbar“ oder „Kein Netz“, rückte die Kopfleiste darunter noch einmal um die Höhe der Statusleiste nach unten. Dasselbe passierte bei den Hinweisen zu einem verlorenen Schlüssel, einer geänderten Sicherheitsnummer und einer gemeldeten Nachricht. Den Abstand zur Statusleiste hält jetzt nur noch, was ganz oben steht
- 🖼️ **Profil- und Gruppenbilder lassen sich nicht mehr aus dem Bild schieben.** Die große Ansicht ließ das Bild beliebig weit wegziehen, es blieb dann halb abgeschnitten stehen. Jetzt verhält sie sich wie die Ansicht für Fotos im Chat: Doppeltippen zoomt, nach unten wischen schließt, und losgelassen findet das Bild seinen Platz wieder
- 🔍 **Fotos im Chat lassen sich lockerer zoomen.** Beim Zoomen und Verschieben kannst du ein Stück über den Bildrand hinaus und etwas kleiner als bildschirmfüllend ziehen. Beim Loslassen federt das Bild zurück, statt an der Kante hart anzuschlagen
- 🗂️ **Ein Fehler am Server kann deine Chats nicht mehr vom Gerät löschen.** Fehlte ein Chat in der Liste, die der Server schickt, hat Chattr ihn samt allen Nachrichten vom Gerät entfernt. Das stimmt, wenn jemand den Chat für alle gelöscht hat, während du offline warst. Eine kaputte Server-Version, die plötzlich keine oder nur noch die Hälfte deiner Chats schickt, hätte so aber den ganzen Verlauf auf jedem Gerät gelöscht, und den gibt es nur dort. Kommt die Liste jetzt leer zurück oder fehlen viele Chats auf einmal, bleiben sie stehen, bis der Server drei Tage lang und über mehrere Abrufe dabei bleibt. Ein einzelner gelöschter Chat verschwindet weiter sofort
- ✍️ **„… schreibt“ kommt nach einer Rückkehr in die App wieder.** Die Anzeige hing an einer Verbindung, die Chattr nach einem Abbruch nie neu aufbaute: Ein Ausflug in eine andere App, ein Netzwechsel oder ein Neustart unseres Servers reichte, und bis zum nächsten Beenden der App sah niemand mehr, dass jemand tippt. Jetzt baut sich die Verbindung von selbst neu auf, und ein Chat, den du verlässt, schließt seine
- 🔔 **Ein Tipp auf die Benachrichtigung des offenen Chats öffnet ihn nicht mehr ein zweites Mal.** Chattr legte dabei einen weiteren Bildschirm desselben Chats darüber, und danach meldete der Chat seine eigenen Nachrichten oben als Banner. Jetzt springt der Tipp zum offenen Chat zurück
- Wer eine App-Sperre mit Code und Face ID nutzt: Der Sperrbildschirm griff sich beim Sperren kurz das Code-Feld, auch wenn Face ID entsperrte. Danach konnte im Chat eine Tastatur stehen, die an kein Feld gebunden war. Das Code-Feld bekommt den Fokus jetzt nur noch, wenn es keine andere Entsperrung gibt
- 📴 **Ohne Netz heißen Einzelchats wieder wie die Person.** Im Flugmodus stand in der Chatliste „Chat cb97c93c“ statt des Namens, in der Farbe des Chats statt der Farbe der Person, und ebenso in der Kopfzeile, der Suche und beim Weiterleiten. Wer in welchem Chat ist und wie die Leute heißen, kam nur vom Server. Chattr legt beides jetzt verschlüsselt auf dem Gerät ab und gleicht es beim nächsten Kontakt mit dem Server ab. Nach dem Update braucht es einen Start mit Netz, bis die Namen auf dem Gerät liegen
- 🔔 **Eine App ohne Netz verdirbt nicht mehr die Namen in Benachrichtigungen.** Wurde Chattr einmal offline geöffnet, ersetzte die App in ihrer Namensliste für Benachrichtigungen die echten Namen durch „Chat …“, und die nächsten Benachrichtigungen kamen mit der Kennung statt mit dem Namen
- ✉️ **Eine Nachricht, die nicht rausgeht, ist nicht mehr weg.** Ohne Netz leerte Chattr beim Senden das Feld, zeigte aber weder eine Blase noch einen Hinweis, und auch der Entwurf wurde gelöscht. Der Text kam nirgends an und war trotzdem fort. Jetzt steht er samt Zitat wieder im Feld, und Chattr sagt, dass er nicht gesendet wurde. Dasselbe gilt, wenn die Schlüssel noch ausgetauscht werden
- 📶 **Nach einem Start im Flugmodus holt Chattr nach, sobald das Netz da ist.** Bisher blieben Nachrichten, die in der Zwischenzeit kamen, auf dem Server liegen, bis du die App einmal verlassen hast
- 😀 **Reaktionen stehen auch ohne Netz unter den Nachrichten.** Beim Öffnen eines Chats kamen sie nur vom Server, ohne Verbindung fehlten deshalb alle Pillen. Chattr merkt sie sich jetzt auf dem Gerät
- ⏱️ **Ohne Netz startet Chattr deutlich schneller.** Der Startbildschirm wartete bis zu 20 Sekunden: gut 12 auf die Prüfung der Anmeldung, die es ohne Netz immer wieder versuchte, und bis zu 8 auf die Kennung für Benachrichtigungen. Die Prüfung bekommt jetzt höchstens 4 Sekunden, die Kennung holt Chattr nach dem Start. Fehlte sie bisher, kamen Benachrichtigungen bei geöffneter App bis zum nächsten Neustart gar nicht mehr an
- 🖼️ **Profil- und Gruppenbilder bleiben ohne Netz sichtbar.** Die Bilder liegen nur hinter kurzlebigen, signierten Adressen, und ohne Netz gibt es keine. In der Chatliste, in Profilen und in der großen Ansicht standen deshalb offline nur Initialen. Chattr nimmt jetzt das Bild, das schon auf dem Gerät liegt. Ein neu hochgeladenes Bild hat einen neuen Namen und ersetzt das alte also von selbst
- 📵 **Chattr sagt, ob dein Gerät offline ist oder unser Server.** Im Flugmodus stand bisher „Server nicht erreichbar“, und das erst nach ein paar vergeblichen Versuchen. Jetzt heißt es „Kein Netz“, sobald das Gerät länger als zwei Sekunden ohne Verbindung ist. Kommt das Netz zurück, verbindet sich Chattr sofort neu, statt bis zu 30 Sekunden auf den nächsten Versuch zu warten
- 🌀 **Ohne Netz kreist nichts mehr endlos.** Gesperrte Kontakte, MCP-Schlüssel, Mitgliederlisten, Einladungen und die Sicherheitsnummer drehten offline gut eine halbe Minute lang und zeigten dann eine rohe Fehlermeldung wie „ClientException with SocketException“. Jetzt steht nach kurzer Zeit „Keine Verbindung zum Server“ mit einem Knopf zum erneuten Versuchen. Sobald das Netz zurück ist, laden diese Seiten von selbst neu
- 💬 **Fehler ohne Netz sagen, was los ist.** Bearbeiten, Löschen für alle, Fotos und Dateien melden „keine Verbindung“ statt einer technischen Meldung. Eine Reaktion, die nicht durchging, verschwand bisher wortlos, jetzt sagt Chattr es
- 🎙️ **Eine Sprachnachricht geht ohne Netz nicht mehr verloren.** Chattr meldete „Aufnahme fehlgeschlagen“ und warf die Aufnahme weg, obwohl nur das Senden gescheitert war. Jetzt bleibt sie eine Minute lang erhalten, mit einem Knopf „Erneut senden“

### Security
- 🖼️ **Profilbilder sehen nur noch Leute, die dich kennen.** Bisher konnte jedes angemeldete Konto die Ablage der Profilbilder auflisten und bekam damit die Kennung jedes Nutzers mit Bild, und anmelden kann sich bei Chattr jeder ohne Weiteres. Jetzt sieht ein Profilbild nur, wer auch das Profil sehen darf: wer mit dir in einem Chat ist, und wem du gerade eine Chat-Anfrage geschickt hast. Gruppenbilder sehen nur die Mitglieder der Gruppe. Server-Update (Migration 00094)
- 🛡️ **Auch der Server nimmt keine gefälschten Chattr-Hinweise mehr an**, und eine Nachricht lässt sich nur noch über die Bearbeiten-Funktion ändern, mit ihrer Frist. Neue Namen mit unsichtbaren Zeichen lehnt jetzt auch der Server ab
- 🤖 **Der MCP-Server für Agenten ist abgedichtet.** Eine Nachricht konnte einen Agenten dazu bringen, entschlüsselte Anhänge an beliebige Stellen des Rechners zu schreiben, auch über Verknüpfungen hinweg. Jetzt landen sie nur noch in einem eigenen Ordner, und nichts Bestehendes wird überschrieben. Eine Nachricht mit einem Datum weit in der Zukunft macht den Agenten im Chat nicht mehr taub, die Sitzungsdatei wird nicht mehr halb geschrieben gelesen, Shots sieht ein Agent nur als Hinweis statt sie dauerhaft zu speichern, und `chattr_wait` wacht wieder sofort bei neuen Nachrichten auf
- 🎭 **Ein Mitglied kann keine Chattr-Hinweise mehr fälschen.** Hinweise wie „X wurde entfernt“ erkennt die App jetzt daran, dass sie keinen Absender haben. Bisher reichte es, eine eigene Nachricht als Hinweis zu kennzeichnen
- 🖼️ **Ein präpariertes Bild legt Chattr nicht mehr lahm.** Ein Bild, das als Datei klein ist, aber beim Öffnen Gigabytes Speicher verlangt, wird nicht mehr geöffnet. Chattr liest vorher die Bildgröße aus dem Dateikopf und zeigt alles andere nur so groß, wie der Bildschirm es braucht
- 🔗 **Links sagen, wohin sie wirklich führen.** Nennt der Text eines Links eine andere Adresse als die, zu der er führt, oder steht vor dem Ziel ein Name mit @, fragt Chattr vor dem Öffnen und zeigt das echte Ziel. Videos aus Links spielt Chattr nur noch über https ab
- ✅ **Ein QR-Code verifiziert nur noch, was zusammenpasst.** Beim Scannen hat Chattr den Schlüssel aus dem Code bisher ungeprüft als verifiziert übernommen, auch über einen früheren hinweg. Jetzt muss er mit dem Schlüssel übereinstimmen, den der Server für diese Person zeigt, offline mit dem bisher gemerkten. Passt er nicht, sagt Chattr das und ändert nichts. Auch „Als verifiziert markieren“ merkt sich jetzt genau den Schlüssel, aus dem die angezeigte Sicherheitsnummer stammt
- 📞 **Ein Anruf prüft den Schlüssel auch bei jemandem, den du noch nie verifiziert hast.** Bisher ging er dann gegen den Schlüssel raus, den der Server lieferte, ohne Abgleich mit der Identität der Person
- 🪪 **Namen dürfen keine unsichtbaren Zeichen mehr enthalten.** Zeichen ohne Breite und Richtungsumkehrer machen „bob“ und „b·ob“ gleich aussehend oder drehen Text um. Sie waren das Werkzeug, um sich als jemand anderes auszugeben
- 🔐 **Ohne Fingerabdruck fragt Chattr nach der Geräte-PIN.** Auf einem Handy mit PIN, aber ohne eingerichteten Fingerabdruck oder Gesichtserkennung öffneten sich die Chats und die App-Sperre bisher ganz ohne Abfrage. Jetzt fragt Chattr dort die PIN, das Muster oder das Passwort des Geräts ab. Nur ein Gerät ganz ohne Bildschirmsperre hat nichts, womit es fragen könnte
- 🔐 **Der App-Code lässt sich nicht mehr beliebig oft raten.** Nach fünf falschen Versuchen wartet Chattr erst 30 Sekunden, danach jedes Mal doppelt so lange, höchstens eine Stunde
- 🧹 **Abmelden löscht auf dem iPhone jetzt auch deine Identität und deine Chat-Schlüssel.** Die lagen dort an einer eigenen Stelle im Schlüsselbund, die das Abmelden nie erreichte. Ein neues Konto auf demselben Gerät hätte deshalb denselben Identitätsschlüssel veröffentlicht, und altes und neues Konto ließen sich verbinden
- 🔔 **Die Warnung „Konto auf einem neuen Gerät wiederhergestellt“ kommt wieder an.** Sie blieb auf Geräten, die Benachrichtigungen selbst erzeugen, stumm oder zeigte nur einen Platzhalter
- 🛡️ **Android: Das Update in der App installiert nur noch Chattr.** Bisher prüfte Chattr eine heruntergeladene Update-Datei nur gegen eine Prüfsumme, die in derselben Update-Beschreibung stand wie die Download-Adresse. Wer diese Beschreibung hätte ändern können, hätte eine fremde App unterschieben können. Jetzt muss die Datei von unserem eigenen Server über https kommen, und vor der Installation prüft Chattr, ob sie wirklich Chattr ist: gleicher Paketname, gleiches Signatur-Zertifikat wie die installierte App und eine neuere Version
- 🛡️ **Ein Link oder eine Nachricht kann Chattr nicht mehr einfrieren.** Die Linkvorschau las die verlinkte Seite in voller Länge und suchte darin mit Mustern, die sich an einer präparierten Seite sekundenlang festbissen, genauso das Erkennen von E-Mail-Adressen in einer Nachricht. Chattr liest jetzt nur noch den Anfang einer Seite, sucht im Hintergrund und mit Mustern, die nicht hängen bleiben können. Die Adresse, für die eine Vorschau gebraucht wird, geht außerdem nicht mehr in der URL an unseren Server, wo sie in Protokollen landen konnte
- 🧹 **Beim Abmelden verschwindet auch die Namensliste für Benachrichtigungen.** Damit eine Benachrichtigung „Alice“ statt einer Kennung zeigen kann, legt Chattr auf dem Gerät eine Liste deiner Chatnamen ab. Die blieb nach dem Abmelden liegen, auf dem iPhone und im Web sogar ohne jede Möglichkeit, sie zu löschen. Jetzt geht sie mit dem Konto
- 🛡️ **Ein Backup vom iPhone enthält jetzt wirklich deine Chat-Schlüssel.** Chattr hat beim Sichern an der falschen Stelle im Schlüsselbund gesucht und unter iOS keinen einzigen Chat-Schlüssel gefunden. Nach einer Wiederherstellung galten dann alle Chats als verloren, und vorher fiel es nicht auf. Das Backup sammelt die Schlüssel jetzt dort ein, wo sie liegen, und nimmt auch deine Identität und die Liste der verifizierten Kontakte mit. Deine Sicherheitsnummer bleibt nach einer Wiederherstellung also gleich. Mach nach dem Update bitte ein neues Backup, ältere Dateien von einem iPhone helfen nicht weiter
- 🔑 **Wiederherstellen klappt auch mit einer älteren Backup-Datei.** Die Anmeldung, die in der Datei steckt, gilt nur einmal und ist meist schon verbraucht. Bist du auf dem neuen Gerät schon mit deiner Wiederherstellungs-Phrase angemeldet, holt Chattr aus der Datei nur noch die Schlüssel. Schlüssel, die das Gerät schon hat, bleiben dabei erhalten, damit Nachrichten an beide lesbar bleiben
- 🛡️ **Teilen aus einer anderen App kann keine Dateien mehr in Chattrs eigenen Speicher schreiben.** Den Dateinamen eines geteilten Bildes oder Dokuments bestimmt die App, aus der geteilt wird. Unter Android wurde er unverändert als Pfad verwendet, und ein Name mit Ordnerangaben konnte die Kopie außerhalb des Zwischenspeichers ablegen, noch bevor du etwas gesehen hast. Jetzt zählt nur der eigentliche Dateiname, jede Kopie bekommt einen eigenen Ordner, und Chattr nimmt nur noch geteilte Inhalte an, die die andere App selbst lesen darf. Chattr-eigene Dateien lassen sich so nicht mehr als Anhang unterschieben. Teilen von Chattr nach Chattr geht weiter
- 🛡️ **Eine Sperre durch die Moderation lässt sich nicht mehr selbst aufheben.** Die Markierung stand bei Konten und Gruppen in derselben Zeile, die ihr Besitzer bearbeiten darf, und ließ sich dort zurücksetzen. Jetzt setzt und löscht sie nur noch die Moderation, ebenso den Zähler für falsche Meldungen
- 🛡️ **Eine Gruppe lässt sich nicht mehr als Agenten-Chat übernehmen.** Ein Mitglied konnte eine bestehende Gruppe an ein eigenes Agenten-Konto binden und wurde dadurch ihr einziger Admin. Binden geht jetzt nur für einen frischen Chat, in dem der Agent allein ist; das ist genau der Weg, den der Chattr-MCP-Server nimmt
- 🛡️ **Der Server lässt vier interne Schnittstellen nicht mehr von außen erreichen:** die Verwaltung des Echtzeit-Dienstes, das fortsetzbare Hochladen, die Protokoll-Konsole und die Bildumrechnung. Chattr selbst hat keine davon benutzt
- 🛡️ **Der Dienst, der Fotos und Dateien am Server ablegt, läuft in einer neuen Version.** Über das fortsetzbare Hochladen ließen sich in der alten ohne Anmeldung Dateien anlegen und überschreiben. Den Weg dorthin hatten wir schon gesperrt, jetzt ist die Lücke auch im Dienst selbst geschlossen, und mit ihr eine zweite in der Suche nach Dateien. Seine S3-Schnittstelle, die Chattr nie benutzt hat, ist abgeschaltet
- 🛡️ **Das Relay für Anrufe kommt nicht mehr in den eigenen Server.** Eine besondere Schreibweise von Adressen umging die Sperre, die das Relay von unseren internen Diensten fernhält. Der Vermittlungsdienst ist auf eine neue Version gehoben und hat zusätzlich eine eigene Regel dagegen
- 🛡️ **Profil- und Gruppenbilder bekommen bei jedem Hochladen einen neuen, nicht erratbaren Namen**, und das vorige Bild wird gelöscht. Bisher lag jedes Bild unter einem festen Namen, den jeder kannte, der die Konto-Kennung kannte
- 🛡️ **Beim Antworten geht der Name der zitierten Person nicht mehr an den Server.** Er stand bis zur Zustellung im Klartext neben der verschlüsselten Nachricht, obwohl jede App die Person ohnehin über ihre Kennung findet
- 🛡️ **Eine angehängte Datei kann beim Entpacken nicht mehr den Speicher füllen.** Chattr bricht jetzt ab, sobald sie größer würde als erlaubt, statt erst alles zu entpacken und danach nachzumessen

## [1.32.3] - 2026-10-24

### Changed
- 🎨 **Die Leiste eines klingelnden Anrufs trägt die Farbe deines Themes.** In 1.32.2 war sie immer bernsteinfarben, jetzt nimmt sie die Akzentfarbe, im Wald-Theme etwa den Ockerton. Wo die Akzentfarbe selbst grün ist, nimmt sie eine andere Farbe des Themes, damit ein Klingeln nie wie ein laufendes Gespräch aussieht

### Fixed
- Wer einen Anruf aus der verkleinerten Leiste ablehnte oder auflegte, sah die Leiste kurz grün aufleuchten, bevor sie verschwand. Jetzt behält sie ihre Farbe bis zum Schluss
- Die Knöpfe im Anrufbildschirm hatten Hinweistexte, die sich dort nicht anzeigen ließen: Ein langes Drücken auf „Annehmen“, „Auflegen“ oder den Pfeil zum Verkleinern konnte ins Leere laufen. Bildschirmleser lesen die Bezeichnungen weiterhin vor

## [1.32.2] - 2026-10-24

### Added
- 📶 **Ein Anruf übersteht jetzt einen Netzwechsel.** Wer mitten im Gespräch das Haus verlässt und vom WLAN ins Mobilnetz wechselt, verlor bisher die Verbindung: Zehn Sekunden Stille, dann war der Anruf vorbei. Jetzt baut Chattr die Verbindung über das neue Netz neu auf, und auf dem Bildschirm steht so lange „Verbindung wird wiederhergestellt …“ statt einer weiterlaufenden Uhr. Kommt sie innerhalb von 20 Sekunden nicht zurück, endet der Anruf. Klappt nur, wenn beide schon diese Version haben; mit einer älteren Gegenseite endet der Anruf wie bisher
- ⬇️ **Anrufe lassen sich runterlegen.** Oben links im Anruf verkleinert ein Pfeil das Gespräch zu einer grünen Leiste am oberen Rand — Chattr lässt sich darunter ganz normal weiterbenutzen, das Gespräch läuft weiter. Ein Tipp auf die Leiste holt den Anruf zurück, auflegen geht direkt aus der Leiste. Auch ein Anruf, der noch klingelt, lässt sich so wegschieben: Die Leiste ist dann bernsteinfarben und hat Annehmen und Ablehnen gleich eingebaut, damit niemand ein Klingeln für ein laufendes Gespräch hält
- 📴 **Auflegen aus der Benachrichtigung.** Die Leiste „Anruf läuft" hat jetzt einen Knopf „Auflegen" — man muss Chattr dafür nicht öffnen
- 🔒 **Eine Nachricht, die sich nicht öffnen lässt, verschwindet nicht mehr spurlos.** Bisher stand so ein Fehler nur im Protokoll, und im Chat fehlte die Nachricht einfach; niemand merkte, dass etwas gesagt worden war. Jetzt steht an ihrer Stelle eine Karte „Nachricht nicht lesbar“. Fehlt diesem Gerät der passende Schlüssel, etwa nach einer Wiederherstellung auf einem anderen Gerät, bleibt die Karte. Bei anderen Fehlern bleibt die Nachricht am Server liegen, Chattr versucht es beim nächsten Abholen noch einmal, und gelingt es, ersetzt der Inhalt die Karte. Eine Nachricht, die dieses Gerät schon geöffnet hat, ersetzt die Karte nie

### Changed
- ⚡ **Anrufe kommen schneller zustande.** Bisher wartete jede Seite, bis ihr Gerät alle denkbaren Verbindungswege durchprobiert hatte. Über den Chattr-Server dauerte das bis zu sechs Sekunden, einmal bevor es beim Gegenüber überhaupt klingelte und noch einmal nach dem Annehmen. Gebraucht wird aber nur einer dieser Wege, und der steht nach rund einer Zehntelsekunde (gemessen). Jetzt gehen Einladung und Antwort los, sobald er da ist, mit einer kurzen Nachfrist für weitere. Außerdem holt Chattr die Verbindungsdaten schon, während es klingelt, und prüft beim Wählen mehrere Dinge gleichzeitig statt nacheinander. Und während es klingelt, bereitet das angerufene Gerät die Verbindung schon vor, nur das Mikrofon bleibt zu bis zum Annehmen. Schon ohne diese Vorbereitung dauerte es vom Tippen auf „Annehmen“ bis zum Gespräch rund zwei Sekunden (gemessen), egal ob beide im selben WLAN waren oder eines im Mobilnetz

### Fixed
- 🖼️ **Fotos und Videos bleiben auf dem Gerät.** Bisher verschwanden sie nach ein, zwei Tagen: Die Nachricht stand noch da, aber statt des Bildes drehte sich ein Ladekreis ohne Ende. Chattr hat Fotos und Videos nie auf dem Gerät behalten, sondern bei jedem Ansehen neu vom Server geholt, und dem Server trotzdem gemeldet, man habe sie. Der löschte sie daraufhin, wie versprochen, und danach hatte sie niemand mehr. Jetzt bewahrt jedes Gerät eine Kopie auf, verschlüsselt wie auf dem Server, auch der Absender seine eigene. Gemeldet wird erst, wenn diese Kopie vollständig liegt, und erst dann darf der Server löschen. Was schon vorher verloren ging, lässt sich nicht zurückholen; dort steht jetzt „Nicht mehr verfügbar“ statt eines Ladekreises. Fotos und Videos belegen dadurch dauerhaft Platz auf dem Gerät
- 🔐 **Ein neuer Chat bekommt genau einen Schlüssel pro Gerät.** Beim Anlegen eines Chats liefen mehrere Vorgänge gleichzeitig los, und jeder erzeugte seinen eigenen Schlüssel. Im Chat stand dann gleich mehrfach „… hat neue Schlüssel erzeugt“, und schlimmer: Das Gerät behielt manchmal einen anderen Schlüssel als den, den es veröffentlicht hatte. Nachrichten an dieses Gerät ließen sich dann nicht öffnen, auch eine Anruf-Einladung nicht. Jetzt entsteht pro Chat und Gerät genau ein Schlüssel, egal wie viele Vorgänge gleichzeitig danach fragen
- 📨 **Chat-Anfragen erscheinen auch, wenn die App gerade im Hintergrund war.** Bisher kam eine Anfrage nur an, wenn Chattr in dem Moment offen war; sonst tauchte sie erst nach einem Neustart auf. Jetzt sieht die App bei jeder Rückkehr nach
- 🎤 **Im Web funktionieren Anrufe, Sprachnachrichten und die Kamera.** Eine Sicherheitseinstellung unseres Servers verbot der Web-App Mikrofon und Kamera, auch wenn man beides im Browser erlaubt hatte. Behoben ist das am Server; wer die Web-App gerade offen hat, lädt sie einmal neu
- 📞 **Annehmen am Sperrbildschirm zeigt jetzt den Anruf** (Android). Wer einen Anruf am Sperrbildschirm annahm und dann entsperrte, sah eine Chattr ohne Anruf — und konnte nicht mehr auflegen, nur das Gegenüber. Der Grund: Android startete dabei eine zweite Chattr neben der ersten, in der das Gespräch unsichtbar weiterlief. Jetzt gibt es nur noch eine
- 📞 **Am iPhone lässt sich ein Anruf auf dem Sperrbildschirm annehmen.** Bisher brach er gleich nach dem Annehmen ab, und der Anrufer sah „Anruf fehlgeschlagen“; bei offener App klappte es. Bevor Chattr antwortet, prüft es den gemerkten Schlüssel des Gegenübers, und den gab das iPhone nur entsperrt heraus. Jetzt ist er lesbar, sobald das iPhone seit dem Einschalten einmal entsperrt war. Beim ersten Öffnen nach dem Update zieht er dafür um; bestätigte Kontakte bleiben bestätigt
- 🔔 **Am iPhone klingelt Chattr mit dem eigenen Klingelton** — auch auf dem Sperrbildschirm, statt mit dem Standard-Klingelton des Systems. Und bei offener App ist das Klingeln wieder zu hören: Bisher spielte Chattr seinen Ton zusätzlich selbst, und das System schaltete ihn stumm. Ist das iPhone auf lautlos, bleibt es still — wie bei jedem Anruf
- Ein Anruf, dessen Einladung sich nicht mehr abholen lässt (offline, schon abgelaufen), verschwindet jetzt aus der System-Anrufanzeige, statt dort hängen zu bleiben
- 🔑 **Nach einer Wiederherstellung hört das alte Gerät auf, Schlüssel zu schreiben.** Wer sein Konto auf einem neuen Gerät wiederherstellte, ließ die alte Installation angemeldet zurück. Die veröffentlichte bei jedem Start ihre Schlüssel neu, über die des neuen Geräts, und das neue schrieb beim nächsten Öffnen zurück. In jedem Chat stand dann immer wieder „… hat neue Schlüssel erzeugt“, und manche Nachrichten ließen sich auf dem neuen Gerät nicht öffnen. Jetzt beendet die Wiederherstellung alle früheren Sitzungen des Kontos. Ist ein altes Gerät mit dieser Version noch angemeldet, merkt es, dass das Konto weitergezogen ist: Es schreibt keine Schlüssel mehr und sagt das oben in der Chatliste. „Abmelden“ dort löscht nur die Daten auf diesem Gerät, das Konto bleibt bestehen
- 👯 **Ein Chat steht nicht mehr doppelt in der Liste.** Wer einen Chat direkt nach einem Anruf verließ, sah ihn manchmal zweimal untereinander, und ein anderer Chat fehlte dafür ganz (gemeldet nach einem Anruf mit SeB). Zwei Dinge liefen gleichzeitig: Der Anruf-Eintrag schob den Chat nach oben, und das Verlassen setzte ihn auf gelesen, und zwar an die Stelle, an der er vor dem Hochschieben gestanden hatte. Dort stand inzwischen der andere Chat. Nach einem Neustart verschwand der doppelte Eintrag wieder; jetzt entsteht er gar nicht erst
- 📭 **Einmalschlüssel des alten Geräts werden weggeräumt.** Nach einer Wiederherstellung lagen am Server noch die Einmalschlüssel der alten Installation. Weil immer der älteste zuerst vergeben wird, verschlüsselten deine Kontakte ihre Nachrichten genau für diese Schlüssel, und die hatte das neue Gerät nie. Jedes Gerät löscht jetzt die Einmalschlüssel, deren privaten Teil es nicht besitzt, bevor es seinen Vorrat zählt und auffüllt
- 🔓 **Statt „Noch keine Chats“ steht da jetzt „Chattr ist gesperrt“.** Wer beim Öffnen Face ID oder den Fingerabdruck abbrach, sah eine leere Chatliste mit „Noch keine Chats“, als wäre alles weg, und kam erst nach einem Neustart der App wieder an seine Chats. Jetzt erscheint der Sperrbildschirm mit „Biometrie verwenden“, auch wenn die App-Sperre aus ist, und nach dem Entsperren ist die Liste da. Kommst du später in die App zurück, fragt Chattr von selbst noch einmal. Das App-Symbol bekommt in dieser Zeit auch keine falsche 0 mehr
- 📶 **Ohne Netz gestartet, bleibt die Chatliste stehen.** Chattr las die Chats vom Gerät, scheiterte dann am Server und räumte die Liste wieder ab, bis zum nächsten Neustart. Jetzt bleibt sie, und den Rest holt Chattr nach, sobald die Verbindung zurück ist oder du die App wieder öffnest
- Wer die App-Sperre mit dem Code öffnet, wird danach nicht mehr bei jedem Chat noch einmal nach Face ID gefragt
- 🔗 **Links in Bildunterschriften lassen sich antippen.** Eine Adresse in der Unterschrift eines Fotos oder Videos stand bisher als reiner Text da. Jetzt ist sie markiert wie in jeder anderen Nachricht, E-Mail-Adressen auch
- ▶️ **YouTube-Videos bleiben in ihrer Nachricht.** Lief ein YouTube-Video im Chat und du hast nach oben gescrollt, lag es über der Kopfleiste und sogar über der Uhrzeit am oberen Rand. Jetzt schneidet der Rand der Liste es ab wie jedes Bild. Vollbild gibt es über den neuen Knopf rechts über dem Video; er öffnet das schwebende Fenster gleich in voller Größe
- Im schwebenden Videofenster fehlten zuletzt die Knöpfe oben (zurück in den Chat, vergrößern, schließen). Sie sind wieder da
- 🙂 **Die Schnellreaktionen lernen wieder dazu.** Ein neues Emoji sollte nach drei Reaktionen in die Reihe kommen, brauchte aber vier, weil die Zählung zwischen den Reaktionen schon ein wenig verblasste. Am iPhone kam dazu: Startete Chattr bei gesperrtem Telefon im Hintergrund, etwa für einen Anruf, ging der gezählte Stand beim nächsten Reagieren verloren. Jetzt reichen drei Reaktionen innerhalb von ein paar Tagen, und der Stand bleibt
- 🙂 **Emoji im Text sitzen richtig.** Eine Zeile mit Emoji wurde höher als eine ohne. Auf dem iPhone stand nach jedem Emoji zudem eine Lücke, als folgte ein Leerzeichen, das gar nicht da war, und die Emoji wirkten kleiner als auf Android. Gemessen: Apples Emoji-Schrift zeichnet ein Emoji kleiner als die Schriftgröße und lässt dahinter Platz frei. Jetzt behält jede Zeile ihre Höhe, die Lücke ist zu, im Eingabefeld und in Bildunterschriften genauso, und ein Emoji in der Blase ist auf dem iPhone so groß wie auf Android
- ⌨️ **Die Tastatur geht weg, wenn ein Anruf kommt.** Wer gerade tippte, als es klingelte, hatte sie auch nach dem Annehmen noch über dem Anrufbildschirm

## [1.32.1] - 2026-10-07

### Added
- 📞 **Anrufe stehen jetzt im Chat.** Nach jedem Anruf erscheint im Verlauf eine kurze Zeile — „Ausgehender Anruf · 2:13", „Eingehender Anruf", „Verpasster Anruf" oder „Abgelehnter Anruf". Die Zeile schreibt jedes Gerät nur für sich, in seine eigene verschlüsselte Datenbank; über den Server läuft dabei nichts, er erfährt also auch nicht, wie lange ihr gesprochen habt. Nur ein verpasster Anruf zählt als ungelesen. Was gar nicht erst geklingelt hat — kein Mikrofon, das Gegenüber kann noch keine Anrufe —, hinterlässt keine Zeile. Noch nicht dabei: ein Anruf, der nur bei geschlossener App geklingelt hat und nie geöffnet wurde

### Changed
- ✏️ **Bearbeiten hat jetzt eine Frist.** Eine gesendete Nachricht lässt sich bis zu einen Tag nach dem Senden ändern — sobald sie jemand gelesen hat, aber nur noch zehn Minuten lang ab diesem ersten Lesen. Eine Korrektur lange nachdem jemand gelesen und vielleicht schon geantwortet hat, würde ändern, worauf geantwortet wurde. Bisher gab es gar keine Frist, und nach etwa einer Woche lief eine Bearbeitung ins Leere, weil der Server die Nachricht da längst aufgeräumt hatte. Ist die Frist um, verschwindet „Bearbeiten" aus dem Menü; hat dein Gerät vom Lesen nichts mitbekommen (Lesebestätigungen aus), sagt der Server Bescheid

### Fixed
- 📱 **Auf Android läuft ein Gespräch weiter, wenn man die App verlässt.** Bisher wurde es stumm, sobald Chattr in den Hintergrund ging — Android nimmt einer App dort Mikrofon und Ton weg. Jetzt meldet Chattr das Gespräch beim System als laufenden Anruf an, mit der üblichen Leiste „Anruf läuft"; ein Tipp darauf führt zurück (gemeldet von SeB)
- 🔔 **Der Klingelton läuft jetzt rund durch.** Bisher stockte er alle drei Sekunden: Die Aufnahme brach den zweiten Ton mitten im Ausklingen ab und sprang sofort zurück an den Anfang, und genau an dieser Stelle setzt das Abspielen beim Wiederholen kurz aus. Jetzt klingt jeder Doppelton sauber aus, danach folgt eine kurze Pause — wie bei einem echten Telefon —, und die Naht liegt in der Stille, wo man sie nicht hört

## [1.32.0] - 2026-10-04

### Added
- 🌍 **Anrufe kommen jetzt auch über verschiedene Netze zustande.** Bisher klappte ein Anruf nur, wenn beide im selben WLAN waren. Damit zwei Geräte hinter verschiedenen Routern zueinander finden, braucht es einen Vermittlungsdienst — und den betreiben wir jetzt selbst, auf unserem eigenen Server in Wien, statt die Verbindungsdaten jedes Anrufs einem fremden Anbieter zu geben. Er hilft beim Finden und leitet das Gespräch weiter, wo eine direkte Verbindung nicht geht. Hören kann er dabei nichts: Das Gespräch bleibt Ende-zu-Ende-verschlüsselt, er reicht Bytes weiter, die er nicht öffnen kann. Er schreibt auch nicht mit, wer wann telefoniert. Die Zugangsdaten dafür sind kurzlebig, gelten nur für Menschen, die einander anrufen dürfen, und tragen keine Kennung deines Kontos
- 🕶️ **Neu in den Datenschutz-Einstellungen: „Anrufe über den Chattr-Server leiten".** Bei einem direkten Anruf sieht dein Gegenüber deine IP-Adresse — das gehört zu „direkt" dazu. Ist der Schalter an, läuft jedes Gespräch über unseren Vermittlungsdienst, und dein Gegenüber sieht nur dessen Adresse. Ist der Dienst gerade nicht erreichbar, kommt der Anruf nicht zustande, statt still doch direkt zu verbinden — sonst wäre die Einstellung ein Versprechen, das im ungünstigsten Moment nicht gilt. **Standardmäßig an**: Deine Adresse bleibt privat, solange du nichts anderes entscheidest. Wer lieber direkt telefoniert, schaltet es aus und bekommt dafür manchmal etwas besseren Klang

- 🌊 **Im Anruf sieht man jetzt, wer gerade spricht.** Unter dem Namen läuft eine Welle mit — in der Farbe deines Themes, und zwar in der einen Farbe, wenn dein Gegenüber spricht, in einer zweiten, wenn du es bist. Bist du stumm geschaltet, zeigt sie deine Stimme auch nicht an: Das Mikrofon hört zwar weiter, aber davon verlässt nichts dein Gerät, und die Welle soll nichts anderes behaupten
- 📲 **Anrufe klingeln jetzt auch, wenn Chattr geschlossen ist.** Bisher kam ein Anruf nur an, solange die App offen war. Jetzt weckt ein Anruf das Telefon mit dem echten Anruf-Bildschirm des Systems — auf dem iPhone derselbe wie bei jedem Telefonat, auf Android als Vollbild. Was dabei über Apple oder Google läuft, ist bewusst knapp: **dass** ein Chattr-Anruf kommt und wann, aber nicht von wem — den Namen setzt dein Telefon selbst ein, aus dem, was es ohnehin weiß. Weil die eigentliche Einladung zu groß für eine Push-Nachricht ist, hält unser Server sie verschlüsselt bereit, bis dein Gerät sie abholt — höchstens zwei Minuten lang, danach ist sie gelöscht, und lesen kann er sie die ganze Zeit nicht. Legt der Anrufer vorher auf, hört das Klingeln bei dir auch auf
- 📵 **Kein Klingeln ins Leere mehr.** Wer noch eine ältere Chattr-Version hat, kann keine Anrufe annehmen — bisher klingelte es trotzdem, bis nach 45 Sekunden „Keine Antwort" kam. Jetzt meldet jede App, was sie kann, und vor dem Anrufen wird nachgesehen: Geht es beim Gegenüber noch nicht, steht das sofort da, statt dass man wartet. Sehen kann diese Angabe nur, wer die Person ohnehin anrufen darf
- 📞 **Rufaufbau zum Hören und Sehen.** Wer anruft, hört jetzt einen leisen Freiton, solange es beim anderen klingelt — vorher war es still, und Stille wirkte wie „kaputt". Und um das Profilbild laufen sanfte Ringe, bis das Gespräch steht. Wer in den Systemeinstellungen Bewegungen reduziert hat, bekommt sie ruhig
- 📴 **Am Ohr wird der Bildschirm dunkel.** Wer im Gespräch das Telefon ans Ohr hält, tippt nicht mehr versehentlich mit der Wange auf „Auflegen" oder „Stumm" — der Näherungssensor schaltet den Bildschirm ab und wieder an, sobald es vom Ohr weg ist. Beim Klingeln und mit Lautsprecher bleibt er an
- 🔔 **Anrufe haben eigene Töne.** Ein eingehender Anruf klingelt jetzt mit einem eigenen, ruhigen Klingelton statt mit dem Benachrichtigungston, und wenn ein Gespräch endet, hören beide Seiten einen kurzen, fallenden Abschlusston — Auflegen hört man also, statt es nur zu sehen. Einstellbar wird der Klingelton später
- 🫧 Das Logo steht jetzt auch unten in den Einstellungen, über der Versionsnummer
- ✨ **Neu in dieser Version — als Karte, einmal.** Nach einem Update mit einer neuen Funktion erscheint beim ersten Öffnen eine kurze Karte dazu, mit „Gelesen" ist sie weg und kommt nicht wieder. Wer mehrere Versionen übersprungen hat, blättert mit „Weiter" durch alle. In den Einstellungen unter „Über" lassen sich die Karten jederzeit noch einmal ansehen

- 🖼️ **Bildunterschriften lassen sich kopieren und nachträglich ändern.** Bei einer reinen Textnachricht gab es beides längst, bei einem Bild mit Text fehlte es — der Text darunter war weder kopierbar noch zu korrigieren. Jetzt bietet das Menü beim langen Drücken „Kopieren" für die Bildunterschrift an, und wer das Bild geschickt hat, kann sie unter „Bildunterschrift bearbeiten" ändern, ergänzen oder ganz entfernen. Das Bild selbst bleibt dabei unangetastet. Bei Shots geht beides bewusst nicht: Ihr Text gehört zum Bild und soll wie das Bild nur einmal zu sehen sein (gemeldet von SeB)

### Fixed
- 🫧 **Das Logo auf dem Anmeldebildschirm hat seine Tiefe wieder.** Im App-Icon wirft das „C“ einen weichen Schatten auf die Sprechblase darunter — erst dadurch heben sich die beiden hellen Flächen voneinander ab. In der App fehlte dieser Schatten, weil die Bibliothek, die das Logo zeichnet, solche Effekte schlicht auslässt, und das Logo wirkte wie eine einzige flache Form. Jetzt zeichnet die App den Schatten selbst nach, mit denselben Werten wie das Icon

### Changed
- 📞 Der Hinweis im Anruf sagt jetzt nur noch „Ende-zu-Ende-verschlüsselt" statt „direkt zwischen euren Geräten" — über den Vermittlungsdienst ist der zweite Teil nicht mehr wahr

## [1.31.0] - 2026-10-03

### Added
- 📞 **Anrufe — zunächst zu zweit und nur mit Ton.** In jedem Einzelchat steht oben ein Hörer. Das Gespräch läuft direkt zwischen den beiden Geräten und ist Ende-zu-Ende-verschlüsselt; unser Server reicht nur die Verabredung weiter, wer wen anruft, und kann sie weder lesen noch fälschen. Das ist kein Nebensatz: Bei Anrufen steckt der Schlüssel zum Gespräch genau in dieser Verabredung, und ein Server, der sie unbemerkt austauschen könnte, säße mitten im Gespräch. Deshalb wird sie verschlüsselt und unterschrieben wie eine Nachricht. Anrufen darf dich nur, wem du eine Chat-Anfrage angenommen hast, und wen du gesperrt hast, der erreicht dich auch hier nicht. Was noch fehlt, sagen wir offen: Es klingelt nur, solange Chattr geöffnet ist. Und vorerst kommen Anrufe nur zustande, wenn beide im selben Netz sind, also zum Beispiel im selben WLAN. Für alles andere braucht es einen Vermittlungsdienst, und den betreiben wir selbst, statt die Verbindungsdaten eines jeden Anrufs einem fremden Anbieter zu geben

## [1.30.0] - 2026-09-24

### Security
- 🔒 **Fremde konnten einem Gerät gefälschte Benachrichtigungen unterschieben.** Der Server meldet jedem Gerät über einen privaten Kanal, was sich getan hat — neue Nachricht, Chat gelöscht, Reaktion. Eine Hilfsfunktion, die in diese Kanäle schreibt, war für jeden aufrufbar, der die App-Kennung kennt, und die steckt in jeder App. Damit ließ sich einem Gerät etwa melden, ein Chat sei gelöscht worden — und die App räumte ihn samt seiner Nachrichten auf, obwohl nichts passiert war. Nötig waren die Kennung des Opfers und die des Chats, also Wissen, das jedes (auch frühere) Mitglied hat. Jetzt dürfen nur noch die Abläufe des Servers selbst in diese Kanäle schreiben. Gefunden haben wir es bei der Arbeit an Anrufen

### Fixed
- ⏱️ **Der Hinweis beim Shot sagt jetzt, was zu tun ist.** Im gesperrten Eingabefeld unter einem Shot stand bisher, was es dort **nicht** gibt („Einmal ansehen, dann weg — ohne Bildunterschrift"). Dass man stattdessen **aufs Bild tippen** kann, um Text hineinzuschreiben, stand nirgends — ausgerechnet das Einzige, wofür der Platz da ist. Jetzt steht es dort
- 📤 **Beim Teilen im Querformat war der Senden-Knopf nicht erreichbar.** Wer etwas aus einer anderen App an Chattr weitergibt, bekommt ein kleines Fenster zum Nachbearbeiten — und quer gehalten nimmt die Tastatur davon fast alles weg. Was übrig bleibt, wird von unten gemessen, und genau dort stand der Knopf: verdeckt, auf einem Fenster, dessen einziger Zweck das Abschicken ist. Quer sitzt er jetzt **oben** neben der Überschrift. Das Textfeld wird quer außerdem etwas flacher, damit der Cursor nicht seinerseits aus dem Streifen rutscht, und der Inhalt lässt sich schieben, falls es doch einmal eng wird. Im Hochformat bleibt alles, wie es war (gemeldet für iOS, geändert für beide — oben stört es auf Android nicht)

### Added
- 👍 **Die Reaktionsreihe ordnet sich nach dem, was du wirklich benutzt.** Beim langen Drücken auf eine Nachricht standen bisher immer dieselben sechs Emoji in derselben Reihenfolge — egal, ob du je eines davon angetippt hast. Jetzt merkt sich die Reihe, womit du reagierst, und sortiert sich danach. Los geht es für alle mit genau der bisherigen Reihenfolge, es sieht also zunächst nichts anders aus. Gezählt werden **nur Reaktionen** (die Reihe selbst und die Auswahl über das „+"), nicht Emoji, die du in Nachrichten schreibst — und nur, wenn du eine Reaktion **setzt**, nicht wenn du sie zurücknimmst. Ältere Benutzung verliert nach und nach an Gewicht, damit die Reihe zeigt, was du in den letzten Wochen tust und nicht, was du im Frühjahr einmal getan hast
- 🖐️ **Die Reaktionsreihe kennt jetzt deinen Hautton.** Wer einen eingestellt hat, sah ihn bisher überall außer dort, wo man am häufigsten hinlangt: Im Raster und über die Suche kam 👍 in deinem Ton, in der Schnellreihe beim langen Drücken stand weiter das gelbe. Jetzt gilt er auch dort. Gefärbt wird über dieselbe Funktion wie im Raster, damit beide Wege **zeichengleich** dasselbe erzeugen — sonst ließe sich eine Reaktion, die man über den einen Weg gesetzt hat, über den anderen nicht mehr zurücknehmen. Und ob ein Emoji überhaupt Hauttöne kennt, wird im Emoji-Satz nachgeschlagen statt angenommen: Ein Ton, der an ❤️ oder 😂 gehängt würde, fiele nicht auf, sondern stünde als zweites Zeichen daneben. Gemerkt wird weiter die blanke Form, der Ton kommt erst beim Anzeigen dazu — ein späterer Wechsel wirft die gelernte Reihenfolge also nicht um

- 🧘 **Und sie tut es betont langsam.** Die Reihe ist Muskelgedächtnis: Wer ohne hinzusehen auf den zweiten Platz greift, muss dort dasselbe Emoji finden. Deshalb sortiert sie sich nicht einfach nach Häufigkeit um, sondern erst, wenn ein Emoji das über ihm **deutlich** schlägt — Gleichstand und knappe Vorsprünge bewegen gar nichts. Ein Emoji, das neu hinzukommt, betritt die Reihe immer **hinten** und arbeitet sich dann Platz um Platz vor, egal wie beliebt es ist; nach vorne gesetzt wird nie etwas. In der Praxis heißt das: ein paar Taps ändern nichts, eine Gewohnheit über Tage schon

## [1.29.6] - 2026-09-24

### Fixed
- 🔴 **Die rote Zahl am App-Symbol ging auf dem iPhone nicht mehr weg.** Sie stand auf 8, obwohl in der App alles gelesen war, und wuchs mit der Zeit weiter. Dahinter stand kein Zählfehler, sondern eine Zahl ohne Rückweg. Damit die Zahl auch dann stimmt, wenn die App gar nicht läuft, zählt ein kleiner Helfer des Betriebssystems jede eintreffende Meldung mit — und der kann nur **hinzufügen**, nie abziehen. Zurückgenommen wird sein Zuschlag erst, wenn die App das nächste Mal nachrechnet. Nur: Meldungen gibt es nicht nur für neue Nachrichten, sondern auch für Reaktionen auf deine Nachrichten und für Beitritts- und Kontaktanfragen — und keine davon hinterlässt etwas Ungelesenes. Der Zuschlag war also da, der Gegenposten konnte es gar nicht geben, und die Zahl blieb für immer stehen. Jetzt hebt nur noch eine echte neue Nachricht sie an. Zweitens bestätigt die App ihren Stand ab sofort **jedes Mal**, wenn du sie nach vorne holst — vorher tat sie das nur, wenn sich die Zahl geändert hatte, was in genau dieser Lage nie der Fall war. Bestätigt wird dabei der richtige Stand, nicht einfach eine 0: Bleiben ungelesene Chats übrig, steht danach deren Zahl da (Android war nie betroffen)

## [1.29.5] - 2026-09-14

### Fixed
- 🙂‍↕️ **Ein verbundenes Emoji allein stand klein in der Blase statt groß daneben.** Wer nur ein Emoji schickt, bekommt es groß und ohne Blase — außer, es war ein zusammengesetztes: 🙂‍↕️, ❤️, 👍🏽 oder eine Flagge saßen klein im Kasten, mit Uhrzeit daneben, während ein 😂 in derselben Unterhaltung groß dastand. Dahinter steckte ein Vergleich, der zwei verschiedene Dinge zählte: auf der einen Seite die **Zeichen**, aus denen der Text besteht, auf der anderen die **Emoji**, die darin gefunden wurden. Bei einem einfachen Emoji ist beides eins, und es ging auf. Sobald ein Emoji aber aus mehreren Zeichen zusammengesetzt ist — 🙂‍↕️ sind vier, ❤️ und 👍🏽 je zwei —, konnten die beiden Zahlen gar nicht mehr übereinstimmen, und die Nachricht galt als „nicht nur Emoji". Jetzt wird beides in dem gezählt, was ein Mensch als ein Zeichen sieht. Nebenbei hängt die Entscheidung nicht mehr an einer mitgelieferten Emoji-Liste, die veraltet: Sonst wäre jeder neue Jahrgang in dem Moment wieder in die Blase gerutscht, in dem er erscheint

## [1.29.4] - 2026-09-14

### Added
- 🫩 **Die Emoji-Auswahl hat keine Jahresgrenze mehr — der ganze Unicode-Satz ist drin.** Bisher endete sie bei den Emoji von 2023; alles Jüngere war weder im Raster noch über die Suche zu finden, auch dann nicht, wenn die eigene Tastatur es längst tippen konnte. Neu dazu kommen unter anderem 🫩, 🫆, 🪾, 🫜, 🪉, 🪏 und 🫟. Der Grund für die alte Grenze war echt und bleibt bestehen: Damit die Auswahl beim Öffnen nicht ruckelt, wird **nicht** geprüft, ob das Gerät jedes Emoji zeichnen kann — ein Emoji, für das die Schrift des Geräts noch keine Vorlage hat, erscheint deshalb als leeres Kästchen statt einfach zu fehlen. Nur schnitt die Grenze in beide Richtungen, und sie war eine Annahme über fremde Schriften, die von allein altert: Schriften holen auf, eine eingetragene Jahreszahl nicht

- 🔍 **Und was das Gerät trotzdem nicht zeichnen kann, steht erst gar nicht in der Auswahl.** Die fehlende Jahresgrenze hätte auf älteren Telefonen leere Kästchen bedeutet. Deshalb misst die App beim Start **einmal** nach, wie breit die 43 jüngsten Emoji gesetzt werden, und vergleicht das mit zwei Bezugsgrößen: einem Zeichen, das keine Schrift haben darf, und einem, das jede hat. Daran ist dreierlei zu unterscheiden, ohne Graubereich: ein gezeichnetes Emoji, ein leeres Kästchen — und eine verbundene Folge, die in ihre Einzelteile zerfällt und deshalb doppelt so breit wird. Der letzte Fall ist der heimtückische: Das ist kein Kästchen, sondern ein **falsches Bild** (statt einer tanzenden Person stehen dort eine Person und ein Ballettschuh nebeneinander), und genau den sieht man nur an der Breite. Wer eine Schrift hat, die alles kennt, verliert nichts; auf einem Gerät ohne die neuesten Vorlagen fehlen sie still, statt als Kästchen dazustehen. Und wenn die Messung selbst nichts taugt, wird **nichts** ausgeblendet — im Zweifel lieber ein Kästchen zu viel als ein Emoji zu wenig

### Fixed
- 🔎 **Die meisten Emoji waren nur über ein einziges Wort zu finden.** Wer „Punkt" in die Emoji-Suche tippte, fand den grünen Punkt nicht — nur „grüner" führte hin. Dahinter steckten zwei Dinge. Erstens hat die Stichwortquelle (die Übersetzungsdatenbank von Unicode) an fast jede Zeile einen Vermerk angehängt, dass die Übersetzung beigesteuert wurde — und unser Einlesen übersah jede Zeile mit so einem Vermerk **stillschweigend**. Betroffen waren ausgerechnet die Zeilen mit den Stichwörtern: **137 der 300** nachgetragenen Emoji behielten nur ihren Namen, und wo auch der Name den Vermerk trug (Posaune, Schatztruhe, Erdrutsch), blieb überhaupt nichts Deutsches übrig und der englische Name stand da. Jetzt werden die Vermerke gelesen statt mitgezählt: von 4,0 auf 7,3 deutsche Stichwörter je Emoji, und kein einziges hängt mehr an einem Wort. Zweitens darf ein Stichwort eine **Wortgruppe** sein, und verglichen wurde immer nur ihr Anfang — 😶‍🌫️ heißt „Gesicht in Wolken" und war damit nicht über „Nebel" zu finden, 🧑‍🦰 nicht über „Haar", ❤️‍🩹 nicht über „Verband". Niemand tippt den Anfang einer Wortgruppe; alle tippen das Wort, das sie meinen. Jetzt zählt jedes Wort darin, auch über Bindestriche hinweg (🦧 über „Utan", nicht nur über „Orang")
- 🙂‍↕️ **Verbundene Emoji zerfielen in ihre Einzelteile.** Aus 🙂‍↕️ wurden in der Blase zwei Zeichen nebeneinander, 🙂 und ↕️ — und das lag nicht an der Schrift, die kann es. Wir haben es vorher zerschnitten. Damit Emoji mitten im Satz nicht zu klein wirken, werden sie etwas größer gesetzt als der Text drumherum; dafür wird die Nachricht in Abschnitte zerlegt. Zerlegt wurde bisher **Zeichen für Zeichen**, und ein verbundenes Emoji ist genau das nicht: 🙂‍↕️ besteht aus einem Gesicht, einem unsichtbaren Bindezeichen und einem Pfeil — und der Pfeil steht im Unicode bei den gewöhnlichen Pfeilen, nicht bei den Emoji. Dort riss der Abschnitt. Zwei Abschnitte sind zwei Schriftgrößen und damit zwei getrennte Setzvorgänge, zwischen denen die Schrift die beiden Teile gar nicht mehr zusammenfügen kann. Zerlegt wird jetzt entlang dessen, was ein Mensch als **ein** Zeichen sieht; ein verbundenes Emoji ist damit unteilbar. Nebenbei richtig geworden: ↕️, ⏰ oder 1️⃣ gelten jetzt selbst als Emoji und werden mitvergrößert — sie tragen keinen Emoji-Code in sich, sondern nur die ausdrückliche Bitte, als Bild statt als Schriftzeichen zu erscheinen. Wer umgekehrt die Schrift-Form verlangt (❤︎), bekommt sie; und ein blankes → oder ™ bleibt wie bisher gewöhnlicher Text

## [1.29.3] - 2026-09-13

### Changed
- 🔭 **Der Zoom hört bei 100× auf, auch wenn das Gerät mehr anbietet.** Bisher wurde übernommen, was die Kamera meldete — und manche Telefone melden Spannen weit darüber. Der Deckel ist keine technische Grenze, sondern eine Entscheidung: Bis dahin ist auf dem Schirm noch etwas auszumachen. Er kostet auch nicht nur den obersten Abschnitt: Weil die Ziehgeste **verdoppelnd** zuordnet, streckt jede höhere Obergrenze die ganze Skala — die unteren, häufigen Stufen werden dadurch schwerer zu treffen. Was ein Gerät an Unsinn meldet (unter null, NaN, Obergrenze unter Untergrenze), führt jetzt zu „kein Zoom" statt zu einer Spanne, in der die Geste ins Leere läuft

### Added
- ✉️ **E-Mail-Adressen im Text sind anklickbar.** Wer eine Adresse schreibt, meinte sie auch — bisher stand sie als gewöhnlicher Text da, und der Empfänger musste sie mit dem Finger markieren und kopieren. Jetzt öffnet ein Tipp die Mail-App. Der Ausdruck dahinter ist bewusst streng: Es braucht einen Punkt und eine Endung aus Buchstaben, damit aus einer Erwähnung (`@gerry`) oder einem `preis@stück` kein Knopf wird, der eine Mail-App aufreißt. Steckt das `@` in einer Web-Adresse (`https://user@host/…`), gehört es weiterhin dem Link — sonst risse die Erkennung mitten aus ihm ein Stück heraus

### Fixed
- 📮 **Ein selbst geschriebener `mailto:`-Link führte in den Browser statt zur Mail-App.** Die App setzte allem, was nicht mit `http` begann, ein `https://` davor — aus `mailto:name@example.at` wurde `https://mailto:name@example.at`, was ein Rechner klaglos als Adresse mit dem Gastgeber `example.at` liest. Der Verweis **sah also richtig aus**, war unterstrichen und antippbar, und landete dann auf einer fremden Website. Ein stiller Fehlgriff ist schlimmer als gar kein Link. `mailto:` und `tel:` gehen jetzt unverändert durch; alles andere (`javascript:`, `file:`, `intent:` …) bleibt bewusst gewöhnlicher Text statt zu einem Knopf zu werden, dessen Wirkung von der Plattform abhängt

## [1.29.2] - 2026-09-04

### Fixed
- 🔁 **Die Kamera-Vorschau stand im Querformat schief und beim Aufnehmen verzerrt.** Aufgeklärt wurde das nicht durch Hinsehen, sondern durch Messen: Ein Prüfstand öffnet die Kamera direkt im Emulator, zeigt nacheinander die Vorschau und die **aufgenommene Datei** — die nachweislich richtig herum ist — und rechnet aus, um wieviel die beiden auseinanderliegen. Das Auge hatte sich zweimal geirrt, die Rechnung nicht. Ergebnis: Die Vorschau braucht genau die Drehung, die das Kamera-Paket vorher abzieht, weil es erwartet, dass sie jemand wieder anlegt — nicht mehr und nicht weniger. Die Sonderbehandlung während einer Aufnahme, die den Kipper heilen sollte, war zu grob gefasst und riss das Querformat mit; ebenso weg ist das Mitdrehen des Seitenverhältnisses, das aus dem hochkanten Sucher im Moment des Aufnahmestarts ein breites Band machte
- 🎬 **Beim Halten des Auslösers kippte die Vorschau — aber nur dort.** Eine Aufnahme aus dem Video-Modus war die ganze Zeit richtig; schief wurde es nur beim langen Druck. Der Grund liegt in der Auflösung: Für Fotos läuft die Kamera in der höchsten Stufe, für Video in einer verlässlicheren. Hängt sich der Videorekorder an eine Vorschau, die für Fotos eingerichtet ist, richtet Android sie neu ein und dreht sie dabei um eine Vierteldrehung. Wer schon im Video-Modus ist, hat die passende Einrichtung bereits — dort passiert nichts. Die Gegendrehung steht jetzt genau an dieser Bedingung — und sie ist **absolut, nicht dazugerechnet**: Beim Neueinrichten zählt die Lage des Geräts nicht mehr mit. Dazugerechnet stimmte nur das Hochformat, wo die Lage zufällig nichts beiträgt; quer lag es um eine halbe Drehung daneben

## [1.29.1] - 2026-09-04

### Added
- 🔍 **Zoomen in der Kamera.** Zwei Finger auseinander, und das Bild kommt näher — bei Foto wie bei Video, auch mitten in einer laufenden Aufnahme. In der eigenen Kamera fehlte das seit 1.29.0 schlicht: Die Kamera-App des Telefons hatte es mitgebracht, unsere hatte es nie bekommen. Wie weit es geht, **fragt die App beim Gerät nach** statt es anzunehmen — manche Rückkameras fangen unter 1,0 an (das Ultraweitwinkel), viele Frontkameras können gar nichts, und eine erfundene Spanne zoomte auf dem einen Gerät ins Leere und auf dem anderen zu kurz. Die Stufe steht kurz als Zahl im Bild und bleibt beim Wechsel zwischen Foto und Video erhalten; wechselt man auf eine Kamera, die so weit nicht kann, rückt sie an deren Grenze statt zu verschwinden
- 👆 **Zoomen mit einem Finger — aus dem Auslöser heraus ziehen.** Wer den Auslöser hält und aufnimmt, hat keine zweite Hand für eine Kneifgeste. Also: Finger drauf lassen und **wegziehen** — je weiter weg, desto näher dran, und zurück zum Auslöser fährt es wieder herunter. Gemessen wird dabei der **Abstand**, nicht die Richtung: Nach oben, zur Seite oder schräg bedeutet dasselbe, und damit funktioniert die Geste im Querformat genau wie im Hochformat. Die Zuordnung ist bewusst nicht gleichmäßig, sondern verdoppelnd — von 1× auf 2× sieht nach genauso viel Veränderung aus wie von 5× auf 10×, also muss gleiche Fingerstrecke das Bild vervielfachen und nicht einen festen Betrag addieren

- 🧭 **Die Bedienung bleibt am Geräterand mit dem Anschluss.** Im Hochformat unten wie bisher, im Querformat **seitlich** — auf der Seite, an der im Hochformat der untere Rand war. Die Oberfläche dreht mit dem Gerät mit, und damit rutschten Auslöser und Umschalter beim Kippen an die lange Kante, also genau dorthin, wo die Hand gerade nicht ist

### Fixed
- 🩹 **Der Zoom ruckelte — und zwar bis ins aufgenommene Video hinein.** Drei Ursachen, alle im heißen Pfad einer Geste, die im Takt der Bildwiederholung meldet. Jede Meldung baute den **ganzen Schirm** neu auf statt nur die Zahl. Solange die Kamera noch an der vorigen Stufe arbeitete, wurde die nächste **fallen gelassen** — damit konnte ausgerechnet die letzte verlorengehen, und der Zoom blieb neben der angezeigten Zahl stehen. Vor allem aber wurde **auf jede Stufe gewartet**, bis die Kamera sie übernommen hatte: Was ankam, waren ein Dutzend grosse Sprünge pro Sekunde statt einer Bewegung — und weil der Zoom eine echte Änderung am Bild ist, standen diese Sprünge auch im fertigen Video. Jetzt läuft die Zustellung in festem Takt und nähert sich der gewollten Stufe in kleinen Schritten; die angezeigte Zahl folgt dem Bild statt dem Finger

## [1.29.0] - 2026-09-02

### Added
- 📷 **Eine eigene Kamera — und damit endlich ein Auslöser, der uns gehört.** Bisher reichte „Kamera" an die Kamera-App des Telefons weiter: Deren Auslöser, deren Videomodus, deren „Wiederholen/Verwenden"-Schirm. Nichts davon war einstellbar, und genau deshalb saß die Geste „kurz = Foto, halten = Video" seit 1.28 auf der **Kachel** im Anhang-Blatt — am einzigen Ort, an den wir herankamen, und dem falschen. Jetzt liegt sie dort, wo man sie sucht: **kurz tippen = Foto, halten = Video, Loslassen beendet.** Dazu ein **eigener Video-Modus** für längere Aufnahmen, in dem ein Tipp startet und der zweite beendet — Halten ist gut für fünf Sekunden, nicht für fünf Minuten
- 🔥 **Die Kachel heißt „Shot" und meint es auch.** Was aus der Kamera kommt, ist voreingestellt ein Shot: einmal ansehen, dann weg. Ein Umschalter oben in der Vorschau macht daraus eine bleibende Aufnahme, und im Sende-Blatt lässt sich das noch einmal umlegen. Umgekehrt hieße es, den häufigeren Fall zu verstecken
- ✍️ **Mehrere Textabschnitte auf einem Foto-Shot, frei in der Höhe.** Bisher gab es genau eine Zeile, fest in der Bildmitte. Jetzt legt ein Tipp einen Abschnitt **genau dort** an, wo der Finger war; ziehen verschiebt ihn nach oben oder unten, und wer einen leer lässt, hat keinen — nichts geschrieben heißt nichts gemeint, dafür braucht es keinen Löschknopf. Bis zu fünf Abschnitte; mehr ist kein Foto mehr, sondern eine Wand. Wie zuvor werden sie **in die Bildpunkte gerechnet**, bevor verschlüsselt wird: Der Text verbrennt mit dem Shot, weil er das Bild IST — eine Bildunterschrift bliebe als Text im Verlauf stehen und erzählte weiter, was der Shot nicht weitererzählen soll. Weiterhin nur Fotos: Ein Video zu beschriften hieße, es neu zu kodieren, Minuten Rechenzeit für eine Zeile Text

### Changed
- ⏹️ **Kein Bestätigungsschirm mehr zwischen Auslösen und Senden.** Die Kamera-App fragte nach jeder Aufnahme „Wiederholen oder Verwenden?" — ein Schirm, der nichts kann, was die Vorschau danach nicht besser kann. Ausgelöst heißt jetzt: Vorschau, Text, senden
- 🎛️ **Die Anhang-Kacheln tun wieder je genau eine Sache.** Die zweite Geste auf der Kamera-Kachel ist ersatzlos weg, samt ihrem Hinweis „halten: Video". Eine Geste, die nur auf einer von sechs Kacheln etwas bedeutet, lernt niemand — sie war ein Notbehelf und ist als solcher aufgelöst

### Fixed
- 🔄 **Beim Halten des Auslösers kippte die Vorschau um 90 Grad.** Das Telefon lag aufrecht, die geschriebene Datei war die ganze Zeit richtig — nur das Bild auf dem Schirm lag quer, und zwar erst ab dem Moment, in dem die Aufnahme lief. Am Gerät nachgemessen: Sämtliche Lagewerte standen währenddessen auf „aufrecht", die Rechnung ergab folgerichtig keine Drehung. Die Ursache liegt tiefer — **Android dreht die Vorschau selbst**, sobald der Videorekorder angehängt wird; auf iPhones passiert das nicht, dort war nie etwas zu sehen. Die Vorschau dreht jetzt genau so weit zurück, und ausschließlich, solange aufgenommen wird
- 🫧 **Der Anmeldeschirm zeigte ein fremdes Symbol.** Dort stand die Sprechblase aus dem Material-Zeichensatz, nicht unsere. Jetzt steht dort das Logo — ohne die Kachel drumherum, aber mit einer weichen Kante auf hellen Themen: Die Blase ist fast weiß, sonst bliebe auf „beach", „sakura" oder „paper" nur das Augenpaar sichtbar

## [1.28.0] - 2026-08-31

### Added
- 🪦 **Rund 285 Emoji, die es im Picker schlicht nicht gab.** Der Grabstein war keine Ausnahme: Dem verwendeten Paket fehlen gegen den Unicode-Bestand etwa 300 Emoji — die neuen Herzfarben, 🫀, 🥲, 🥱, die geschlechtsneutralen Berufe 🧑‍⚕️🧑‍💻 und vieles mehr. Ein Paket-Update behebt das nicht, die neueste Fassung hat dieselben Löcher. Nachgetragen wird jetzt selbst, aus den Daten von Unicode, mit **deutschen und englischen Suchbegriffen** — und jedes nachgetragene Emoji steht dort, wo man es sucht (🪦 direkt hinter ⚰️), nicht hinten angehängt. Was noch keine Schrift kennt, bleibt bewusst draußen: ein leeres Kästchen ist schlechter als ein fehlendes Emoji
- 🔍 **Eine Suche im Emoji-Picker.** Sie war die ganze Zeit im Paket vorhanden — ihr Knopf saß nur in einer unteren Leiste, die wir wegen der dort mitgelieferten Rücktaste komplett abgeschaltet hatten. Jetzt sitzt sie fest in der linken Ecke der Kopfzeile, und gesucht wird in der eingestellten Sprache: „grab" findet den Grabstein, „headstone" ebenso
- ✋ **Ein Hautton für das ganze Raster.** Bisher ging das nur pro Emoji über langes Drücken und galt für genau diesen einen Griff — wer 👍 in seinem Hautton schicken wollte, drückte jedes Mal lang. Die Wahl steht jetzt rechts in der Kopfzeile — als **neutraler Farbkreis**, nicht als Hand: Eine Hand sieht in einem Raster voller Emoji aus wie eines, das man antippt, um es zu schicken. Der Ton gilt für alle Emoji und bleibt über Neustarts. Voreingestellt ist **keiner**: Ein Hautton ist eine Aussage über die eigene Person und wird niemandem zugewiesen. Langes Drücken bleibt für den Einzelfall

### Changed
- 🎨 **Neue Kopfzeile im Emoji-Picker.** Links fest Suche und Verlauf, rechts fest der Hautton, dazwischen scrollen die Kategorien — **unter den Ecken hindurch**, die dafür milchig hinterlegt sind. Ein Icon, das darunter wegtaucht, verschwindet allmählich statt an einer harten Kante abzureißen: Man sieht, dass die Reihe weitergeht, und die festen Knöpfe bleiben trotzdem lesbar. Die Treffer der Suche liegen jetzt im gewohnten Raster statt in einem schmalen Band, durch das man waagrecht scrollen musste

### Fixed
- 🧾 **In der Suche standen bei Fotos und Shots rohe Umschläge.** Zwei Fehler in einem: Die Zeile zeigte `{"_chattr_media":1,…}` statt eines lesbaren Satzes — und der Treffer war oft gar keiner, weil „jpg", „items" oder der Dateiname in **jedem** Medien-Umschlag stehen. Ab jetzt gilt: Ein Foto ist nur über seine **Bildunterschrift** auffindbar, und angezeigt wird auch nur sie; hat es keine, taucht es in der Suche nicht auf (dafür ist der Medien-Tab da). Ein **Shot** hat nie Text — sonst wäre eine Trefferliste ein zweiter Weg an seinem Versprechen vorbei, und sein Umschlag trägt Pfad und Medienschlüssel. Dieselbe Regel entscheidet über Treffer *und* Anzeige, damit nie wieder ein Treffer ohne sichtbaren Grund dasteht
- ⌨️ **Die Tastatur legte sich über die Emoji-Suche.** Suchfeld und Treffer verschwanden dahinter — und zwar immer, nicht gelegentlich: Die Suche setzt den Schreibfokus beim Öffnen selbst, die Tastatur kommt also mit. Das Blatt weicht ihr jetzt aus und wird dabei **halb so hoch**: Volles Blatt plus Tastatur ließen vom Chat fast nichts übrig, während die Trefferliste darin halb leer stand
- ⬆️ **Ein nie geöffneter Shot zog den Chat bei jedem Öffnen zu sich hoch.** Er galt dauerhaft als ungelesen — zu Recht, denn ein Shot bekommt seine Lesemarke erst beim Öffnen: Dieselbe Marke startet die 24-Stunden-Uhr auf beiden Seiten, ein früherer Stempel ließe die Blase verschwinden, bevor sie jemand gesehen hat. Nur wurde daraus auch abgeleitet, *wo das Lesen aufgehört hat*, und damit war der Shot ein dauerhafter Anker. Der Chat öffnet jetzt dort, wo er zuletzt offen war — was davor liegt, hat man nachweislich vor sich gehabt
- ✨ **Das Sprung-Leuchten reichte über die Nachbarblasen.** `spreadRadius` bläht die Schattenfläche **vor** dem Weichzeichnen auf, seine Wirkung kommt also doppelt an — der Puls leuchtete die Nachbarn mit an, statt auf **eine** Nachricht zu zeigen. Jetzt macht die Weichzeichnung das Leuchten allein
- 🔍 **Ein Treffer der Suche im Chat führte nirgendwohin.** Man sah die Vorschau, konnte sie antippen — und es passierte nichts. Der Tipp springt jetzt zur Nachricht, und zwar auch dann, wenn sie weit oben liegt: Ältere Geschichte wird erst nachgeladen, bis der Treffer da ist, dann pulst er auf. Genau der Weg, den Favoriten und die globale Suche schon nehmen

### Changed
- 📸 **Die Kamera nimmt sofort auf: kurz tippen für ein Foto, halten für ein Video.** Bisher führte ein Tipp auf „Kamera" erst in ein zweites Blatt, das fragte, was es denn werden soll — ein Tipp mehr auf dem Weg zu etwas, das man gerade *jetzt* aufnehmen will, und der Moment ist dann oft vorbei. Der lange Druck steht als Hinweis unter der Beschriftung: Eine Geste, die nirgends geschrieben steht, wäre gegenüber dem Auswahlblatt, das sie ersetzt, ein Rückschritt

## [1.27.2] - 2026-08-28

### Fixed
- 📐 **Die Textzeile auf einem Shot stand links am Rand statt in der Mitte.** Die Vorschau zeigte sie mittig, das gesendete Bild nicht — genau die Abweichung, die diese Leiste eigentlich vermeiden soll: Man tippt gegen eine Vorschau und bekommt etwas anderes

## [1.27.1] - 2026-08-28

### Added
- 📝 **Eine Textzeile auf einem Foto-Shot.** Tipp aufs Bild, schreib etwas, fertig — schwarz hinterlegt, weiße Schrift, quer über die Mitte. Der Satz wird **in die Bildpunkte gerechnet**, bevor verschlüsselt wird, und das ist keine Bequemlichkeit: Ein Shot hat bewusst keine Bildunterschrift, weil die das Bild überlebte. Der Inhalt verbrennt beim Öffnen — eine Unterschrift stünde als Text weiter im Verlauf, wäre durchsuchbar, zitierbar, kopierbar und erzählte genau das weiter, was der Shot nicht weitererzählen soll. Also gibt es keinen zweiten Kanal für Text: Der Satz wird Teil des Fotos und verbrennt mit ihm, weil er es ist. Nachträglich ändern lässt er sich dadurch nicht — bei etwas, das man genau einmal ansieht, gibt es nichts nachzubessern. Nur Fotos; ein Video zu beschriften hieße, es neu zu kodieren

### Fixed
- ⏳ **Ein abgelaufener Shot verschwand erst beim nächsten Betreten des Chats.** Die Blase eines geöffneten Shots geht 24 Stunden später auf beiden Seiten weg — nur hat der Takt, der Selbstzerstörungs-Nachrichten live aus der offenen Ansicht schiebt, gar nicht nach Shots geschaut. Saß man zufällig genau dann im Chat, blieb das Abzeichen stehen. Kein Leck (der Inhalt war längst weg), aber nicht das, was die App zusagt. Die Frage „ist das jetzt fällig?" steht jetzt an **einer** Stelle statt an zweien, und beide Aufräumer stellen dieselbe

## [1.27.0] - 2026-08-28

### Added
- 📉 **Medien wahlweise kleiner verschicken.** Fotos gehen auf 1600 Bildpunkte lange Kante, Videos auf 720p — **freiwillig**, und das ist der Kern der Sache: Standard bleibt die volle Qualität, denn ein Messenger, der ungefragt verkleinert, nimmt eine Entscheidung ab, die niemand von ihm verlangt hat, und man merkt es erst, wenn sich das Bild nicht mehr vergrößern lässt. Zwei Ebenen: eine Vorgabe in den Einstellungen und ein Umschalter im Sende-Sheet, der nur für diesen einen Versand gilt. Verkleinert wird nie „auf Verdacht" — ein Bild unter der Grenze, ein schon sparsames Video und jedes Ergebnis, das nicht kleiner wäre, gehen unverändert raus. Videos nur auf Android und iPhone (dort arbeitet der Kodierer nativ), Fotos überall; der Erklärtext sagt das dazu
- 🔥 **Shots — Fotos und Videos, die sich genau einmal öffnen lassen.** Eine eigene Blase im Verlauf, milchglasartig hinterlegt, damit sie sich vom gemusterten Chat-Hintergrund abhebt: gefüllt heißt „noch da", hohl heißt „schon gesehen", eine Farbe für Foto, eine andere für Video. Ein Tipp, eine Rückfrage, ein Blick — danach ist der Inhalt weg, auch nach einem Neustart. Verbraucht ist er in dem Moment, in dem er auf dem Schirm steht, nicht erst beim Zumachen: Zwischen Sehen und Schließen liegen sonst zu viele Wege hinaus — Zurück-Taste, Wisch-Geste, App abwürgen —, und wer sie einzeln abdichten will, verliert das Versprechen beim ersten, den er übersieht. Schließen geht deshalb auch beiläufig: nach unten wischen, wie überall sonst im Vollbild. Der eigentliche Brand ist nicht das Löschen der Datei (das darf ein Empfänger gar nicht), sondern dass der **Schlüssel** aus der lokalen Kopie verschwindet: Ohne ihn schließt niemand mehr auf, und der Server räumt den Rest wie gewohnt weg. **Als gelesen zählt erst das Öffnen**, nicht das Sehen der Blase — dieselbe Marke startet auf beiden Seiten die Uhr, nach 24 Stunden verschwindet auch die Blase, bei Absender und Empfänger. Bis dahin kann der **Absender** nachsehen, was er geschickt hat — seine eigene Blase lässt sich antippen, so oft er will; verbraucht wird dabei nichts, denn seine Kopie stirbt an der Uhr, nicht am Blick. Weiterleiten, Anheften, Antworten und Kopieren gibt es dafür nicht: Weiterleiten würde eine zweite, dauerhafte Kopie anlegen — das Gegenteil des Versprechens. Während des Ansehens sperrt die App Bildschirmaufnahmen, soweit das Gerät das zulässt; sie behauptet nicht, es überall zu können, sondern schreibt es hin
- 🧱 **Ein Shot an eine ältere App zeigt dort die Karte „neuere App-Version nötig" — nie das Bild.** Dafür gibt es eine neue Umschlag-Version. Ein zusätzliches Feld hätte nicht gereicht: Unbekannte Felder werden überall stillschweigend übergangen, und ein Client, der die Einmal-Regel übergeht, bricht sie, ohne dass es jemand merkt. Die Nachricht ist nicht verloren — sie kommt nach dem Update

### Fixed
- 📏 **Die Warnung „Große Datei" nannte die Größe vor dem Verkleinern.** Bei aktivem Schalter stand dort die Größe des Originals, obwohl deutlich weniger hochgeladen wird. Die Zahl bleibt (etwas anderes wäre geraten, solange das Video nicht durch den Kodierer war), aber der Text sagt jetzt dazu, dass verkleinert wird — und warnt vor dem, was hier wirklich dauert: nicht das Hochladen, sondern das Verkleinern selbst

### Changed
- ⚡ **Videos ruckeln nicht mehr — die Ursache lag woanders als vermutet.** Android hat Video bisher vollständig auf dem Hauptprozessor dekodiert: Der Schalter dafür stammte aus einem Notbehelf für Linux und galt seither pauschal für alles außer dem iPhone. Bei einem 4K-Clip vom Telefon reicht das nicht. Jetzt macht es der Video-Baustein des Geräts
- ▶️ **Große Videos spielen, während sie laden.** Vorher wurde erst alles geladen, entschlüsselt und auf die Platte geschrieben — bei einem 82-MB-Video vier Sekunden Stillstand, bevor überhaupt etwas zu sehen war. Jetzt beginnt die Wiedergabe nach dem **ersten** Block. Das geht, weil ein großes Video in Blöcken liegt, von denen jeder seine eigene Prüfsumme trägt: Ein Block lässt sich einzeln prüfen, und was geprüft ist, darf laufen. Eine kleine Datei ist dagegen ein einziger Geheimtext mit einer Prüfsumme ganz am Ende — die wird weiterhin erst vollständig geprüft und dann gezeigt, denn früher anzufangen hieße, Ungeprüftes anzuzeigen. Nebenbei: Dabei entsteht **keine entschlüsselte Videodatei mehr auf dem Gerät**; bisher lagen dort bis zum Schließen des Players bis zu 400 MB Klartext
- ⏩ **Und sie laden schneller.** Die Blöcke wurden einer nach dem anderen geholt, jeder erst nach dem vorigen — bei einem 400-MB-Video rund 67 Wartezeiten hintereinander. Jetzt sind mehrere gleichzeitig unterwegs, kommen aber weiterhin streng der Reihe nach an
- 📺 **Verlinkte Videos puffern mehr.** Bei ihnen kommt der Strom wirklich aus dem Netz — dort hilft ein größerer Puffer, bei Chat-Videos läge die Datei ohnehin längst auf der Platte

## [1.26.2] - 2026-08-27

### Added
- ⚡ **Eine Person als wichtig markieren — ihre Nachrichten kommen auf dem iPhone durch den Fokus.** Markiert wird eine *Person*, kein Chat: So gilt es auch, wenn dieselbe Person in einer Gruppe schreibt, und das ist der häufigere Fall, in dem man eine Stimme aus dem Rauschen heben will. Die Markierung bleibt **auf dem Gerät**, und das ist keine Bequemlichkeit: Der Server könnte die Dringlichkeit selbst in die Benachrichtigung schreiben — dann hielte er eine Rangliste deiner Beziehungen, an dein Konto gebunden und aus einer Tabelle ablesbar. Er behandelt weiterhin alle gleich; die Unterscheidung fällt erst auf dem Gerät, in der Erweiterung, die die Nachricht ohnehin entschlüsselt. Preis, ehrlich benannt: Sie wandert nicht auf ein zweites Gerät. Den Schalter gibt es **nur auf iOS** — auf Android steht der Kanal ohnehin schon auf hoher Wichtigkeit, im Browser existiert die Stufe nicht, und ein Schalter, der nichts tut, ist schlimmer als keiner
- ↕️ **Die Agenten-Zeile lässt sich wieder wegräumen.** Bisher deckte ein Ziehen nach unten sie auf, und danach blieb sie bis zum nächsten App-Start stehen — die Geste war eine Tür ohne Klinke auf der Rückseite. Dasselbe Ziehen versteckt sie jetzt wieder. Unverändert: Solange ein Agent etwas Ungelesenes hat, bleibt die Zeile — sie ist dann die einzige Erklärung für die Zahl am App-Symbol

### Fixed
- 🔇 **Das Vorhören der Benachrichtigungstöne blieb im Lautlos-Modus stumm.** Ein Abspielknopf, der nichts tut, sieht kaputt aus, nicht rücksichtsvoll — und Apples eigener Klingeltonwähler hält es genauso. Vorhören und eintreffende Meldung sind jetzt getrennt: Der Ton, um den du gebeten hast, spielt; der, den die App von sich aus abspielt, gehorcht weiterhin dem Schalter
- 📐 **„Wie in den Einstellungen" und „Stumm" standen schief.** Beide Zeilen samt Symbol rutschten in der Ton-Auswahl um 24 Punkte nach links, weil ein Abspielknopf mehr Platz belegt als ein einfaches Symbol. Und das Zahnrad war auf dunklem Grund kaum zu sehen
- 🔔 **„Stumm schalten" meldete „An", wenn nichts stumm war.** Unter diesem Titel las sich das wie „stummgeschaltet: an" — jetzt steht dort „Aus"

## [1.26.1] - 2026-08-25

### Added
- 🔔 **Benachrichtigungen pro Chat haben einen eigenen Bildschirm.** Vorher führten zwei Wege zu genau einer Handlung: Der Knopf unter dem Gruppenbild und die Zeile „Benachrichtigungen" riefen denselben Code auf und konnten beide nur stumm schalten. Zwei Einstiege für eine Sache sind kein Komfort — sie versprechen, dahinter läge Verschiedenes. Der Knopf oben bleibt als **Abkürzung**: Er führt in den neuen Bildschirm und öffnet dort gleich die Dauer-Auswahl
- 🎵 **Ein eigener Ton je Chat.** Aus demselben Katalog wie die allgemeine Einstellung, mit „wie in den Einstellungen" als Rückfall und einer stillen Wahl für einen einzelnen Chat. Die Auswahl bleibt **auf dem Gerät** — dass ein Chat dir einen eigenen Klang wert ist, sagt etwas über ihn aus, und das geht den Server nichts an. Sie gilt für die Einblendung bei offener App; die Systembenachrichtigung nutzt weiter den Ton des Geräts, und der Bildschirm schreibt das dazu, statt mehr zu versprechen

### Changed
- 👥 **Die Mitglieder stehen jetzt unter den Einstellungen.** Der Abschnitt wächst: Fünf Menschen sind gedeckelt, die Agenten darunter nicht — in einem Projektchat schob er alles Einstellbare unter den Bildschirmrand, und man musste an der ganzen Liste vorbei, um stumm zu schalten. Verlassen und Löschen bleiben das Ende; was sich nicht rückgängig machen lässt, gehört unter alles andere

### Fixed
- 🤖 **Einem Agenten wird keine Chat-Anfrage mehr angeboten.** Die neue Zeile kannte den Unterschied nicht, und der Agent kann gar nicht zustimmen — er kennt nur Gruppen-Beitritte. Die Anfrage wäre für immer liegengeblieben, während dort dauerhaft „Anfrage gesendet" stand

## [1.26.0] - 2026-08-25

### Added
- 🤝 **Chat-Anfragen: niemand schreibt dir, ohne dass du zugestimmt hast.** Bisher konnte jeder, der deine Kennung kannte, einfach einen 1:1-Chat mit dir aufmachen — und in einer gemeinsamen Gruppe kennt sie jedes Mitglied. Aufgefallen ist das nie, weil es keinen Knopf dafür gab; die Tür stand trotzdem offen. Jetzt entsteht eine Unterhaltung nur noch, wenn **beide** Seiten zugestimmt haben. **Ablehnen ist still:** Wer abgelehnt wird, erfährt es nicht — für ihn bleibt die Anfrage „gesendet", und ein zweiter Versuch ändert nichts. Das ist Absicht: Eine Absage, die man sieht, lädt dazu ein, einen anderen Weg zu suchen. Und eine Anfrage trägt **keinen Text**, nur Name und Bild — sonst wäre sie selbst der Kanal, den die Blockierung schließen soll
- 👤 **Von der Gruppe zur Person.** Ein Tipp auf ein Mitglied im Gruppenchat führt jetzt zu **dieser Person**: Profil ansehen, Sicherheitsnummer vergleichen, Chat öffnen — oder eben anfragen. Vorher führte derselbe Tipp bei Admins ins Verwalten-Menü und bei allen anderen nirgendwohin, und der Weg zum Profil war ein Avatar, den man kennen musste. Verwalten (befördern, entfernen) liegt jetzt ausschließlich hinter den drei Punkten rechts
- 🔑 **Einmal verifiziert gilt überall.** Die Bestätigung einer Sicherheitsnummer hing bisher an der Kennung, unter der man jemanden gerade sah. Sie hängt jetzt an der Person selbst — wer in einer Gruppe verifiziert wurde, ist es im frisch geöffneten Einzelchat sofort auch
- 🖼️ **„Medien & Dateien" pro Chat.** Ein Verzeichnis dessen, was in diesem Verlauf geteilt wurde — Art, Name, Größe, Datum, Absender; ein Tipp springt zur Nachricht. Bewusst **kein Kachel-Album**, und der Grund ist ehrlicher als eine Ausrede: Chattr behält Medien nirgends dauerhaft. Jedes Anzeigen lädt sie neu vom Server, und der Server löscht sie, sobald alle Empfänger sie geladen haben. Ein Album voller Vorschaubilder würde also überwiegend Bilder versprechen, die es nicht mehr gibt. Was vermutlich fort ist, steht ausgegraut da und sagt es
- ⭐ **Favoriten dieses Chats.** Bisher gab es die Favoriten nur gesammelt über alle Unterhaltungen; jetzt auch dort, wo sie entstanden sind

### Changed
- 📷 **Auch der QR-Scan fragt an, statt sofort einen Chat anzulegen.** Es gibt bewusst keine Ausnahme: Ob wirklich gescannt wurde, kann der Server nicht nachprüfen — eine Ausnahme für den Scan wäre eine Ausnahme für jeden, der behauptet zu scannen. Bei zwei Menschen, die nebeneinanderstehen, kostet das einen Tipp
- ✅ **Bestehende Unterhaltungen bleiben, wie sie sind.** Alle vorhandenen 1:1-Chats gelten als beiderseits erlaubt und wurden beim Umstellen entsprechend eingetragen — niemand muss etwas nachträglich bestätigen
- ℹ️ **Die Chat-Info ist neu gebaut.** Sie war über ein Jahr gewachsen und stapelte am Ende neun gleich aussehende Karten — Bild, Name, QR-Code, Selbstzerstörung, Anfragen, Einladungen, Mitglieder. Wenn alles gleich aussieht, ist nichts wichtiger als der Rest: Worum es in der Gruppe geht, stand optisch gleichauf mit dem QR-Code. Jetzt trägt oben ein Kopfbereich Bild, Name, „23 Mitglieder · erstellt am …" und die Beschreibung, darunter kommen ruhige, betitelte Abschnitte
- ✏️ **Gruppen bearbeiten hat einen eigenen Bildschirm.** Vorher trug die Info-Ansicht für Admins pro Feld einen Stift und im Bearbeiten-Zustand Haken und Kreuz — wer nur nachsehen wollte, wie die Gruppe heißt, sah vor allem Werkzeug. Die Info sieht jetzt für alle gleich aus
- 🔔 **Einstellungen zeigen ihren Zustand.** Ob ein Chat stumm ist, stand nur im Menü, aus dem man es setzt — man musste es öffnen, um zu sehen, ob die Einstellung wirkt. Jetzt steht „Stumm bis Fr, 18:00" an der Zeile selbst
- 🛡️ **Der Vertrauens-Status steht jetzt überall gleich.** Ob neben einem Namen ein Schild erschien, hing davon ab, über welchen Weg man in die Mitgliederliste gekommen war — in der Info-Ansicht fehlte es ganz. Dass ausgerechnet die Vertrauensanzeige vom Weg abhing, war der eigentliche Fehler
- 👥 **Die Mitgliederliste in der Info ist gekürzt.** Vorher standen in einer Gruppe mit dreißig Leuten dreißig Zeilen da — und darunter ein Knopf „Alle 30 anzeigen", der dieselben dreißig nochmal zeigte
- 🔒 **Profilbilder liegen nicht mehr offen.** Der Zugriff war zweigeteilt, und beide Hälften waren nötig: Das *Auflisten* der Ablage verlangt seit 1.24 eine Anmeldung — damit war die Liste der Konten weg. Der *direkte Abruf* eines bekannten Pfades ging aber weiter ohne Konto, denn ein öffentlicher Speicher liefert an der Zugriffsprüfung vorbei aus. Nachgemessen kurz vor der Umstellung: derselbe anonyme Aufruf, der beim Auflisten nichts mehr bekam, lieferte ein 472 KB großes Bild. Jetzt führt der einzige Weg über eine **kurzlebige, signierte Adresse**. Gewartet wurde damit, bis kein Gerät mehr im Umlauf war, das die alte Adresse baut — sonst hätten genau diese Leute überall nur noch Initialen gesehen
- 📡 **Der alte öffentliche Benachrichtigungskanal ist abgeschaltet.** Seit August liefen zwei parallel: der private, der nur seinem eigenen Konto gehört, und daneben ein offener als Rückfallebene für ältere Installationen. Den offenen konnte jeder abonnieren, der sich ein Konto anlegte — Inhalte blieben verschlüsselt, aber **wer wann mit wem** war live mitlesbar, samt Antwortbeziehungen und Reaktionen. Ein Gerät, das seit Monaten nicht aktualisiert hat, verliert dadurch die sofortige Zustellung, nicht die Nachrichten: Sie kommen beim nächsten Öffnen nach

### Fixed
- ⏳ **Die Web-App blieb beim ersten Besuch für immer im Ladebild stehen.** Beim Start fragt sie nach der Erlaubnis für Benachrichtigungen — und diese Frage **antwortet nicht**, solange der Browser-Dialog offen ist. Da der Start darauf wartete, kam die App nie zum Vorschein: kein Fehler, keine Meldung, sie war schlicht nie fertig. Wer den Dialog früher schon einmal beantwortet hatte, merkte nichts, weshalb es lange nach einem Problem einer einzelnen Umgebung aussah. Jetzt hat dieser Schritt eine Frist; danach startet die App eben ohne Push weiter
- 🎯 **Der Sprung aus Favoriten, Suche und Medien-Index öffnet den Chat nicht mehr doppelt.** Ein Tipp auf einen Treffer schob eine **zweite** Ansicht desselben Chats obendrauf — sichtbar am doppelten Zurück, spürbar daran, dass der Sprung am Ende hängenblieb: Beide Ansichten horchen auf dasselbe Signal, und der Sprung-Lauf lässt nur einen Durchlauf gleichzeitig zu, also traten sie sich gegenseitig ab. Liegt der Chat schon offen, wird jetzt dorthin zurückgeräumt statt neu geöffnet
- ▶️ **Direkt verlinkte Videos spielen jetzt in der Blase.** Wer eine `.mp4` verschickte — etwa aus dem eigenen CMS —, bekam beim Gegenüber nur den nackten Link. Solche Adressen liefern kein HTML und damit keine Vorschau-Angaben, an denen die Karte sonst hängt; die Art steht aber schon in der Adresse. Video-Links landen jetzt im selben Spieler wie Reddit-Videos, samt Bild-in-Bild und Andocken, Bild-Links zeigen das Bild. Geladen wird **erst beim Antippen**: Die Datei liegt auf einem fremden Server, und ein automatischer Abruf würde IP und Zeitpunkt preisgeben, ohne dass jemand das Video sehen wollte
- ⏱️ **YouTube-Links beginnen dort, wo sie sollen.** Der Zeitstempel im Link wurde nie gelesen — wer „ab Minute 3" teilte, bekam beim Gegenüber den Anfang. Jetzt werden alle Formen verstanden, die YouTube erzeugt (`?t=90`, `?t=90s`, `?t=1m30s`, `?t=1h2m3s`, `?start=`, die alte `#t=`-Form) und zusätzlich `1:30`/`1:02:03`, weil Links durch Notizen und andere Werkzeuge wandern
- ✨ **Der Sprung zu einer Nachricht leuchtet nicht mehr die Nachbarn mit an.** Wer aus den Favoriten oder der Suche zu einer Nachricht springt, sieht sie kurz aufleuchten — nur reichte der Schein weiter als der Abstand zwischen zwei Blasen, sodass am Ende drei Nachrichten glühten und keine davon die gemeinte war. Ursache war die Ausdehnung des Scheins, die die Fläche **vor** dem Weichzeichnen aufbläht. Jetzt zeigt der Puls wieder auf genau eine Nachricht

## [1.25.2] - 2026-08-20

### Added
- 🗑️ **Eine fremde Nachricht lässt sich jetzt vom eigenen Gerät entfernen.** Bisher gab es Löschen nur für die eigenen — was fremd war, blieb stehen, auch das Bild, das man nie sehen wollte. Der Eintrag heißt jetzt ausdrücklich **„Nur für mich"** und fasst den Server nicht an: Beim Gegenüber ändert sich nichts, und es erfährt auch nichts davon. Bei eigenen Nachrichten stehen beide Wege nebeneinander — „für alle" und „nur für mich" —, damit die Reichweite eine Entscheidung ist und keine Nebenwirkung. Zurückkommen kann eine so entfernte Nachricht nicht: Der Aufhol-Lauf holt nur, was das Gerät noch nie hatte
- ❓ **Vor dem Löschen kommt eine Rückfrage.** Der Eintrag lag direkt unter „Bearbeiten", und ein Fehlgriff war endgültig — bei „für alle" auch beim Gegenüber

### Fixed
- 🔕 **Nach dem Öffnen der App regnete es Banner.** Was liegen geblieben war, wurde beim Start nachgeholt — und jede nachgeholte Nachricht meldete sich einzeln, als käme sie gerade erst an. Nachgeholtes ist jetzt still: Es landet im Verlauf und im Ungelesen-Zähler, aber es klopft nicht. Die eine Benachrichtigung, die vorher schon aufs Sperrbildschirm kam, bleibt — sie hat ihren Zweck ja erfüllt
- 🙋 **Ein Banner aus einem 1:1-Chat hieß „Chat".** Diese Unterhaltungen tragen keinen Namen; angezeigt wird jetzt der Name der Gegenstelle, wie überall sonst in der App
- 📱 **Das Menü einer Nachricht war unten abgeschnitten.** Auf kürzeren iPhones lag „Löschen" auf der Kante über dem Home-Indikator und ließ sich kaum treffen. Das Menü scrollt jetzt und hält Abstand nach unten
- ↕️ **Bei fremden Nachrichten stand „Melden" unter „Löschen".** Am unteren Rand, wo der Daumen beim Scrollen aufsetzt, lag damit die einzige Aktion, die etwas wegnimmt. Löschen steht jetzt zuletzt

### Changed
- 🔎 **Das Teilen-Menü von iOS zählte nur die halbe Unterhaltung.** Wer dir schreibt, brachte deinen Chat dort nicht nach oben — vorgeschlagen wurde nur, wem **du** zuletzt geschrieben hattest. Ein Chat, in dem der andere mehr erzählt als du, rutschte deshalb hinter Fremdes. Jetzt zählt auch das Lesen: Öffnest du einen Chat mit Ungelesenem, wird das als Kontakt gewertet — einmal je Leserunde, nicht je Nachricht, damit zwanzig Nachrichten am Stück nicht ein echtes Hin und Her überholen. Ein stiller Chat, den du nur durchklickst, zählt nicht mit, und **Empfangen allein** zählt weiterhin nicht: Sonst stünden Fremde und Werbung im Vorschlag, ohne dass du je hingesehen hast

## [1.25.1] - 2026-08-14

### Fixed
- 🆕 **Eine Nachricht von einer neueren App-Version verschwand bisher spurlos.** Konnte dein Gerät sie nicht öffnen, wurde sie nicht gespeichert und war für dich einfach nicht da — ohne Platzhalter, ohne Hinweis. An ihrer Stelle steht jetzt eine Karte „Neuere App-Version nötig", an der richtigen Stelle im Verlauf, mit Zeit und Absender. **Die Nachricht ist nicht verloren:** Der Server behält seine Kopie, und sobald du aktualisiert hast, erscheint der echte Inhalt von selbst an dieser Stelle. Gebaut, bevor es überhaupt eine neuere Version gibt — nachrüsten ließe es sich nicht, denn eine App, die den Hinweis noch nicht kennt, kann ihn auch nicht zeigen

## [1.25.0] - 2026-08-14

### Changed
- 📏 **Nachrichten verraten ihre Länge nicht mehr.** Der Inhalt war immer verschlüsselt — die **Länge** nicht: Das Verfahren erzeugt einen Geheimtext, der exakt so lang ist wie der Klartext, und die gespeicherte Zeile ließ sich ausmessen. Das ist mehr, als es klingt: Eine Zwei-Zeichen-Antwort auf eine Frage ist so gut wie sicher „ja" oder „ok", und wo nur wenige Nachrichten in Frage kommen — eine von fünf Adressen, ein Name, eine Uhrzeit — schneidet die Länge oft auf eine einzige Möglichkeit zu. Jede Nachricht wird jetzt vor dem Speichern auf eine feste Stufe aufgefüllt, sodass viele verschiedene Texte dieselbe Größe haben. Das gilt auch für Hinweise wie „… ist beigetreten", deren Größe das Ereignis bisher praktisch benannt hat. **Was es nicht verbirgt, ehrlich gesagt:** die ungefähre Länge bleibt sichtbar, und über Zeitpunkt und Häufigkeit sagt es nichts — dass zwei Leute abends geschrieben haben, ist so sichtbar wie vorher. Ein eingelöster Punkt der öffentlichen Roadmap

## [1.24.0] - 2026-08-14

### Fixed
- 🗑️ **Beim Löschen eines Kontos blieb sein Profilbild auf dem Server liegen.** Alles andere verschwand — Nachrichten, Mitgliedschaften, Geräte —, nur die Bilddatei hing an keiner dieser Ketten und wurde deshalb nie mitgenommen. Da die Bild-Ablage öffentlich lesbar ist, blieb sie damit auch weiterhin für jeden abrufbar. Jetzt gehen die Bilder mit: das eigene, und das einer Gruppe, die mit dem Konto verschwindet. Eine Gruppe, die **weiterbesteht**, behält ihr Bild — sie gehört den anderen, die drin geblieben sind

### Changed
- 🔢 **Dein Gerät nennt beim Anmelden für Benachrichtigungen jetzt die App-Version.** Nur die Nummer, kein Gerätemodell und kein Betriebssystem-Stand. Der Grund ist unspektakulär, aber wichtig: Manche Verbesserungen am Server dürfen erst greifen, wenn keine alte App-Version mehr unterwegs ist — sonst verlieren genau diese Geräte ihre Bilder oder ihre Benachrichtigungen. Bisher war das eine Schätzung; jetzt ist es eine Auskunft

## [1.23.1] - 2026-08-13

### Fixed
- 📐 **Die ⓘ-Symbole in den Privatsphäre-Einstellungen standen nicht untereinander.** „Lesebestätigungen senden" passt in eine Zeile, die drei Einträge darunter brechen um — dadurch klebte das erste Symbol am Textende, während die anderen am Rand saßen. Jetzt bilden sie eine Spalte, unabhängig davon, wie lang eine Beschriftung ist

## [1.23.0] - 2026-08-13

### Added
- 💬 **Ein Ort lässt sich jetzt kommentieren.** Zwischen „Ort auswählen" und „Senden" steht ein Schritt, der die **fertige Karte** zeigt — genau die, die beim Empfänger ankommt — und darunter ein Feld für eine Zeile dazu („20:30 dort?"). Leer lassen geht: der Kommentar ist ein Angebot, keine Pflicht. Er reist **in derselben Nachricht** wie der Ort, damit er nie ohne ihn ankommt oder von ihm wegscrollt. Gilt genauso für geteilte Termine

## [1.22.3] - 2026-08-13

### Fixed
- 🗺️ **Ein geteilter Ort öffnete auf dem iPhone die OpenStreetMap-Webseite** statt Karten. Die App reicht den Ort über ein neutrales Format weiter, damit er in *deiner* Karten-App landet — iOS kennt dieses Format aber gar nicht, und der Versuch fiel still auf die Webseite zurück. Auf Apple-Geräten wird jetzt zuerst Karten angesprochen; das neutrale Format bleibt als zweiter Versuch stehen, damit eine installierte Fremd-App es weiterhin beanspruchen kann, und die Webseite ist nur noch der letzte Ausweg

## [1.22.2] - 2026-08-13

### Fixed
- 📍 **Ein Ort aus Apple Karten kam als roher Datensatz an** statt als Karte. Die iOS-Freigabe liest den Ort seit dem neuen Baustein selbst aus — mit Name und Adresse, die kein Link mitbringt — und hängt oft **zusätzlich** einen `maps.apple`-Kurzlink an. Beides zusammen war kein lesbarer Datensatz mehr, und die App fiel auf den Link zurück oder gar nicht: Name und Adresse waren weg, im schlechteren Fall stand der Datensatz im Klartext in der Nachricht. Jetzt wird ein bereits fertiger Ort erkannt und unverändert übernommen

## [1.22.1] - 2026-08-13

### Fixed
- 🔢 **Der Ungelesen-Zähler blieb leer** — in jedem Chat, auch in Agenten-Chats. Kein Anzeigefehler: Seit der Zähler auf dem Gerät läuft, zählt er nur, was das Gerät **hat**, und Nachrichten wurden ausschließlich für den gerade geöffneten Chat abgeholt. Alles, was ankam, während die App zu war, blieb auf dem Server liegen — unsichtbar für den Zähler — und beim Öffnen des Chats wanderte die Lesemarke im selben Zug darüber hinweg. Jetzt werden beim Start und nach jeder Unterbrechung alle noch nicht zugestellten Nachrichten **chatübergreifend** geholt, auf demselben Weg wie eine live eintreffende: entschlüsseln, erst lokal speichern, erst dann als empfangen melden

## [1.22.0] - 2026-08-13

### Added
- ↩️ **Reaktionen lassen sich zurücknehmen.** Bisher kam eine Reaktion immer dazu; weg ging sie nur, wenn man *dasselbe* Emoji ein zweites Mal wählte — das funktionierte, stand aber nirgends dran, und ein Emoji aus dem Picker musste man dafür erst wiederfinden. Jetzt gibt es einen ausdrücklichen Eintrag im Menü der Nachricht, der auch zeigt, **was** verschwindet
- 👆 **In der Reaktions-Liste lässt sich die eigene Zeile wegwischen** — oder über den Knopf daneben entfernen. Nur die eigene: fremde Zeilen tragen weder Geste noch Knopf, damit die Wischbewegung nicht auf der falschen Zeile ins Leere greift

### Changed
- 🖼️ **Profilbilder liegen jetzt in Formaten, die jedes Gerät anzeigen kann.** Das Format wird aus den Bilddaten selbst gelesen statt aus der Dateiendung — bisher landeten iPhone-Fotos als HEIC in der Ablage, ausgezeichnet als JPEG, und blieben damit auf Android, Linux und in jedem Browser **unsichtbar**. Auf dem Handy wandelt die Auswahl automatisch um; sonst wird ein Format, das wir nicht anzeigen können, mit Begründung abgelehnt
- 📉 **Große Profilbilder werden verkleinert** (ein Bild in der Ablage war 3,1 MB — geladen von jedem Betrachter, immer wieder). PNG bleibt PNG, damit ein freigestelltes Bild seinen transparenten Hintergrund behält; ein GIF bleibt unangetastet, sonst verlöre es seine Animation
- 🔑 **Profilbilder werden über kurzlebige, signierte Adressen geladen** statt über dauerhaft offene Pfade — der erste Teil einer Roadmap-Zusage. Der zweite Teil (die Ablage selbst schließen) folgt, sobald genug Geräte aktualisiert haben

### Fixed
- ✏️ **Einladungen, Orte und Termine lassen sich nicht mehr „bearbeiten".** Diese Karten reisen als Textnachricht mit strukturiertem Inhalt, bekamen deshalb jede Text-Aktion — und im Eingabefeld stand dann der rohe Datensatz. Gespeichert hätte das die Karte für **alle** Empfänger zerstört. Antworten und Weiterleiten bleiben

## [1.21.0] - 2026-08-13

### Added
- 📍 **Orte teilen.** Suchst du einen Ort in deiner Karten-App und teilst ihn nach Chattr, kommt er als **Karte** an statt als Link-Wüste: Name, Adresse, Koordinaten — und ein Tippen öffnet ihn in *deiner* Karten-App. **Ausdrücklich kein Live-Standort**: geteilt wird eine Markierung, die jemand bewusst ausgewählt hat, genau wie eine Adresse im Text. Die Nachricht kann gar nichts anderes enthalten — Zeitpunkt, Genauigkeit oder Richtung lassen sich in ihr nicht ausdrücken, damit sich aus mehreren davon niemals ein Bewegungsprofil zusammensetzen lässt
- 🗺️ **Die Ortskarte lädt bewusst kein Kartenbild.** Eine Vorschaukachel müsste bei jedem Empfänger von einem Kartendienst geholt werden — und der erführe damit die Koordinaten und die IP jedes Einzelnen. Aus einer Nachricht, die der Server nicht lesen kann, würde so eine Anfrage, die ein Dritter mitliest. Die Karte zeigt deshalb, was sie weiß, und übergibt beim Tippen an die Karten-App
- 📅 **Termine teilen** — teilst du eine Kalenderdatei (`.ics`) in einen Chat, erscheint eine Termin-Karte mit Titel, Datum und Ort. Ganztägige Termine zeigen **keine Uhrzeit** (statt „00:00"), und ein mehrtägiger Termin nennt seinen **letzten** Tag statt des Tages danach. Die Karte ist reine Anzeige — sie schreibt in niemandes Kalender

### Changed
- 😀 **Das Reaktions-Emoji im Push ist jetzt voreingestellt an** (kam in 1.20.0 mit „aus"). Die Abwägung ist unverändert — das Emoji muss über Google bzw. Apple laufen, um in der Benachrichtigung zu erscheinen — nur trifft die Voreinstellung sie jetzt anders. Abschalten geht weiter unter Einstellungen → Privatsphäre

## [1.20.0] - 2026-08-13

### Added
- 😀 **Das Reaktions-Emoji kann wieder in der Benachrichtigung stehen** — „Sebi hat mit 👍 reagiert" statt nur „Sebi hat auf deine Nachricht reagiert". Seit „Push ohne Klartext" verließ das Emoji das Gerät nicht mehr, weil dort **nur noch Kennungen** hinausgehen und alles andere abgeschnitten wird. Es kommt jetzt zurück — aber **nur, wenn du es einschaltest**: Einstellungen → Privatsphäre, **Voreinstellung aus**. Der Grund für die Zurückhaltung steht im Schalter: das Emoji ist Nachrichten-Inhalt, und um in der Benachrichtigung zu erscheinen, muss es über Google bzw. Apple laufen. Alles andere am Push bleibt, wie es ist

### Fixed
- ✉️ **Eingelöste Einladungen verschwinden jetzt auch dann, wenn ein anderer Admin sie erstellt hat.** Die App konnte das nur für Chats prüfen, die sie selbst sieht — lud jemand über einen Chat ein, in dem man nicht ist, blieb die Einladung stehen, obwohl der Eingeladene längst beigetreten war. Das entscheidet jetzt der Server beim Beitritt selbst, weil nur er beide Seiten kennt. Bestehende verbrauchte Einladungen wurden dabei einmalig mit aufgeräumt

## [1.19.0] - 2026-08-12

### Added
- 🤖 **`@agents`** — ein Stichwort für die Agenten-Konten im Chat, wie `@all`, `@admins` und `@members`. „Wer von euch das übernimmt" ging vorher nur, indem man jeden Agenten einzeln nannte oder `@all` schrieb und die Menschen mitzog. Angeboten wird es nur dort, wo auch wirklich ein Agent im Chat ist
- 👤 **Aktive Einladungen sagen jetzt, wer sie erstellt hat.** In einer Gruppe mit mehreren Admins entscheidet man an dieser Stelle über die Einladung eines anderen — dann sollte dort auch stehen, wessen

### Changed
- 📝 **Lange Nachrichten behalten ihre Formatierung.** Ab 2000 Zeichen wurde bisher alles als Klartext angezeigt — Sternchen und Rauten mitten im Text statt Fettschrift und Überschriften. Die Grenze sollte vor **verschachtelten** Nachrichten schützen, die die Darstellung einfrieren können; sie hat aber die **Länge** gemessen. Das ging in beide Richtungen schief: ein langer, harmloser Bericht verlor seine Formatierung, während dreihundert Zeichen aus lauter `>` — genau der Fall, für den die Grenze gedacht war — durchrutschten. Gemessen wird jetzt, wie tief verschachtelt und wie dicht mit Sonderzeichen eine Nachricht ist. Normale Texte dürfen dadurch **zehnmal so lang** sein wie vorher

## [1.18.2] - 2026-08-12

### Fixed
- 🔢 **Der Ungelesen-Zähler fehlte manchmal, obwohl im Chat der Trenner „Ungelesene Nachrichten" richtig stand.** Beide zählen dasselbe, maßen es aber verschieden: der Trenner geht von der Nachricht selbst aus, der Zähler von einem Zeitstempel, der beim Öffnen des Chats auf die **Uhr des Geräts** gesetzt wurde. Eine Nachricht, die auf dem Server schon existierte, aber erst gleich danach ankam, war damit „älter als gelesen" — und blieb für den Zähler für immer unsichtbar. Die Marke hängt jetzt an der **neuesten Nachricht, die das Gerät wirklich hat**, statt an der Uhrzeit; damit kann sie keiner Nachricht mehr vorauseilen

## [1.18.1] - 2026-08-12

### Fixed
- 🔏 **„Nicht signiert" stand über Fotos, die einwandfrei signiert waren.** Seit 1.16.0 steht der Vertrauens-Hinweis **neben** dem Inhalt statt darin — richtig so, aber die neue Anzeige unterschied nicht mehr zwischen „Signatur geprüft und in Ordnung" und „keine Signatur da". Ergebnis: **jedes** Bild, jedes Album und jede Einladung von einem geprüften Absender behauptete „Urheberschaft ungeprüft", während Textnachrichten desselben Absenders sauber blieben. Der Hinweis erscheint jetzt wieder nur bei den zwei Fällen, für die er gedacht ist: **falsche** Signatur und **fehlende** Signatur. Ein Warnzeichen, das fast immer leuchtet, bringt einem bei, es zu übersehen — deshalb ist das kein Schönheitsfehler
- 🎨 **Die Einladungs-Karte war im Wald-Design kaum zu lesen** — Titel und „Öffnen" holten ihre Farbe von der Umgebung, während die Karte selbst einen anderen Untergrund malt: goldene Schrift auf beigem Grund. Alle Farben der Karte richten sich jetzt nach dem Untergrund der Karte; geprüft ist das für **alle vierzehn Designs**, hell wie dunkel
- ✉️ **Eingelöste Einladungen blieben unter „Aktive Einladungen" stehen** und boten an, einen längst verbrauchten Zugang zurückzuziehen. Sobald alle aus dem Chat, in den die Einladung ging, in der Gruppe sind, wird sie automatisch **zurückgezogen** und verschwindet — nicht nur ausgeblendet, denn ein gültiger Zugang, den niemand mehr braucht, soll auch keiner mehr sein
- 🙈 **Eine Einladung in einen fremden Chat zeigte einen Kennungs-Schnipsel** („04eceb3b"), der aussah wie ein Benutzername. Hat ein anderer Admin in einen Chat eingeladen, den man selbst nicht sieht, steht dort jetzt schlicht „Chat nicht sichtbar"
- 🔔 **Push aus einer frischen Gruppe hieß „Chattr" statt wie die Gruppe.** Die Namen, mit denen das Gerät eine Benachrichtigung selbst beschriftet (der Server schickt seit „Push ohne Klartext" nur noch Kennungen), wurden allein beim Aufbau der Chatliste hinterlegt. Eine gerade erstellte oder beigetretene Gruppe konnte ihre erste Nachricht bekommen, bevor das je passiert war. Der Name wird jetzt in dem Moment hinterlegt, in dem der Chat entsteht

## [1.18.0] - 2026-08-08

### Added
- 📣 **Wenn eine Erwähnung dich meint, sieht man das jetzt.** Bisher waren `@name`, `@all`, `@admins` und `@members` alle gleich hervorgehoben — in einer Gruppe mit Verkehr musste man jede Markierung lesen, um herauszufinden, ob sie einen betrifft. Erwähnungen, die **dich** meinen, bekommen jetzt einen farbigen Hintergrund; die von anderen bleiben, wie sie waren. Ob `@admins` oder `@members` dich meint, richtet sich nach deiner Rolle in **diesem** Chat
- 🖼️ **Auch in Bildunterschriften** — dort wurden Erwähnungen bisher überhaupt nicht hervorgehoben, obwohl die Chatliste sie mitgezählt hat: Der @-Punkt an der Liste leuchtete, und im Chat war nichts zu finden. Das passt jetzt zusammen

## [1.17.0] - 2026-08-08

### Changed
- ⌨️ **Die Tipp-Anzeige verrät deinen Namen nicht mehr.** „… tippt gerade" lief über einen Kanal, den der Server sieht — und dort stand dein **Anzeigename im Klartext**, während jede Nachricht im selben Chat verschlüsselt ist. Übertragen wird jetzt nur noch eine Kennung; den Namen setzt das Gerät des Gegenübers aus den Daten dazu, die es ohnehin hat. Zu sehen ist derselbe Hinweis wie vorher. **Während der Übergangszeit:** Wer die App noch nicht aktualisiert hat, sieht die Tipp-Anzeige von aktualisierten Geräten vorübergehend nicht — sie fehlt dann einfach, kaputt geht nichts

### Added
- 🎨 **Farbige Initialen im Teilen-Menü** — Kontakte und Gruppen ohne Bild zeigten in der Vorschlagszeile des Systems einen leeren Platzhalter. Jetzt erscheint dort derselbe farbige Kreis mit Initialen wie in der App

## [1.16.1] - 2026-08-07

### Fixed
- 🔑 **„Neuen Schlüssel erstellen" war nicht erreichbar — ausgerechnet dann, wenn man ihn braucht.** Ist der Identitätsschlüssel eines Geräts vorhanden, aber nicht mehr lesbar (etwa nach einem Eingriff des Android-Schlüsselspeichers), zeigte das Verifizierungs-Fenster nur eine technische Fehlermeldung und sonst nichts. Der Knopf, der genau diesen Zustand behebt, saß hinter der Anzeige, die dabei abstürzte. Jetzt erscheint er
- ⬇️ **„Nach Updates suchen" meldete einen Fund, bot aber nichts an.** Das Installieren war einem Hinweisbalken überlassen, der nur beim **ersten** Fund erscheint — beim zweiten Nachsehen passierte also nichts mehr. Der Knopf steht jetzt direkt in der Rückmeldung, dort wo man ihn angefordert hat

## [1.16.0] - 2026-08-07

### Fixed
- 🖼️ **Fotos und Einladungen von unsignierten Absendern kamen als Buchstabensalat an** — seit 1.14.0 stand der Hinweis „Nicht signiert" **im Nachrichtentext**, und genau an diesem Text erkennt die App, ob eine Nachricht ein Bild, ein Album oder eine Gruppeneinladung ist. Mit dem Hinweis davor griff diese Erkennung nicht mehr, und statt des Bildes erschienen die technischen Daten dahinter als Textwand. Betroffen waren ausschließlich Nachrichten von Geräten **ohne Identitätsschlüssel** — zwischen zwei normalen Geräten gibt es den Hinweis gar nicht. Der Hinweis steht jetzt **neben** dem Inhalt statt darin

### Added
- 🤖 **Die Agenten-Zeile zeigt ungelesene Nachrichten** — bisher stand dort nur, **wie viele** Agenten-Chats es gibt, und die Zeile war zudem hinter der Aufklapp-Geste versteckt. Das App-Symbol zählt Agenten-Nachrichten aber mit: Das Symbol zeigte also eine Zahl, für die in der Liste nichts zu sehen war. Jetzt trägt die Zeile die Anzahl ungelesener Agenten-Nachrichten und klappt von selbst auf, sobald es welche gibt — und versteckt sich wieder, sobald sie gelesen sind

## [1.15.0] - 2026-08-07

### Changed
- 🔢 **Ungelesene Nachrichten zählt jetzt dein Gerät** — bisher führte der Server die Zahl am Chat, und dafür merkte er sich, **wann du welchen Chat zuletzt geöffnet hast**. Das ist nichts, was er zum Zustellen wissen muss: Dein Gerät hat die Nachrichten ohnehin und kann selbst zählen. Die Zahl verhält sich wie vorher, sie entsteht nur woanders — und ein Zähler, der beim Öffnen kurz zurücksprang, kann das nicht mehr, weil es keine zwei Meinungen darüber mehr gibt. **Ein Unterschied, den du merkst:** Nach einer Neuinstallation beginnt die Zahl bei null; gezählt wird, was danach ankommt. Der Server hält nur noch das vor, was er ohnehin für dich vorhalten muss, und das wird beim Abholen gelöscht

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
