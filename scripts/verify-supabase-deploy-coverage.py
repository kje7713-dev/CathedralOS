#!/usr/bin/env python3
"""Fail when a production Edge Function is absent from the deploy workflow."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
functions_dir = root / "supabase" / "functions"
workflow = root / ".github" / "workflows" / "supabase-deploy.yml"

functions = {
    path.name
    for path in functions_dir.iterdir()
    if path.is_dir() and (path / "index.ts").is_file() and not path.name.startswith("_")
}
workflow_text = workflow.read_text(encoding="utf-8")
deployed = set(re.findall(r"supabase functions deploy ([A-Za-z0-9_-]+)", workflow_text))
missing = sorted(functions - deployed)
extra = sorted(deployed - functions)

if missing:
    print("Missing Supabase deploy steps:", ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)

print(f"Verified {len(functions)} Edge Functions have deploy steps.")
if extra:
    print("Workflow-only deploy names:", ", ".join(extra))
