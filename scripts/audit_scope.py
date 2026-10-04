"""Structural audit for a SwiftUI view file.

`swiftc -parse` verifies *grammar* only. It happily accepts a member declared inside
another member's body, because `VStack { private var x ... }` is syntactically valid —
it is only the type-checker that rejects it. So a green parse is not evidence that the
declarations sit at the right scope, which is exactly the bug CI caught in MiniAppView.

This script approximates the missing check: it walks the file tracking brace depth and
flags any line that *declares* something at a depth deeper than the enclosing type's
member level. It is not a compiler and will produce false positives on nested local
declarations inside closures — those are legal — so the output is a review list, not a
verdict. What it must never do is stay silent on a real case, so the depth is printed
with every hit.

Usage:  python scripts/audit_scope.py <file.swift> [...]
"""

import io
import re
import sys

# A line that opens a declaration: `private var x`, `var body`, `struct Y`, `func f`,
# `let z`, `@State private var q`. Deliberately broad; precision is not the point.
DECL = re.compile(
    r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*'
    r'(?:public\s+|internal\s+|fileprivate\s+|private\s+|open\s+)?'
    r'(?:static\s+|class\s+|final\s+|lazy\s+|mutating\s+|override\s+|weak\s+|unowned\s+)*'
    r'(?:var|let|func|struct|enum|class|typealias)\s+\w'
)


def strip_noise(line):
    """Drop trailing line comments and string literals so braces inside them do not count."""
    out = []
    in_string = False
    escaped = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == '"':
                in_string = False
        else:
            if ch == '"':
                in_string = True
            elif ch == '/' and i + 1 < len(line) and line[i + 1] == '/':
                break
            else:
                out.append(ch)
        i += 1
    return ''.join(out)


def audit(path):
    with io.open(path, encoding='utf-8') as handle:
        raw = handle.read().split('\n')

    depth = 0
    in_block_comment = False
    findings = []

    for number, line in enumerate(raw, start=1):
        code = strip_noise(line)

        if not in_block_comment and code.lstrip().startswith('/*'):
            in_block_comment = '*/' in code
            continue
        if in_block_comment:
            if '*/' in code:
                in_block_comment = False
            continue

        stripped = line.strip()
        is_comment = stripped.startswith('//')

        if not is_comment and DECL.match(line):
            # Depth 2 == directly inside a struct/class/enum body. Anything deeper that
            # declares a name is the shape of the bug CI found.
            if depth > 2:
                findings.append((number, depth, stripped[:78]))

        depth += code.count('{') - code.count('}')

    return findings


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2

    total = 0
    for path in argv[1:]:
        findings = audit(path)
        name = path.replace('\\', '/')
        if findings:
            total += len(findings)
            print("%s -- %d declaration(s) nested deeper than a type body:" % (name, len(findings)))
            for number, depth, text in findings:
                print("   line %-5d depth %-3d %s" % (number, depth, text))
        else:
            print("%s -- OK" % name)

    print()
    if total:
        print("REVIEW the %d hit(s) above: legal if inside a closure, a bug if not."
              % total)
    else:
        print("No nested declarations found.")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))