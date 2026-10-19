"""Bounded reported type compositions; net counts do not identify allocations."""
from collections import Counter
import json
import re

import ax_frozen_nodes as frozen
import ax_parser_evidence as parser_evidence

NODE_LIMIT = 512
BUCKET_LIMIT = 128
PUBLIC_LIMIT = 8192
FRAGMENT_LIMIT = 4096
RAW_LIMIT = 16 * 1024 * 1024
TYPES = frozen.REFERENCE_TYPES
REASONS = ("not_available", "invalid_report", "node_budget", "bucket_budget", "summary_budget",
           "unknown_type", "size_unresolved")
# Keep legacy schema-3 "header" receipts readable. New failures identify the
# rejected structural check using fixed literals, never private report text.
FAILURE_STAGES = ("header", "report_header", "report_prefix", "stack_header", "stack_prefix",
                  "stack_separator", "stack_frame", "stack_order", "stack_duplicate", "stack_name",
                  "root_header", "tree_shape", "child_marker", "backref", "byte_bounds", "totals", "budget")


class _GroupedError(ValueError):
    def __init__(self, stage):
        super().__init__("Invalid grouped composition")
        self.stage = stage


def encoded(value):
    return json.dumps(value, separators=(",", ":")).encode()


def require(condition, stage=None):
    if not condition:
        if stage is not None:
            raise _GroupedError(stage)
        raise ValueError("Invalid bounded composition")


def integer(value):
    return type(value) is int and 0 <= value <= 1_000_000_000


def empty_histogram(reason="not_available"):
    require(reason in ("not_available", "summary_budget"))
    return {"schema": 1, "status": "unavailable", "total_nodes": None, "total_bytes": None,
            "buckets": [], "unknown_type_nodes": 0, "omitted_nodes": 0, "omitted_bytes": 0,
            "omitted_buckets": 0, "reasons": [reason]}


def histogram_nodes(nodes):
    """Accept already decoded nodes; only allowlisted types and exact sizes escape."""
    require(type(nodes) is list and len(nodes) <= 100000)
    counts = Counter()
    for node in nodes:
        require(type(node) is dict and integer(node.get("size")) and node["size"] > 0)
        counts[(node.get("type") if node.get("type") in TYPES else "unknown", node["size"])] += 1
    total_bytes = sum(size * count for (_, size), count in counts.items())
    require(integer(total_bytes))
    rows = sorted(counts.items())
    kept = rows[:BUCKET_LIMIT] if len(nodes) <= NODE_LIMIT else []
    omitted = rows[len(kept):]
    unknown = sum(count for (kind, _), count in counts.items() if kind == "unknown")
    reasons = (["node_budget"] if len(nodes) > NODE_LIMIT else []) + (["bucket_budget"] if len(rows) > BUCKET_LIMIT else [])
    if unknown: reasons.append("unknown_type")
    value = {"schema": 1, "status": "partial" if reasons else "complete", "total_nodes": len(nodes),
        "total_bytes": total_bytes, "buckets": [{"type": kind, "size": size, "count": count} for (kind, size), count in kept],
        "unknown_type_nodes": unknown, "omitted_nodes": sum(count for _, count in omitted),
        "omitted_bytes": sum(size * count for (_, size), count in omitted), "omitted_buckets": len(omitted), "reasons": reasons}
    while len(encoded(value)) > PUBLIC_LIMIT and value["buckets"]:
        row = value["buckets"].pop()
        value["omitted_nodes"] += row["count"]
        value["omitted_bytes"] += row["size"] * row["count"]
        value["omitted_buckets"] += 1
        value["status"] = "partial"
        if "summary_budget" not in reasons: reasons.append("summary_budget")
    validate_histogram(value)
    return value


