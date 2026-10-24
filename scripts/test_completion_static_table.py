#!/usr/bin/env python3
"""Synthetic temporary fixtures only; never product command data."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from completion_static_table import DatasetError, load_entries, render, repository_file


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.license = b"Synthetic test fixture license; not a product source.\n"
        (self.root / "LICENSE").write_bytes(self.license)
        self.source = dict(id="fixture", upstream="test fixture", version="1", license="test-only",
                           reviewed_by="fixture", reviewed_at="2000-01-01", update_process="test fixture",
                           redistribution_approved=True, license_file="LICENSE",
                           license_sha256=hashlib.sha256(self.license).hexdigest(), entries_file="entries.json")
        self.manifest = dict(schema_version=1, status="reviewed", target_count=500, sources=[self.source])

    def write_entries(self, entries):
        content = json.dumps(entries).encode()
        (self.root / "entries.json").write_bytes(content)
        self.source["entries_sha256"] = hashlib.sha256(content).hexdigest()

    def test_pending_manifest_cannot_generate(self):
        with self.assertRaisesRegex(DatasetError, "pending source review"):
            load_entries(self.root, dict(schema_version=1, status="pending_source_review", target_count=500))

    def test_rejects_unapproved_source(self):
        self.source["redistribution_approved"] = False
        with self.assertRaisesRegex(DatasetError, "approval"):
            load_entries(self.root, self.manifest)

    def test_pinned_license_cannot_change(self):
        (self.root / "LICENSE").write_bytes(b"changed")
        with self.assertRaisesRegex(DatasetError, "SHA256 mismatch"):
            load_entries(self.root, self.manifest)

    def test_pinned_entries_cannot_change(self):
        self.write_entries([dict(text="fixture", kind="command")])
        (self.root / "entries.json").write_text("[]")
        with self.assertRaisesRegex(DatasetError, "SHA256 mismatch"):
            load_entries(self.root, self.manifest)

    def test_malformed_manifest_rejected(self):
        with self.assertRaisesRegex(DatasetError, "manifest must be an object"):
            load_entries(self.root, [])

    def test_missing_source_and_provenance_rejected(self):
        self.manifest["sources"] = []
        with self.assertRaisesRegex(DatasetError, "declare sources"):
            load_entries(self.root, self.manifest)
        self.manifest["sources"] = [self.source]
        self.source["license"] = ""
        with self.assertRaisesRegex(DatasetError, "provenance field: license"):
            load_entries(self.root, self.manifest)

    def test_missing_entry_kind_coverage_rejected(self):
        self.write_entries([dict(text=f"fixture-{i}", kind="command") for i in range(450)])
        with self.assertRaisesRegex(DatasetError, "must cover"):
            load_entries(self.root, self.manifest)

    def test_duplicate_rejected(self):
        self.write_entries([dict(text="fixture", kind="command")] * 2)
        with self.assertRaisesRegex(DatasetError, "duplicate completion"):
            load_entries(self.root, self.manifest)

    def test_control_character_rejected(self):
        self.write_entries([dict(text="fixture\n", kind="command")])
        with self.assertRaisesRegex(DatasetError, "control characters"):
            load_entries(self.root, self.manifest)

    def test_small_dataset_cannot_claim_completion(self):
        self.write_entries([dict(text="fixture", kind="command")])
        with self.assertRaisesRegex(DatasetError, "got 1"):
            load_entries(self.root, self.manifest)

    def test_path_escape_and_symlink_escape_rejected(self):
        with self.assertRaises(DatasetError):
            repository_file(self.root, "../LICENSE")
        (self.root / "outside").symlink_to(Path(__file__).resolve())
        with self.assertRaises(DatasetError):
            repository_file(self.root, "outside")

    def test_valid_synthetic_fixture_is_sorted_and_deterministic(self):
        # Temporary synthetic identifiers verify the count gate, not product coverage.
        data = [dict(text=f"fixture-{i:03}", kind=("command", "subcommand", "flag")[i % 3]) for i in range(450)]
        self.write_entries(data[::-1])
        first = load_entries(self.root, self.manifest)
        self.write_entries(data)
        self.assertEqual(first, load_entries(self.root, self.manifest))
        self.assertEqual(len(first), 450)
        self.assertEqual(render(first), render(first))

    def test_renderer_escapes_quotes_and_backslashes(self):
        result = render([('fixture "value" \\', 'flag', 'fixture')])
        self.assertIn('fixture \\"value\\" \\\\', result)


if __name__ == "__main__":
    unittest.main()
