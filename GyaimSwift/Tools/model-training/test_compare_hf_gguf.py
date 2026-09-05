import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("compare-hf-gguf.py")
SPEC = importlib.util.spec_from_file_location("compare_hf_gguf", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ExcludeCasesByTagsTests(unittest.TestCase):
    def test_excludes_any_matching_tag(self):
        cases = [
            {"id": "general", "tags": ["fast-context"]},
            {"id": "user", "tags": ["fast-context", "user-dict"]},
            {"id": "dogfood", "tags": ["dogfood-regression"]},
            {"id": "untagged"},
        ]

        filtered = MODULE.exclude_cases_by_tags(
            cases, ["user-dict", "dogfood-regression"]
        )

        self.assertEqual(["general", "untagged"], [case["id"] for case in filtered])

    def test_empty_exclusion_keeps_all_cases(self):
        cases = [{"id": "one", "tags": ["user-dict"]}]

        self.assertIs(cases, MODULE.exclude_cases_by_tags(cases, []))


if __name__ == "__main__":
    unittest.main()
