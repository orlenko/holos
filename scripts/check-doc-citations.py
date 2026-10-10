#!/usr/bin/env python3
"""Checks that every numbered doc citation in the repository resolves (AGENTS.md "Docs and comments").

    scripts/check-doc-citations.py               check every tracked .swift, .md, .sh and .py file
    scripts/check-doc-citations.py FILE...       check only these files
    scripts/check-doc-citations.py --self-test   run the checker's own cases (in memory; writes nothing)

Each file is split into paragraphs: in Markdown, a paragraph, a list item, a row of a table (a header row followed
by a delimiter row; with or without a leading pipe) or a heading, read through block quote markers (a blank quoted
line ends a paragraph, a change of quote depth starts one; inside fenced code, each run of non-blank lines; HTML
comments, also after block quote and list markers, and citation region markers belong to none); in Swift, a run of
`//` lines or a whole `/* ... */` block, nested to any depth, with string literals (escapes, interpolations, raw and
multiline strings) lexed so a comment marker inside one is text; in shell and Python, a run of `#` lines; every
other source line on its own. Paragraphs, headings, index rows, regions and reference definitions all come from one
reading of each Markdown line (`classify`), so fences, block quotes, HTML comments and markers mean the same in
each. Within a paragraph, every `§<N.M>` cites the last Markdown file named before it in that paragraph. A file is
named by

- a Markdown link to it: inline (`[label](<file>.md)`, `[label](<<file>.md>)`, a title in quotes or parentheses,
  a destination with balanced parentheses) or by reference (`[label][ref]`, `[ref][]`, `[ref]` with
  `[ref]: <file>.md` defined in the file). The label may wrap across lines and hold brackets nested to any depth,
  backslash escapes and code spans; its text never names a file (a `§` inside it cites the link's file). Links in
  code spans are not links;
- a path: `docs/<file>.md`, `./<file>.md`, any number of `../` before it, any path with a folder, and in Markdown
  files under `docs/` also a plain `<file>.md`. A path that a section follows must be written from the repository
  root (`docs/<file>.md §<N.M>`, AGENTS.md); only link destinations are relative.

A citation resolves when the file exists and has a heading, outside fenced code and HTML comments and possibly in a
block quote, whose text starts with the number: `§4.1` needs a heading `4.1 ...` (not `4.10 ...`), and `§3` a
heading `3. ...` or `3 ...`. A range (`§<A>–<B>` or `§<A>–§<B>`, with an en dash or a hyphen) cites every number in
it, counting up the last component (`§4.1–4.3` is 4.1, 4.2 and 4.3; `§8–§10` is 8, 9 and 10). Fences follow
CommonMark, also after list markers and block quote markers in any order: a block closes at a fence of the same
character, at least as long as the opening one, inside the same block quotes, and indented at most 3 spaces more
than the opening fence's container. Files are found like this:

- a link destination: from the citing file's folder (from the repository root when it starts with `/`);
- a path starting with `./` or `../`: from the citing file's folder;
- a path whose first folder is a top-level folder of the repository (`docs/...`, `Sources/...`): from the root;
- any other path: from the citing file's folder.

A `§<N.M>` with no file named before it in its paragraph is bare and is not checked: it names a section of the file
it appears in, or, in older code comments, of the meeting design, whose section numbers are unique. Between the
lines `<!-- citations: <file>.md -->` and `<!-- /citations -->` of a Markdown file (outside fenced code; regions
nest, the innermost counts, and each must be closed), a bare `§<N.M>` cites that file (from the repository root). It
resolves to a heading of that file or, when that file is an index, to a heading of the file its table maps the
number to: a row names `§<N.M>`, or a range `§<N.M>–<N.K>` that holds it, and the first cell after it with a link
has exactly one (inline or by reference); a number not listed is looked up by its parents: `§0.2` by `§0`.

Prints each problem as `file:line: ...` and a summary; exits 1 when there is any.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUFFIXES = (".swift", ".md", ".sh", ".py")
SELF = "scripts/check-doc-citations.py"

REFERENCE = re.compile(r"^ {0,3}\[(?P<label>(?:[^\[\]\\]|\\.)+)\]:[ \t]*(?:<(?P<angle>[^<>\n]*)>|(?P<plain>\S+))")
PATH = re.compile(r"(?<![\w./:>-])(?P<path>(?:\.{1,2}/)*[A-Za-z0-9_][A-Za-z0-9_./-]*\.md)(?![\w/-])")
HEADING = re.compile(r"^ {0,3}#{1,6}[ \t]+(.*?)[ \t#]*$")
# A fence's container: up to 3 spaces, then block quote markers and list markers, each with the spaces after it.
FENCE_OPEN = re.compile(
    r"^(?P<prefix> {0,3}(?:>[ \t]*|(?:[-*+]|\d+[.)])[ \t]+)*[ \t]{0,3})(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
FENCE_CLOSE = re.compile(r"^(?P<lead>[ \t>]*)(?P<marks>`{3,}|~{3,})[ \t]*$")
REGION_OPEN = re.compile(r"^[ \t]*<!--[ \t]*citations:[ \t]*(?P<path>\S+\.md)[ \t]*-->[ \t]*$")
REGION_CLOSE = re.compile(r"^[ \t]*<!--[ \t]*/citations[ \t]*-->[ \t]*$")
# A section number or a range of them: `§4.1`, `§4.1–4.6`, `§4.1-§4.6`, `§8–§10`.
SECTION_RUN = re.compile(r"§(\d+(?:\.\d+)*)(?:[–-]§?(\d+(?:\.\d+)*))?(?!\d)")
LIST_ITEM = re.compile(r"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+")
QUOTE_PREFIX = re.compile(r"^(?:[ \t]{0,3}>[ \t]?)+")
# The container markers before a line's own content: block quote markers and list markers, in any order.
CONTAINER_PREFIX = re.compile(r"^(?:[ \t]{0,3}>[ \t]?|[ \t]*(?:[-*+]|\d+[.)])[ \t]+)+")
SWIFT_CODE = re.compile(r'//|/\*|(#*)"("")?')
SWIFT_COMMENT = re.compile(r"/\*|\*/")
TABLE_DELIMITER = re.compile(r"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*$|^[ \t]*\|[ \t]*:?-+:?[ \t]*\|[ \t]*$")


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


def code_span_end(text, i):
    """The end of the code span opening at text[i] (a run of backticks), or i + the run's length when unclosed."""
    run = len(text[i:]) - len(text[i:].lstrip("`"))
    closing = re.compile(r"(?<!`)" + "`" * run + r"(?!`)")
    match = closing.search(text, i + run)
    return match.end() if match else i + run


