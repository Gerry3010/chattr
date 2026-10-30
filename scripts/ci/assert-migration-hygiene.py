#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Checks every migration after the security baseline (00093) for the three
# mistakes the check of 2026-10-25 found grown over months (CHAT-43):
#
#  1. A SECURITY DEFINER function without a pinned `search_path`. The
#     session's temp schema would be searched first, and a temp table named
#     like `chat_members` would answer the membership checks.
#  2. A SECURITY DEFINER function without a `REVOKE ... FROM PUBLIC` in the
#     same file. PostgreSQL grants EXECUTE to PUBLIC on every new function, so
#     anon can call it with nothing but the public key (`chattr_send` sat like
#     that from 00063 to 00084).
#  3. A new table in `public` without `ENABLE ROW LEVEL SECURITY` in the same
#     file.
#
# Older migrations are not checked: 00093 repaired what they left behind, and
# rewriting history is not the point. A deliberate exception is marked in the
# migration with a comment on the line before the statement:
#     -- hygiene: allow <reason>
#
# Usage: assert-migration-hygiene.py [migrations_dir]   (exit 1 on findings)

import re
import sys
from pathlib import Path

BASELINE = 93

# Only the start of a definition is matched by a pattern; the header up to the
# body is cut with plain string search. A single pattern spanning name, argument
# list and header backtracked over large migrations and hung (found while
# writing this very check).
FUNC_START = re.compile(
    r"create\s+(?:or\s+replace\s+)?function\s+([\w.\"]+)\s*\(",
    re.IGNORECASE,
)


def _header(sql: str, start: int) -> str:
    """Text from the function name to the start of its body (`$tag$` or `AS '`)."""
    end = len(sql)
    dollar = sql.find("$", start)
    if dollar != -1:
        end = dollar
    quote = re.compile(r"\bas\s+'", re.IGNORECASE).search(sql, start, end)
    if quote:
        end = quote.start()
    return sql[start:end]
TABLE = re.compile(
    r"create\s+table\s+(?:if\s+not\s+exists\s+)?((?:public\.)?[\w\"]+)",
    re.IGNORECASE,
)


def _name(raw: str) -> str:
    return raw.replace('"', "").split(".")[-1].lower()


def _allowed(sql: str, pos: int) -> bool:
    line_start = sql.rfind("\n", 0, pos)
    prev_start = sql.rfind("\n", 0, max(line_start, 0))
    previous = sql[prev_start + 1 : line_start] if line_start > 0 else ""
    return "hygiene: allow" in previous.lower()


def check(path: Path, earlier: set[str] | None = None) -> list[str]:
    """[earlier]: function names defined by migrations before this one. A
    CREATE OR REPLACE of one of those keeps its grants (unless this file drops
    it first), so it needs no new REVOKE."""
    earlier = earlier or set()
    sql = path.read_text(encoding="utf-8")
    # Comments must not count as statements, but the allow marker lives in a
    # comment: strip block comments only, keep line comments for _allowed.
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.DOTALL)
    findings = []
    for m in FUNC_START.finditer(sql):
        header = _header(sql, m.end())
        if "security definer" not in header.lower():
            continue
        if _allowed(sql, m.start()):
            continue
        name = _name(m.group(1))
        if not re.search(r"set\s+search_path\s*(=|to)", header, re.IGNORECASE):
            findings.append(f"{path.name}: SECURITY DEFINER {name}() without SET search_path")
        # A trigger function cannot be called on its own, and only `public`
        # is exposed over the API; nothing to revoke in either case.
        if re.search(r"returns\s+trigger\b", header, re.IGNORECASE):
            continue
        raw = m.group(1).replace('"', "").lower()
        if "." in raw and not raw.startswith("public."):
            continue
        replaced = re.match(r"create\s+or\s+replace", m.group(0), re.IGNORECASE)
        dropped = re.search(
            rf"drop\s+function\s+(?:if\s+exists\s+)?(?:public\.)?\"?{re.escape(name)}\"?\b",
            sql,
            re.IGNORECASE,
        )
        if replaced and name in earlier and not dropped:
            continue
        revoke = re.compile(
            rf"revoke\s+(?:all|execute)[^;]*on\s+function\s+(?:public\.)?\"?{re.escape(name)}\"?\b[^;]*from[^;]*\bpublic\b",
            re.IGNORECASE | re.DOTALL,
        )
        if not revoke.search(sql):
            findings.append(f"{path.name}: SECURITY DEFINER {name}() without REVOKE ... FROM PUBLIC")
    for m in TABLE.finditer(sql):
        raw = m.group(1)
        if "." in raw and not raw.lower().startswith("public."):
            continue
        if _allowed(sql, m.start()):
            continue
        name = _name(raw)
        rls = re.compile(
            rf"alter\s+table\s+(?:if\s+exists\s+)?(?:public\.)?\"?{re.escape(name)}\"?\s+enable\s+row\s+level\s+security",
            re.IGNORECASE,
        )
        if not rls.search(sql):
            findings.append(f"{path.name}: table {name} without ENABLE ROW LEVEL SECURITY")
    return findings


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "supabase" / "migrations"
    findings = []
    earlier: set[str] = set()
    for path in sorted(root.glob("*.sql")):
        number = re.match(r"(\d{5})_", path.name)
        if number and int(number.group(1)) > BASELINE:
            findings += check(path, earlier)
        text = path.read_text(encoding="utf-8")
        earlier |= {_name(m.group(1)) for m in FUNC_START.finditer(text)}
    for f in findings:
        print(f"✗ {f}")
    if findings:
        print("Migration hygiene failed (see scripts/ci/assert-migration-hygiene.py).")
        return 1
    print("✓ migration hygiene: nothing after the baseline to complain about")
    return 0


if __name__ == "__main__":
    sys.exit(main())
