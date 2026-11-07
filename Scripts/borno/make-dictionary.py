#!/usr/bin/env python3
"""Builds Resources/borno/{words,autocorrect}.txt from an Avro Keyboard install.
   innoextract -s setup_avrokeyboard_5.6.0.exe -d /tmp/avro
   python3 Scripts/borno/make-dictionary.py "/tmp/avro/commonappdata/Avro Keyboard"
Avro's data is MPL 1.1 (OmicronLab)."""
import re, sqlite3, sys
src, out = sys.argv[1], "Resources/borno"

db = sqlite3.connect(f"{src}/Database.db3")
words = set()
for (t,) in db.execute("select name from sqlite_master where type='table' and name<>'Suffix'"):
    words.update(w.strip() for (w,) in db.execute(f'select Words from "{t}"') if w)
bangla = re.compile(r"^[ঀ-৿‌‍]+$")
words = sorted(w for w in words if bangla.match(w))
open(f"{out}/words.txt", "w", encoding="utf-8").write("\n".join(words) + "\n")

# "english roman-spelling" pairs, e.g. "academy oZakaDemi"; emoticons and identity rows dropped.
pairs = []
for line in open(f"{src}/autodict.dct", "rb").read().decode("latin1").split("\r\n"):
    k, _, v = line.partition(" ")
    if re.fullmatch(r"[A-Za-z]+", k) and v and v != k:
        pairs.append(f"{k}\t{v}")
open(f"{out}/autocorrect.txt", "w", encoding="utf-8").write("\n".join(pairs) + "\n")
print(len(words), "words,", len(pairs), "autocorrect")