def bracket_end(text, i):
    """The index of the `]` that closes the `[` at text[i], at any depth, past escapes and code spans; or None."""
    depth, j = 0, i
    while j < len(text):
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == "`":
            j = code_span_end(text, j)
            continue
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return None


def destination(text, i):
    """The inline link destination in `(...)` at text[i]: (destination, index after the `)`), or (None, i). Accepts
    `<dest>`, a destination with balanced parentheses, and a title in quotes or parentheses."""
    j = i + 1
    j += len(text[j:]) - len(text[j:].lstrip(" \t\n"))
    if j < len(text) and text[j] == "<":
        end = j + 1
        while end < len(text) and text[end] not in "<>\n":
            end += 2 if text[end] == "\\" else 1
        if end >= len(text) or text[end] != ">":
            return None, i
        dest, j = text[j + 1:end], end + 1
    else:
        start, depth = j, 0
        while j < len(text) and not text[j].isspace():
            c = text[j]
            if c == "\\":
                j += 2
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                if depth == 0:
                    break
                depth -= 1
            j += 1
        if depth:
            return None, i
        dest = text[start:j]
    j += len(text[j:]) - len(text[j:].lstrip(" \t\n"))
    if j < len(text) and text[j] in "\"'(":
        close = {"\"": "\"", "'": "'", "(": ")"}[text[j]]
        j += 1
        while j < len(text) and text[j] != close:
            j += 2 if text[j] == "\\" else 1
        j += 1
        j += len(text[j:]) - len(text[j:].lstrip(" \t\n"))
    if j < len(text) and text[j] == ")":
        return dest, j + 1
    return None, i