def validate_histogram(value):
    require(type(value) is dict and set(value) == set(empty_histogram()))
    require(type(value["schema"]) is int and value["schema"] == 1)
    require(value["status"] in ("complete", "partial", "unavailable"))
    require(type(value["reasons"]) is list and len(value["reasons"]) == len(set(value["reasons"])) and all(r in REASONS for r in value["reasons"]))
    if value["status"] == "unavailable":
        require(len(value["reasons"]) == 1 and value == empty_histogram(value["reasons"][0]))
        return
    require(all(integer(value[key]) for key in ("total_nodes", "total_bytes", "unknown_type_nodes", "omitted_nodes", "omitted_bytes", "omitted_buckets")))
    buckets(value["buckets"])
    require(sum(row["count"] for row in value["buckets"]) + value["omitted_nodes"] == value["total_nodes"])
    require(sum(row["size"] * row["count"] for row in value["buckets"]) + value["omitted_bytes"] == value["total_bytes"])
    require(value["omitted_buckets"] <= value["omitted_nodes"] and (value["omitted_nodes"] == 0) == (value["omitted_bytes"] == 0))
    shown_unknown = sum(row["count"] for row in value["buckets"] if row["type"] == "unknown")
    require(shown_unknown <= value["unknown_type_nodes"] <= shown_unknown + value["omitted_nodes"])
    require(sum(row["count"] for row in value["buckets"]) <= NODE_LIMIT)
    require((value["status"] == "complete") == (not value["reasons"]))
    if value["unknown_type_nodes"]: require("unknown_type" in value["reasons"])
    if value["omitted_nodes"]: require(any(reason in value["reasons"] for reason in ("node_budget", "bucket_budget", "summary_budget")))
    require(len(encoded(value)) <= PUBLIC_LIMIT)


def buckets(rows):
    require(type(rows) is list and len(rows) <= BUCKET_LIMIT)
    keys = []
    for row in rows:
        require(type(row) is dict and set(row) == {"type", "size", "count"})
        require(row["type"] in TYPES and integer(row["size"]) and row["size"] > 0 and integer(row["count"]) and row["count"] > 0)
        keys.append((row["type"], row["size"]))
    require(keys == sorted(set(keys)))


def empty_grouped(reason="not_available", totals=None, failure_stage=None):
    require(reason in ("not_available", "invalid_report", "node_budget", "summary_budget"))
    if reason == "node_budget": failure_stage = "budget"
    require(failure_stage in FAILURE_STAGES if reason == "invalid_report" else
            failure_stage == ("budget" if reason == "node_budget" else None))
    return {"schema": 3, "status": "unavailable", "counts_status": "unavailable",
            "size_bounds": "combined-self-bytes", "failure_stage": failure_stage, "failure_fragment": None,
            "total_nodes": totals[0] if totals else None, "total_bytes": totals[1] if totals else None,
            "type_counts": [], "exact_size_histogram": [], "size_unknown_nodes": 0, "unresolved_sizes": [],
            "unknown_type_nodes": 0, "omitted_nodes": totals[0] if totals else 0, "reasons": [reason]}


def _failure_fragment(lines):
    """Reuse the reviewed lexical codec; discard an incomplete/oversized fragment."""
    if not 1 <= len(lines) <= 3 or any(len(line) > parser_evidence.LINE_LENGTH_LIMIT for line in lines):
        return None
    try:
        collector = parser_evidence.Collector()
        # Required codec metadata is synthetic: no checkpoint or graph is bound.
        collector.record("tree", "baseline", 0, "0" * 64, "\n".join(lines), ValueError("Unsupported tree row"))
        value = {"kind": "diagnostic-only", "equivalence": "non-equivalent-fragment",
                 "codec_context": "synthetic-placeholders", "offender_index": len(lines) - 1,
                 "evidence": collector.value}
        _validate_failure_fragment(value)
        return value
    except (ValueError, TypeError, KeyError, RecursionError, OverflowError):
        return None


