#!/usr/bin/env python3
"""Vérifie la traduction anglaise de PlayTendo (Support/Language.swift, Support/English.swift).

1. Chaque texte passé à tr("…") a sa traduction dans English.table (clé = texte français, chaque valeur insérée
   \\(…) remplacée par %@) ; même nombre de %@ des deux côtés.
2. Pas de clé en double dans la table (le dictionnaire ferait planter l'app au lancement).
3. Liste les textes qui ressemblent à du français mais ne passent pas par tr() (hors Journal, commentaires) :
   à relire, certains sont voulus (noms de dossiers, clés de réglages).
4. Liste les traductions qui ne servent plus (sauf celles des messages Objective-C, traduits par trMessage).

    python3 scripts/check_translations.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app", "PlayTendo")
TABLE = os.path.join(APP, "Support", "English.swift")

FRENCH = re.compile(r"[éèàùâêîôûçÉÈÀÊ]|\b(le|la|les|de|du|des|et|un|une|ton|ta|tes|pas|est|sur|dans|avec)\b")
# Lignes dont les textes ne s'affichent pas (Journal, clés, chemins).
IGNORED_LINE = re.compile(r"PTLogLine|Console\.WriteLn|forKey|fatalError|assert|NSLog|Notification\.Name|"
                          r"appendingPathComponent|seenKey|Key = \"|static let \w+Key|withName:")


def parse_literal(text, start):
    """Lit le littéral Swift qui commence au guillemet `start`. Renvoie (clé avec %@, nombre de valeurs, fin)."""
    assert text[start] == '"'
    i = start + 1
    out = []
    values = 0
    while i < len(text):
        c = text[i]
        if c == '"':
            return "".join(out), values, i + 1
        if c == "\\":
            n = text[i + 1]
            if n == "(":
                i = skip_interpolation(text, i + 2)
                out.append("%@")
                values += 1
                continue
            if n == "u" and text[i + 2] == "{":
                end = text.index("}", i)
                out.append(chr(int(text[i + 3:end], 16)))
                i = end + 1
                continue
            out.append({"n": "\n", "t": "\t", "0": "\0", "r": "\r"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    raise ValueError("littéral non fermé")


def skip_interpolation(text, i):
    """Saute le contenu de \\( … ) (parenthèses et littéraux imbriqués), renvoie l'indice après la parenthèse."""
    depth = 1
    while depth:
        c = text[i]
        if c == '"':
            _, _, i = parse_literal(text, i)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        i += 1
    return i


def strip_comments(text):
    """Remplace les commentaires par des espaces (mêmes positions et numéros de ligne)."""
    out = list(text)
    i = 0
    while i < len(text):
        if text.startswith('"""', i):
            end = text.index('"""', i + 3)
            i = end + 3
        elif text[i] == '"':
            try:
                _, _, i = parse_literal(text, i)
            except (ValueError, IndexError):
                i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            end = len(text) if end < 0 else end
            for k in range(i, end):
                out[k] = " "
            i = end
        elif text.startswith("/*", i):
            end = text.index("*/", i) + 2
            for k in range(i, end):
                if out[k] != "\n":
                    out[k] = " "
            i = end
        else:
            i += 1
    return "".join(out)


def read_table():
    text = open(TABLE, encoding="utf-8").read()
    entries = []
    for number, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        if not stripped.startswith('"'):
            continue
        offset = line.index('"')
        key, _, end = parse_literal(line, offset)
        rest = line[end:]
        if not rest.startswith(": "):
            continue
        value, _, _ = parse_literal(line, end + 2)
        entries.append((number, key, value))
    return entries


def main():
    problems = 0
    entries = read_table()
    table = {}
    for number, key, value in entries:
        if key in table:
            print(f"DOUBLON (plante au lancement) : English.swift:{number} {key!r}")
            problems += 1
        table[key] = value
        if key.count("%@") != len(re.findall(r"%(?:\d+\$)?@", value)):
            print(f"Nombre de %@ différent : English.swift:{number} {key!r} → {value!r}")
            problems += 1

    used = set()
    suspects = []
    for folder, _, files in os.walk(APP):
        for name in sorted(files):
            if not name.endswith(".swift") or name == "English.swift":
                continue
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, APP)
            source = strip_comments(open(path, encoding="utf-8").read())
            for match in re.finditer(r"(?<![\w.])tr\(\"", source):
                key, _, _ = parse_literal(source, match.end() - 1)
                used.add(key)
                if key not in table:
                    line = source.count("\n", 0, match.start()) + 1
                    print(f"SANS TRADUCTION : {relative}:{line} {key!r}")
                    problems += 1
            # Littéraux français hors tr().
            lines = source.split("\n")
            i = 0
            while i < len(source):
                if source.startswith('"""', i):
                    i = source.index('"""', i + 3) + 3
                    continue
                if source[i] != '"':
                    i += 1
                    continue
                try:
                    key, _, end = parse_literal(source, i)
                except (ValueError, IndexError):
                    i += 1
                    continue
                before = source[max(0, i - 3):i]
                line_number = source.count("\n", 0, i) + 1
                line = lines[line_number - 1]
                if before != "tr(" and FRENCH.search(key) and not IGNORED_LINE.search(line) and len(key) > 2:
                    suspects.append(f"{relative}:{line_number} {key!r}")
                i = end

    objc = ""
    for folder, _, files in os.walk(APP):
        for name in files:
            if name.endswith((".m", ".mm")):
                objc += open(os.path.join(folder, name), encoding="utf-8").read()
    unused = [k for k in table if k not in used and k.replace("%@", "") not in objc
              and k.split(" : %@")[0] not in objc]
    if suspects:
        print(f"\n{len(suspects)} texte(s) en français hors tr() (à relire) :")
        for line in suspects:
            print("  " + line)
    if unused:
        print(f"\n{len(unused)} traduction(s) inutilisée(s) :")
        for key in unused:
            print(f"  {key!r}")
    print(f"\n{len(table)} traductions, {len(used)} textes tr() ; {problems} problème(s)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
