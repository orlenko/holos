#!/usr/bin/env python3
"""Checks that every numbered doc citation in the repository resolves (AGENTS.md "Docs and comments").

    scripts/check-doc-citations.py               check every tracked .swift, .md, .sh and .py file
    scripts/check-doc-citations.py FILE...       check only these files
    scripts/check-doc-citations.py --self-test   run the checker's own cases (in memory; writes nothing)

Each file is split into paragraphs: in Markdown, a paragraph, a list item, a table row or a heading (inside fenced
code, each run of non-blank lines); in source files, a run of consecutive comment lines (`//`, `///`, every line of
a `/* ... */` block, or `#` in shell and Python), with each other line on its own. Within a paragraph, every `§<N.M>` cites the last
Markdown file named before it in that paragraph. A file is named by

- a Markdown link to it: `[label](<file>.md)`, `[label](<<file>.md>)` or `[label](<file>.md "title")`; the label may
  wrap across lines and hold balanced brackets, and its text never names a file (a `§` inside it cites the link's
  file);
- a path: `docs/<file>.md`, `./<file>.md`, any number of `../` before it, any path with a folder, and in Markdown
  files under `docs/` also a plain `<file>.md`.

A citation resolves when the file exists and has a heading, outside fenced code, whose text starts with the number:
`§4.1` needs a heading `4.1 ...` (not `4.10 ...`), and `§3` a heading `3. ...` or `3 ...`. Fences follow CommonMark,
also after a list marker or in a block quote: a block closes at a fence of the same character, at least as long as
the opening one, indented at most 3 spaces more than the opening one's container content.
Files are found like this:

- a link destination: from the citing file's folder (from the repository root when it starts with `/`);
- a path starting with `./` or `../`: from the citing file's folder;
- a path whose first folder is a top-level folder of the repository (`docs/...`, `Sources/...`): from the root;
- any other path: from the citing file's folder.

A `§<N.M>` with no file named before it in its paragraph is bare and is not checked: it names a section of the
file it appears in, or, in older code comments, of the meeting design, whose section numbers are unique. Between
the lines `<!-- citations: <file>.md -->` and `<!-- /citations -->` of a Markdown file, a bare `§<N.M>` cites that
file (from the repository root). It resolves to a heading of that file or, when that file is an index, to a
heading of the file its table maps the number to (a row naming `§<N.M>`, or a range `§<N.M>–<N.K>` that holds it,
and a link; a number not listed is looked up by its parents: `§0.2` by `§0`).

Prints each problem as `file:line: ...` and a summary; exits 1 when there is any.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUFFIXES = (".swift", ".md", ".sh", ".py")
SELF = "scripts/check-doc-citations.py"

SECTION = re.compile(r"§(\d+(?:\.\d+)*)")
LINK = re.compile(
    r"\[(?P<label>(?:[^\[\]]|\[[^\[\]]*\])*)\]\(\s*(?:<(?P<angle>[^<>\n]*)>|(?P<plain>[^\s()<>]+))"
    r"""(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)""")
PATH = re.compile(r"(?<![\w./:<>-])(?P<path>(?:\.{1,2}/)*[A-Za-z0-9_][A-Za-z0-9_./-]*\.md)(?![\w/-])")
HEADING = re.compile(r"^ {0,3}#{1,6}[ \t]+(.*?)[ \t#]*$")
# A fence's container: up to 3 spaces, then block quote markers and list markers, each with the spaces after it.
FENCE_OPEN = re.compile(r"^(?P<prefix> {0,3}(?:(?:>|[-*+]|\d+[.)])(?:[ \t]+|$))*?[ \t]{0,3})(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
QUOTE = re.compile(r"^[ \t]*(?:>[ \t]?)+")
REGION_OPEN = re.compile(r"^[ \t]*<!--[ \t]*citations:[ \t]*(?P<path>\S+\.md)[ \t]*-->[ \t]*$")
REGION_CLOSE = re.compile(r"^[ \t]*<!--[ \t]*/citations[ \t]*-->[ \t]*$")
RANGE = re.compile(r"§(\d+)\.(\d+)[–-](?:§?\1\.)?(\d+)(?![\d.])")
LIST_ITEM = re.compile(r"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+")
SOURCE_COMMENT = re.compile(r"^[ \t]*(?://|/\*|\*|#)")


class Tree:
    """The files the checker reads: the repository, or the self-test's files in memory."""

    def __init__(self, root, files=None):
        self.root = root
        self.files = files

    def normalize(self, rel):
        return os.path.relpath(os.path.normpath(os.path.join(self.root, rel)), self.root)

    def isfile(self, rel):
        if self.files is not None:
            return rel in self.files
        return os.path.isfile(os.path.join(self.root, rel))

    def isdir(self, rel):
        if self.files is not None:
            return any(name.startswith(rel + "/") for name in self.files)
        return os.path.isdir(os.path.join(self.root, rel))

    def read(self, rel):
        if self.files is not None:
            return self.files[rel]
        with open(os.path.join(self.root, rel), encoding="utf-8") as handle:
            return handle.read()