def references(text):
    """The link reference definitions of a Markdown text, outside fenced code and HTML comments: {normalized label:
    destination}."""
    found = {}
    lines = text.split("\n")
    for (kind, content, _, _) in classify(lines)[0]:
        match = REFERENCE.match(content) if kind == "text" else None
        if match:
            found.setdefault(" ".join(match.group("label").lower().split()),
                             match.group("angle") if match.group("angle") is not None else match.group("plain"))
    return found


def links(text, refs):
    """Every link in `text`: (start, end, label start, label end, destination). Inline links (any balanced label,
    `<dest>`, a title) and reference links (`[text][ref]`, `[ref][]`, `[ref]` when `ref` is defined). Links inside
    code spans are not links."""
    found, i = [], 0
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "`":
            i = code_span_end(text, i)
            continue
        if c != "[":
            i += 1
            continue
        end = bracket_end(text, i)
        if end is None:
            i += 1
            continue
        dest, after = None, end + 1
        if after < len(text) and text[after] == "(":
            dest, after = destination(text, after)
        if dest is None and after < len(text) and text[after] == "[":
            ref_end = bracket_end(text, after)
            if ref_end is not None:
                ref = text[after + 1:ref_end] or text[i + 1:end]
                dest = refs.get(" ".join(ref.lower().split()))
                after = ref_end + 1 if dest is not None else end + 1
        if dest is None and (after >= len(text) or text[after] not in "(["):
            dest = refs.get(" ".join(text[i + 1:end].lower().split()))
            after = end + 1
        if dest is None:
            i += 1
            continue
        found.append((i, after, i + 1, end, dest))
        i = after
    return found


def opens(line):
    """The fence a line opens, as (fence, width of its container prefix, block quote markers in it), or None."""
    match = FENCE_OPEN.match(line)
    if not match or (match.group("fence")[0] == "`" and "`" in match.group("info")):
        return None
    prefix = match.group("prefix")
    return match.group("fence"), len(prefix), prefix.count(">")


def closes(line, fence):
    """Whether a line closes the fence: same character, at least as long, inside the same block quotes, and
    indented at most 3 spaces more than the opening fence's container."""
    marks, width, quotes = fence
    match = FENCE_CLOSE.match(line)
    return (match is not None and match.group("marks")[0] == marks[0] and len(match.group("marks")) >= len(marks)
            and match.group("lead").count(">") == quotes and len(match.group("lead")) <= width + 3)


def sections(text):
    """Every section number in `text` with its offset, ranges expanded (`§4.1–4.3` is 4.1, 4.2 and 4.3)."""
    found = []
    for match in SECTION_RUN.finditer(text):
        first, last = match.group(1), match.group(2)
        numbers = [first]
        if last:
            start, end = first.split("."), last.split(".")
            if len(end) < len(start):
                end = start[:len(start) - len(end)] + end
            if len(start) == len(end) and start[:-1] == end[:-1] and 0 < int(end[-1]) - int(start[-1]) <= 100:
                numbers = [".".join(start[:-1] + [str(n)]) for n in range(int(start[-1]), int(end[-1]) + 1)]
            else:
                numbers.append(".".join(end))
        found += [(number, match.start()) for number in numbers]
    return found