def _validate_failure_fragment(value):
    require(type(value) is dict and set(value) == {"kind", "equivalence", "codec_context", "offender_index", "evidence"})
    require(value["kind"] == "diagnostic-only" and value["equivalence"] == "non-equivalent-fragment"
            and value["codec_context"] == "synthetic-placeholders")
    require(len(encoded(value)) <= FRAGMENT_LIMIT)
    evidence = parser_evidence.validate_evidence(value["evidence"])
    require(evidence["status"] == "complete" and evidence["omitted_documents"] == 0 and len(evidence["documents"]) == 1)
    doc = evidence["documents"][0]
    require(doc["tool"] == "tree" and doc["label"] == "baseline" and doc["tool_index"] == 0
            and doc["graph_sha256"] == "0" * 64 and doc["error"] == "unsupported_tree_row"
            and doc["status"] == "complete" and doc["nodes"] == [] and doc["target"] is None)
    require(1 <= len(doc["lines"]) <= 3 and type(value["offender_index"]) is int
            and value["offender_index"] == len(doc["lines"]) - 1)


def _name(text, stage=None):
    if text.startswith("<") and text.endswith(">"):
        text = text[1:-1]
    require(0 < len(text) <= 256 and text == text.strip() and text.isprintable(), stage)
    require(not re.search(r"0x[0-9a-fA-F]+", text) and "-->" not in text, stage)
    # Observed grouped origin labels include an Objective-C allocation site.
    # This private description is not an object type; publication still uses TYPES.
    origin = re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]* in [+-]\[[A-Za-z_][A-Za-z_0-9]* "
                          r"(?:[A-Za-z_][A-Za-z_0-9]*:)+\]", text)
    require(origin is not None or not re.search(r"[<>\[\]:|]", text), stage)
    return text


def _byte_range(text, count, total):
    exact = re.fullmatch(r"(\d{1,10}) bytes?", text)
    if exact:
        size = int(exact[1])
        require(count <= size <= total, "byte_bounds")
        return size, size
    # The rounding/scale convention is not proven by a grouped label. Retain a
    # conservative interval bounded by the whole-report exact byte total.
    require(re.fullmatch(r"\d{1,10}(?:\.\d{1,4})?[KMGT](?:B)?", text) is not None, "byte_bounds")
    return count, total


