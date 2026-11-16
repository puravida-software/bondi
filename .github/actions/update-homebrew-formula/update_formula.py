"""Rewrite a Homebrew formula's version and Linux sha256 for a release.

Usage: update_formula.py FORMULA VERSION LINUX_SHA

VERSION must not be empty and LINUX_SHA must be 64 lowercase hex digits.

The file is rewritten only when it can be read without guessing:
- the version "..." declaration appears exactly once and is not commented out;
- there is exactly one url line and exactly one sha256 line, commented-out
    lines included, so a leftover commented block is refused, not tolerated;
- that url names the Linux tarball, its sha256 is on the very next line, and
    neither line is commented out.

Otherwise every failed condition is printed, the exit code is 1, and the file
is left byte-identical: nothing is written before every check has passed.
"""

import re
import sys

LINUX_TARBALL = "bondi-linux-x86_64.tar.gz"
VERSION = re.compile(r'version\s+"[^"]*"')
URL = re.compile(r'\burl\s+"')
SHA256 = re.compile(r'\bsha256\s+"')
SHA256_VALUE = re.compile(r'(sha256\s+")[^"]*(")')
COMMENTED = re.compile(r"^\s*#")
SHA_ARGUMENT = re.compile(r"[0-9a-f]{64}")
USAGE = "usage: update_formula.py FORMULA VERSION LINUX_SHA"


def refusals(lines, version, linux_sha):
    """Every condition the formula fails, in the order they are checked."""
    found = []
    if not version:
        found.append("version must not be empty")
    if not SHA_ARGUMENT.fullmatch(linux_sha):
        found.append(
            f"LINUX_SHA must be 64 lowercase hex digits, got {linux_sha!r}"
        )
    versions = sum(len(VERSION.findall(line)) for line in lines)
    if versions != 1:
        found.append(f'version "..." appears {versions} times; expected exactly once')
    elif any(VERSION.search(line) and COMMENTED.match(line) for line in lines):
        found.append('the version "..." line is commented out')
    urls = [i for i, line in enumerate(lines) if URL.search(line)]
    if len(urls) != 1:
        found.append(
            f"url lines (commented-out ones included): {len(urls)}; expected exactly one"
        )
    shas = [i for i, line in enumerate(lines) if SHA256.search(line)]
    if len(shas) != 1:
        found.append(
            f"sha256 lines (commented-out ones included): {len(shas)}; expected exactly one"
        )
    linux = [i for i in urls if f'{LINUX_TARBALL}"' in lines[i]]
    if not linux:
        found.append(f"no url line names {LINUX_TARBALL}")
    elif len(linux) == 1:
        url = linux[0]
        sha = url + 1
        if sha not in shas:
            found.append(f"the line after the {LINUX_TARBALL} url is not its sha256 line")
        elif COMMENTED.match(lines[url]) or COMMENTED.match(lines[sha]):
            found.append(f"the {LINUX_TARBALL} url or its sha256 line is commented out")
    # More than one Linux url line is already refused by the url count above.
    return found


def main():
    if len(sys.argv) != 4:
        print(USAGE, file=sys.stderr)
        sys.exit(1)
    formula_path, version, linux_sha = sys.argv[1], sys.argv[2].strip(), sys.argv[3]

    with open(formula_path, "r", encoding="utf-8", newline="") as f:
        data = f.read()
    lines = data.splitlines(keepends=True)

    found = refusals(lines, version, linux_sha)
    if found:
        for reason in found:
            print(f"::error::{reason}", file=sys.stderr)
        print(f"::error::{formula_path} left unchanged", file=sys.stderr)
        sys.exit(1)

    sha = next(i for i, line in enumerate(lines) if SHA256.search(line))
    lines[sha] = SHA256_VALUE.sub(lambda m: m.group(1) + linux_sha + m.group(2), lines[sha])
    data = VERSION.sub(f'version "{version}"', "".join(lines))

    with open(formula_path, "w", encoding="utf-8", newline="") as f:
        f.write(data)


if __name__ == "__main__":
    main()
