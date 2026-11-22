import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import disk_budget as db  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BUDGET = db.load(os.path.join(ROOT, "config", "disk-budget.json"))
GIB = db.GIB_KIB


class Table(unittest.TestCase):
    def test_shipped_caps_sum_under_the_line(self):
        total, limit, ok = db.commitment(BUDGET)
        self.assertTrue(ok, f"caps {total} GiB must stay under {limit} GiB")

    def test_overcommitted_table_fails(self):
        fat = {**BUDGET, "rows": BUDGET["rows"] + [{"id": "x", "paths": [], "owner": "o", "cap_gib": 50}]}
        self.assertFalse(db.commitment(fat)[2])
        self.assertEqual(db.main(["--table", "--budget", self._write(fat)]), 2)

    def test_docs_table_matches_the_budget_file(self):
        with open(os.path.join(ROOT, "docs", "disk.md"), encoding="utf-8") as f:
            doc = f.read()
        caps = {m.group(1): float(m.group(2)) for m in re.finditer(r"^\| `([a-z-]+)` \|[^\n]*?\| ([0-9.]+) \|", doc, re.M)}
        want = {r["id"]: float(r["cap_gib"]) for r in BUDGET["rows"]}
        self.assertEqual(caps, want, "docs/disk.md budget table and config/disk-budget.json disagree")

    def _write(self, data):
        import json
        import tempfile
        fd, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        self.addCleanup(os.unlink, path)
        return path


class Measure(unittest.TestCase):
    budget = {
        "rows": [
            {"id": "a", "paths": ["/p/a"], "owner": "alpha", "cap_gib": 2, "enforced_by": "x"},
            {"id": "b", "paths": ["/p/b"], "owner": "alpha", "cap_gib": 2, "enforced_by": "x"},
            {"id": "c", "paths": ["/p/c"], "owner": "beta", "cap_gib": 2, "enforced_by": "x"},
            {"id": "rest", "paths": [], "rest": True, "owner": "vps", "cap_gib": 3, "enforced_by": "x"},
        ]
    }

    def rows(self, sizes, used):
        return db.measure(self.budget, du=lambda p: sizes[p] * GIB, used_kib=lambda: used * GIB)

    def test_rest_is_used_minus_the_rows(self):
        os_path = os.path.lexists
        db.os.path.lexists = lambda p: True
        try:
            rows = self.rows({"/p/a": 1, "/p/b": 1, "/p/c": 1}, used=10)
        finally:
            db.os.path.lexists = os_path
        self.assertEqual([r["measured_gib"] for r in rows], [1, 1, 1, 7])
        self.assertEqual([r["over"] for r in rows], [False, False, False, True])

    def test_one_signal_per_owner_and_refile_window(self):
        rows = [
            {"id": "a", "paths": ["/p/a"], "owner": "alpha", "cap_gib": 2, "measured_gib": 3, "over": True, "enforced_by": "x"},
            {"id": "b", "paths": ["/p/b"], "owner": "alpha", "cap_gib": 2, "measured_gib": 5, "over": True, "enforced_by": "x"},
            {"id": "c", "paths": ["/p/c"], "owner": "beta", "cap_gib": 2, "measured_gib": 1, "over": False, "enforced_by": "x"},
        ]
        sent = []
        send = lambda owner, title, text: sent.append((owner, title, text)) or "filed"
        state = db.signal_owners(rows, {}, 1_000_000, send=send)
        self.assertEqual([s[0] for s in sent], ["alpha"], "one signal for alpha's two rows, none for the owner under its cap")
        self.assertIn("a (/p/a): 3 GiB", sent[0][2])
        self.assertIn("b (/p/b): 5 GiB", sent[0][2])
        db.signal_owners(rows, state, 1_000_000 + 86400, send=send)
        self.assertEqual(len(sent), 1, "refiled inside the window")
        db.signal_owners(rows, state, 1_000_000 + 8 * 86400, send=send)
        self.assertEqual(len(sent), 2, "refiled after the window while still over")

    def test_a_row_joining_the_set_refiles_inside_the_window(self):
        row = lambda i, over: {"id": i, "paths": ["/p/" + i], "owner": "alpha", "cap_gib": 2, "measured_gib": 3, "over": over, "enforced_by": "x"}
        sent = []
        send = lambda owner, title, text: sent.append(title) or "filed"
        state = db.signal_owners([row("a", True), row("b", False)], {}, 1000, send=send)
        db.signal_owners([row("a", True), row("b", True)], state, 1000 + 86400, send=send)
        self.assertEqual(len(sent), 2)
        self.assertIn("a, b", sent[1])

    def test_a_failed_delivery_is_not_remembered(self):
        rows = [{"id": "a", "paths": ["/p/a"], "owner": "alpha", "cap_gib": 1, "measured_gib": 3, "over": True, "enforced_by": "x"}]

        def boom(*_):
            raise RuntimeError("down")

        self.assertEqual(db.signal_owners(rows, {}, 5, send=boom), {})
        self.assertEqual(db.signal_owners(rows, {}, 5, send=lambda *_: "no sink"), {})

    def test_unknown_growth_skips_covered_paths(self):
        budget = {**self.budget, "scan_roots": ["/h"], "unknown_gib": 5}
        budget["rows"] = [{"id": "x", "paths": ["/h/exp[0-9]*", "/h/steps"], "owner": "o", "cap_gib": 1, "enforced_by": "x"}]
        sizes = {"/h/exp12": 9, "/h/steps": 9, "/h/stray": 9, "/h/small": 1}
        found = db.unknown_growth(budget, du=lambda p: sizes[p] * GIB, listdir=lambda _: list(n.split("/")[-1] for n in sizes))
        self.assertEqual([f["path"] for f in found], ["/h/stray"])


if __name__ == "__main__":
    unittest.main()
