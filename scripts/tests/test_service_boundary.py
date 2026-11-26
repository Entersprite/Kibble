import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "lint_service", Path(__file__).resolve().parents[1] / "lint-service-boundaries.py"
)
LINT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LINT)


class ServiceBoundaryTests(unittest.TestCase):
    def graph(self, package):
        return {"targets": [
            {"name": name, "type": "regular", "dependencies": [
                {"byName": [dependency, None]} for dependency in sorted(dependencies)
            ]} for name, dependencies in LINT.GRAPHS[package].items()
        ]}

    def test_declared_graphs_pass(self):
        for package in LINT.GRAPHS:
            self.assertEqual(LINT.violations(self.graph(package), package), [])

    def test_upward_dependencies_fail_for_every_shipping_target(self):
        for package in LINT.GRAPHS:
            for index in range(len(self.graph(package)["targets"])):
                graph = self.graph(package)
                graph["targets"][index]["dependencies"].append({"byName": ["MacHost", None]})
                with self.subTest(package=package, index=index):
                    self.assertTrue(LINT.violations(graph, package))

    def test_extra_shipping_target_fails(self):
        graph = self.graph("ChatService")
        graph["targets"].append({"name": "Hidden", "type": "regular", "dependencies": []})
        self.assertTrue(LINT.violations(graph, "ChatService"))

    def test_unrecognized_dependency_cannot_pass(self):
        graph = self.graph("ServiceClient")
        graph["targets"][0]["dependencies"] = [{"newDependency": ["ChatAPI"]}]
        with self.assertRaises(ValueError):
            LINT.violations(graph, "ServiceClient")