def _group_tree(lines, instances, marker, header_name, total_bytes, failure_context):
    """Return own-byte bounds, roots with feasible subtree bounds, and group bounds."""
    stack, output, roots = [], [], []
    total_row = None
    separated = any(re.fullmatch(r" +----", line) for line in lines)
    separator_pending = False

    def close():
        row = stack.pop()
        own = row["count"] - sum(child["count"] for child in row["children"])
        require(own == 0 if row["name"] is None else own > 0, "totals")
        child_low = sum(child["bytes"][0] for child in row["children"])
        child_high = sum(child["bytes"][1] for child in row["children"])
        # Closed children carry feasible subtree intervals, not just their
        # displayed ranges. Every allocated instance needs at least one byte;
        # TOTAL contributes none and must also respect the children's maximum.
        low = max(row["bytes"][0], child_low + own)
        high = min(row["bytes"][1], child_high) if row["name"] is None else row["bytes"][1]
        require(low <= high, "byte_bounds")
        row["bytes"] = (low, high)
        if row["name"] is not None:
            output.append((row["name"] if row["name"] in TYPES else "unknown", own,
                           max(own, low - child_high), high - child_low))
            row["own"] = own

    for line in lines:
        if not line.strip(): continue
        # These private strings never leave through a public field. Only the
        # bounded reviewed codec may publish the current line and two ancestors.
        failure_context[:] = [row["line"] for row in stack[-2:]] + [line]
        if re.fullmatch(r" +----", line):
            require(total_row is not None and not separator_pending and len(line) - 4 == total_row["indent"] + 2)
            while len(stack) > 1: close()
            separator_pending = True
            continue
        match = re.fullmatch(r"( *)(?:(\d{1,6}) \(([^()]+)\) )?(.+)", line)
        require(match is not None)
        indent, count, byte_text, text = len(match[1]), match[2], match[3], match[4]
        while stack and indent <= stack[-1]["indent"]: close()
        if count is not None:
            failure_context[:] = [row["line"] for row in stack[-2:]] + [line]
        if " --> " in text:
            edge, text = text.split(" --> ", 1)
            # Grouped reports can compose storage offsets ("storage + 8 + 8").
            # This reference annotation contributes no nodes or bytes.
            require(re.fullmatch(frozen.EDGE_NAME + r"(?: \+ [0-9]{1,10})*", edge) is not None)
        if text.startswith("CYCLE BACK TO "):
            require(count is None and stack and indent == stack[-1]["indent"] + 3, "backref")
            target = _name(text[len("CYCLE BACK TO "):], "backref")
            require(any(row["name"] == target for row in stack), "backref")
            continue  # Back references are not additional allocated nodes.
        require(count is not None and 0 < int(count) <= NODE_LIMIT)
        row_marker = None
        for candidate in ("ROOT LEAK", "ROOT CYCLE"):
            if text.startswith(candidate + ": "):
                row_marker, text = candidate, text[len(candidate) + 2:]
                break
        aggregate = text == "<< TOTAL >>"
        name = None if aggregate else _name(text)
        if aggregate:
            require(total_row is None and not stack and not roots and row_marker is None)
        elif not stack or stack[-1]["name"] is None:
            require(row_marker is not None and (marker is None or (row_marker, name) == (marker, header_name)), "root_header")
            if total_row is not None:
                require(indent == total_row["indent"] + 2 and (not separated or separator_pending))
            separator_pending = False
        else:
            # leaks repeats ROOT CYCLE on members within an existing cycle.
            # Indentation still determines ancestry; the marker adds no root.
            require(row_marker in (None, "ROOT CYCLE"), "child_marker")
            require(indent == stack[-1]["indent"] + 3)
        row = {"indent": indent, "name": name, "count": int(count), "bytes": _byte_range(byte_text, int(count), total_bytes), "children": [], "line": line}
        if stack:
            stack[-1]["children"].append(row)
        if aggregate: total_row = row
        elif not stack or stack[-1]["name"] is None: roots.append(row)
        stack.append(row)
    require(not separator_pending)
    while stack: close()
    require(roots and (instances is None or sum(root["own"] for root in roots) == instances), "totals")
    if total_row is not None:
        require(total_row["count"] == sum(root["count"] for root in roots), "totals")
    group_bytes = total_row["bytes"] if total_row is not None else (
        sum(root["bytes"][0] for root in roots), sum(root["bytes"][1] for root in roots))
    failure_context.clear()
    return output, roots, group_bytes


