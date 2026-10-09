#!/usr/bin/env python3
"""Checks that every numbered doc citation in the repository resolves (AGENTS.md "Docs and comments").

    scripts/check-doc-citations.py               check every tracked .swift, .md, .sh and .py file
    scripts/check-doc-citations.py FILE...       check only these files
    scripts/check-doc-citations.py --self-test   run the checker's own cases in a temporary folder

A citation names a Markdown file and a section number, in one of two forms:

- a path followed by the number (`docs/<file>.md §<N.M>`), also when a backtick, spaces, or a line break and a
  comment marker (`///`, `//`, `*`, `>`, `#`) come between them;
- a Markdown link to a `.md` file with the number in its text or right after it (`[text §<N.M>](<file>.md)`,
  `[text](<file>.md) §<N.M>`). The link target is the cited file, whatever the text says.

Numbers chained after a citation are citations of the same file. Between two numbers there may be commas,
semicolons, "and", "to", "or", a slash or a dash, quoted subheadings, spaces and line breaks with comment markers
(`§<A>, §<B>`, `§<A>, "Heading"; §<B>`, `§<A>, and §<B>`, `§<A>–§<B>`).

A citation resolves when the file exists and has a heading, outside fenced code, whose text starts with the
number: `§4.1` needs a heading `4.1 ...` (not `4.10 ...`), and `§3` a heading `3. ...` or `3 ...`. Fences follow
CommonMark: a block closes only at a fence of the same character that is at least as long as the opening one.
Paths are found like this:

- a link target: from the citing file's folder (from the repository root when it starts with `/`);
- a path starting with `./` or `../`: from the citing file's folder;
- a path whose first folder is a top-level folder of the repository (`docs/...`, `Sources/...`): from the root;
- any other path: from the citing file's folder, then from the root.

A bare `§N.M` with no path before it is not checked: it names a section of the file it appears in, or, in older
code comments, of the meeting design, whose section numbers are unique.

Prints each broken citation as `file:line: path §N.M: reason` and a summary; exits 1 when any is broken.
"""

import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUFFIXES = (".swift", ".md", ".sh", ".py")

NUMBER = r"§(\d+(?:\.\d+)*)"
# Spaces, and at most one line break followed by a comment marker.
SPACE = r"[ \t]*(?:\n[ \t]*(?:///?|\*|>|#)?[ \t]*)?"
QUOTED = r'"[^"\n]*(?:\n[ \t]*(?:///?|\*|>|#)?[^"\n]*)?"'
JOINER = r"(?:" + SPACE + r"(?:,|;|\band\b|\bto\b|\bor\b|/|–|-|" + QUOTED + r"))+" + SPACE
CHAIN = re.compile(JOINER + NUMBER)
PATH_CITATION = re.compile(r"(?<![\w./-])(?P<path>[A-Za-z0-9_./-]*[A-Za-z0-9_-]\.md)`?" + SPACE + NUMBER)
LINK = re.compile(r"\[(?P<text>[^\]\n]*)\]\((?P<target>[^)\s#]+\.md)(?:#[^)\s]*)?\)")
AFTER_LINK = re.compile(SPACE + NUMBER)
IN_TEXT = re.compile(NUMBER)
HEADING = re.compile(r"^ {0,3}#{1,6}[ \t]+(.*?)[ \t#]*$")
FENCE_OPEN = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")


def tracked_files():
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], check=True, capture_output=True).stdout
    # This file's self-test cases cite fixture files that exist only while the self-test runs.
    return [p for p in out.decode().split("\0") if p.endswith(SUFFIXES) and p != "scripts/check-doc-citations.py"]


def heading_texts(path, cache):
    """The headings of a Markdown file, outside fenced code (CommonMark fences)."""
    if path not in cache:
        texts = []
        fence = None
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if fence:
                    if re.match(r"^[ \t]*" + re.escape(fence[0]) + "{" + str(len(fence)) + r",}[ \t]*$", line):
                        fence = None
                    continue
                opening = FENCE_OPEN.match(line)
                if opening and not (opening.group(1)[0] == "`" and "`" in opening.group(2)):
                    fence = opening.group(1)
                    continue
                match = HEADING.match(line)
                if match:
                    texts.append(match.group(1).strip().strip("*`"))
        cache[path] = texts
    return cache[path]


def has_section(texts, number):
    pattern = re.compile(re.escape(number) + r"(?:\.?(?:[ \t]|$))")
    return any(pattern.match(text) for text in texts)


def resolve(cited, citing, link):
    here = os.path.dirname(os.path.join(ROOT, citing))
    if link:
        candidates = [os.path.join(ROOT, cited.lstrip("/")) if cited.startswith("/") else os.path.join(here, cited)]
    elif cited.startswith(("./", "../")):
        candidates = [os.path.join(here, cited)]
    elif "/" in cited and os.path.isdir(os.path.join(ROOT, cited.split("/", 1)[0])):
        candidates = [os.path.join(ROOT, cited)]
    else:
        candidates = [os.path.join(here, cited), os.path.join(ROOT, cited)]
    for candidate in candidates:
        if os.path.isfile(candidate):
            return os.path.normpath(candidate)
    return None


