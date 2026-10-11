"""Bounded, private-address comparison of an existing frozen AX control.

This runs after the fixture exits. Default leak trees describe the tool's chosen
tree, and traceTree counts external roots; neither is a complete ownership graph.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import resource
import stat
import subprocess
import time

from ax_probe_report import HEAP_LABELS, HEAP_TYPES, allocation_generation, allocation_history, heap_allocations

SECONDS = 90
TOOL_SECONDS = 15
CANDIDATES = 16
RAW_LIMIT = 16 * 1024 * 1024
PUBLIC_LIMIT = 16384
INTEGER_LIMIT = 1_000_000_000
REASONS = ("input_invalid", "graph_changed", "list_invalid", "tree_invalid",
           "heap_unavailable", "history_unavailable", "allocation_unknown", "trace_unavailable",
           "candidate_limit", "tool_failed", "deadline", "process_exit_unconfirmed", "artifact_failed", "summary_budget")
TOOL_KINDS = ("list", "tree", "heap", "heap_diff", "history", "trace")
TOOL_STATES = ("complete", "spawn_failed", "timeout", "exit_failed", "output_invalid", "output_limit")


class EvidenceError(Exception):
    def __init__(self, reason):
        self.reason = reason
        super().__init__(reason)


class ExitUnconfirmed(EvidenceError):
    def __init__(self):
        super().__init__("process_exit_unconfirmed")


def integer(value):
    return type(value) is int and 0 <= value <= INTEGER_LIMIT


def read_bytes(path, limit=RAW_LIMIT):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
        raise ValueError("Invalid bounded evidence file")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Oversized evidence file")
    return data


def read_json(path, limit=65536):
    return json.loads(read_bytes(path, limit))


def graph_hash(path):
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("Invalid graph file")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def totals(report):
    matches = re.findall(r"^Process \d+: (\d{1,10}) leaks? for (\d{1,10}) total leaked bytes\.$", report, re.M)
    if len(matches) != 1:
        raise ValueError("Missing unique leak totals")
    nodes, size = map(int, matches[0])
    if not integer(nodes) or not integer(size) or nodes > 100000:
        raise ValueError("Invalid leak totals")
    return nodes, size


def parse_list(report):
    """Return complete private addresses; never treat a prefix as a full list."""
    expected = totals(report)
    rows = re.findall(r"^Leak: (0x[0-9a-fA-F]{1,16})\s+size=(\d{1,10})\s+zone:\s+\S+\s+([^\n]*)$", report, re.M)
    nodes, kinds = {}, {}
    for address, size, description in rows:
        address, size = int(address, 16), int(size)
        if address == 0 or address in nodes or not integer(size) or size == 0:
            raise ValueError("Invalid leak entry")
        nodes[address] = size
        kind = re.split(r"\s{2,}", description.strip())[0]
        kinds[address] = kind if kind in HEAP_TYPES else "unknown"
    if (len(re.findall(r"^Leak:", report, re.M)) != len(rows)
            or (len(nodes), sum(nodes.values())) != expected):
        raise ValueError("Incomplete leak list")
    return nodes, kinds


def parse_tree(report, nodes):
    """Accept only the observed default-tree grammar and validated back edges.

    A nested ROOT CYCLE label is a node, not another top-level cycle instance.
    Unsupported tree forms remain unknown instead of inventing an ownership map.
    """
    if totals(report) != (len(nodes), sum(nodes.values())):
        raise ValueError("Tree/list totals differ")
    body = report.split("Binary Images:", 1)[0]
    headers = list(re.finditer(r"^STACK OF (\d+) INSTANCES? OF '(ROOT CYCLE|ROOT LEAK): ([^\n]+)':$", body, re.M))
    if len(headers) != len(re.findall(r"^STACK OF ", body, re.M)) or (bool(nodes) != bool(headers)):
        raise ValueError("Unsupported tree header")
    mapping, seen = {}, set()
    for index, header in enumerate(headers):
        header_kind = header[3]
        # Actual default reports wrap allocation-site descriptions in <...>.
        if header_kind.startswith("<") and header_kind.endswith(">"):
            header_kind = header_kind[1:-1]
        block = body[header.end():headers[index + 1].start() if index + 1 < len(headers) else len(body)]
        if block.count("\n====\n") != 1:
            raise ValueError("Missing tree boundary")
        tree = block.split("\n====\n", 1)[1]
        stack, ancestors, roots = [], set(), []

        def close_node():
            entry = stack.pop()
            ancestors.remove(entry["address"])
            if entry["reported"] != len(seen) - entry["start"]:
                raise ValueError("Incomplete subtree")

        for line in tree.splitlines():
            if not line.strip():
                continue
            back = re.fullmatch(r"( +)CYCLE BACK TO <[^\n]+ (0x[0-9a-fA-F]{1,16})> \[(\d{1,10})\]", line)
            if back:
                address, size = int(back[2], 16), int(back[3])
                if not stack or len(back[1]) <= stack[-1]["indent"] or address not in ancestors or nodes.get(address) != size:
                    raise ValueError("Unbound cycle back edge")
                roots[-1]["cycle_back_edges"] += 1
                continue
            row = re.fullmatch(r"( +)(\d{1,6}) \([^\n)]+\) (?:(ROOT CYCLE|ROOT LEAK): )?<([^\n]+) (0x[0-9a-fA-F]{1,16})> \[(\d{1,10})\]", line)
            if not row:
                raise ValueError("Unsupported tree row")
            indent, count, marker, kind, address, size = row.groups()
            indent, count, address, size = len(indent), int(count), int(address, 16), int(size)
            if address in seen or nodes.get(address) != size:
                raise ValueError("Duplicate or unlisted tree node")
            while stack and indent <= stack[-1]["indent"]:
                close_node()
            if not stack:
                if marker != header[2] or kind != header_kind:
                    raise ValueError("Root/header mismatch")
                roots.append({"status": "mapped", "root_kind": "cycle" if marker == "ROOT CYCLE" else "leak",
                              "root_type": kind if kind in HEAP_TYPES else "unknown", "nodes": 0,
                              "bytes": 0, "cycle_back_edges": 0})
            stack.append({"address": address, "indent": indent, "reported": count, "start": len(seen)})
            ancestors.add(address)
            roots[-1]["nodes"] += 1
            roots[-1]["bytes"] += size
            mapping[address] = roots[-1]
            seen.add(address)
        while stack:
            close_node()
        if len(roots) != int(header[1]):
            raise ValueError("Root instance count mismatch")
    if seen != set(nodes):
        raise ValueError("Incomplete tree membership")
    return mapping


def trace_roots(report, address, size):
    prefix = r"<[^\n]+ (0x[0-9a-fA-F]{1,16})> \[(\d{1,10})\]"
    target = re.findall(r"^Tracing: " + prefix + r"$", report, re.M)
    roots = re.findall(r"^Found (\d{1,10}) roots? referencing: " + prefix + r"$", report, re.M)
    if (len(target) != 1 or len(roots) != 1
            or (int(target[0][0], 16), int(target[0][1])) != (address, size)
            or (int(roots[0][1], 16), int(roots[0][2])) != (address, size)
            or not integer(int(roots[0][0]))
            or "This is a reverse reference tree showing how the specified block is referenced.\n" not in report):
        raise ValueError("Unbound trace result")
    # Region lines include intermediate nodes and are not a root counter.
    return int(roots[0][0])


def empty_tree(status="unavailable"):
    return {"status": status, "root_kind": None, "root_type": None, "nodes": None, "bytes": None, "cycle_back_edges": None}


def initial_summary():
    return {"schema": 1, "status": "unavailable", "selection": None, "selected_label": None,
            "baseline": None, "selected": None, "comparison": None, "candidate_count": 0,
            "omitted_candidates": 0, "nodes": [], "tools": [], "reasons": [], "process_cleanup_confirmed": True}


def validate_summary(value):
    """Exact public schema: no raw address, type, path, symbol or exception text."""
    def require(condition):
        if not condition:
            raise ValueError("Invalid bounded frozen-node summary")
    require(type(value) is dict and set(value) == set(initial_summary()))
    require(type(value["schema"]) is int and value["schema"] == 1)
    require(value["status"] in ("complete", "partial", "unavailable"))
    require(value["selection"] in (None, "first-new-leak", "no-new-leak"))
    require(value["selected_label"] is None or value["selected_label"] in HEAP_LABELS[1:])
    require(type(value["process_cleanup_confirmed"]) is bool)
    for key in ("baseline", "selected"):
        point = value[key]
        if point is not None:
            require(type(point) is dict and set(point) == {"leak_nodes", "leak_bytes", "graph_sha256"})
            require(integer(point["leak_nodes"]) and integer(point["leak_bytes"]))
            require(type(point["graph_sha256"]) is str and re.fullmatch(r"[0-9a-f]{64}", point["graph_sha256"]) is not None)
    comparison = value["comparison"]
    if comparison is not None:
        require(type(comparison) is dict and set(comparison) == {"added_nodes", "added_bytes", "removed_nodes", "removed_bytes", "retained_addresses", "resized_addresses"})
        require(all(integer(item) for item in comparison.values()))
        require(value["baseline"] is not None and value["selected"] is not None)
        require(comparison["added_nodes"] + comparison["retained_addresses"] == value["selected"]["leak_nodes"])
        require(comparison["removed_nodes"] + comparison["retained_addresses"] == value["baseline"]["leak_nodes"])
        require(comparison["resized_addresses"] <= comparison["retained_addresses"])
        require(comparison["added_bytes"] <= value["selected"]["leak_bytes"] and comparison["removed_bytes"] <= value["baseline"]["leak_bytes"])
    require(integer(value["candidate_count"]) and integer(value["omitted_candidates"]))
    require(type(value["nodes"]) is list and len(value["nodes"]) <= CANDIDATES)
    require(value["candidate_count"] == len(value["nodes"]) + value["omitted_candidates"])
    require(value["candidate_count"] == (comparison["added_nodes"] + comparison["resized_addresses"]
                                         if comparison is not None else 0))
    for index, node in enumerate(value["nodes"]):
        require(type(node) is dict and set(node) == {"index", "type", "size", "baseline_heap_size", "baseline_presence",
                "baseline_tree", "selected_tree", "history", "baseline_external_roots", "selected_external_roots"})
        require(type(node["index"]) is int and node["index"] == index)
        require(node["type"] in (*HEAP_TYPES, "unknown") and integer(node["size"]) and node["size"] > 0)
        require(node["baseline_presence"] in ("present", "absent", "unknown"))
        require(node["baseline_heap_size"] is None or integer(node["baseline_heap_size"]))
        require((node["baseline_presence"] == "present") == (node["baseline_heap_size"] is not None))
        for field in ("baseline_external_roots", "selected_external_roots"):
            require(node[field] is None or integer(node[field]))
        require(node["baseline_presence"] == "present" or node["baseline_external_roots"] is None)
        for field in ("baseline_tree", "selected_tree"):
            tree = node[field]
            require(type(tree) is dict and set(tree) == set(empty_tree()))
            require(tree["status"] in ("mapped", "not_leaked", "unavailable"))
            if tree["status"] == "mapped":
                require(tree["root_kind"] in ("cycle", "leak") and tree["root_type"] in (*HEAP_TYPES, "unknown"))
                require(all(integer(tree[key]) for key in ("nodes", "bytes", "cycle_back_edges")))
                require(tree["nodes"] > 0)
            else:
                require(tree == empty_tree(tree["status"]))
        history = node["history"]
        require(type(history) is dict and set(history) == {"classification", "before_allocs", "before_frees", "after_allocs", "after_frees", "heap_diff_present"})
        require(history["classification"] in ("preexisting", "new_allocation", "unknown"))
        require(all(history[key] is None or integer(history[key]) for key in ("before_allocs", "before_frees", "after_allocs", "after_frees")))
        require(history["heap_diff_present"] is None or type(history["heap_diff_present"]) is bool)
    require(type(value["tools"]) is list and len(value["tools"]) <= 45)
    for tool in value["tools"]:
        require(type(tool) is dict and set(tool) == {"tool", "label", "status", "return_code", "cleanup_confirmed"})
        require(tool["tool"] in TOOL_KINDS and tool["label"] in HEAP_LABELS and tool["status"] in TOOL_STATES)
        require(tool["return_code"] is None or type(tool["return_code"]) is int and -255 <= tool["return_code"] <= 255)
        require(type(tool["cleanup_confirmed"]) is bool)
        allowed = (0, 1) if tool["tool"] in ("list", "tree") else (0,)
        require(tool["status"] != "complete" or tool["cleanup_confirmed"] and tool["return_code"] in allowed)
    require(type(value["reasons"]) is list and all(type(reason) is str and reason in REASONS for reason in value["reasons"]))
    require(len(set(value["reasons"])) == len(value["reasons"]))
    require(value["process_cleanup_confirmed"] or "process_exit_unconfirmed" in value["reasons"])
    if value["selection"] == "first-new-leak":
        require(value["selected_label"] is not None and value["baseline"] is not None and value["selected"] is not None)
    else:
        require(value["selected_label"] is None and value["selected"] is None and comparison is None and not value["nodes"] and value["candidate_count"] == 0)
    if value["status"] == "complete":
        require(value["selection"] is not None and value["baseline"] is not None and not value["reasons"] and value["process_cleanup_confirmed"])
        require(all(tool["status"] == "complete" and tool["cleanup_confirmed"] for tool in value["tools"]))
        labels = HEAP_LABELS
        if value["selection"] == "first-new-leak":
            labels = HEAP_LABELS[:HEAP_LABELS.index(value["selected_label"]) + 1]
            require(comparison is not None and bool(value["nodes"]) and value["omitted_candidates"] == 0)
            require(all(node["selected_tree"]["status"] == "mapped" and node["baseline_tree"]["status"] != "unavailable"
                        and node["history"]["classification"] != "unknown" and node["selected_external_roots"] is not None
                        and node["baseline_presence"] in ("present", "absent")
                        and (node["baseline_presence"] != "present" or node["baseline_external_roots"] is not None) for node in value["nodes"]))
        expected_tools = [("list", label) for label in labels]
        if value["selection"] == "first-new-leak":
            selected = value["selected_label"]
            expected_tools += [("tree", "baseline"), ("tree", selected), ("heap", "baseline"),
                               ("heap_diff", selected), ("history", "baseline"), ("history", selected)]
            for node in value["nodes"]:
                if node["baseline_presence"] == "present":
                    expected_tools.append(("trace", "baseline"))
                expected_tools.append(("trace", selected))
        require([(tool["tool"], tool["label"]) for tool in value["tools"]] == expected_tools)
    else:
        require(bool(value["reasons"]))
    require(len(encode_summary(value)) <= PUBLIC_LIMIT)


def encode_summary(value):
    return (json.dumps(value, separators=(",", ":")) + "\n").encode("utf-8")


class Tools:
    """Children stay in the outer run_owned group; wait before another tool."""
    def __init__(self, directory, summary, deadline):
        self.directory, self.summary, self.deadline = directory, summary, deadline
        directory.mkdir(exist_ok=False)

    def run(self, kind, label, command, allowed=(0,)):
        started = time.monotonic()
        remaining = self.deadline - started
        if remaining <= 2:
            raise EvidenceError("deadline")
        row = {"tool": kind, "label": label, "status": "spawn_failed", "return_code": None, "cleanup_confirmed": True}
        self.summary["tools"].append(row)
        name = f"{len(self.summary['tools']):02d}-{kind}-{label}"
        stdout, stderr = self.directory / (name + ".stdout.txt"), self.directory / (name + ".stderr.txt")
        def limit_output():
            resource.setrlimit(resource.RLIMIT_FSIZE, (RAW_LIMIT, RAW_LIMIT))
        with stdout.open("xb") as output, stderr.open("xb") as errors:
            try:
                child = subprocess.Popen(command, stdout=output, stderr=errors, preexec_fn=limit_output)
            except OSError:
                raise EvidenceError("tool_failed")
            except subprocess.SubprocessError:
                row["cleanup_confirmed"] = False
                self.summary["process_cleanup_confirmed"] = False
                raise ExitUnconfirmed()
            try:
                row["return_code"] = child.wait(timeout=min(TOOL_SECONDS - 2, remaining - 2))
            except subprocess.TimeoutExpired:
                row["status"] = "timeout"
                try:
                    child.kill()
                    row["return_code"] = child.wait(timeout=min(2, max(0.001, min(self.deadline, started + TOOL_SECONDS) - time.monotonic())))
                except (OSError, subprocess.TimeoutExpired):
                    row["cleanup_confirmed"] = False
                    self.summary["process_cleanup_confirmed"] = False
                    raise ExitUnconfirmed()
                raise EvidenceError("tool_failed")
            except OSError:
                row["status"] = "exit_failed"
                row["cleanup_confirmed"] = False
                self.summary["process_cleanup_confirmed"] = False
                raise ExitUnconfirmed()
        if row["return_code"] not in allowed:
            row["status"] = "exit_failed"
            raise EvidenceError("tool_failed")
        try:
            data, error_data = read_bytes(stdout, RAW_LIMIT), read_bytes(stderr, RAW_LIMIT)
        except ValueError:
            row["status"] = "output_limit"
            raise EvidenceError("tool_failed")
        row["status"] = "output_invalid"
        if error_data:
            raise EvidenceError("tool_failed")
        try:
            report = data.decode("utf-8")
        except UnicodeError:
            raise EvidenceError("tool_failed")
        row["status"] = "complete"
        return report


def compare(graph_directory, records):
    result = initial_summary()
    deadline = time.monotonic() + SECONDS
    def reason(name):
        if name not in result["reasons"]:
            result["reasons"].append(name)
    def attempt(code, operation):
        try:
            return operation()
        except ExitUnconfirmed:
            raise
        except EvidenceError as error:
            reason(error.reason)
        except (OSError, ValueError, TypeError, KeyError, RecursionError):
            pass
        reason(code)
        return None
    try:
        cleanup = read_json(records / "process-cleanup.json")
        scans = read_json(records / "scans.json")
        fixture = read_json(records / "result.json")
        if (type(cleanup) is not dict or cleanup.get("processes_exited") is not True
                or type(fixture) is not dict or fixture.get("mode") != "heap-control" or fixture.get("scan_mode") != "diagnostic"
                or type(scans) is not list or len(scans) != len(HEAP_LABELS)):
            raise EvidenceError("input_invalid")
        for label, point in zip(HEAP_LABELS, scans):
            if (type(point) is not dict or point.get("label") != label or not integer(point.get("leak_nodes"))
                    or not integer(point.get("leak_bytes")) or type(point.get("exit_code")) is not int or point["exit_code"] not in (0, 1)):
                raise EvidenceError("input_invalid")
        def snapshot(index):
            point = scans[index]
            return {"leak_nodes": point["leak_nodes"], "leak_bytes": point["leak_bytes"],
                    "graph_sha256": graph_hash(graph_directory / (point["label"] + ".memgraph"))}
        result["baseline"] = snapshot(0)
        tools = Tools(records / "frozen-nodes-private", result, deadline)
        def listing(name, graph, point):
            report = tools.run("list", name, ["/usr/bin/leaks", "--noContent", "--nosources", "--list", str(graph)], (0, 1))
            nodes, kinds = parse_list(report)
            if (len(nodes), sum(nodes.values())) != (point["leak_nodes"], point["leak_bytes"]):
                raise ValueError("List/scan mismatch")
            if graph_hash(graph) != point["graph_sha256"]:
                raise EvidenceError("graph_changed")
            return nodes, kinds
        before_graph = graph_directory / "baseline.memgraph"
        before = attempt("list_invalid", lambda: listing("baseline", before_graph, result["baseline"]))
        if before is None:
            return result
        selected, diff_nodes = None, None
        # Absolute lists, not leaks --diffFrom, determine later-reported nodes.
        # An equal total can hide address replacement; size changes also count.
        for index, label in enumerate(HEAP_LABELS[1:], 1):
            point = snapshot(index)
            graph = graph_directory / (label + ".memgraph")
            after = attempt("list_invalid", lambda: listing(label, graph, point))
            if after is None:
                return result  # Do not skip an unknown earlier checkpoint.
            changed = {address: size for address, size in after[0].items() if before[0].get(address) != size}
            if changed:
                selected, diff_nodes = index, changed
                result.update(selection="first-new-leak", selected_label=label, selected=point)
                break
        if selected is None:
            if snapshot(0) != result["baseline"]:
                raise EvidenceError("graph_changed")
            result.update(status="complete", selection="no-new-leak")
            return result
        label = result["selected_label"]
        after_graph = graph_directory / (label + ".memgraph")
        old, new = before[0], after[0]
        added, removed, retained = new.keys() - old.keys(), old.keys() - new.keys(), new.keys() & old.keys()
        result["comparison"] = {"added_nodes": len(added), "added_bytes": sum(new[a] for a in added),
            "removed_nodes": len(removed), "removed_bytes": sum(old[a] for a in removed),
            "retained_addresses": len(retained), "resized_addresses": sum(old[a] != new[a] for a in retained)}
        candidates = sorted(diff_nodes)[:CANDIDATES]
        result["candidate_count"] = len(diff_nodes)
        result["omitted_candidates"] = len(diff_nodes) - len(candidates)
        if result["omitted_candidates"]:
            reason("candidate_limit")
        for index, address in enumerate(candidates):
            result["nodes"].append({"index": index, "type": after[1][address], "size": new[address],
                "baseline_heap_size": None, "baseline_presence": "unknown", "baseline_tree": empty_tree(), "selected_tree": empty_tree(),
                "history": {"classification": "unknown", "before_allocs": None, "before_frees": None, "after_allocs": None, "after_frees": None, "heap_diff_present": None},
                "baseline_external_roots": None, "selected_external_roots": None})
        for name, graph, nodes, field in (("baseline", before_graph, old, "baseline_tree"), (label, after_graph, new, "selected_tree")):
            trees = attempt("tree_invalid", lambda: parse_tree(tools.run("tree", name,
                ["/usr/bin/leaks", "--noContent", "--nosources", str(graph)], (0, 1)), nodes))
            for address, row in zip(candidates, result["nodes"]):
                if address not in nodes:
                    row[field] = empty_tree("not_leaked")
                elif trees is not None:
                    row[field] = dict(trees[address])
        def heap(name, graph, diff=False):
            parsed = heap_allocations(tools.run("heap_diff" if diff else "heap", name,
                ["/usr/bin/heap", "--noContent", "--addresses", "all", *([f"--diffFrom={before_graph}"] if diff else []), str(graph)]))
            if parsed is None:
                raise ValueError("Incomplete heap inventory")
            return parsed
        baseline_heap = attempt("heap_unavailable", lambda: heap("baseline", before_graph))
        changed_heap = attempt("heap_unavailable", lambda: heap(label, after_graph, True))
        address_args = [hex(address) for address in candidates]
        def history(name, graph):
            parsed = allocation_history(tools.run("history", name, ["/usr/bin/malloc_history", str(graph), *address_args]), candidates)
            if parsed is None:
                raise ValueError("Incomplete allocation history")
            return parsed
        before_history = attempt("history_unavailable", lambda: history("baseline", before_graph))
        after_history = attempt("history_unavailable", lambda: history(label, after_graph))
        for address, row in zip(candidates, result["nodes"]):
            if baseline_heap is not None:
                row["baseline_presence"] = "present" if address in baseline_heap else "absent"
                row["baseline_heap_size"] = baseline_heap.get(address)
            evidence = row["history"]
            for prefix, events in (("before", before_history), ("after", after_history)):
                if events is not None:
                    for event, field in (("ALLOC", "allocs"), ("FREE", "frees")):
                        evidence[prefix + "_" + field] = sum(count for (kind, _), count in events[address].items() if kind == event)
            if changed_heap is not None:
                evidence["heap_diff_present"] = address in changed_heap
            if baseline_heap is not None and changed_heap is not None:
                if address not in baseline_heap and changed_heap.get(address) == row["size"]:
                    evidence["classification"] = "new_allocation"
                elif address in baseline_heap and before_history is not None and after_history is not None:
                    kind = allocation_generation(before_history[address], after_history[address], baseline_heap[address], row["size"])
                    if kind == "preexisting_nodes" and address not in changed_heap:
                        evidence["classification"] = "preexisting"
                    elif kind == "new_allocation_nodes" and changed_heap.get(address) == row["size"]:
                        evidence["classification"] = "new_allocation"
            if evidence["classification"] == "unknown":
                reason("allocation_unknown")
            for name, graph, size, field in (("baseline", before_graph, row["baseline_heap_size"], "baseline_external_roots"),
                                           (label, after_graph, row["size"], "selected_external_roots")):
                if size is not None:
                    row[field] = attempt("trace_unavailable", lambda: trace_roots(tools.run("trace", name,
                        ["/usr/bin/leaks", "--noContent", "--nosources", f"--traceTree={hex(address)}", str(graph)]), address, size))
        if snapshot(0) != result["baseline"] or snapshot(selected) != result["selected"]:
            reason("graph_changed")
    except EvidenceError as error:
        reason(error.reason)
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        reason("input_invalid")
    finally:
        if result["reasons"]:
            result["status"] = "partial" if result["comparison"] is not None else "unavailable"
        elif result["selection"] is not None:
            result["status"] = "complete"
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graph-directory", type=Path, required=True)
    parser.add_argument("--records-directory", type=Path, required=True)
    args = parser.parse_args(argv)
    result = compare(args.graph_directory, args.records_directory)
    while len(encode_summary(result)) > PUBLIC_LIMIT and result["nodes"]:
        result["nodes"].pop()
        result["omitted_candidates"] += 1
        result["status"] = "partial"
        if "summary_budget" not in result["reasons"]:
            result["reasons"].append("summary_budget")
    try:
        validate_summary(result)
        target = args.records_directory / "frozen-nodes.json"
        if target.is_symlink():
            raise ValueError("Invalid output file")
        target.write_bytes(encode_summary(result))
    except (OSError, ValueError, TypeError, RecursionError):
        # Never print private tool output, paths, or exception text.
        print("Frozen-node summary unavailable")
        return 1
    print("Frozen-node summary " + result["status"])
    return 0 if result["status"] == "complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
