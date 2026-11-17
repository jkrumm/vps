"""Unit tests for scripts/telemetry-lint.py: rules over a synthetic snapshot, no ClickHouse."""

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("telemetry_lint", os.path.join(HERE, "telemetry-lint.py"))
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)

NOW = 1_800_000_000


def entry(name="svc", **kw):
    base = {"name": name, "namespace": "p", "host": "vps", "env": "prod", "repo": "owner", "signals": ["traces", "logs"]}
    base.update(kw)
    return base


def attr(service="svc", signal="traces", env="prod", ns="p", version="abc1234", host="vps", rows=100):
    return {"signal": signal, "service": service, "env": env, "ns": ns, "version": version, "host": host, "rows": rows}


def act(service="svc", signal="traces", rows7d=700, rows24h=100, last=NOW - 60):
    return {"signal": signal, "service": service, "rows7d": rows7d, "rows24h": rows24h, "last": last}


def run(entries, activity=(), attrs=(), logs=(), drift=None):
    registry = {e["name"]: e for e in entries}
    snap = {"activity": list(activity), "attrs": list(attrs), "logs": list(logs)}
    return lint.evaluate(registry, snap, NOW, drift)


def rules(findings):
    return sorted((f.rule, f.service) for f in findings)


class Rules(unittest.TestCase):
    def test_clean_service_has_no_findings(self):
        found = run([entry()], [act(), act(signal="logs")], [attr(), attr(signal="logs")],
                    [{"service": "svc", "total": 1000, "empty_body": 0, "untraced": 0}])
        self.assertEqual(found, [])

    def test_unregistered_service(self):
        found = run([entry()], [act(), act(service="stranger")])
        self.assertEqual([(f.rule, f.service, f.repo) for f in found if f.rule == "unregistered"],
                         [("unregistered", "stranger", "vps")])

    def test_silent_signal_and_expected_none(self):
        stale = [act(last=NOW - 25 * 3600), act(signal="logs")]
        self.assertEqual(rules(run([entry()], stale)), [("silent", "svc")])
        self.assertEqual(run([entry(expected="none")], stale), [])
        self.assertEqual(run([entry(expected=["logs"])], stale), [])
        missing = run([entry()], [act()])
        self.assertIn("no logs in 7 d", missing[0].measured)

    def test_retired_service_is_skipped(self):
        self.assertEqual(run([entry(status="retired")], [], [attr(env="")]), [])

    def test_environment(self):
        for env, want in (("", 1), ("production", 1), ("test", 1), ("dev", 1), ("prod", 0)):
            found = [f for f in run([entry()], [act(), act(signal="logs")], [attr(env=env)]) if f.rule == "environment"]
            self.assertEqual(len(found), want, env)
        dev_only = run([entry(env="dev")], [act(), act(signal="logs")], [attr(env="dev", version="local")])
        self.assertEqual(dev_only, [])

    def test_namespace_version_host(self):
        found = run([entry()], [act(), act(signal="logs")],
                    [attr(ns="", version="local", host="bbeab9c3e8bd")])
        self.assertEqual(rules(found), [("host", "svc"), ("namespace", "svc"), ("version", "svc")])
        self.assertEqual(rules(run([entry()], [act(), act(signal="logs")], [attr(version="0.0.0", host="")])),
                         [("host", "svc"), ("version", "svc")])

    def test_client_host_may_be_unset_and_dev_version_is_free(self):
        found = run([entry(host="client")], [act(), act(signal="logs")], [attr(host="")])
        self.assertEqual(found, [])
        found = run([entry(env="dev")], [act(), act(signal="logs")], [attr(env="dev", version="")])
        self.assertEqual(found, [])

    def test_empty_body_threshold(self):
        base = {"service": "svc", "total": 1000, "untraced": 0}
        self.assertEqual(run([entry()], [act(), act(signal="logs")], [], [dict(base, empty_body=10)]), [])
        found = run([entry()], [act(), act(signal="logs")], [], [dict(base, empty_body=11)])
        self.assertEqual(rules(found), [("body-empty", "svc")])

    def test_untraced_budget_applies_only_when_set(self):
        row = {"service": "svc", "total": 100, "empty_body": 0, "untraced": 60}
        a = [act(), act(signal="logs")]
        self.assertEqual(run([entry()], a, [], [row]), [])
        self.assertEqual(run([entry(budget={"untraced_logs": 0.6})], a, [], [row]), [])
        self.assertEqual(rules(run([entry(budget={"untraced_logs": 0.5})], a, [], [row])), [("untraced-logs", "svc")])

    def test_volume_budget(self):
        a = [act(rows24h=1001), act(signal="logs")]
        self.assertEqual(rules(run([entry(budget={"traces": 1000})], a)), [("volume", "svc")])
        self.assertEqual(run([entry(budget={"traces": 1001})], a), [])
        self.assertEqual(run([entry()], a), [])

    def test_drift(self):
        drift = (({"A", "P"}, {"x"}), ({"A", "R"}, {"x"}))
        found = run([], [], drift=drift)
        self.assertEqual(len(found), 2)
        self.assertIn("'P' is in prod", found[0].measured)
        self.assertIn("'R' is in observability/", found[1].measured)

    def test_ignore_silences_one_rule_for_one_service(self):
        attrs = [attr(env=""), attr(service="other", env="")]
        entries = [entry(), entry("other")]
        a = [act(), act(signal="logs"), act("other"), act("other", "logs")]
        self.assertEqual(rules(run(entries, a, attrs)), [("environment", "other"), ("environment", "svc")])
        entries[0]["ignore"] = {"environment": "third-party image"}
        self.assertEqual(rules(run(entries, a, attrs)), [("environment", "other")])


class Registry(unittest.TestCase):
    def test_shipped_registry_is_well_formed(self):
        registry = lint.load_registry(lint.REGISTRY)
        self.assertGreater(len(registry), 20)
        for name, e in registry.items():
            for key in ("namespace", "host", "env", "repo", "signals"):
                self.assertIn(key, e, f"{name} lacks {key}")
            expected = e.get("expected", "all")
            self.assertTrue(expected in ("all", "none") or set(expected) <= set(lint.SIGNALS), f"{name}: bad expected")
            for rule, reason in (e.get("ignore") or {}).items():
                self.assertIn(rule, lint.RULES, f"{name}: unknown rule {rule}")
                self.assertTrue(reason, f"{name}: ignore.{rule} needs a reason")
            for key in e.get("budget") or {}:
                self.assertIn(key, (*lint.SIGNALS, "untraced_logs"), f"{name}: unknown budget key {key}")


if __name__ == "__main__":
    unittest.main()