def classify(lines):
    """The one reading of a Markdown file's lines that every pass uses: ([(kind, content, quote depth, region)],
    problems). `content` is the line without its block quote markers. Kinds: "fence" (a fence line), "code" (inside
    fenced code), "html" (an HTML comment block, after any block quote and list markers; it runs to the line holding
    `-->`), "marker" (a `<!-- citations: ... -->` or `<!-- /citations -->` line), "blank", "heading", "row" (a table
    row: a header row followed by a delimiter row, that delimiter row, and the rows after it), "text". `region` is the
    path of the innermost open citations region (regions nest; an unclosed region or a stray close is a problem).
    Nothing inside fenced code or an HTML comment is a marker, a heading, a row or a reference definition."""
    infos, problems, stack, fence, comment = [], [], [], None, False
    for number, line in enumerate(lines, 1):
        quote = QUOTE_PREFIX.match(line)
        content = line[quote.end():] if quote else line
        container = CONTAINER_PREFIX.match(line)
        inner = line[container.end():] if container else line
        depth = quote.group(0).count(">") if quote else 0
        if fence:
            kind = "fence" if closes(line, fence) else "code"
            fence = None if kind == "fence" else fence
        elif comment:
            kind, comment = "html", "-->" not in content
        elif opens(line):
            kind, fence = "fence", opens(line)
        elif REGION_OPEN.match(inner):
            kind = "marker"
            stack.append((REGION_OPEN.match(inner).group("path"), number))
        elif REGION_CLOSE.match(inner):
            kind = "marker"
            if stack:
                stack.pop()
            else:
                problems.append((number, "<!-- /citations --> with no region open"))
        elif re.match(r"^ {0,3}<!--", inner):
            kind, comment = "html", "-->" not in inner[inner.index("<!--") + 4:]
        elif not content.strip():
            kind = "blank"
        elif HEADING.match(content):
            kind = "heading"
        else:
            kind = "text"
        infos.append([kind, content, depth, stack[-1][0] if stack and kind != "marker" else None])
    problems += [(number, f"<!-- citations: {path} --> is never closed") for path, number in stack]
    table = False
    for index, info in enumerate(infos):
        follows = infos[index + 1] if index + 1 < len(infos) else None
        if info[0] != "text" or "|" not in info[1]:
            table = False
        elif table or (follows and follows[0] == "text" and follows[2] == info[2]
                       and TABLE_DELIMITER.match(follows[1])):
            info[0], table = "row", True
    return [tuple(info) for info in infos], problems


def markdown_paragraphs(lines):
    """Paragraphs of a Markdown file as lists of (line number, text), from `classify`. Block quote markers are read
    through: a blank quoted line ends a paragraph, and a change of quote depth starts one. Each table row (with or
    without a leading pipe) is its own paragraph; inside fenced code, each run of non-blank lines is one. Fence lines,
    HTML comments and region markers are boundaries and belong to no paragraph."""
    infos, _ = classify(lines)
    paragraphs, current, depth = [], [], 0

    def flush():
        nonlocal current
        if current:
            paragraphs.append(current)
        current = []

    for number, (line, (kind, content, quotes, _)) in enumerate(zip(lines, infos), 1):
        if kind == "code":
            if content.strip():
                current.append((number, line))
            else:
                flush()
            continue
        if kind in ("fence", "html", "marker", "blank"):
            flush()
            continue
        if quotes and quotes != depth:
            flush()
        depth = quotes
        if kind in ("heading", "row"):
            flush()
            paragraphs.append([(number, line)])
        else:
            if LIST_ITEM.match(content):
                flush()
            current.append((number, line))
    flush()
    return paragraphs


def swift_string_end(line, j, hashes, close):
    """The index after a Swift string's closing delimiter `close`, scanning from line[j] inside the string, or None
    when the line ends first. Escapes (`\\` and `#`s for a raw string) are skipped, and an interpolation `\\(...)`
    is skipped whole, strings inside it included."""
    escape = "\\" + "#" * hashes
    while j < len(line):
        if line.startswith(close, j):
            return j + len(close)
        if line.startswith(escape, j):
            j += len(escape)
            if j < len(line) and line[j] == "(":
                depth = 0
                while j < len(line):
                    if line[j] == "(":
                        depth += 1
                    elif line[j] == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    elif line[j] == '"':
                        end = swift_string_end(line, j + 1, 0, '"')
                        j = len(line) if end is None else end
                        continue
                    j += 1
            j += 1
            continue
        j += 1
    return None


def swift_scan(line, state):
    """The Swift lexer state after a line: (block comment depth, hashes of an open multiline string or None). String
    literals (`"..."`, raw `#"..."#`, multiline `\"\"\"...\"\"\"`) are skipped, so a `/*` or `//` inside one is text."""
    depth, multiline = state
    j = 0
    while j < len(line):
        if multiline is not None:
            end = swift_string_end(line, j, multiline, '"""' + "#" * multiline)
            if end is None:
                return depth, multiline
            j, multiline = end, None
        elif depth:
            match = SWIFT_COMMENT.search(line, j)
            if not match:
                return depth, None
            depth += 1 if match.group() == "/*" else -1
            j = match.end()
        else:
            match = SWIFT_CODE.search(line, j)
            if not match or match.group() == "//":
                return 0, None
            if match.group() == "/*":
                depth, j = 1, match.end()
            elif match.group(2):
                multiline, j = len(match.group(1)), match.end()
            else:
                hashes = len(match.group(1))
                end = swift_string_end(line, match.end(), hashes, '"' + "#" * hashes)
                j = len(line) if end is None else end
    return depth, multiline


