# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.0.0/),
und dieses Projekt folgt [Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

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
