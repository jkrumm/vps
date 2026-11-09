import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("lint_compose", pathlib.Path(__file__).with_name("lint-compose.py"))
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)

HC = {"test": ["CMD", "true"]}
WT = {"com.centurylinklabs.watchtower.enable": "false"}


def run(svc, path="apps/x/compose.yml", name="svc"):
    return lint.lint_service(path, name, svc)


class LintComposeTest(unittest.TestCase):
    def test_clean_rollhook_app(self):
        self.assertEqual(run({"image": "${IMAGE_TAG:-r/x:latest}", "healthcheck": HC}), [])

    def test_unlisted_port_rejected(self):
        errors = run({"image": "nginx:1", "ports": ["8080:80"]})
        self.assertTrue(any("allowlist" in e for e in errors))
        self.assertTrue(all(e.startswith("apps/x/compose.yml:svc:") for e in errors))

    def test_allowlisted_port_must_bind_tailscale(self):
        path, name = "compose.monitoring.yml", "dozzle"
        self.assertEqual(lint.lint_service(path, name, {"image": "d:1", "ports": ["${VPS_TAILSCALE_IP:?must be set}:7007:7007"]}), [])
        self.assertTrue(lint.lint_service(path, name, {"image": "d:1", "ports": ["7007:7007"]}))

    def test_public_mariadb_exception(self):
        svc = {"image": "mariadb:11.4", "ports": ["33306:3306"], "labels": WT}
        self.assertEqual(lint.lint_service("apps/fpp/compose.yml", "mariadb", svc), [])

    def test_rollhook_constraints(self):
        errors = run({"image": "${IMAGE_TAG:-r/x:latest}", "container_name": "x"})
        self.assertEqual(len(errors), 2)

    def test_stateful_needs_label_and_pin(self):
        self.assertEqual(len(run({"image": "postgres"})), 2)
        self.assertEqual(run({"image": "postgres:18", "labels": [f"{lint.WATCHTOWER_LABEL}=false"]}), [])
        self.assertTrue(run({"image": "valkey/valkey:latest", "labels": WT}))


if __name__ == "__main__":
    unittest.main()