def source_paragraphs(lines, swift):
    """Paragraphs of a source file: runs of comment lines (`//` lines and whole `/* ... */` blocks, nested to any
    depth, in Swift; `#` lines in shell and Python); every other line alone. Swift string literals are lexed, so a
    comment marker inside one is text; a line that cannot change the lexer state (no `/*`, no `\"\"\"`, outside a
    block comment and a multiline string) is not lexed."""
    paragraphs, current, state = [], [], (0, None)
    for number, line in enumerate(lines, 1):
        start, stripped = state, line.lstrip()
        if swift:
            if state != (0, None) or "/*" in line or '"""' in line:
                state = swift_scan(line, state)
            starts_comment = start == (0, None) and stripped.startswith(("//", "/*"))
            inside = start[0] > 0
        else:
            starts_comment = stripped.startswith("#") and not line.startswith("#!")
            inside = False
        if inside or starts_comment:
            current.append((number, line))
            continue
        if current:
            paragraphs.append(current)
            current = []
        if state[0]:
            current.append((number, line))
        elif "§" in line or ".md" in line:
            paragraphs.append([(number, line)])
    if current:
        paragraphs.append(current)
    return paragraphs


def headings(tree, rel, cache):
    """The headings of a Markdown file, from `classify`: outside fenced code and HTML comments, possibly in a block
    quote."""
    if rel not in cache:
        cache[rel] = [HEADING.match(content).group(1).strip().strip("*`")
                      for kind, content, _, _ in classify(tree.read(rel).split("\n"))[0] if kind == "heading"]
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


def tokens(text, in_docs, refs):
    """The files named and the sections cited in one paragraph, in order: (offset, kind, value, is a link)."""
    found, spans = [], []
    for start, end, label_start, label_end, dest in links(text, refs):
        spans.append((start, end))
        dest = dest.split("#", 1)[0]
        if dest.endswith(".md") and "://" not in dest:
            found.append((start, "file", dest, True))
    for match in PATH.finditer(text):
        path = match.group("path")
        if any(start <= match.start() < end for start, end in spans):
            continue
        if "/" in path or in_docs:
            found.append((match.start(), "file", path, False))
    for number, offset in sections(text):
        found.append((offset, "section", number, False))
    return sorted(found, key=lambda token: (token[0], token[1] == "section"))


def row_cells(line):
    """The cells of a table row as (start, end) spans, split at pipes outside code spans and escapes."""
    cells, start, j = [], 0, 0
    while j < len(line):
        if line[j] == "\\":
            j += 2
            continue
        if line[j] == "`":
            j = code_span_end(line, j)
            continue
        if line[j] == "|":
            cells.append((start, j))
            start = j + 1
        j += 1
    cells.append((start, len(line)))
    return cells


def row_sections(line, refs):
    """The section numbers of an index row with the `.md` links they map to: [(number, offset, [destinations])].
    A number maps to the links of the first cell after its own that has any; a well-formed row has exactly one."""
    cells = row_cells(line)
    dests = []
    for start, end in cells:
        found = [link[4].split("#", 1)[0] for link in links(line[start:end], refs)]
        dests.append([dest for dest in found if dest.endswith(".md") and "://" not in dest])
    rows = []
    for number, offset in sections(line):
        cell = next(index for index, (start, end) in enumerate(cells) if start <= offset < end)
        rows.append((number, offset, next((found for found in dests[cell + 1:] if found), [])))
    return rows


def index_map(tree, rel, cache):
    """What an index's table rows map each listed section number to: {number: file}. Rows come from `classify` (real
    table rows only, none in fenced code or HTML comments); reference links resolve through the index's own
    definitions, and a destination starting with `/` from the repository root."""
    key = ("index", rel)
    if key not in cache:
        mapping = {}
        text = tree.read(rel)
        refs = references(text)
        for kind, content, _, _ in classify(text.split("\n"))[0]:
            if kind != "row":
                continue
            for number, _, dests in row_sections(content, refs):
                if len(dests) == 1:
                    dest = dests[0]
                    path = dest.lstrip("/") if dest.startswith("/") else os.path.join(os.path.dirname(rel), dest)
                    mapping.setdefault(number, os.path.normpath(path))
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