def chained(text, number, end):
    """The citation's first number and the numbers chained after it, with their offsets."""
    numbers = [number]
    while follow := CHAIN.match(text, end):
        numbers.append((follow.group(1), follow.start(1)))
        end = follow.end()
    return numbers


def citations(text):
    """Every citation in `text`: (cited path, is a link target, [(number, offset)])."""
    found = []
    links = []
    for link in LINK.finditer(text):
        target = link.group("target")
        links.append(link.span())
        if "://" in target:
            continue
        numbers = [(m.group(1), link.start("text") + m.start(1)) for m in IN_TEXT.finditer(link.group("text"))]
        after = AFTER_LINK.match(text, link.end())
        if after:
            numbers += chained(text, (after.group(1), after.start(1)), after.end())
        if numbers:
            found.append((target, True, numbers))
    for match in PATH_CITATION.finditer(text):
        if any(start <= match.start() < end for start, end in links):
            continue
        found.append((match.group("path"), False, chained(text, (match.group(2), match.start(2)), match.end())))
    return found


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
        for cited, link, numbers in citations(text):
            target = resolve(cited, rel, link)
            for number, offset in numbers:
                count += 1
                line = text.count("\n", 0, offset) + 1
                if target is None:
                    broken.append(f"{rel}:{line}: {cited} §{number}: no such file")
                elif not has_section(heading_texts(target, cache), number):
                    where = os.path.relpath(target, ROOT)
                    broken.append(f"{rel}:{line}: {cited} §{number}: no heading {number} in {where}")
    return count, broken


SELF_TEST_FILES = {
    "docs/a.md": "# A\n\n## 1.3 Three\n\n### 4.10 Ten\n\n````md\n```\n## 9.9 Inside a fence\n```\n````\n",
    "docs/sub/b.md": "# B\n\n## 1.1 One\n",
    "link-target.md": "[design](docs/a.md) §1.3 resolves; [design](docs/a.md) §3.2 does not.\n",
    "link-text.md": "[docs/a.md](missing.md) §4.10 and [docs/a.md §1.3](missing.md) cite the target.\n",
    "wrapped.swift": "/// (docs/a.md §1.3\n/// and §3.2)\n",
    "comma-and.swift": "// docs/a.md §1.3, and §3.2\n",
    "subheading.swift": '/// (docs/a.md §1.3, "A heading that wraps\n/// here"; §5.11, "Other"): rest\n',
    "docs/sub/relative.md": "./b.md §1.1, ../a.md §1.3 and docs/a.md §1.3 resolve; ./a.md §1.3 does not.\n",
    "fence.md": "docs/a.md §9.9\n",
    "prefix.md": "docs/a.md §4.1 is not docs/a.md §4.10.\n",
}
SELF_TEST_BROKEN = [
    "link-target.md:1: docs/a.md §3.2: no heading 3.2 in docs/a.md",
    "link-text.md:1: missing.md §4.10: no such file",
    "link-text.md:1: missing.md §1.3: no such file",
    "wrapped.swift:2: docs/a.md §3.2: no heading 3.2 in docs/a.md",
    "comma-and.swift:1: docs/a.md §3.2: no heading 3.2 in docs/a.md",
    "subheading.swift:2: docs/a.md §5.11: no heading 5.11 in docs/a.md",
    "docs/sub/relative.md:1: ./a.md §1.3: no such file",
    "fence.md:1: docs/a.md §9.9: no heading 9.9 in docs/a.md",
    "prefix.md:1: docs/a.md §4.1: no heading 4.1 in docs/a.md",
]


def self_test():
    global ROOT
    with tempfile.TemporaryDirectory() as folder:
        for rel, text in SELF_TEST_FILES.items():
            os.makedirs(os.path.dirname(os.path.join(folder, rel)), exist_ok=True)
            with open(os.path.join(folder, rel), "w", encoding="utf-8") as handle:
                handle.write(text)
        ROOT = folder
        count, broken = check([rel for rel in SELF_TEST_FILES if not rel.startswith(("docs/a.md", "docs/sub/b.md"))])
    missing = [line for line in SELF_TEST_BROKEN if line not in broken]
    unexpected = [line for line in broken if line not in SELF_TEST_BROKEN]
    for line in missing:
        print(f"self-test: not reported: {line}")
    for line in unexpected:
        print(f"self-test: reported but should resolve: {line}")
    print(f"self-test: {count} citations, {len(broken)} broken, {len(missing) + len(unexpected)} mismatches")
    return 1 if missing or unexpected else 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    paths = sys.argv[1:] or tracked_files()
    count, broken = check(paths)
    for line in broken:
        print(line)
    print(f"{count} citations in {len(paths)} files, {len(broken)} broken")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