def tracked_files():
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], check=True, capture_output=True).stdout
    # This file's self-test cases name files that exist only in the self-test.
    return [p for p in out.decode().split("\0") if p.endswith(SUFFIXES) and p != SELF]


def opens(line):
    """The fence a line opens, as (fence, column of the container's content, in a block quote), or None."""
    match = FENCE_OPEN.match(line)
    if not match or (match.group("fence")[0] == "`" and "`" in match.group("info")):
        return None
    prefix = match.group("prefix")
    quote = QUOTE.match(prefix)
    quoted = quote.group(0) if quote else ""
    return match.group("fence"), len(prefix) - len(quoted), bool(quoted)


def closes(line, fence):
    marks, column, quoted = fence
    if quoted:
        line = QUOTE.sub("", line, count=1)
    pattern = r"^[ \t]{0," + str(column + 3) + "}" + re.escape(marks[0]) + "{" + str(len(marks)) + r",}[ \t]*$"
    return re.match(pattern, line) is not None


def markdown_paragraphs(lines):
    """Paragraphs of a Markdown file as lists of (line number, text)."""
    paragraphs, current, fence = [], [], None

    def flush():
        nonlocal current
        if current:
            paragraphs.append(current)
        current = []

    for number, line in enumerate(lines, 1):
        if fence:
            if closes(line, fence):
                flush()
                fence = None
            elif line.strip():
                current.append((number, line))
            else:
                flush()
            continue
        fence = opens(line)
        if fence:
            flush()
        elif not line.strip():
            flush()
        elif HEADING.match(line) or line.lstrip().startswith("|"):
            flush()
            paragraphs.append([(number, line)])
        else:
            if LIST_ITEM.match(line):
                flush()
            current.append((number, line))
    flush()
    return paragraphs


def source_paragraphs(lines):
    """Paragraphs of a source file: runs of comment lines (a `/* ... */` block whole); every other line alone."""
    paragraphs, current, block = [], [], False
    for number, line in enumerate(lines, 1):
        if block or (SOURCE_COMMENT.match(line) and not line.startswith("#!")):
            opened = block or line.lstrip().startswith("/*")
            if opened:
                start = 0 if block else line.index("/*") + 2
                block = "*/" not in line[start:]
            current.append((number, line))
            continue
        if current:
            paragraphs.append(current)
            current = []
        if "§" in line or ".md" in line:
            paragraphs.append([(number, line)])
    if current:
        paragraphs.append(current)
    return paragraphs


def headings(tree, rel, cache):
    """The headings of a Markdown file, outside fenced code."""
    if rel not in cache:
        texts, fence = [], None
        for line in tree.read(rel).split("\n"):
            if fence:
                if closes(line, fence):
                    fence = None
                continue
            fence = opens(line)
            if fence:
                continue
            match = HEADING.match(line)
            if match:
                texts.append(match.group(1).strip().strip("*`"))
        cache[rel] = texts
    return cache[rel]


def has_section(texts, number):
    pattern = re.compile(re.escape(number) + r"(?:\.?(?:[ \t]|$))")
    return any(pattern.match(text) for text in texts)