def root_form(tree, cited):
    """Whether a path is written from the repository root (`docs/...`, `Sources/...`)."""
    return "/" in cited and not cited.startswith(".") and tree.isdir(cited.split("/", 1)[0])


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
        infos, region_problems = classify(lines) if markdown else ([], [])
        region_of = {number: info[3] for number, info in enumerate(infos, 1) if info[3]}
        problems += [f"{rel}:{number}: {problem}" for number, problem in region_problems]
        refs = references(text) if markdown else {}
        paragraphs = markdown_paragraphs(lines) if markdown else source_paragraphs(lines, rel.endswith(".swift"))
        for paragraph in paragraphs:
            joined = "\n".join(line for _, line in paragraph)
            starts = []
            offset = 0
            for number, line in paragraph:
                starts.append((offset, number))
                offset += len(line) + 1

            def line_of(position):
                return [number for start, number in starts if start <= position][-1]

            named = None
            if "§" not in joined and not (in_docs and ".md" in joined):
                continue
            for position, kind, value, link in tokens(joined, in_docs, refs):
                if kind == "file":
                    named = (value, resolve(tree, value, rel, link), link)
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
                cited, target, linked = named
                if not linked and not root_form(tree, cited):
                    problems.append(f"{rel}:{line_of(position)}: {cited} §{value}: cite by the path from the repository "
                                    f"root (AGENTS.md)")
                if target is None:
                    problems.append(f"{rel}:{line_of(position)}: {cited} §{value}: no such file")
                elif not has_section(headings(tree, target, cache), value):
                    problems.append(f"{rel}:{line_of(position)}: {cited} §{value}: no heading {value} in {target}")
    return count, problems


