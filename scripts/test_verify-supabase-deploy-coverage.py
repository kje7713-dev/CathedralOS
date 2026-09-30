#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest

_spec = importlib.util.spec_from_file_location("deployment_guard", pathlib.Path(__file__).with_name("verify-supabase-deploy-coverage.py"))
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)
validate_coverage = _module.validate_coverage


class DeploymentCoverageTests(unittest.TestCase):
    functions = {"alpha", "beta"}

    def test_valid_run_blocks(self):
        workflow = """
jobs:
  deploy:
    steps:
      - run: |
          supabase functions deploy alpha
      - run: supabase functions deploy beta
"""
        self.assertEqual(validate_coverage(self.functions, workflow), ([], [], []))

    def test_missing_function_fails(self):
        self.assertEqual(validate_coverage(self.functions, "run: supabase functions deploy alpha"), (["beta"], [], []))

    def test_nonexistent_function_fails(self):
        self.assertEqual(validate_coverage(self.functions, "run: supabase functions deploy alpha\nrun: supabase functions deploy ghost"), (["beta"], ["ghost"], []))

    def test_duplicate_function_fails(self):
        workflow = "run: supabase functions deploy alpha\nrun: supabase functions deploy alpha\nrun: supabase functions deploy beta"
        self.assertEqual(validate_coverage(self.functions, workflow), ([], [], ["alpha"]))

    def test_comments_and_documentation_are_ignored(self):
        workflow = """
# supabase functions deploy ghost
- name: Documentation
  run: echo 'supabase functions deploy ghost'
- run: |
    # supabase functions deploy ghost
    supabase functions deploy alpha
    # supabase functions deploy beta
    supabase functions deploy beta # active command
"""
        self.assertEqual(validate_coverage(self.functions, workflow), ([], [], []))


if __name__ == "__main__":
    unittest.main()