def grouped_composition(report):
    """Decode full grouped trees; subtract direct child subtrees before counting."""
    totals = None
    stage = "report_header"
    failure_context = []
    try:
        require(type(report) is str)
        stage = "budget"
        require(len(report.encode()) <= RAW_LIMIT)
        stage = "totals"
        totals = frozen.totals(report)
        if totals[0] > NODE_LIMIT: return empty_grouped("node_budget", totals)
        stage = "report_header"
        body = report.split("Binary Images:", 1)[0]
        total = re.search(r"^Process \d+: \d+ leaks? for \d+ total leaked bytes\.$", body, re.M)
        require(total is not None)
        prefix, body = body[:total.start()], body[total.end():]
        stage = "report_prefix"
        require("STACK OF " not in prefix and "====" not in prefix)
        stage = "stack_header"
        headers = list(re.finditer(r"^STACK OF (\d{1,6}) INSTANCES? OF '(ROOT LEAK|ROOT CYCLE): ([^\n']+)':$", body, re.M))
        require(len(headers) == len(re.findall(r"^STACK OF ", body, re.M)))
        rows, roots, byte_ranges, seen = [], [], [], set()
        if headers:
            stage = "stack_prefix"
            require(not body[:headers[0].start()].strip())
            for index, header in enumerate(headers):
                stage = "stack_separator"
                block = body[header.end():headers[index + 1].start() if index + 1 < len(headers) else len(body)]
                require(block.count("\n====\n") == 1)
                frames, tree = block.split("\n====\n")
                # Stacks are checked structurally and discarded, never published.
                stage = "stack_frame"
                frame_rows = [line.strip() for line in frames.splitlines() if line.strip()]
                require(all(line.replace("\t", " ").isprintable() and re.fullmatch(r"\d{1,3}\s+\S+\s+0x[0-9a-fA-F]{1,16}\s+[^\r\n]+ \+ \d{1,10}", line) for line in frame_rows))
                indices = [int(line.split()[0]) for line in frame_rows]
                stage = "stack_order"
                require(len(set(indices)) == len(indices) and indices in (sorted(indices), sorted(indices, reverse=True)))
                stage = "stack_duplicate"
                key = (header[0], tuple(frame_rows), tuple(line for line in tree.splitlines() if line.strip()))
                require(key not in seen); seen.add(key)
                stage = "stack_name"
                header_name = _name(header[3])
                stage = "tree_shape"
                group, group_roots, group_bytes = _group_tree(tree.splitlines(), int(header[1]), header[2], header_name, totals[1], failure_context)
                rows.extend(group); roots.extend(group_roots)
                byte_ranges.append(group_bytes)
        elif body.strip():
            stage = "tree_shape"
            lines = [line for line in body.splitlines() if line.strip()]
            require(re.fullmatch(r" *\d+ \([^)]+\) << TOTAL >>", lines[0]) is not None)
            rows, roots, group_bytes = _group_tree(lines, None, None, None, totals[1], failure_context)
            byte_ranges.append(group_bytes)
        else:
            require(totals == (0, 0), "totals")
        stage = "totals"
        require(sum(root["count"] for root in roots) == totals[0])
        require(sum(low for low, _ in byte_ranges) <= totals[1] <= sum(high for _, high in byte_ranges))
        require(sum(count for _, count, _, _ in rows) == totals[0])
        types, exact, unresolved = Counter(), Counter(), []
        for kind, count, low, high in rows:
            types[kind] += count
            if count == 1 and low == high:
                exact[(kind, low)] += 1
            else:
                unresolved.append({"type": kind, "count": count, "bytes_min": low, "bytes_max": high,
                                   "reason": "multiple_instances" if count > 1 else "rounded_subtree"})
        exact_rows = [{"type": kind, "size": size, "count": count} for (kind, size), count in sorted(exact.items())]
        kept_exact, kept_unresolved = exact_rows[:BUCKET_LIMIT], unresolved[:BUCKET_LIMIT]
        omitted = sum(row["count"] for row in exact_rows[BUCKET_LIMIT:]) + sum(row["count"] for row in unresolved[BUCKET_LIMIT:])
        unknown_sizes = sum(row["count"] for row in kept_unresolved)
        reasons = (["unknown_type"] if types["unknown"] else []) + (["size_unresolved"] if unresolved else []) + (["bucket_budget"] if omitted else [])
        value = {"schema": 3, "status": "partial" if reasons else "complete", "counts_status": "complete",
            "size_bounds": "combined-self-bytes", "failure_stage": None, "failure_fragment": None,
            "total_nodes": totals[0], "total_bytes": totals[1], "type_counts": [{"type": kind, "count": count} for kind, count in sorted(types.items()) if count],
            "exact_size_histogram": kept_exact, "size_unknown_nodes": unknown_sizes, "unresolved_sizes": kept_unresolved,
            "unknown_type_nodes": types["unknown"], "omitted_nodes": omitted, "reasons": reasons}
        if len(encoded(value)) > PUBLIC_LIMIT:
            value.update(status="partial", exact_size_histogram=[], size_unknown_nodes=0, unresolved_sizes=[], omitted_nodes=totals[0])
            value["reasons"].append("summary_budget")
        validate_grouped_composition(value)
        return value
    except (ValueError, TypeError, KeyError, RecursionError, OverflowError) as exc:
        value = empty_grouped("invalid_report", totals, exc.stage if isinstance(exc, _GroupedError) else stage)
        if value["failure_stage"] == "tree_shape":
            value["failure_fragment"] = _failure_fragment(failure_context)
        return value


