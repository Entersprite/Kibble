import copy
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "lint_chatapi", Path(__file__).resolve().parents[1] / "lint-chatapi.py"
)
LINT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LINT)


class ChatAPIBoundaryTests(unittest.TestCase):
    def graph(self):
        return {
            "dependencies": [{"fileSystem": [{"identity": "chatkit"}]}],
            "targets": [
                {"name": "ChatAPI", "type": "regular", "dependencies": [{"byName": ["ChatKit", None]}]},
                {"name": "InProcessChatTransport", "type": "regular",
                 "dependencies": [{"byName": ["ChatAPI", None]}]},
                {"name": "ChatAPITests", "type": "test", "dependencies": []},
            ],
        }

    def test_clean_graph(self):
        self.assertEqual(LINT.violations(self.graph()), [])

    def test_implementation_dependency_is_rejected_for_each_shipping_target(self):
        for name in ("ChatService", "AppCore", "SyncEngine", "LocalBridgeBackend", "MacHost"):
            for index in (0, 1):
                graph = self.graph()
                graph["targets"][index]["dependencies"].append({"byName": [name, None]})
                with self.subTest(name=name, index=index):
                    self.assertTrue(LINT.violations(graph))

    def test_unknown_graph_is_not_a_clean_graph(self):
        with self.assertRaises(ValueError):
            LINT.violations({})
        graph = self.graph()
        graph["targets"][0]["dependencies"] = [{"futureDependency": ["ChatKit"]}]
        with self.assertRaises(ValueError):
            LINT.violations(graph)

    def test_undeclared_shipping_targets_are_rejected(self):
        graph = self.graph()
        graph["targets"].append({"name": "HiddenService", "type": "regular", "dependencies": []})
        self.assertTrue(LINT.violations(graph))

    def test_other_packages_are_rejected_even_without_imports(self):
        graph = self.graph()
        graph["dependencies"].append({"fileSystem": [{"identity": "machost"}]})
        self.assertTrue(LINT.violations(graph))

    def test_missing_dependencies_are_not_silently_allowed(self):
        graph = self.graph()
        graph["targets"][0]["dependencies"] = []
        self.assertTrue(LINT.violations(graph))
        graph = self.graph()
        graph["dependencies"] = []
        self.assertTrue(LINT.violations(graph))

    def test_test_dependencies_do_not_count_as_shipping_dependencies(self):
        graph = self.graph()
        original = copy.deepcopy(graph)
        graph["targets"][2]["dependencies"] = [{"byName": ["TestSupport", None]}]
        self.assertEqual(LINT.violations(graph), LINT.violations(original))


if __name__ == "__main__":
    unittest.main()
