#!/usr/bin/env python3
"""Validate required production URLs before an iOS archive/upload."""
import os
import sys
from urllib.parse import urlparse

required = ("PRIVACY_POLICY_URL", "TERMS_OF_USE_URL")
errors = []
for name in required:
    value = os.environ.get(name, "").strip()
    parsed = urlparse(value)
    if not value or parsed.scheme != "https" or not parsed.netloc:
        errors.append(f"{name} must be a non-empty HTTPS URL")
if errors:
    print("Release configuration invalid:", file=sys.stderr)
    print("\n".join(f"- {error}" for error in errors), file=sys.stderr)
    raise SystemExit(1)
print("Required legal URLs are valid HTTPS URLs.")
