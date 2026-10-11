"""Bounded, private-address comparison of existing frozen AX checkpoints.

This runs after the fixture exits. Default leak trees describe the tool's chosen
tree, and traceTree describes reverse paths; neither is a complete ownership graph.
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

from ax_parser_evidence import Collector, encode_evidence, validate_evidence, thread_register
from ax_evidence_errors import EvidenceError, ExitUnconfirmed
from ax_probe_report import HEAP_LABELS, HEAP_TYPES, allocation_generation, allocation_history, heap_allocations

SECONDS = 90
TOOL_SECONDS = 15
CANDIDATES = 16
RAW_LIMIT = 16 * 1024 * 1024
PUBLIC_LIMIT = 131072
INTEGER_LIMIT = 1_000_000_000
REASONS = ("input_invalid", "graph_changed", "list_invalid", "tree_invalid",
           "heap_unavailable", "history_unavailable", "allocation_unknown", "trace_unavailable",
           "candidate_limit", "tool_failed", "deadline", "process_exit_unconfirmed", "artifact_failed", "summary_budget",
           "references_invalid", "references_budget")
TOOL_KINDS = ("list", "tree", "heap", "heap_diff", "history", "trace")
TOOL_STATES = ("complete", "spawn_failed", "timeout", "exit_failed", "output_invalid", "output_limit")
REFERENCE_NODES = 512
REFERENCE_EDGES = 1024
REFERENCE_TYPES = (*HEAP_TYPES, "NSXPCInterface", "xpc_connection_t", "dispatch_mach_t", "__NSMallocBlock__",
                   "CFDictionary", "CFDictionary (Value Storage)", "CFDictionary (Key Storage)", "NSSet",
                   "dispatch_queue_t (serial)", "dispatch_group_t", "unknown")
REFERENCE_LABELS = ("unlabeled", "unknown", "_connection", "_remoteObjectInterface", "_methodInfo", "list",
                    "__strong [capture]", "[capture]", "[__block capture]", "__strong", "__strong _object",
                    "__strong storage", "__strong _values", "_userQueue", "_exportInfo", "_replyGroup",
                    "_importInfo", "_interruptionHandler", "_repliesRequested", "_dCache", "_eCache", "_repliesExpected")
REFERENCE_PROTOCOLS = ("none", "unknown", "NSAccessibilityRemoteUIElement", "NSAccessibilityRemoteUIElementProtocol",
                       "LNDaemonApplicationInterface")
REFERENCE_REGIONS = ("none", "stack", "data", "kernel", "other")
ADDRESS = r"0x[0-9a-fA-F]{1,16}"
EDGE_NAME = r"(?:(?:__strong|__weak) ?)?(?:\[(?:__block )?capture\]|[A-Za-z_][A-Za-z0-9_.]*)?"


def reference_label(raw):
    return raw if raw in REFERENCE_LABELS else "unknown" if raw else "unlabeled"


def object_description(text):
    """Parse tool syntax privately; publish only literal type/protocol buckets."""
    match = re.fullmatch(r"(?:<(.+) (" + ADDRESS + r")>|(" + ADDRESS + r")) \[(\d{1,10})\](.*)", text)
    if not match:
        raise ValueError("Unsupported object description")
    kind, address, bare, size, suffix = match.groups()
    address, size = int(address or bare, 16), int(size)
    if not address or not 0 < size <= INTEGER_LIMIT:
        raise ValueError("Invalid object")
    protocol = "none"
    if suffix:
        protocol_match = re.fullmatch(r"  Protocol: ([A-Za-z_][A-Za-z0-9_]*)(?:  Connection: <[^\n>]+> \[[^\n\]]+\])?", suffix)
        if protocol_match:
            protocol = protocol_match[1] if protocol_match[1] in REFERENCE_PROTOCOLS else "unknown"
        elif re.fullmatch(r"  <[^\n>]+> \[[^\n\]]+\]", suffix):
            pass
        elif kind == "__NSMallocBlock__" and re.fullmatch(r"  \S+  [^\n]+  " + ADDRESS, suffix):
            pass
        else:
            raise ValueError("Unsupported object suffix")
    return {"address": address, "size": size, "kind": kind or "unknown", "protocol": protocol, "region": "none"}


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


def parse_tree_graph(report, nodes):
    """Validate the complete reported tree, retaining private address relations.

    These are leaks' selected relationships, not a complete ARC ownership graph.
    Both allocation-stack groups and the ungrouped TOTAL form are observed forms.
    """
    if totals(report) != (len(nodes), sum(nodes.values())):
        raise ValueError("Tree/list totals differ")
    body = report.split("Binary Images:", 1)[0]
    total_line = re.search(r"^Process \d+: \d+ leaks? for \d+ total leaked bytes\.$", body, re.M)
    body = body[total_line.end():]
    headers = list(re.finditer(r"^STACK OF (\d+) INSTANCES? OF '(ROOT CYCLE|ROOT LEAK): ([^\n]+)':$", body, re.M))
    if len(headers) != len(re.findall(r"^STACK OF ", body, re.M)):
        raise ValueError("Unsupported tree header")
    blocks = []
    if headers:
        if body[:headers[0].start()].strip():
            raise ValueError("Unparsed tree prefix")
        for index, header in enumerate(headers):
            block = body[header.end():headers[index + 1].start() if index + 1 < len(headers) else len(body)]
            if block.count("\n====\n") != 1:
                raise ValueError("Missing tree boundary")
            kind = header[3]
            if kind.startswith("<") and kind.endswith(">"):
                kind = kind[1:-1]
            blocks.append((block.split("\n====\n", 1)[1], int(header[1]), header[2], kind))
    else:
        lines = [line for line in body.splitlines() if line.strip()]
        if lines:
            marker = re.fullmatch(r" *(\d+) \([^\n)]+\) << TOTAL >>", lines.pop(0))
            if not marker or int(marker[1]) != len(nodes):
                raise ValueError("Unsupported ungrouped tree")
        elif nodes:
            raise ValueError("Missing tree")
        blocks.append(("\n".join(lines), None, None, None))
    graph = {"members": {}, "roots": [], "back_edges": []}
    seen = set()
    for tree, instances, header_marker, header_kind in blocks:
        stack, ancestors, root_count = [], set(), 0
        lines = [line for line in tree.splitlines() if line.strip()]
        aggregate = re.fullmatch(r"( +)(\d{1,6}) \([^\n)]+\) << TOTAL >>", lines[0]) if lines else None
        group_start, separator_pending = len(seen), False
        if aggregate:
            if instances is None or instances < 2 or not 0 < int(aggregate[2]) <= 100000:
                raise ValueError("Unsupported tree row")
            lines.pop(0)
        separated = aggregate and any(re.fullmatch(r" +----", line) for line in lines)

        def close_node():
            entry = stack.pop()
            ancestors.remove(entry["address"])
            if entry["reported"] != len(seen) - entry["start"]:
                raise ValueError("Incomplete subtree")

        for line in lines:
            # Observed multi-instance groups use either blank lines or a ----
            # separator before every root, never arbitrary skipped content.
            if aggregate and re.fullmatch(r" +----", line):
                if len(line) - 4 != len(aggregate[1]) + 2 or separator_pending:
                    raise ValueError("Unsupported tree row")
                while stack:
                    close_node()
                separator_pending = True
                continue
            row = re.fullmatch(r"( +)(?:(\d{1,6}) \([^\n)]+\) )?(.*)", line)
            if not row:
                raise ValueError("Unsupported tree row")
            indent, count, text = len(row[1]), row[2], row[3]
            while stack and indent <= stack[-1]["indent"]:
                close_node()
            if aggregate and not stack:
                if bool(separator_pending) != bool(separated) or indent != len(aggregate[1]) + 2:
                    raise ValueError("Unsupported tree row")
                separator_pending = False
            edge = None
            if " --> " in text:
                edge, text = text.split(" --> ", 1)
                if not edge or not re.fullmatch(EDGE_NAME, edge):
                    raise ValueError("Unsupported edge syntax")
            if text.startswith("CYCLE BACK TO "):
                if count is not None:
                    raise ValueError("Counted back edge")
                obj = object_description(text[len("CYCLE BACK TO "):])
                address = obj["address"]
                if not stack or address not in ancestors or nodes.get(address) != obj["size"]:
                    raise ValueError("Unbound cycle back edge")
                target = graph["members"][address]
                if obj["kind"] != target["kind"] or obj["protocol"] not in ("none", target["protocol"]):
                    raise ValueError("Contradictory back edge")
                graph["back_edges"].append({"source": stack[-1]["address"], "target": address,
                                            "label": reference_label(edge), "root": target["root"]})
                graph["roots"][target["root"]]["summary"]["cycle_back_edges"] += 1
                continue
            if count is None:
                raise ValueError("Uncounted tree node")
            marker = None
            for prefix in ("ROOT CYCLE", "ROOT LEAK"):
                if text.startswith(prefix + ": "):
                    marker, text = prefix, text[len(prefix) + 2:]
                    break
            obj = object_description(text)
            address, size, kind = obj["address"], obj["size"], obj["kind"]
            if address in seen or nodes.get(address) != size:
                raise ValueError("Duplicate or unlisted tree node")
            if not stack:
                if edge is not None or marker is None or (header_marker is not None and (marker, kind) != (header_marker, header_kind)):
                    raise ValueError("Root/header mismatch")
                root_count += 1
                graph["roots"].append({"address": address, "protocol": obj["protocol"], "summary": {
                    "status": "mapped", "root_kind": "cycle" if marker == "ROOT CYCLE" else "leak",
                    "root_type": kind if kind in HEAP_TYPES else "unknown", "nodes": 0, "bytes": 0, "cycle_back_edges": 0}})
            root = len(graph["roots"]) - 1
            obj.update(parent=stack[-1]["address"] if stack else None, edge=reference_label(edge), root=root)
            graph["members"][address] = obj
            graph["roots"][root]["summary"]["nodes"] += 1
            graph["roots"][root]["summary"]["bytes"] += size
            stack.append({"address": address, "indent": indent, "reported": int(count), "start": len(seen)})
            ancestors.add(address)
            seen.add(address)
        while stack:
            close_node()
        if separator_pending:
            raise ValueError("Unsupported tree row")
        if aggregate and int(aggregate[2]) != len(seen) - group_start:
            raise ValueError("Incomplete subtree")
        if instances is not None and root_count != instances:
            raise ValueError("Root instance count mismatch")
    if seen != set(nodes):
        raise ValueError("Incomplete tree membership")
    for root in graph["roots"]:
        graph["members"][root["address"]]["tree"] = dict(root["summary"])
    return graph


def parse_tree(report, nodes):
    graph = parse_tree_graph(report, nodes)
    return {address: graph["roots"][node["root"]]["summary"] for address, node in graph["members"].items()}


def trace_roots(report, address, size):
    target = re.findall(r"^Tracing: (.+)$", report, re.M)
    roots = re.findall(r"^Found (\d{1,10}) roots? referencing: (.+)$", report, re.M)
    if len(target) != 1 or len(roots) != 1 or not integer(int(roots[0][0])):
        raise ValueError("Unbound trace result")
    for text in (target[0], roots[0][1]):
        obj = object_description(text)
        if (obj["address"], obj["size"]) != (address, size):
            raise ValueError("Unbound trace result")
    if "This is a reverse reference tree showing how the specified block is referenced.\n" not in report:
        raise ValueError("Unbound trace result")
    # Region lines include intermediate nodes and are not a root counter.
    return int(roots[0][0])


def parse_trace_graph(report, address, size):
    """Validate all reverse paths; edge direction is referrer -> referenced."""
    roots = trace_roots(report, address, size)
    preamble = (
        "This is a reverse reference tree showing how the specified block is referenced.\n"
        "The top node is the specified block, the next level down are blocks that reference that, and so on.\n"
        "The number at the start of each line is the number of paths-to-roots going through that node.\n")
    marker = "This reverse reference tree can be imported into Instruments using Import Sample Data to allow data mining.\n"
    if report.count(preamble) != 1 or any(report.count(line) != 1 for line in preamble.splitlines()):
        raise ValueError("Unsupported trace preamble")
    body = report.split(preamble, 1)[1]
    if marker in report:
        if report.count(marker) != 1 or not body.startswith(marker):
            raise ValueError("Unsupported trace preamble")
        body = body[len(marker):]
    members, edges, stack, slots = {}, [], [], []
    top = None

    def close():
        entry = stack.pop()
        if entry["children"]:
            if entry["children"] != entry["paths"]:
                raise ValueError("Trace path count mismatch")
        elif not entry["terminal"] or entry["paths"] != 1:
            raise ValueError("Incomplete trace root")

    for line in body.splitlines():
        if not line.strip():
            continue
        row = re.fullmatch(r"([ +!:|]+)(\d{1,10}) (.+?) *", line)
        if not row:
            raise ValueError("Unsupported trace row")
        indent, paths, text = len(row[1]), int(row[2]), row[3]
        if not 0 < paths <= INTEGER_LIMIT:
            raise ValueError("Invalid trace paths")
        while stack and indent <= stack[-1]["indent"]:
            close()
        if stack and stack[-1]["leaf_only"]:
            raise ValueError("Invalid reverse nesting")
        label, leaf_only, heap_offset = "unlabeled", False, None
        slot_root = re.fullmatch(r"<([^<>\r\n\t]{1,1024})> +\+(\d{1,10}): +__strong +(" + ADDRESS + r")", text)
        register_root = thread_register(text)
        if register_root:
            if paths != 1 or not stack:
                raise ValueError("Unsupported reverse object")
            offset = int(register_root[6] or 0)
            parent = members[stack[-1]["address"]]
            if parent["size"] and offset >= parent["size"]:
                raise ValueError("Unbound reference slot")
            # Report-local thread ordinals identify register slots within a
            # checkpoint only; they do not identify a thread across snapshots.
            key = ("thread-register", int(register_root[1]), register_root[5])
            obj = {"address": key, "kind": "unknown", "protocol": "none", "size": 0, "region": "other",
                   "slot_binding": (register_root[3], stack[-1]["address"], offset)}
            terminal, leaf_only = True, True
        elif slot_root:
            description, offset, slot = slot_root[1], int(slot_root[2]), int(slot_root[3], 16)
            if (not description.strip() or not description.isprintable() or re.search(r"\b" + ADDRESS + r"\b", description)
                    or not integer(offset) or not slot or paths != 1 or not stack):
                raise ValueError("Unsupported reverse object")
            # The tool omits the base and size of this root. Its identity is the
            # reported reference slot, not an inferred heap object or ownership.
            key = ("metadata-slot", slot)
            obj = {"address": key, "kind": "unknown", "protocol": "none", "size": 0, "region": "other",
                   "slot_binding": (description, offset, stack[-1]["address"])}
            label, terminal, leaf_only = "__strong", True, True
        elif text.startswith("Region "):
            region = re.fullmatch(r"Region ([^\n]+) (" + ADDRESS + r")(?: --> offset \d+)?", text)
            if not region:
                raise ValueError("Unsupported region")
            name = region[1]
            category = "stack" if name.startswith("Stack ") else "data" if "__DATA" in name else "other"
            key = ("region", int(region[2], 16))
            obj = {"address": key, "kind": "unknown", "protocol": "none", "size": 0, "region": category}
            terminal = True
        elif text == "Kernel Pointers Into User Space":
            key = ("kernel",)
            obj = {"address": key, "kind": "unknown", "protocol": "none", "size": 0, "region": "kernel"}
            terminal = True
        else:
            # Offset and pointer are checked privately and never become node IDs.
            match = re.fullmatch(r"(.*? \[\d{1,10}\])(?: +(\+\d+): *(.*?) (" + ADDRESS + r")(?: --> offset \d+)?)?", text)
            if not match:
                raise ValueError("Unsupported reverse object")
            obj = object_description(match[1])
            key, terminal = obj["address"], False
            if match[2]:
                offset = int(match[2][1:])
                if offset >= obj["size"] or int(match[4], 16) != key + offset:
                    raise ValueError("Unbound reference slot")
                heap_offset = offset
                raw_label = match[3].strip()
                if raw_label and not re.fullmatch(EDGE_NAME + r"(?: \+ \d+)?", raw_label):
                    raise ValueError("Unsupported reference label")
                label = reference_label(raw_label)
            elif stack:
                raise ValueError("Missing reverse reference slot")
        existing = members.get(key)
        if existing is not None and existing != obj:
            raise ValueError("Conflicting trace object")
        members[key] = obj
        if not stack:
            if top is not None or key != address or obj["size"] != size or paths != roots:
                raise ValueError("Unbound trace tree")
            top = key
        else:
            if indent != stack[-1]["indent"] + 2:
                raise ValueError("Invalid reverse nesting")
            stack[-1]["children"] += paths
            edge = {"source": key, "target": stack[-1]["address"], "label": label, "relation": "reverse_reference"}
            if edge not in edges:
                edges.append(edge)
            if heap_offset is not None:
                slot = {"source": key, "target": stack[-1]["address"], "offset": heap_offset}
                if slot not in slots:
                    slots.append(slot)
        stack.append({"address": key, "indent": indent, "paths": paths, "children": 0, "terminal": terminal, "leaf_only": leaf_only})
    while stack:
        close()
    if bool(roots) != (top is not None):
        raise ValueError("Missing trace tree")
    if not roots:
        members[address] = object_description(re.search(r"^Tracing: (.+)$", report, re.M)[1])
    return {"members": members, "edges": edges, "slots": slots, "root": address, "target": address, "roots": roots}


def tree_reference_graph(graph, address):
    member = graph["members"][address]
    root = member["root"]
    backs = [edge for edge in graph["back_edges"] if edge["root"] == root]
    selected = set()
    for endpoint in [address, *(edge["source"] for edge in backs), *(edge["target"] for edge in backs)]:
        while endpoint is not None and endpoint not in selected:
            selected.add(endpoint)
            endpoint = graph["members"][endpoint]["parent"]
    edges = []
    for key in sorted(selected):
        obj = graph["members"][key]
        if obj["parent"] is not None:
            edges.append({"source": obj["parent"], "target": key, "label": obj["edge"], "relation": "tree_child"})
    edges.extend({"source": edge["source"], "target": edge["target"], "label": edge["label"], "relation": "cycle_back"} for edge in backs)
    return {"members": {key: graph["members"][key] for key in sorted(selected)}, "edges": edges,
            "root": graph["roots"][root]["address"], "target": address}


def empty_references():
    return {"status": "not_needed", "semantics": "tool-reported", "nodes": [], "edges": [], "views": []}


def reference_view(candidate, checkpoint, kind, status="unavailable"):
    return {"candidate": candidate, "checkpoint": checkpoint, "kind": kind, "status": status,
            "root": None, "target": None, "nodes": [], "edges": []}


class References:
    """Atomically publish bounded views with shared same-run address IDs."""
    def __init__(self, summary, addresses):
        self.summary = summary
        self.value = summary["references"]
        self.ids = {address: index for index, address in enumerate(sorted(addresses))}
        self.slot_bindings = {}

    def view(self, candidate, checkpoint, kind):
        return next(view for view in self.value["views"] if
                    (view["candidate"], view["checkpoint"], view["kind"]) == (candidate, checkpoint, kind))

    def add(self, graph, view):
        checkpoint = view["checkpoint"]
        slot_bindings = {(checkpoint, key): obj["slot_binding"] for key, obj in graph["members"].items() if "slot_binding" in obj}
        if any(key in self.slot_bindings and self.slot_bindings[key] != binding for key, binding in slot_bindings.items()):
            raise ValueError("Conflicting trace object")
        identities = {key: (checkpoint, key) if isinstance(key, tuple) and key[0] == "thread-register" else key
                      for key in graph["members"]}
        for address in identities.values():
            if address not in self.ids:
                self.ids[address] = len(self.ids)
        nodes = [{"id": self.ids[identities[key]], "checkpoint": checkpoint,
                  "type": obj["kind"] if obj["kind"] in REFERENCE_TYPES else "unknown",
                  "protocol": obj["protocol"], "size": obj["size"], "region": obj["region"], "tree": obj.get("tree")}
                 for key, obj in graph["members"].items()]
        edges = [{"checkpoint": checkpoint, "source": self.ids[identities[edge["source"]]], "target": self.ids[identities[edge["target"]]],
                  "relation": edge["relation"], "label": edge["label"], "count": 1} for edge in graph["edges"]]
        unique_edges = []
        for edge in edges:
            previous = next((item for item in unique_edges if all(item[key] == edge[key] for key in edge if key != "count")), None)
            if previous is None: unique_edges.append(edge)
            else: previous["count"] += 1
        edges = unique_edges
        new_nodes = [node for node in nodes if node not in self.value["nodes"]]
        added_identities = {(node["id"], checkpoint) for node in new_nodes} - {(node["id"], node["checkpoint"]) for node in self.value["nodes"]}
        new_edges = [edge for edge in edges if edge not in self.value["edges"]]
        if len(self.value["nodes"]) + len(added_identities) > REFERENCE_NODES or len(self.value["edges"]) + len(new_edges) > REFERENCE_EDGES:
            view["status"] = "budget_exceeded"
            raise EvidenceError("references_budget")
        # Unknown type information in one tool is not a conflicting identity.
        for node in new_nodes:
            previous = next((item for item in self.value["nodes"] if (item["id"], item["checkpoint"]) == (node["id"], checkpoint)), None)
            if previous is not None:
                if previous["size"] != node["size"] or previous["region"] != node["region"]:
                    raise ValueError("Conflicting reference identity")
                if node["type"] != "unknown" and previous["type"] not in ("unknown", node["type"]):
                    raise ValueError("Conflicting reference type")
                if node["protocol"] != "none" and previous["protocol"] not in ("none", node["protocol"]):
                    raise ValueError("Conflicting reference protocol")
                if node["tree"] is not None and previous["tree"] not in (None, node["tree"]):
                    raise ValueError("Conflicting root metadata")
        for node in new_nodes:
            previous = next((item for item in self.value["nodes"] if (item["id"], item["checkpoint"]) == (node["id"], checkpoint)), None)
            if previous is None:
                self.value["nodes"].append(node)
            else:
                if previous["type"] == "unknown": previous["type"] = node["type"]
                if previous["protocol"] == "none": previous["protocol"] = node["protocol"]
                if previous["tree"] is None: previous["tree"] = node["tree"]
        self.value["edges"].extend(new_edges)
        self.slot_bindings.update(slot_bindings)
        view.update(status="complete", root=self.ids[graph["root"]], target=self.ids[graph["target"]],
                    nodes=[node["id"] for node in nodes], edges=[self.value["edges"].index(edge) for edge in edges])


def roots_overview(graph):
    roots = [{**{key: value for key, value in root["summary"].items() if key != "status"}, "protocol": root["protocol"]}
             for root in graph["roots"]]
    if len(roots) > REFERENCE_NODES:
        return {"status": "budget_exceeded", "roots": []}
    return {"status": "complete", "roots": roots}

def empty_tree(status="unavailable"):
    return {"status": status, "root_kind": None, "root_type": None, "nodes": None, "bytes": None, "cycle_back_edges": None}


def initial_summary():
    return {"schema": 2, "status": "unavailable", "selection": None, "selected_label": None,
            "checked_points": [], "baseline_roots": {"status": "not_requested", "roots": []}, "references": empty_references(),
            "baseline": None, "selected": None, "comparison": None, "candidate_count": 0,
            "omitted_candidates": 0, "nodes": [], "tools": [], "reasons": [], "process_cleanup_confirmed": True}


def validate_summary(value):
    """Exact public schema: no raw address, type, path, symbol or exception text."""
    def require(condition):
        if not condition:
            raise ValueError("Invalid bounded frozen-node summary")
    require(type(value) is dict and set(value) == set(initial_summary()))
    require(type(value["schema"]) is int and value["schema"] == 2)
    require(value["status"] in ("complete", "partial", "unavailable"))
    require(value["selection"] in (None, "first-new-leak", "no-new-leak", "first-strict-growth", "no-strict-growth"))
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
    if value["selection"] in ("first-new-leak", "first-strict-growth"):
        require(value["selected_label"] is not None and value["baseline"] is not None and value["selected"] is not None)
    else:
        require(value["selected_label"] is None and value["selected"] is None and comparison is None and not value["nodes"] and value["candidate_count"] == 0)
    if value["status"] == "complete":
        require(value["selection"] is not None and value["baseline"] is not None and not value["reasons"] and value["process_cleanup_confirmed"])
        require(all(tool["status"] == "complete" and tool["cleanup_confirmed"] for tool in value["tools"]))
        labels = HEAP_LABELS
        if value["selection"] in ("first-new-leak", "first-strict-growth"):
            labels = HEAP_LABELS[:HEAP_LABELS.index(value["selected_label"]) + 1]
            require(comparison is not None and bool(value["nodes"]) and value["omitted_candidates"] == 0)
            require(all(node["selected_tree"]["status"] == "mapped" and node["baseline_tree"]["status"] != "unavailable"
                        and node["history"]["classification"] != "unknown" and node["selected_external_roots"] is not None
                        and node["baseline_presence"] in ("present", "absent")
                        and (node["baseline_presence"] != "present" or node["baseline_external_roots"] is not None) for node in value["nodes"]))
        expected_tools = [("list", label) for label in labels]
        if value["selection"] in ("first-new-leak", "first-strict-growth"):
            selected = value["selected_label"]
            expected_tools += [("tree", "baseline"), ("tree", selected), ("heap", "baseline"),
                               ("heap_diff", selected), ("history", "baseline"), ("history", selected)]
            for node in value["nodes"]:
                if node["baseline_presence"] == "present":
                    expected_tools.append(("trace", "baseline"))
                expected_tools.append(("trace", selected))
        if value["selection"] == "no-strict-growth":
            expected_tools.append(("tree", "baseline"))
        require([(tool["tool"], tool["label"]) for tool in value["tools"]] == expected_tools)
    else:
        require(bool(value["reasons"]))
    validate_references(value)
    require(len(encode_summary(value)) <= PUBLIC_LIMIT)



def validate_references(value):
    """Public references have no free text or address-derived strings."""
    def require(condition):
        if not condition:
            raise ValueError("Invalid public reference evidence")
    points = value["checked_points"]
    require(type(points) is list and len(points) <= len(HEAP_LABELS))
    for index, point in enumerate(points):
        require(type(point) is dict and set(point) == {"label", "leak_nodes", "leak_bytes"})
        require(point["label"] == HEAP_LABELS[index] and integer(point["leak_nodes"]) and integer(point["leak_bytes"]))
    if points:
        require(value["baseline"] is not None and all(points[0][key] == value["baseline"][key] for key in ("leak_nodes", "leak_bytes")))
    selection = value["selection"]
    if selection in ("first-strict-growth", "no-strict-growth"):
        require(bool(points))
        growth = [index for index, point in enumerate(points) if
                  point["leak_nodes"] > points[0]["leak_nodes"] or point["leak_bytes"] > points[0]["leak_bytes"]]
        if selection == "no-strict-growth":
            require(len(points) == len(HEAP_LABELS) and not growth)
        else:
            require(growth == [len(points) - 1] and points[-1]["label"] == value["selected_label"])
    if value["selected"] is not None:
        require(bool(points) and points[-1]["label"] == value["selected_label"])
        require(all(points[-1][key] == value["selected"][key] for key in ("leak_nodes", "leak_bytes")))
    if value["status"] == "complete":
        labels = HEAP_LABELS[:HEAP_LABELS.index(value["selected_label"]) + 1] if value["selected_label"] else HEAP_LABELS
        require([point["label"] for point in points] == list(labels))
        if value["selected"] is not None:
            require(all(points[-1][key] == value["selected"][key] for key in ("leak_nodes", "leak_bytes")))
    overview = value["baseline_roots"]
    require(type(overview) is dict and set(overview) == {"status", "roots"})
    require(overview["status"] in ("not_requested", "complete", "unavailable", "budget_exceeded"))
    require(type(overview["roots"]) is list and len(overview["roots"]) <= REFERENCE_NODES)
    for root in overview["roots"]:
        require(type(root) is dict and set(root) == {"root_kind", "root_type", "protocol", "nodes", "bytes", "cycle_back_edges"})
        require(root["root_kind"] in ("cycle", "leak") and root["root_type"] in REFERENCE_TYPES and root["protocol"] in REFERENCE_PROTOCOLS)
        require(all(integer(root[key]) for key in ("nodes", "bytes", "cycle_back_edges")) and root["nodes"] > 0 and root["bytes"] > 0)
    if overview["status"] == "complete":
        require(value["baseline"] is not None)
        require(sum(root["nodes"] for root in overview["roots"]) == value["baseline"]["leak_nodes"])
        require(sum(root["bytes"] for root in overview["roots"]) == value["baseline"]["leak_bytes"])
    else:
        require(not overview["roots"])
    if value["status"] == "complete" and selection != "no-new-leak":
        require(overview["status"] == "complete")
    refs = value["references"]
    require(type(refs) is dict and set(refs) == set(empty_references()))
    require(refs["status"] in ("not_needed", "complete", "partial", "unavailable") and refs["semantics"] == "tool-reported")
    require(type(refs["nodes"]) is list and len(refs["nodes"]) <= REFERENCE_NODES)
    require(type(refs["edges"]) is list and len(refs["edges"]) <= REFERENCE_EDGES)
    require(type(refs["views"]) is list and len(refs["views"]) <= CANDIDATES * 4)
    identities = set()
    for node in refs["nodes"]:
        require(type(node) is dict and set(node) == {"id", "checkpoint", "type", "protocol", "size", "region", "tree"})
        require(integer(node["id"]) and node["checkpoint"] in ("baseline", "selected"))
        require(node["type"] in REFERENCE_TYPES and node["protocol"] in REFERENCE_PROTOCOLS and node["region"] in REFERENCE_REGIONS)
        require(integer(node["size"]) and ((node["region"] == "none") == (node["size"] > 0)))
        if node["tree"] is not None:
            tree = node["tree"]
            require(type(tree) is dict and set(tree) == set(empty_tree()) and tree["status"] == "mapped")
            require(tree["root_kind"] in ("cycle", "leak") and tree["root_type"] == (node["type"] if node["type"] in HEAP_TYPES else "unknown"))
            require(all(integer(tree[key]) for key in ("nodes", "bytes", "cycle_back_edges")) and tree["nodes"] > 0 and tree["bytes"] >= node["size"])
        identity = (node["checkpoint"], node["id"])
        require(identity not in identities)
        identities.add(identity)
    edge_keys = set()
    for edge in refs["edges"]:
        require(type(edge) is dict and set(edge) == {"checkpoint", "source", "target", "relation", "label", "count"})
        require(edge["checkpoint"] in ("baseline", "selected") and integer(edge["source"]) and integer(edge["target"]))
        require((edge["checkpoint"], edge["source"]) in identities and (edge["checkpoint"], edge["target"]) in identities)
        require(edge["relation"] in ("tree_child", "cycle_back", "reverse_reference") and edge["label"] in REFERENCE_LABELS)
        require(integer(edge["count"]) and edge["count"] > 0)
        key = tuple(edge[field] for field in ("checkpoint", "source", "target", "relation", "label"))
        require(key not in edge_keys)
        edge_keys.add(key)
    view_keys = set()
    candidate_ids = {}
    for view in refs["views"]:
        require(type(view) is dict and set(view) == set(reference_view(0, "baseline", "tree")))
        require(integer(view["candidate"]) and view["candidate"] < len(value["nodes"]))
        require(view["checkpoint"] in ("baseline", "selected") and view["kind"] in ("tree", "trace"))
        key = (view["candidate"], view["checkpoint"], view["kind"])
        require(key not in view_keys)
        view_keys.add(key)
        require(view["status"] in ("complete", "not_leaked", "not_present", "unavailable", "budget_exceeded"))
        require(type(view["nodes"]) is list and all(integer(item) for item in view["nodes"]) and len(set(view["nodes"])) == len(view["nodes"]))
        require(type(view["edges"]) is list and all(integer(item) and item < len(refs["edges"]) for item in view["edges"]) and len(set(view["edges"])) == len(view["edges"]))
        candidate = value["nodes"][view["candidate"]]
        if view["status"] == "complete":
            require(integer(view["root"]) and integer(view["target"]) and view["root"] in view["nodes"] and view["target"] in view["nodes"])
            require(all((view["checkpoint"], ident) in identities for ident in view["nodes"]))
            target_node = next(node for node in refs["nodes"] if (node["checkpoint"], node["id"]) == (view["checkpoint"], view["target"]))
            expected_size = candidate["size"] if view["checkpoint"] == "selected" else candidate["baseline_heap_size"]
            if expected_size is not None: require(target_node["size"] == expected_size)
            previous = candidate_ids.setdefault(view["candidate"], view["target"])
            require(previous == view["target"])
            included = [refs["edges"][index] for index in view["edges"]]
            require(all(edge["checkpoint"] == view["checkpoint"] and edge["source"] in view["nodes"] and edge["target"] in view["nodes"] for edge in included))
            require(all((edge["relation"] == "reverse_reference") == (view["kind"] == "trace") for edge in included))
            if view["kind"] == "trace":
                require(view["root"] == view["target"] and candidate[view["checkpoint"] + "_external_roots"] is not None)
            else:
                tree = candidate[view["checkpoint"] + "_tree"]
                require(tree["status"] == "mapped")
                root_node = next(node for node in refs["nodes"] if (node["checkpoint"], node["id"]) == (view["checkpoint"], view["root"]))
                require(root_node["tree"] == tree)
                require(sum(edge["count"] for edge in included if edge["relation"] == "cycle_back") == tree["cycle_back_edges"])
                parents = {}
                for edge in included:
                    if edge["relation"] == "tree_child":
                        require(edge["target"] not in parents and edge["target"] != view["root"] and edge["count"] == 1)
                        parents[edge["target"]] = edge["source"]
                require(set(parents) == set(view["nodes"]) - {view["root"]})
                for edge in included:
                    if edge["relation"] == "cycle_back":
                        ancestors, current = set(), edge["source"]
                        while current is not None and current not in ancestors:
                            ancestors.add(current)
                            current = parents.get(current)
                        require(edge["target"] in ancestors)
            reached = {view["root"]}
            while True:
                found = {edge["source"] if view["kind"] == "trace" else edge["target"] for edge in included
                         if (edge["target"] if view["kind"] == "trace" else edge["source"]) in reached}
                if found <= reached: break
                reached |= found
            require(reached == set(view["nodes"]))
        else:
            require(view["root"] is None and view["target"] is None and not view["nodes"] and not view["edges"])
            if view["status"] == "not_leaked":
                require(view["kind"] == "tree" and candidate[view["checkpoint"] + "_tree"]["status"] == "not_leaked")
            if view["status"] == "not_present":
                require(view["kind"] == "trace" and view["checkpoint"] == "baseline" and candidate["baseline_presence"] == "absent")
    if refs["status"] in ("complete", "partial"):
        require(view_keys == {(index, checkpoint, kind) for index in range(len(value["nodes"]))
                              for checkpoint in ("baseline", "selected") for kind in ("tree", "trace")})
    if refs["status"] == "complete":
        require(bool(refs["views"]) and all(view["status"] in ("complete", "not_leaked", "not_present") for view in refs["views"]))
    if refs["status"] == "not_needed":
        require(not refs["views"] and not refs["nodes"] and not refs["edges"] and not value["nodes"])
    if value["status"] == "complete" and selection in ("first-new-leak", "first-strict-growth"):
        require(refs["status"] == "complete")

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


def compare(graph_directory, records, first_strict_growth=False, collector=None, bridge_context=None):
    result = initial_summary()
    deadline = time.monotonic() + SECONDS
    if bridge_context is not None:
        bridge_context.update(deadline=deadline, traces={}, baseline_heap=None, reference_ids={})
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
                or type(fixture) is not dict or fixture.get("mode") not in (("heap-control", "product") if first_strict_growth else ("heap-control",)) or fixture.get("scan_mode") != "diagnostic"
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
            result["checked_points"].append({"label": name, "leak_nodes": len(nodes), "leak_bytes": sum(nodes.values())})
            return nodes, kinds
        def parse_report(tool, name, report, nodes=None, target=None):
            try:
                parsed = parse_tree_graph(report, nodes) if tool == "tree" else parse_trace_graph(report, *target)
            except ValueError as error:
                if collector is not None:
                    point = result["baseline"] if name == "baseline" else result["selected"]
                    collector.record(tool, name, len(result["tools"]) - 1, point["graph_sha256"],
                                     report, error, nodes=nodes, target=target)
                raise
            # A candidate's original referrers are needed even when parsing
            # succeeds: a recognized graph alone drops allocation names/slots.
            if collector is not None and tool == "trace" and name == "baseline":
                collector.record(tool, name, len(result["tools"]) - 1, result["baseline"]["graph_sha256"],
                                 report, None, target=target)
            return parsed
        def tree_report(name, graph, nodes):
            report = tools.run("tree", name, ["/usr/bin/leaks", "--noContent", "--nosources", str(graph)], (0, 1))
            return parse_report("tree", name, report, nodes=nodes)
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
            growth = point["leak_nodes"] > result["baseline"]["leak_nodes"] or point["leak_bytes"] > result["baseline"]["leak_bytes"]
            if growth if first_strict_growth else changed:
                selected, diff_nodes = index, changed
                result.update(selection="first-strict-growth" if first_strict_growth else "first-new-leak", selected_label=label, selected=point)
                break
        if selected is None:
            if snapshot(0) != result["baseline"]:
                raise EvidenceError("graph_changed")
            if first_strict_growth:
                graph = attempt("tree_invalid", lambda: tree_report("baseline", before_graph, before[0]))
                result["baseline_roots"] = roots_overview(graph) if graph is not None else {"status": "unavailable", "roots": []}
                if result["baseline_roots"]["status"] == "budget_exceeded": reason("references_budget")
                if snapshot(0) != result["baseline"]: reason("graph_changed")
            result.update(status="complete", selection="no-strict-growth" if first_strict_growth else "no-new-leak")
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
        references = References(result, old.keys() | new.keys())
        result["references"]["status"] = "unavailable"
        for index in range(len(candidates)):
            for checkpoint in ("baseline", "selected"):
                for kind in ("tree", "trace"):
                    result["references"]["views"].append(reference_view(index, checkpoint, kind))
        for name, graph, nodes, field, checkpoint in (("baseline", before_graph, old, "baseline_tree", "baseline"),
                                                    (label, after_graph, new, "selected_tree", "selected")):
            parsed = attempt("tree_invalid", lambda: tree_report(name, graph, nodes))
            if checkpoint == "baseline":
                result["baseline_roots"] = roots_overview(parsed) if parsed is not None else {"status": "unavailable", "roots": []}
                if result["baseline_roots"]["status"] == "budget_exceeded": reason("references_budget")
            for index, (address, row) in enumerate(zip(candidates, result["nodes"])):
                view = references.view(index, checkpoint, "tree")
                if address not in nodes:
                    row[field] = empty_tree("not_leaked")
                    view["status"] = "not_leaked"
                elif parsed is not None:
                    row[field] = dict(parsed["roots"][parsed["members"][address]["root"]]["summary"])
                    attempt("references_invalid", lambda: references.add(tree_reference_graph(parsed, address), view))
        def heap(name, graph, diff=False):
            parsed = heap_allocations(tools.run("heap_diff" if diff else "heap", name,
                ["/usr/bin/heap", "--noContent", "--addresses", "all", *([f"--diffFrom={before_graph}"] if diff else []), str(graph)]))
            if parsed is None:
                raise ValueError("Incomplete heap inventory")
            return parsed
        baseline_heap = attempt("heap_unavailable", lambda: heap("baseline", before_graph))
        if bridge_context is not None:
            bridge_context.update(baseline_heap=baseline_heap, before_graph=before_graph,
                                  after_graph=after_graph, reference_ids=references.ids)
        changed_heap = attempt("heap_unavailable", lambda: heap(label, after_graph, True))
        address_args = [hex(address) for address in candidates]
        def history(name, graph):
            parsed = allocation_history(tools.run("history", name, ["/usr/bin/malloc_history", str(graph), *address_args]), candidates)
            if parsed is None:
                raise ValueError("Incomplete allocation history")
            return parsed
        before_history = attempt("history_unavailable", lambda: history("baseline", before_graph))
        after_history = attempt("history_unavailable", lambda: history(label, after_graph))
        for index, (address, row) in enumerate(zip(candidates, result["nodes"])):
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
                    report = attempt("trace_unavailable", lambda: tools.run("trace", name,
                        ["/usr/bin/leaks", "--noContent", "--nosources", f"--traceTree={hex(address)}", str(graph)]))
                    if report is not None:
                        row[field] = attempt("trace_unavailable", lambda: trace_roots(report, address, size))
                        view = references.view(index, "baseline" if name == "baseline" else "selected", "trace")
                        def add_trace():
                            parsed = parse_report("trace", name, report, target=(address, size))
                            references.add(parsed, view)
                            if bridge_context is not None and name == "baseline":
                                bridge_context["traces"][index] = parsed
                        attempt("references_invalid", add_trace)
                elif name == "baseline" and row["baseline_presence"] == "absent":
                    references.view(index, "baseline", "trace")["status"] = "not_present"
        if snapshot(0) != result["baseline"] or snapshot(selected) != result["selected"]:
            reason("graph_changed")
    except EvidenceError as error:
        reason(error.reason)
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        reason("input_invalid")
    finally:
        refs = result["references"]
        if refs["views"]:
            refs["status"] = "complete" if all(view["status"] in ("complete", "not_leaked", "not_present") for view in refs["views"]) else "partial"
            if refs["status"] != "complete" and not result["reasons"]: reason("references_invalid")
        if result["reasons"]:
            result["status"] = "partial" if result["comparison"] is not None or result["selection"] == "no-strict-growth" else "unavailable"
        elif result["selection"] is not None:
            result["status"] = "complete"
        bound_summary(result)
        if collector is not None:
            # Budgeting can remove a successfully parsed view. Do not let its
            # optional syntax invalidate the independently useful failure docs.
            baseline_tools = [index for index, tool in enumerate(result["tools"])
                              if (tool["tool"], tool["label"]) == ("trace", "baseline")]
            baseline_views = [view for view in result["references"]["views"]
                              if view["kind"] == "trace" and view["checkpoint"] == "baseline"
                              and view["status"] != "not_present"]
            complete = {index for index, view in zip(baseline_tools, baseline_views) if view["status"] == "complete"}
            documents = collector.value["documents"]
            kept = [doc for doc in documents if doc["error"] != "none" or doc["tool_index"] in complete]
            if len(kept) != len(documents):
                collector.value["omitted_documents"] += len(documents) - len(kept)
                collector.value.update(status="truncated", documents=kept)
    return result



def prune_references(result):
    refs = result["references"]
    used_edges = sorted({index for view in refs["views"] for index in view["edges"]})
    renumber = {index: new for new, index in enumerate(used_edges)}
    refs["edges"] = [refs["edges"][index] for index in used_edges]
    for view in refs["views"]:
        view["edges"] = [renumber[index] for index in view["edges"]]
    used_nodes = {(view["checkpoint"], ident) for view in refs["views"] for ident in view["nodes"]}
    refs["nodes"] = [node for node in refs["nodes"] if (node["checkpoint"], node["id"]) in used_nodes]


def bound_summary(result):
    """Keep complete selected-cycle views before larger reverse paths."""
    while len(encode_summary(result)) > PUBLIC_LIMIT:
        refs = result["references"]
        disposable = [view for view in refs["views"] if view["status"] == "complete" and view["kind"] == "trace"]
        if not disposable:
            disposable = [view for view in refs["views"] if view["status"] == "complete" and view["checkpoint"] == "baseline"]
        if disposable:
            view = max(disposable, key=lambda item: len(item["nodes"]) + len(item["edges"]))
            view.update(status="budget_exceeded", root=None, target=None, nodes=[], edges=[])
            prune_references(result)
            refs["status"] = "partial"
        elif result["nodes"]:
            result["nodes"].pop()
            result["omitted_candidates"] += 1
            refs["views"] = [view for view in refs["views"] if view["candidate"] < len(result["nodes"])]
            prune_references(result)
            refs["status"] = "partial"
        elif result["baseline_roots"]["roots"]:
            result["baseline_roots"] = {"status": "budget_exceeded", "roots": []}
        else:
            break
        result["status"] = "partial"
        if "summary_budget" not in result["reasons"]:
            result["reasons"].append("summary_budget")

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graph-directory", type=Path, required=True)
    parser.add_argument("--records-directory", type=Path, required=True)
    parser.add_argument("--first-strict-growth", action="store_true")
    parser.add_argument("--bridge-evidence", action="store_true")
    args = parser.parse_args(argv)
    collector = Collector()
    bridge_context = {} if args.bridge_evidence else None
    result = compare(args.graph_directory, args.records_directory, first_strict_growth=args.first_strict_growth,
                     collector=collector, bridge_context=bridge_context)
    bound_summary(result)
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
    try:
        validate_evidence(collector.value)
        target = args.records_directory / "parser-evidence.json"
        if target.is_symlink():
            raise ValueError("Invalid output file")
        target.write_bytes(encode_evidence(collector.value))
    except (OSError, ValueError, TypeError, RecursionError):
        print("Parser evidence unavailable")
        return 1
    bridge_written = True
    if args.bridge_evidence:
        bridge_written = write_bridge_evidence(result, bridge_context, args.records_directory)
    print("Frozen-node summary " + result["status"])
    return 0 if result["status"] == "complete" and bridge_written else 1


def write_bridge_evidence(frozen, context, records):
    """Supplement the final frozen summary without replacing its evidence."""
    import ax_bridge_evidence as bridge
    result = bridge.initial_summary(frozen)
    try:
        tools = Tools(records / "bridge-private", {"tools": [], "process_cleanup_confirmed": True}, context["deadline"])
        graphs = [(context.get("before_graph"), frozen["baseline"]),
                  (context.get("after_graph"), frozen["selected"])]
        def unchanged():
            return all(path is None or point is not None and graph_hash(path) == point["graph_sha256"]
                       for path, point in graphs)
        if not unchanged():
            bridge.fail_closed(result, "graph_changed")
        else:
            result = bridge.collect(frozen=frozen, traces=context["traces"], baseline_heap=context["baseline_heap"],
                before_graph=context.get("before_graph"), after_graph=context.get("after_graph"),
                tools=tools, reference_ids=context["reference_ids"])
            if not unchanged():
                bridge.fail_closed(result, "graph_changed")
        payload = bridge.encode_summary(result, frozen)
        target = records / "bridge-evidence.json"
        if target.is_symlink():
            raise ValueError("Invalid output file")
        target.write_bytes(payload)
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        print("Bridge evidence unavailable")
        return False
    print("Bridge evidence " + result["status"])
    # The workflow validates and gates the bridge verdict independently. Its
    # partial result must not change the successfully collected frozen verdict.
    return True


if __name__ == "__main__":
    raise SystemExit(main())
