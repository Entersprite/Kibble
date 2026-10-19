#!/usr/bin/env python3
"""Keep the service contract and embedded transport independent of implementations.

Reads `swift package dump-package` on stdin. Exit 2 means the graph could not
be checked; it must never be interpreted as a passing architecture check.
"""
import json
import sys


def violations(graph):
    allowed = {"ChatAPI": {"ChatKit"}, "InProcessChatTransport": {"ChatAPI"}}
    if not isinstance(graph, dict) or not isinstance(graph.get("targets"), list):
        raise ValueError("missing target graph")
    shipping = [target for target in graph["targets"] if target.get("type") != "test"]
    if {target.get("name") for target in shipping} != set(allowed):
        return ["ChatAPI: unexpected or missing shipping target"]
    result = []
    for target in shipping:
        actual = set()
        for dependency in target.get("dependencies", []):
            if len(dependency) != 1:
                raise ValueError("unknown dependency shape")
            kind, values = next(iter(dependency.items()))
            if kind not in ("byName", "target", "product") or not isinstance(values, list) or not values:
                raise ValueError("unknown dependency shape")
            if values[0] not in allowed[target["name"]]:
                result.append("ChatAPI: {} depends on {}".format(target["name"], values[0]))
            actual.add(values[0])
        if actual != allowed[target["name"]]:
            result.append("ChatAPI: dependency set changed for {}".format(target["name"]))
    if len(graph.get("dependencies", [])) != 1:
        result.append("ChatAPI: expected one ChatKit package dependency")
    for dependency in graph.get("dependencies", []):
        entries = dependency.get("fileSystem", [])
        if len(entries) != 1 or entries[0].get("identity") != "chatkit":
            result.append("ChatAPI: package dependency outside ChatKit")
    return result


def main():
    try:
        found = violations(json.load(sys.stdin))
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        print("ChatAPI: cannot check graph: {}".format(error))
        return 2
    for issue in found:
        print(issue)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
