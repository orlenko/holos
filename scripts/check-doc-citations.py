#!/usr/bin/env python3
"""Checks that every numbered doc citation in the repository resolves (AGENTS.md "Docs and comments").

    scripts/check-doc-citations.py           check every tracked .swift, .md, .sh and .py file
    scripts/check-doc-citations.py FILE...   check only these files

A citation is a Markdown file path followed by a section number: `docs/conventions.md §1.7`, also when a line break
and a comment marker (`///`, `//`, `*`, `>`) come between the path and the number, or when the path is a Markdown
link (`[meeting-design.md §7.2](meeting-design.md)`). Numbers chained after it with a comma, "and", "to", "or",
a slash or a dash (`docs/conventions.md §1.5, §1.9`, `§4.8 to §4.11`, `§8–§10`), optionally after a quoted
subheading, are citations of the same file. Each one resolves when the file exists and has a heading (outside
fenced code) whose text starts with the number: `§4.1` needs a heading `4.1 ...`, and `§3` a heading `3. ...` or
`3 ...`. A path that starts with a top-level folder of the repository is read from the repository root; any other
path from the citing file's folder first.

A bare `§N.M` with no path before it is not checked: it names a section of the file it appears in, or, in older
code comments, of the meeting design, whose numbers stay unique across its files (`docs/meeting-design.md` maps
each number to its file).

Prints each broken citation as `file:line: path §N.M: reason` and a summary; exits 1 when any is broken.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUFFIXES = (".swift", ".md", ".sh", ".py")

NUMBER = r"§(\d+(?:\.\d+)*)"
# What may stand between a path and its number: a closing backtick or bracket, a link target, spaces, and one line
# break followed by a comment marker.
GAP = r"[`\]]*(?:\([^)\s]*\))?[ \t]*(?:\n[ \t]*(?:///?|\*|>|#)?[ \t]*)?"
CITATION = re.compile(r"(?P<path>[A-Za-z0-9_./-]*[A-Za-z0-9_-]\.md)" + GAP + NUMBER)
CHAIN = re.compile(r'(?:[ \t]+"[^"\n]*")?[ \t]*(?:,|and|to|or|/|–|-)[ \t]*(?:\n[ \t]*(?:///?|\*|>)?[ \t]*)?' + NUMBER)
HEADING = re.compile(r"^#{1,6}[ \t]+(.*)$")
FENCE = re.compile(r"^[ \t]*(```|~~~)")


def tracked_files():
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], check=True, capture_output=True).stdout
    return [p for p in out.decode().split("\0") if p.endswith(SUFFIXES)]


def heading_texts(path, cache):
    if path not in cache:
        texts = []
        fenced = False
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if FENCE.match(line):
                    fenced = not fenced
                    continue
                match = None if fenced else HEADING.match(line)
                if match:
                    texts.append(match.group(1).strip().strip("*`"))
        cache[path] = texts
    return cache[path]


def has_section(texts, number):
    pattern = re.compile(re.escape(number) + r"(?:\.?(?:[ \t]|$))")
    return any(pattern.match(text) for text in texts)


def resolve(cited, citing):
    top = cited.split("/", 1)[0]
    candidates = []
    if "/" in cited and os.path.isdir(os.path.join(ROOT, top)):
        candidates.append(os.path.join(ROOT, cited))
    candidates.append(os.path.normpath(os.path.join(ROOT, os.path.dirname(citing), cited)))
    candidates.append(os.path.join(ROOT, cited))
    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate
    return None


def check(paths):
    cache = {}
    broken = []
    count = 0
    for rel in paths:
        try:
            with open(os.path.join(ROOT, rel), encoding="utf-8") as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError) as error:
            broken.append(f"{rel}: cannot read: {error}")
            continue
        for match in CITATION.finditer(text):
            numbers = [(match.group(2), match.start(2))]
            end = match.end()
            while chained := CHAIN.match(text, end):
                numbers.append((chained.group(1), chained.start(1)))
                end = chained.end()
            cited = match.group("path")
            target = resolve(cited, rel)
            for number, offset in numbers:
                count += 1
                line = text.count("\n", 0, offset) + 1
                if target is None:
                    broken.append(f"{rel}:{line}: {cited} §{number}: no such file")
                elif not has_section(heading_texts(target, cache), number):
                    broken.append(f"{rel}:{line}: {cited} §{number}: no heading {number} in {os.path.relpath(target, ROOT)}")
    return count, broken


def main():
    paths = sys.argv[1:] or tracked_files()
    count, broken = check(paths)
    for line in broken:
        print(line)
    print(f"{count} citations in {len(paths)} files, {len(broken)} broken")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