def resolve(tree, cited, citing, link):
    """The repository path of a named file, or None when it does not exist."""
    here = os.path.dirname(citing)
    if link and cited.startswith("/"):
        candidate = cited.lstrip("/")
    elif link or cited.startswith(("./", "../")):
        candidate = os.path.join(here, cited)
    elif "/" in cited and tree.isdir(cited.split("/", 1)[0]):
        candidate = cited
    else:
        candidate = os.path.join(here, cited)
    candidate = os.path.normpath(candidate)
    return candidate if not candidate.startswith("..") and tree.isfile(candidate) else None


def tokens(text, in_docs):
    """The files named and the sections cited in one paragraph, in order: (offset, kind, value, is a link)."""
    found, links = [], []
    for link in LINK.finditer(text):
        links.append(link.span())
        dest = link.group("angle") if link.group("angle") is not None else link.group("plain")
        dest = dest.split("#", 1)[0]
        if dest.endswith(".md") and "://" not in dest:
            found.append((link.start(), "file", dest, True))
    for match in PATH.finditer(text):
        path = match.group("path")
        if any(start <= match.start() < end for start, end in links):
            continue
        if "/" in path or in_docs:
            found.append((match.start(), "file", path, False))
    for match in SECTION.finditer(text):
        found.append((match.start(), "section", match.group(1), False))
    return sorted(found, key=lambda token: (token[0], token[1] == "section"))


def index_map(tree, rel, cache):
    """What an index's table rows map each listed section number to: {number: file}."""
    key = ("index", rel)
    if key not in cache:
        mapping = {}
        for line in tree.read(rel).split("\n"):
            if not line.lstrip().startswith("|"):
                continue
            dests = [link.group("angle") or link.group("plain") for link in LINK.finditer(line)]
            dests = [dest for dest in dests if dest.endswith(".md")]
            if not dests:
                continue
            target = os.path.normpath(os.path.join(os.path.dirname(rel), dests[-1]))
            numbers = [match.group(1) for match in SECTION.finditer(line)]
            for match in RANGE.finditer(line):
                major, first, last = match.group(1), int(match.group(2)), int(match.group(3))
                numbers += [f"{major}.{minor}" for minor in range(first, last + 1)]
            for number in numbers:
                mapping.setdefault(number, target)
        cache[key] = mapping
    return cache[key]


def region_resolves(tree, rel, number, cache):
    if has_section(headings(tree, rel, cache), number):
        return True
    mapping = index_map(tree, rel, cache)
    parts = number.split(".")
    while parts:
        target = mapping.get(".".join(parts))
        if target:
            return tree.isfile(target) and has_section(headings(tree, target, cache), number)
        parts.pop()
    return False


def regions(lines):
    """The file each line's bare sections cite through a `<!-- citations: ... -->` region: {line number: path}."""
    found, current = {}, None
    for number, line in enumerate(lines, 1):
        opening = REGION_OPEN.match(line)
        if opening:
            current = opening.group("path")
        elif REGION_CLOSE.match(line):
            current = None
        elif current:
            found[number] = current
    return found


def check(paths, tree):
    cache = {}
    problems = []
    count = 0
    for given in paths:
        rel = tree.normalize(given)
        try:
            text = tree.read(rel)
        except (OSError, UnicodeDecodeError, KeyError) as error:
            problems.append(f"{rel}: cannot read: {error}")
            continue
        markdown = rel.endswith(".md")
        in_docs = markdown and rel.startswith("docs/")
        lines = text.split("\n")
        region_of = regions(lines) if markdown else {}
        for paragraph in (markdown_paragraphs if markdown else source_paragraphs)(lines):
            joined = "\n".join(line for _, line in paragraph)
            starts = []
            offset = 0
            for number, line in paragraph:
                starts.append((offset, number))
                offset += len(line) + 1

            def line_of(position):
                return [number for start, number in starts if start <= position][-1]

            named = None
            for position, kind, value, link in tokens(joined, in_docs):
                if kind == "file":
                    named = (value, resolve(tree, value, rel, link))
                    continue
                if named is None:
                    region = region_of.get(line_of(position))
                    if region:
                        count += 1
                        target = os.path.normpath(region)
                        if not tree.isfile(target):
                            problems.append(f"{rel}:{line_of(position)}: {region} §{value}: no such file")
                        elif not region_resolves(tree, target, value, cache):
                            problems.append(f"{rel}:{line_of(position)}: {region} §{value}: no heading {value} in "
                                            f"{target} or the file its index maps it to")
                    continue
                count += 1
                cited, target = named
                if target is None:
                    problems.append(f"{rel}:{line_of(position)}: {cited} §{value}: no such file")
                elif not has_section(headings(tree, target, cache), value):
                    problems.append(f"{rel}:{line_of(position)}: {cited} §{value}: no heading {value} in {target}")
    return count, problems


