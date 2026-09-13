#!/usr/bin/env python3
"""Erzeugt lib/features/reactions/emoji_supplement.g.dart.

Der Datensatz von `emoji_picker_flutter` ist unvollständig — gegen den
Unicode-Basissatz fehlen rund 300 Emoji, darunter Alltägliches wie 🪦, die
neuen Herzfarben oder die geschlechtsneutralen Berufe. Ein Paket-Update hilft
nicht (4.5.3 hat exakt dieselben Lücken), also tragen wir sie selbst nach.

Nachgetragen wird NICHT als Vollersatz, sondern als Ergänzung: Der Paket-Satz
bleibt, wie er ist, und jedes fehlende Emoji bekommt einen **Anker** — das
nächste in Unicode-Reihenfolge davorliegende Emoji, das das Paket kennt.
Daraus ergibt sich beides von selbst, die Kategorie UND die Einfügestelle;
eine Zuordnungstabelle Unicode-Gruppe → `Category` braucht es dadurch nicht,
und die Ergänzungen landen dort, wo man sie sucht, statt am Ende des Rasters.

Quellen (beide unter Unicode-3.0-Lizenz, verträgt sich mit AGPL):
  * unicode.org  emoji-test.txt        — welche Emoji es gibt, in welcher Reihenfolge
  * CLDR         annotations{,Derived} — Stichwörter je Sprache (de + en)

Aufruf:  python3 scripts/gen-emoji-supplement.py [--offline <verzeichnis>]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import urllib.request

# Emoji from this version on stay out. We have set `checkPlatformCompatibility:
# false` (otherwise the package renders every emoji once as a probe on opening
# and the picker visibly stutters) — so an emoji the device's font does not know
# appears as an empty box. Practically no shipped Android knows E16/E17.
MAX_EMOJI_VERSION = 15.1

QUELLEN = {
    'emoji-test.txt': 'https://unicode.org/Public/emoji/latest/emoji-test.txt',
    'cldr_de.xml': 'https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotations/de.xml',
    'cldr_en.xml': 'https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotations/en.xml',
    'cldrd_de.xml': 'https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotationsDerived/de.xml',
    'cldrd_en.xml': 'https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotationsDerived/en.xml',
}

VS16 = '️'


def lade(name: str, offline: pathlib.Path | None) -> str:
    if offline:
        return (offline / name).read_text(encoding='utf-8')
    with urllib.request.urlopen(QUELLEN[name], timeout=120) as r:
        return r.read().decode('utf-8')


# --------------------------------------------------------------------------
# Paket-Satz einlesen
# --------------------------------------------------------------------------

def paket_lib(repo: pathlib.Path) -> pathlib.Path:
    cfg = json.loads((repo / '.dart_tool' / 'package_config.json').read_text())
    for p in cfg['packages']:
        if p['name'] == 'emoji_picker_flutter':
            wurzel = urllib.request.url2pathname(
                p['rootUri'].replace('file://', ''))
            return (repo / '.dart_tool' / wurzel).resolve() / 'lib'
    raise SystemExit('emoji_picker_flutter nicht in package_config.json — '
                     'erst `flutter pub get` laufen lassen')


def paket_emoji(pfad: pathlib.Path) -> list[str]:
    """Alle Emoji-Zeichen des Paket-Satzes, in Dateireihenfolge."""
    txt = pfad.read_text(encoding='utf-8')
    return re.findall(r"Emoji\(\s*'([^']+)'", txt)


# --------------------------------------------------------------------------
# Unicode-Referenz
# --------------------------------------------------------------------------

def hauttoen(c: str) -> bool:
    return any(0x1F3FB <= ord(x) <= 0x1F3FF for x in c)


def flagge(c: str) -> bool:
    return any(0x1F1E6 <= ord(x) <= 0x1F1FF for x in c) or '\U0001F3F4' in c


def unicode_liste(txt: str) -> tuple[list[tuple[str, float, str]], set[str]]:
    """Basis-Emoji in Dateireihenfolge plus die Menge derer mit Hauttönen.

    „Hat Hauttöne" heisst: Es gibt im selben Datensatz eine Fassung mit
    Hautton-Modifikator. Das Paket setzt den Modifikator hinter das erste
    Zeichen und hängt den Rest wieder an (`applySkinTone`), funktioniert also
    auch bei ZWJ-Folgen wie 🧑‍⚕️.
    """
    raus: list[tuple[str, float, str]] = []
    mit_hautton: set[str] = set()
    for zeile in txt.splitlines():
        if zeile.startswith('#') or '; fully-qualified' not in zeile:
            continue
        cps = zeile.split(';', 1)[0].strip()
        character = ''.join(chr(int(c, 16)) for c in cps.split())
        if flagge(character):
            continue
        if hauttoen(character):
            mit_hautton.add(''.join(
                c for c in character if not (0x1F3FB <= ord(c) <= 0x1F3FF)))
            continue
        m = re.match(r'\S+\s+E(\d+\.\d+)\s+(.*)', zeile.split('#', 1)[1].strip())
        if not m:
            continue
        raus.append((character, float(m.group(1)), m.group(2)))
    return raus, mit_hautton


# --------------------------------------------------------------------------
# CLDR keywords
# --------------------------------------------------------------------------

def stichwoerter(*xml: str) -> dict[str, tuple[str, list[str]]]:
    """cp -> (Name, Stichwörter). Spätere Dateien ergänzen, überschreiben nicht."""
    raus: dict[str, tuple[str, list[str]]] = {}
    muster = re.compile(
        r'<annotation cp="([^"]+)"(\s+type="tts")?\s*>([^<]*)</annotation>')
    for quelle in xml:
        for cp, tts, inhalt in muster.findall(quelle):
            cp = cp.replace('&quot;', '"').replace('&amp;', '&')
            inhalt = (inhalt.replace('&quot;', '"').replace('&amp;', '&')
                      .replace('&lt;', '<').replace('&gt;', '>').strip())
            name, kw = raus.get(cp, ('', []))
            if tts:
                name = name or inhalt
            else:
                kw = kw or [t.strip() for t in inhalt.split('|') if t.strip()]
            raus[cp] = (name, kw)
    return raus


def suchtext(character: str, tabelle: dict[str, tuple[str, list[str]]],
             notname: str) -> str:
    """Der Suchtext, wie ihn das Paket erwartet: 'a | b | c'."""
    for schluessel in (character, character.replace(VS16, ''), character + VS16):
        if schluessel in tabelle:
            name, kw = tabelle[schluessel]
            teile = ([name] if name else []) + kw
            break
    else:
        teile = [notname]
    # The name is often already among the keywords — drop duplicates, keep the
    # order.
    gesehen: set[str] = set()
    sauber = []
    for t in teile:
        k = t.lower()
        if k and k not in gesehen:
            gesehen.add(k)
            sauber.append(t)
    return ' | '.join(sauber)


# --------------------------------------------------------------------------
# Erzeugen
# --------------------------------------------------------------------------

def dart_string(s: str) -> str:
    return "'" + s.replace('\\', r'\\').replace("'", r"\'").replace('$', r'\$') + "'"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--offline', type=pathlib.Path,
                    help='Verzeichnis mit bereits geladenen Quelldateien')
    args = ap.parse_args()

    repo = pathlib.Path(__file__).resolve().parent.parent
    lib = paket_lib(repo)

    satz_de = paket_emoji(lib / 'locales' / 'emoji_set_de.dart')
    satz_en = paket_emoji(lib / 'locales' / 'emoji_set_en.dart')
    if satz_de != satz_en:
        raise SystemExit('de- und en-Satz des Pakets sind unterschiedlich '
                         'sortiert — der Anker-Ansatz setzt gleiche '
                         'Reihenfolge voraus')

    vorhanden = set(satz_de) | {e.replace(VS16, '') for e in satz_de}
    referenz, mit_hautton = unicode_liste(lade('emoji-test.txt', args.offline))

    de = stichwoerter(lade('cldr_de.xml', args.offline),
                      lade('cldrd_de.xml', args.offline))
    en = stichwoerter(lade('cldr_en.xml', args.offline),
                      lade('cldrd_en.xml', args.offline))

    # Determine the anchor: the last emoji seen that is in the package.
    eintraege: list[tuple[str, str, str, str, bool]] = []
    zu_neu = 0
    anchor = ''
    for character, version, name in referenz:
        if character in vorhanden or character.replace(VS16, '') in vorhanden:
            anchor = character
            continue
        if version > MAX_EMOJI_VERSION:
            zu_neu += 1
            continue
        if not anchor:
            # It would come before the first known emoji — that would not
            # happen, but it would be a silent loss. Better to be loud.
            print(f'  ! ohne Anker, übersprungen: {character} ({name})',
                  file=sys.stderr)
            continue
        eintraege.append((anchor, character, suchtext(character, de, name),
                          suchtext(character, en, name),
                          character in mit_hautton))

    ziel = repo / 'lib' / 'features' / 'reactions' / 'emoji_supplement.g.dart'
    ziel.parent.mkdir(parents=True, exist_ok=True)

    zeilen = [
        '// GENERIERT von scripts/gen-emoji-supplement.py — nicht von Hand ändern.',
        '//',
        '// Die Emoji, die `emoji_picker_flutter` fehlen, samt Anker: dem letzten',
        '// Emoji davor, das das Paket kennt. Daraus ergibt sich Kategorie UND',
        '// Einfügestelle — siehe chattr_emoji_set.dart.',
        '//',
        '// Datenquellen: unicode.org emoji-test.txt und CLDR-Annotationen',
        '// (© Unicode, Inc., Unicode-3.0-Lizenz).',
        f'// Emoji ab E{MAX_EMOJI_VERSION} bleiben draussen ({zu_neu} Stück) — ohne',
        '// Schriftunterstützung wären sie leere Kästchen.',
        '',
        '/// Ein nachgetragenes Emoji: [character] gehört direkt hinter [anchor].',
        'class SupplementEmoji {',
        '  /// Das Emoji, das das Paket kennt und hinter dem dieses hier steht.',
        '  final String anchor;',
        '',
        '  /// Das nachgetragene Emoji selbst.',
        '  final String character;',
        '',
        '  /// Suchbegriffe, deutsch — Format wie im Paket: `a | b | c`.',
        '  final String de;',
        '',
        '  /// Suchbegriffe, englisch.',
        '  final String en;',
        '',
        '  /// Ob es das Emoji in Hauttönen gibt.',
        '  final bool skinTone;',
        '',
        '  /// Konstruktor.',
        '  const SupplementEmoji(this.anchor, this.character, this.de, this.en,',
        '      {this.skinTone = false});',
        '}',
        '',
        f'/// Die {len(eintraege)} Emoji, die dem Paket-Satz fehlen.',
        'const List<SupplementEmoji> supplementEmoji = [',
    ]
    for a, z, d, e, h in eintraege:
        schwanz = '),' if not h else ',\n      skinTone: true),'
        zeilen.append(f'  SupplementEmoji({dart_string(a)}, {dart_string(z)},')
        zeilen.append(f'      {dart_string(d)},')
        zeilen.append(f'      {dart_string(e)}{schwanz}')
    zeilen += ['];', '']

    ziel.write_text('\n'.join(zeilen), encoding='utf-8')
    print(f'{ziel.relative_to(repo)}: {len(eintraege)} Emoji nachgetragen, '
          f'{zu_neu} wegen E>{MAX_EMOJI_VERSION} ausgelassen')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