def validate_grouped_composition(value):
    require(type(value) is dict and set(value) == set(empty_grouped()))
    require(type(value["schema"]) is int and value["schema"] == 3 and value["status"] in ("complete", "partial", "unavailable"))
    require(value["counts_status"] in ("complete", "unavailable"))
    require(value["size_bounds"] == "combined-self-bytes")
    require(type(value["reasons"]) is list and len(value["reasons"]) == len(set(value["reasons"])) and all(r in REASONS for r in value["reasons"]))
    if value["failure_fragment"] is not None:
        require(value["status"] == value["counts_status"] == "unavailable"
                and value["reasons"] == ["invalid_report"] and value["failure_stage"] == "tree_shape")
        _validate_failure_fragment(value["failure_fragment"])
    require(len(encoded(value)) <= PUBLIC_LIMIT)
    if value["counts_status"] == "unavailable":
        totals = (value["total_nodes"], value["total_bytes"]) if value["total_nodes"] is not None else None
        require(totals is None and value["total_bytes"] is None or totals is not None and all(integer(n) for n in totals))
        expected = empty_grouped(value["reasons"][0], totals, value["failure_stage"]) if len(value["reasons"]) == 1 else None
        if expected is not None: expected["failure_fragment"] = value["failure_fragment"]
        require(value == expected)
        return
    require(value["status"] in ("complete", "partial"))
    require(value["failure_stage"] is None)
    require(integer(value["total_nodes"]) and value["total_nodes"] <= NODE_LIMIT and integer(value["total_bytes"]))
    require(type(value["type_counts"]) is list and len(value["type_counts"]) <= len(TYPES))
    names = []
    for row in value["type_counts"]:
        require(type(row) is dict and set(row) == {"type", "count"} and row["type"] in TYPES and integer(row["count"]) and row["count"] > 0)
        names.append(row["type"])
    require(names == sorted(set(names)) and sum(row["count"] for row in value["type_counts"]) == value["total_nodes"])
    buckets(value["exact_size_histogram"])
    require(type(value["unresolved_sizes"]) is list and len(value["unresolved_sizes"]) <= BUCKET_LIMIT)
    for row in value["unresolved_sizes"]:
        require(type(row) is dict and set(row) == {"type", "count", "bytes_min", "bytes_max", "reason"})
        require(row["type"] in TYPES and all(integer(row[key]) for key in ("count", "bytes_min", "bytes_max")))
        require(0 < row["count"] <= row["bytes_min"] <= row["bytes_max"] <= value["total_bytes"])
        require(row["reason"] == ("multiple_instances" if row["count"] > 1 else "rounded_subtree"))
    require(all(integer(value[key]) for key in ("omitted_nodes", "size_unknown_nodes", "unknown_type_nodes")))
    require(value["size_unknown_nodes"] == sum(row["count"] for row in value["unresolved_sizes"]))
    require(sum(row["count"] for row in value["exact_size_histogram"]) + value["size_unknown_nodes"] + value["omitted_nodes"] == value["total_nodes"])
    for row in value["type_counts"]:
        known = sum(item["count"] for item in value["exact_size_histogram"] + value["unresolved_sizes"] if item["type"] == row["type"])
        require(known <= row["count"] <= known + value["omitted_nodes"])
    require(all(row["type"] in names for row in value["exact_size_histogram"] + value["unresolved_sizes"]))
    require(value["unknown_type_nodes"] == sum(row["count"] for row in value["type_counts"] if row["type"] == "unknown"))
    exact_bytes = sum(row["size"] * row["count"] for row in value["exact_size_histogram"])
    require(exact_bytes + sum(row["bytes_min"] for row in value["unresolved_sizes"]) + value["omitted_nodes"] <= value["total_bytes"])
    if not value["omitted_nodes"]:
        require(value["total_bytes"] <= exact_bytes + sum(row["bytes_max"] for row in value["unresolved_sizes"]))
    require((value["status"] == "complete") == (not value["reasons"]))
    if value["unknown_type_nodes"]: require("unknown_type" in value["reasons"])
    if value["size_unknown_nodes"]: require("size_unresolved" in value["reasons"])
    if value["omitted_nodes"]: require(any(r in value["reasons"] for r in ("bucket_budget", "summary_budget")))
    require(len(encoded(value)) <= PUBLIC_LIMIT)


