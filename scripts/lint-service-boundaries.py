#!/usr/bin/env python3
"""Validate shipping service target dependencies from a SwiftPM graph."""
import json
import sys

GRAPHS = {
    "ChatService": {
        "ChatService": {"ChatAPI", "ChatKit", "ChatRules"},
        "ChatServiceStorage": {"ChatService", "ChatAPI", "ChatKit", "ChatRules", "ChatPersistence", "GRDB"},
    },
    "SyncEngine": {
        "ChatPersistence": {"ChatKit", "ChatRules", "GRDB"},
        "SyncEngine": {"ChatKit", "ChatRules", "ChatPersistence", "GRDB"},
    },
    "ChatRules": {"ChatRules": {"ChatKit"}},
}


def violations(graph, package):
    expected = GRAPHS[package]
    targets = graph["targets"]
    shipping = [target for target in targets if target["type"] != "test"]
    if {target["name"] for target in shipping} != set(expected):
        return ["unexpected shipping targets"]
    result = []
    for target in shipping:
        names = set()
        for dependency in target["dependencies"]:
            if len(dependency) != 1:
                raise ValueError("unknown dependency shape")
            kind, values = next(iter(dependency.items()))
            if kind not in {"product", "target", "byName"} or not isinstance(values, list):
                raise ValueError("unknown dependency shape")
            names.add(values[0])
        if names != expected[target["name"]]:
            result.append("unexpected dependencies of " + target["name"])
    return result


def main():
    try:
        found = violations(json.load(sys.stdin), sys.argv[1])
    except (KeyError, ValueError, TypeError, IndexError) as error:
        print("cannot check service graph:", error)
        return 2
    for issue in found:
        print(issue)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