SELF_TEST_FILES = {
    "docs/a.md": "# A\n\n## 1.3 Three\n\n### 4.10 Ten\n\n````md\n```\n## 9.9 Inside a fence\n```\n````\n\n"
                 "<!--\n## 9.1 Inside an HTML comment\n-->\n\n> <!--\n> ## 1.5 Inside an HTML comment in a block quote\n> -->\n\n"
                 "- <!--\n  ## 1.6 Inside an HTML comment in a list item\n  -->\n",
    "docs/c.md": "# C\n\n```\n    ```\n## 7.1 Still fenced: that closing fence is indented 4 spaces\n```\n",
    "docs/sub/b.md": "# B\n\n## 1.1 One\n",
    "docs/spec.md": "# Spec\n\n## 1.2 Two\n\n> ## 1.4 A heading in a block quote\n",
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
    "docs/fenced.md": "# F\n\n- ```\n  ## 8.1 Fake\n  ```\n\n1. ```\n   ## 8.2 Fake\n   ```\n\n> ```\n## 8.3 Fake\n> ```\n\n"
                      "- > ```\n## 8.4 Fake\n  > ```\n\n## 8.5 Real: the fence above closed\n\n```\n> ```\n## 8.6 Fake\n```\n\n"
                      ">>> ```\n## 8.7 Fake\n>>> ```\n",
    "fence-containers.md": "docs/fenced.md §8.1, §8.2, §8.3, §8.4, §8.5, §8.6 and §8.7\n",
    "docs/r.md": "# R\n\n## 0.2 A\n\n## 0.4 C\n\n## 8 E\n\n## 10 G\n",
    "ranges.md": "docs/r.md §0.2–0.4 and §8–§10\nand §0.2-0.4, §0.2–§0.4\n",
    "block.swift": "/* docs/spec.md\nSee §99.9\n*/\n/* docs/spec.md §1.2\n and §9.9\n*/\nlet x = 1 // §9.8\n",
    "docs/sub/deep.md": "../../docs/spec.md §99.9\n",
    "docs/folder.md": "missing/status.md §1.1, and sub/b.md §1.1 resolves.\n",
    "nested-label.md": "[§99.9 [draft]](missing.md)\n",
    "deep-label.md": "[§9.9 [outer [inner]]](missing.md)\n\n[§9.8 \\[ escaped](missing.md)\n\n[`]` §9.7](missing.md)\n",
    "nested.swift": "/* docs/a.md /* inner */\n still the outer comment §9.9 */\nlet y = 2 /* docs/a.md\n §9.8 */\n",
    "destinations.md": "[x](missing.md 'title') §9.6\n\n[x](missing.md (title)) §9.5\n\n[x](<docs/a.md>) §1.3\n\n"
                       "[x](miss(ing).md) §8.9\n",
    "reference.md": "[spec][s] §9.4 and [s] §1.3\n\n[s]: docs/a.md\n",
    "strings.swift": 'let a = "/* docs/a.md"\n// §9.7 is bare\nlet b = #"raw "/* docs/a.md"#\n// §9.6 is bare\n'
                     'let c = """\n  /* docs/a.md\n  """\n// §9.5 is bare\nlet d = "\\("/*") docs/a.md"\n// §9.4 is bare\n'
                     'let e = "done" /* docs/a.md\n §9.3 */\n',
    "docs/index3.md": "# I\n\n| Sections | File |\n|---|---|\n| §1.1 One | [B][b] |\n| §1.2 Two | [spec](spec.md) | [B](sub/b.md) |\n\n[b]: sub/b.md\n",
    "docs/region3.md": "<!-- citations: docs/index3.md -->\n| §1.1 | §1.2 |\n<!-- /citations -->\n",
    "code-span.md": "Some words before a `code` then [x](missing.md) §8.8; and `[y](missing2.md) §8.7` is code, "
                    "not a link.\n",
    "quote.md": "> see docs/a.md\n>\n> §9.3 is bare: a blank quoted line ends the paragraph\n",
    "table.md": "a | b\n--- | ---\ndocs/a.md §1.3 | x\n§9.2 | bare in its own row\n",
    "heading-forms.md": "docs/a.md §9.1, docs/spec.md §1.4, docs/a.md §1.5, docs/a.md §1.6\n",
    "docs/index5.md": "# I\n\n```\n| Sections | File |\n|---|---|\n| §1.1 A sample row | [spec](spec.md) |\n```\n\n| Sections | File |\n|---|---|\n"
                      "| §1.1 One | [b](sub/b.md) |\n",
    "docs/region5.md": "<!-- citations: docs/index5.md -->\n| §1.1 |\n<!-- /citations -->\n",
    "docs/index6.md": "# I\n\nProse: §1.1 | then [spec](spec.md), a pipe in a sentence, not a row.\n\n| Sections | File |\n|---|---|\n"
                      "| §1.1 One | [b](/docs/sub/b.md) |\n",
    "docs/region6.md": "<!-- citations: docs/index6.md -->\n§1.1\n<!-- /citations -->\n",
    "docs/marker.md": "<!-- citations: docs/index.md -->\n§1.1 resolves through the index, not as a citation of the marker\n"
                      "<!-- /citations -->\n",
    "reference2.md": "```\n[t]: docs/a.md\n```\n[x][t] §9.9 is bare: the definition is in a fence\n",
    "docs/regions2.md": "<!-- citations: docs/index.md -->\n<!-- citations: docs/a.md -->\n| §1.3 |\n<!-- /citations -->\n"
                        "| §7.7 |\n<!-- /citations -->\n<!-- /citations -->\n<!-- citations: docs/a.md -->\n",
    "docs/index.md": "# Index\n\n| Sections | File |\n|---|---|\n| §1.1 One | [sub/b.md](sub/b.md#11-one) |\n| §1.2–1.3 Two | [spec.md](spec.md) |\n",
    "docs/region.md": "<!-- citations: docs/index.md -->\n| §1.1 | §1.2 | §1.3 | §7.7 |\n<!-- /citations -->\n§7.7\n\n"
                      "```\n<!-- citations: docs/index.md -->\n```\n| §7.6 | outside any region: the marker above is in a fence |\n",
    "fence-indent.md": "docs/c.md §7.1\n",
    "prefix.md": "docs/a.md §4.1 is not docs/a.md §4.10.\n",
    "docs/bare.md": "# Bare\n\n## 2.1 Here\n\nSee §2.1 and §2.2; docs/a.md §1.3, §2.1 is a citation.\n\n- §2.3 is bare\n",
    "bare.swift": "// §7.7 is not checked outside docs/; nor is https://example.com/README.md §2.\n",
}
SELF_TEST_PATHS = [name for name in SELF_TEST_FILES if name not in ("docs/a.md", "docs/c.md", "docs/sub/b.md",
                                                                     "docs/spec.md", "docs/conventions.md",
                                                                     "docs/fenced.md", "docs/index.md", "docs/r.md",
                                                                     "docs/index3.md", "docs/index5.md",
                      "docs/index6.md")]
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
    "docs/sub/relative.md:1: ./b.md §1.1: cite by the path from the repository root (AGENTS.md)",
    "docs/sub/relative.md:1: ../a.md §1.3: cite by the path from the repository root (AGENTS.md)",
    "docs/sub/relative.md:1: ./a.md §1.3: cite by the path from the repository root (AGENTS.md)",
    "docs/sub/deep.md:1: ../../docs/spec.md §99.9: cite by the path from the repository root (AGENTS.md)",
    "docs/folder.md:1: missing/status.md §1.1: cite by the path from the repository root (AGENTS.md)",
    "docs/folder.md:1: sub/b.md §1.1: cite by the path from the repository root (AGENTS.md)",
    "fence.md:1: docs/a.md §9.9: no heading 9.9 in docs/a.md",
    "fence-indent.md:1: docs/c.md §7.1: no heading 7.1 in docs/c.md",
    "prefix.md:1: docs/a.md §4.1: no heading 4.1 in docs/a.md",
    "docs/bare.md:5: docs/a.md §2.1: no heading 2.1 in docs/a.md",
    "fence-containers.md:1: docs/fenced.md §8.1: no heading 8.1 in docs/fenced.md",
    "fence-containers.md:1: docs/fenced.md §8.2: no heading 8.2 in docs/fenced.md",
    "fence-containers.md:1: docs/fenced.md §8.3: no heading 8.3 in docs/fenced.md",
    "fence-containers.md:1: docs/fenced.md §8.4: no heading 8.4 in docs/fenced.md",
    "fence-containers.md:1: docs/fenced.md §8.6: no heading 8.6 in docs/fenced.md",
    "fence-containers.md:1: docs/fenced.md §8.7: no heading 8.7 in docs/fenced.md",
    "ranges.md:1: docs/r.md §0.3: no heading 0.3 in docs/r.md",
    "ranges.md:1: docs/r.md §9: no heading 9 in docs/r.md",
    "ranges.md:2: docs/r.md §0.3: no heading 0.3 in docs/r.md",
    "block.swift:2: docs/spec.md §99.9: no heading 99.9 in docs/spec.md",
    "block.swift:5: docs/spec.md §9.9: no heading 9.9 in docs/spec.md",
    "docs/sub/deep.md:1: ../../docs/spec.md §99.9: no heading 99.9 in docs/spec.md",
    "docs/folder.md:1: missing/status.md §1.1: no such file",
    "nested-label.md:1: missing.md §99.9: no such file",
    "deep-label.md:1: missing.md §9.9: no such file",
    "deep-label.md:3: missing.md §9.8: no such file",
    "deep-label.md:5: missing.md §9.7: no such file",
    "nested.swift:2: docs/a.md §9.9: no heading 9.9 in docs/a.md",
    "nested.swift:4: docs/a.md §9.8: no heading 9.8 in docs/a.md",
    "destinations.md:1: missing.md §9.6: no such file",
    "destinations.md:3: missing.md §9.5: no such file",
    "destinations.md:7: miss(ing).md §8.9: no such file",
    "reference.md:1: docs/a.md §9.4: no heading 9.4 in docs/a.md",
    "code-span.md:1: missing.md §8.8: no such file",
    "strings.swift:12: docs/a.md §9.3: no heading 9.3 in docs/a.md",
    "code-span.md:1: missing.md §8.7: no such file",
    "heading-forms.md:1: docs/a.md §9.1: no heading 9.1 in docs/a.md",
    "heading-forms.md:1: docs/a.md §1.5: no heading 1.5 in docs/a.md",
    "heading-forms.md:1: docs/a.md §1.6: no heading 1.6 in docs/a.md",
    "docs/regions2.md:5: docs/index.md §7.7: no heading 7.7 in docs/index.md or the file its index maps it to",
    "docs/regions2.md:7: <!-- /citations --> with no region open",
    "docs/regions2.md:8: <!-- citations: docs/a.md --> is never closed",
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