def histogram_snapshot(list_report, tree_report):
    value = {"schema": 1, "status": "unavailable", "leak_nodes": None, "leak_bytes": None,
             "root_count": None, "histogram": empty_histogram(), "reasons": ["invalid_report"]}
    try:
        require(all(type(report) is str and len(report.encode()) <= RAW_LIMIT for report in (list_report, tree_report)))
        nodes, _ = frozen.parse_list(list_report)
        tree = frozen.parse_tree_graph(tree_report, nodes)
        histogram = histogram_nodes([{"type": row["kind"], "size": row["size"]} for row in tree["members"].values()])
        value.update(status=histogram["status"], leak_nodes=len(nodes), leak_bytes=sum(nodes.values()),
                     root_count=len(tree["roots"]), histogram=histogram, reasons=list(histogram["reasons"]))
    except (ValueError, TypeError, KeyError, RecursionError, OverflowError):
        pass
    validate_snapshot(value)
    return value


def validate_snapshot(value):
    require(type(value) is dict and set(value) == {"schema", "status", "leak_nodes", "leak_bytes", "root_count", "histogram", "reasons"})
    require(type(value["schema"]) is int and value["schema"] == 1)
    validate_histogram(value["histogram"])
    require(value["status"] == value["histogram"]["status"])
    if value["status"] == "unavailable":
        require(all(value[key] is None for key in ("leak_nodes", "leak_bytes", "root_count")) and value["reasons"] == ["invalid_report"])
    else:
        require(integer(value["leak_nodes"]) and integer(value["leak_bytes"]))
        require(value["leak_nodes"] == value["histogram"]["total_nodes"] and value["leak_bytes"] == value["histogram"]["total_bytes"])
        require(integer(value["root_count"]) and value["root_count"] <= value["leak_nodes"] and value["reasons"] == value["histogram"]["reasons"])


def composition_delta(before, after):
    validate_grouped_composition(before); validate_grouped_composition(after)
    value = {"schema": 1, "status": "unavailable", "semantics": "reported-type-net-count", "generation": "unknown",
             "baseline_total_nodes": None, "selected_total_nodes": None, "net_nodes": None, "changes": []}
    if before["counts_status"] == after["counts_status"] == "complete":
        old, new = ({row["type"]: row["count"] for row in value["type_counts"]} for value in (before, after))
        value.update(status="complete", baseline_total_nodes=before["total_nodes"], selected_total_nodes=after["total_nodes"],
            net_nodes=after["total_nodes"] - before["total_nodes"],
            changes=[{"type": kind, "count_delta": new.get(kind, 0) - old.get(kind, 0)} for kind in sorted(old.keys() | new.keys()) if new.get(kind, 0) != old.get(kind, 0)])
    return value


def validate_composition_delta(value, before, after):
    expected = composition_delta(before, after)
    require(type(value) is dict and set(value) == set(expected) and type(value["schema"]) is int)
    for key in ("baseline_total_nodes", "selected_total_nodes"):
        require(value[key] is None or integer(value[key]))
    require(value["net_nodes"] is None or type(value["net_nodes"]) is int and -NODE_LIMIT <= value["net_nodes"] <= NODE_LIMIT)
    require(type(value["changes"]) is list and len(value["changes"]) <= len(TYPES))
    for row in value["changes"]:
        require(type(row) is dict and set(row) == {"type", "count_delta"} and row["type"] in TYPES)
        require(type(row["count_delta"]) is int and -NODE_LIMIT <= row["count_delta"] <= NODE_LIMIT and row["count_delta"] != 0)
    require(value == expected)