SELF_TEST_FILES = {
    "docs/a.md": "# A\n\n## 1.3 Three\n\n### 4.10 Ten\n\n````md\n```\n## 9.9 Inside a fence\n```\n````\n",
    "docs/c.md": "# C\n\n```\n    ```\n## 7.1 Still fenced: that closing fence is indented 4 spaces\n```\n",
    "docs/sub/b.md": "# B\n\n## 1.1 One\n",
    "docs/spec.md": "# Spec\n\n## 1.2 Two\n",
    "docs/conventions.md": "# Conventions\n\n### 1.7 Locks\n",
    "docs/meeting-design.md": "# Index\n\n## 1.3 Concurrency\n\n§4.1 is in another file.\n",
    "link-target.md": "[design](docs/a.md) §1.3 resolves; [design](docs/a.md) §3.2 does not.\n",
    "link-text.md": "[docs/a.md](missing.md) §4.10 and [docs/a.md §1.3](missing.md) cite the destination.\n",
    "link-chain.md": "[Concurrency §1.3](docs/meeting-design.md), §3.2\n",
    "wrapped-label.swift": "/// [docs/meeting-design.md\n/// §1.3](missing.md)\n",
    "link-forms.md": '[label](<docs/spec.md>) §1.2 and [label](docs/spec.md "title") §1.2, §9.1\n',
    "qualifier.swift": "// docs/conventions.md §1.7 rule 4, §4.1\n",
    "wrapped.swift": "/// (docs/a.md §1.3\n/// and §3.2)\n",
    "comma-and.swift": "// docs/a.md §1.3, and §3.2\n",
    "subheading.swift": '/// (docs/a.md §1.3, "A heading that wraps\n/// here"; §5.11, "Other"): rest\n',
    "code-breaks.swift": "// docs/a.md §1.3\nlet x = 1\n// §3.2 is bare: the code line ends the comment\n",
    "docs/sub/relative.md": "./b.md §1.1, ../a.md §1.3 and docs/a.md §1.3 resolve; ./a.md §1.3 does not.\n",
    "fence.md": "docs/a.md §9.9\n",
    "docs/fenced.md": "# F\n\n- ```\n  ## 8.1 Fake\n  ```\n\n1. ```\n   ## 8.2 Fake\n   ```\n\n> ```\n## 8.3 Fake\n> ```\n",
    "fence-containers.md": "docs/fenced.md §8.1, §8.2 and §8.3\n",
    "block.swift": "/* docs/spec.md\nSee §99.9\n*/\n/* docs/spec.md §1.2\n and §9.9\n*/\nlet x = 1 // §9.8\n",
    "docs/sub/deep.md": "../../docs/spec.md §99.9\n",
    "docs/folder.md": "missing/status.md §1.1, and sub/b.md §1.1 resolves.\n",
    "nested-label.md": "[§99.9 [draft]](missing.md)\n",
    "docs/index.md": "# Index\n\n| §1.1 One | [sub/b.md](sub/b.md) |\n| §1.2–1.3 Two | [spec.md](spec.md) |\n",
    "docs/region.md": "<!-- citations: docs/index.md -->\n| §1.1 | §1.2 | §1.3 | §7.7 |\n<!-- /citations -->\n§7.7\n",
    "fence-indent.md": "docs/c.md §7.1\n",
    "prefix.md": "docs/a.md §4.1 is not docs/a.md §4.10.\n",
    "docs/bare.md": "# Bare\n\n## 2.1 Here\n\nSee §2.1 and §2.2; docs/a.md §1.3, §2.1 is a citation.\n\n- §2.3 is bare\n",
    "bare.swift": "// §7.7 is not checked outside docs/; nor is https://example.com/README.md §2.\n",
}
SELF_TEST_PATHS = [name for name in SELF_TEST_FILES if name not in ("docs/a.md", "docs/c.md", "docs/sub/b.md",
                                                                     "docs/spec.md", "docs/conventions.md",
                                                                     "docs/fenced.md", "docs/index.md")]
