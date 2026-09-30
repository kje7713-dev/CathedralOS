#!/usr/bin/env python3
"""Verify every production Edge Function has exactly one executable deploy step."""
from pathlib import Path
import re
import sys
from collections import Counter

DEPLOY_RE = re.compile(r"(?:^|[;&|]|\bthen)\s*supabase\s+functions\s+deploy\s+([A-Za-z0-9_-]+)\b")


def executable_run_text(workflow_text: str) -> str:
    """Return only YAML run values, excluding comments and documentation."""
    lines = workflow_text.splitlines()
    runs: list[str] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        match = re.match(r"^(\s*)(?:-\s*)?run:\s*(.*)$", line)
        if not match:
            index += 1
            continue
        indent = len(match.group(1))
        value = match.group(2).strip()
        if value in {"|", ">", "|-", ">-", "|+", ">+"} or not value:
            index += 1
            while index < len(lines):
                candidate = lines[index]
                if candidate.strip() and len(candidate) - len(candidate.lstrip()) <= indent:
                    break
                stripped = candidate.strip()
                if stripped and not stripped.startswith("#"):
                    runs.append(stripped)
                index += 1
            continue
        if not value.startswith("#"):
            runs.append(value)
        index += 1
    return "\n".join(runs)


def deploy_commands(workflow_text: str) -> list[str]:
    commands: list[str] = []
    for line in executable_run_text(workflow_text).splitlines():
        # Shell comments are not executable; keep quoted text from echo/docs
        # from becoming a false deployment match by requiring a command boundary.
        line = line.split(" #", 1)[0]
        commands.extend(DEPLOY_RE.findall(line))
    return [name for name in commands if name != "_shared"]


def validate_coverage(functions: set[str], workflow_text: str) -> tuple[list[str], list[str], list[str]]:
    deployed = deploy_commands(workflow_text)
    counts = Counter(deployed)
    missing = sorted(functions - set(deployed))
    extra = sorted(set(deployed) - functions)
    duplicates = sorted(name for name, count in counts.items() if count > 1)
    return missing, extra, duplicates


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    functions_dir = root / "supabase" / "functions"
    workflow = root / ".github" / "workflows" / "supabase-deploy.yml"
    functions = {
        path.name for path in functions_dir.iterdir()
        if path.is_dir() and (path / "index.ts").is_file() and not path.name.startswith("_")
    }
    missing, extra, duplicates = validate_coverage(functions, workflow.read_text(encoding="utf-8"))
    failed = False
    if missing:
        print("Missing Supabase deploy steps:", ", ".join(missing), file=sys.stderr)
        failed = True
    if extra:
        print("Workflow-only deploy names:", ", ".join(extra), file=sys.stderr)
        failed = True
    if duplicates:
        print("Duplicate Supabase deploy steps:", ", ".join(duplicates), file=sys.stderr)
        failed = True
    if failed:
        return 1
    print(f"Verified {len(functions)} Edge Functions have exactly one deploy step.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