SELF_TEST_PROBLEMS = [
    "link-target.md:1: docs/a.md §3.2: no heading 3.2 in docs/a.md",
    "link-text.md:1: missing.md §4.10: no such file",
    "link-text.md:1: missing.md §1.3: no such file",
    "link-chain.md:1: docs/meeting-design.md §3.2: no heading 3.2 in docs/meeting-design.md",
    "wrapped-label.swift:2: missing.md §1.3: no such file",
    "link-forms.md:1: docs/spec.md §9.1: no heading 9.1 in docs/spec.md",
    "qualifier.swift:1: docs/conventions.md §4.1: no heading 4.1 in docs/conventions.md",
    "wrapped.swift:2: docs/a.md §3.2: no heading 3.2 in docs/a.md",
    "comma-and.swift:1: docs/a.md §3.2: no heading 3.2 in docs/a.md",
    "subheading.swift:2: docs/a.md §5.11: no heading 5.11 in docs/a.md",
    "docs/sub/relative.md:1: ./a.md §1.3: no such file",
    "fence.md:1: docs/a.md §9.9: no heading 9.9 in docs/a.md",
    "fence-indent.md:1: docs/c.md §7.1: no heading 7.1 in docs/c.md",
    "prefix.md:1: docs/a.md §4.1: no heading 4.1 in docs/a.md",
    "docs/bare.md:5: docs/a.md §2.1: no heading 2.1 in docs/a.md",
    "fence-containers.md:1: docs/fenced.md §8.1: no heading 8.1 in docs/fenced.md",
    "fence-containers.md:1: docs/fenced.md §8.2: no heading 8.2 in docs/fenced.md",
    "fence-containers.md:1: docs/fenced.md §8.3: no heading 8.3 in docs/fenced.md",
    "block.swift:2: docs/spec.md §99.9: no heading 99.9 in docs/spec.md",
    "block.swift:5: docs/spec.md §9.9: no heading 9.9 in docs/spec.md",
    "docs/sub/deep.md:1: ../../docs/spec.md §99.9: no heading 99.9 in docs/spec.md",
    "docs/folder.md:1: missing/status.md §1.1: no such file",
    "nested-label.md:1: missing.md §99.9: no such file",
    "docs/region.md:2: docs/index.md §1.3: no heading 1.3 in docs/index.md or the file its index maps it to",
    "docs/region.md:2: docs/index.md §7.7: no heading 7.7 in docs/index.md or the file its index maps it to",
]


def self_test():
    count, problems = check(SELF_TEST_PATHS, Tree("/self-test", SELF_TEST_FILES))
    missing = [line for line in SELF_TEST_PROBLEMS if line not in problems]
    unexpected = [line for line in problems if line not in SELF_TEST_PROBLEMS]
    for line in missing:
        print(f"self-test: not reported: {line}")
    for line in unexpected:
        print(f"self-test: reported but should not be: {line}")
    print(f"self-test: {count} citations, {len(problems)} problems, {len(missing) + len(unexpected)} mismatches")
    return 1 if missing or unexpected else 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    paths = sys.argv[1:] or tracked_files()
    count, problems = check(paths, Tree(ROOT))
    for line in problems:
        print(line)
    print(f"{count} citations in {len(paths)} files, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
