#!/usr/bin/env python3
"""Join one explicitly associated creation trace and native visible-selection evidence.

The collector must establish traceID/pid from the same controlled input and output,
not select a trace just because it is closest in time. Raw inputs stay local.
"""
import argparse
import json
from pathlib import Path
import uuid


def uint64(value):
    return type(value) is int and 0 <= value <= 2**64 - 1


def valid_pid(value):
    return type(value) is int and 1 <= value <= 2**31 - 1


def valid_session_id(value):
    try:
        return type(value) is str and str(uuid.UUID(value)) == value.lower()
    except (ValueError, AttributeError):
        return False


def validate_delivery(reports, receipts, source):
    """A sealed receipt certifies this JSON session, not an entire process/run."""
    if any(not valid_pid(report.get("pid")) for report in reports):
        raise ValueError("Report PID must be a positive Int32")
    if source == "signpost-export":
        if any("delivery" in report for report in reports):
            raise ValueError("JSON delivery metadata cannot be validated as signpost evidence")
        return []
    if source != "json":
        raise ValueError("Unknown evidence source")
    by_id = {}
    for receipt in receipts:
        session_id = receipt.get("sessionID")
        counters = [receipt.get(key) for key in
                    ("acceptedReports", "writtenReports", "droppedReports", "failedReports")]
        if (not valid_session_id(session_id) or session_id in by_id
                or type(receipt.get("schemaVersion")) is not int or receipt["schemaVersion"] != 1
                or not valid_pid(receipt.get("pid"))
                or receipt.get("closed") is not True
                or any(not uint64(value) for value in counters)
                or counters[0] != counters[1] or counters[2:] != [0, 0]):
            raise ValueError("JSON session receipt is unclosed, malformed or records lost reports")
        by_id[session_id] = receipt
    seen = set()
    for report in reports:
        delivery = report.get("delivery", {})
        if not isinstance(delivery, dict):
            raise ValueError("Malformed JSON delivery metadata")
        session_id, sequence = delivery.get("sessionID"), delivery.get("sequence")
        if not valid_session_id(session_id):
            raise ValueError("Missing or malformed JSON session identity")
        receipt = by_id.get(session_id)
        if (receipt is None or not uint64(sequence) or not 1 <= sequence <= receipt["acceptedReports"]
                or receipt["pid"] != report["pid"]
                or (session_id, sequence) in seen):
            raise ValueError("JSON report lacks a matching closed-session receipt or unique sequence")
        seen.add((session_id, sequence))
    return sorted({session_id for session_id, _ in seen})


def validate_successful_authorization(events):
    """Parse actual grant attempts; return the successful scope's stop index.

    Bookmark failures, revision changes and rejected scopes can fall back.
    Table/revision read failures and terminal authorization results cannot.
    Keep original indices so filtering cannot move writer work outside its scope.
    """
    phases = [(index, event["phase"]) for index, event in enumerate(events)
              if event["phase"].startswith("authorization.")]
    cursor = 0

    def consume(phase):
        nonlocal cursor
        if cursor >= len(phases) or phases[cursor][1] != phase:
            raise ValueError("Successful authorization is incomplete, contradictory or out of order")
        cursor += 1

    def span(prefix, results):
        nonlocal cursor
        consume(prefix + ".begin")
        if cursor >= len(phases) or phases[cursor][1] not in [prefix + "." + result for result in results]:
            raise ValueError("Successful authorization has a failed or invalid " + prefix + " result")
        result = phases[cursor][1].removeprefix(prefix + ".")
        cursor += 1
        consume(prefix + ".end")
        return result

    consume("authorization.begin")
    span("authorization.table", ["loaded"])
    available_candidates = 0
    while cursor < len(phases):
        if phases[cursor][1] == "authorization.bookmark.begin":
            if span("authorization.bookmark", ["resolved", "failed"]) == "resolved":
                available_candidates += 1
            continue
        if available_candidates == 0:
            raise ValueError("Authorization attempt has no unattempted resolved grant")
        available_candidates -= 1
        if span("authorization.revision.before-scope", ["current", "changed"]) == "changed":
            continue
        consume("authorization.scope.begin")
        if cursor < len(phases) and phases[cursor][1] == "authorization.scope.rejected":
            consume("authorization.scope.rejected")
            continue
        consume("authorization.scope.started")
        if span("authorization.revision.after-scope", ["current", "changed"]) == "changed":
            consume("authorization.scope.stopped")
            continue
        consume("authorization.admitted")
        scope_stop_index = phases[cursor][0] if cursor < len(phases) else -1
        consume("authorization.scope.stopped")
        consume("authorization.end")
        if cursor != len(phases):
            raise ValueError("Authorization has phases after its successful end")
        return scope_stop_index
    raise ValueError("Authorization never admitted a successful scoped operation")


def assemble(trace, observation, menu, preparation, *, receipts=(), source="json"):
    def validate_lifecycle(report):
        events = report["events"]
        phases = [event["phase"] for event in events]
        if (not phases or phases[0] != "begin" or phases[-1] != "end"
                or phases.count("begin") != 1 or phases.count("end") != 1
                or not uint64(report["droppedEvents"]) or report["droppedEvents"] != 0
                or any(not uint64(event["uptimeNS"]) for event in events)
                or any(a["uptimeNS"] > b["uptimeNS"] for a, b in zip(events, events[1:]))):
            raise ValueError("Trace lifecycle or timestamp order is invalid")

    def ordered_points(report, required, label):
        points, indices = {}, []
        for phase in required:
            matches = [(index, event["uptimeNS"]) for index, event in enumerate(report["events"])
                       if event["phase"] == phase]
            if len(matches) != 1:
                raise ValueError("Missing or ambiguous " + label + " phase: " + phase)
            index, timestamp = matches[0]
            indices.append(index)
            points[phase] = timestamp
        # Equal timestamps are legal, but never substitute for event causality.
        if indices != sorted(indices):
            raise ValueError(label + " phases are out of order")
        return points

    session_ids = validate_delivery((trace, menu, preparation), receipts, source)
    for report in (trace, menu, preparation):
        validate_lifecycle(report)
    if (not valid_pid(observation["pid"])
            or trace["id"] != observation["traceID"] or trace["pid"] != observation["pid"]
            or trace["kind"] != "creation" or trace["outcome"] != "reveal-returned"
            or trace["droppedEvents"] != 0):
        raise ValueError("Trace identity, outcome or completeness does not match this input")
    if observation["endpoint"] != "recorded-visible-selection":
        raise ValueError("Endpoint must be independently observed visible selection")
    anchor = trace["clockAnchor"]
    numerator, denominator = anchor["numerator"], anchor["denominator"]
    timebase = observation["machTimebase"]
    if (any(not uint64(anchor[key]) for key in
            ("numerator", "denominator", "machTimeTicks", "uptimeBeforeNS", "uptimeAfterNS"))
            or any(not uint64(observation[key]) for key in
                   ("inputMachTicks", "selectedMachTicksUpper"))
            or type(timebase) is not list or len(timebase) != 2
            or any(type(value) is not int or not 1 <= value <= 2**32 - 1 for value in timebase)
            or [numerator, denominator] != timebase):
        raise ValueError("Native and product clock timebases do not match")
    anchor_ns = anchor["machTimeTicks"] * numerator // denominator
    lower, upper = anchor["uptimeBeforeNS"], anchor["uptimeAfterNS"]
    if not lower <= anchor_ns <= upper <= trace["events"][0]["uptimeNS"]:
        raise ValueError("Clock anchor does not bracket the native clock")
    offset_lower, offset_upper = lower - anchor_ns, upper - anchor_ns
    input_ns = observation["inputMachTicks"] * numerator // denominator
    selected_ns = observation["selectedMachTicksUpper"] * numerator // denominator
    events = trace["events"]
    preflight = ["destination.validation.begin", "destination.validation.validated", "destination.validation.end",
                 "templates.load.begin", "templates.load.loaded", "templates.load.end"]
    required = ["begin", "action.callback", "action.menu.link", "background.submit", "background.entered",
                *preflight, "authorization.begin",
                "authorization.admitted", "writer.preflight.begin", "writer.preflight.validated",
                "writer.preflight.end", "file.published", "writer.result.ready", "writer.end",
                "authorization.end", "background.work.finished", "main.completion.enqueued",
                "main.completion.entered", "finder.reveal.request", "finder.reveal.return", "end"]
    points = ordered_points(trace, required, "Operation")
    if [event["phase"] for event in events if event["phase"].startswith(
            ("destination.validation.", "templates.load."))] != preflight:
        raise ValueError("Successful destination/template preflight has contradictory or unknown phases")
    scope_stop_index = validate_successful_authorization(events)
    writer_end_index = next(index for index, event in enumerate(events) if event["phase"] == "writer.end")
    if writer_end_index >= scope_stop_index:
        raise ValueError("Writer operation is outside its admitted authorization scope")
    if [event["phase"] for event in events if event["phase"].startswith("writer.preflight.")] != [
            "writer.preflight.begin", "writer.preflight.validated", "writer.preflight.end"]:
        raise ValueError("Successful writer preflight has contradictory or unknown phases")
    # Recorder setup already happened by begin. Input must precede this earliest
    # known creation timestamp under the entire clock-anchor uncertainty interval.
    if (input_ns + offset_upper > points["begin"]
            or selected_ns + offset_lower < points["file.published"]):
        raise ValueError("Native endpoints cannot bracket this creation")
    menu_links = [event.get("relatedID") for event in events if event["phase"] == "action.menu.link"]
    if len(menu_links) != 1 or not menu_links[0]:
        raise ValueError("Creation is not linked to its registering menu")
    if (menu["id"] != menu_links[0] or menu["pid"] != trace["pid"] or menu["kind"] != "menu"
            or menu["outcome"] != "menu-returned" or menu["droppedEvents"] != 0):
        raise ValueError("Registering menu trace does not match this creation")
    proof_links = [event.get("relatedID") for event in menu["events"]
                   if event["phase"] == "menu.destination.preparation.link"]
    if (proof_links != [preparation["id"]] or preparation["pid"] != trace["pid"]
            or preparation["kind"] not in ("destination-preparation", "destination-prewarm")
            or preparation["outcome"] != "ready" or preparation["droppedEvents"] != 0):
        raise ValueError("Menu's prepared proof is missing, unrelated or discarded")
    preparation_phases = ["preparation.submitted", "preparation.entered", "preparation.ready",
                          "preparation.cache.publish.begin", "preparation.cache.accepted", "preparation.cache.publish.end"]
    preparation_points = ordered_points(preparation, preparation_phases, "Preparation")
    if [event["phase"] for event in preparation["events"]
            if event["phase"].startswith("preparation.")] != preparation_phases:
        raise ValueError("Ready preparation has contradictory or unknown phases")
    menu_phases = ["menu.destination.preparation.link", "menu.destination.ready", "menu.prepared"]
    menu_points = ordered_points(menu, menu_phases, "Ready-menu")
    if [event["phase"] for event in menu["events"]
            if event["phase"].startswith("menu.destination.")] != menu_phases[:2]:
        raise ValueError("Ready menu has contradictory or unknown destination phases")
    # A reader can acquire the published snapshot before the worker logs acceptance
    # after unlocking. Require publication to have begun, not its later log to precede
    # that reader. The registering menu must have returned before creation began.
    if not (preparation_points["preparation.cache.publish.begin"] <= menu_points["menu.destination.preparation.link"]
            <= menu_points["menu.destination.ready"] <= menu_points["menu.prepared"]
            <= menu["events"][-1]["uptimeNS"] <= points["begin"]):
        raise ValueError("Ready proof, menu and action are not in causal order")

    def span(start, end):
        return (points[end] - points[start]) / 1_000_000

    return {
        "traceID": trace["id"], "pid": trace["pid"], "menuTraceID": menu_links[0],
        "preparationTraceID": preparation["id"],
        "preparationTriggerMenuTraceID": preparation.get("parentID"),
        "preparationQueueMS": (preparation_points["preparation.entered"] - preparation_points["preparation.submitted"]) / 1_000_000,
        "preparationMetadataMS": (preparation_points["preparation.ready"] - preparation_points["preparation.entered"]) / 1_000_000,
        "preparationCachePublicationMS": (preparation_points["preparation.cache.publish.end"] - preparation_points["preparation.cache.publish.begin"]) / 1_000_000,
        "clockAnchorUncertaintyNS": upper - lower,
        "inputToCallbackMS": [(points["action.callback"] - input_ns - offset_upper) / 1_000_000,
                              (points["action.callback"] - input_ns - offset_lower) / 1_000_000],
        "callbackToPublicationMS": span("action.callback", "file.published"),
        "inputToPublicationMS": [(points["file.published"] - input_ns - offset_upper) / 1_000_000,
                                 (points["file.published"] - input_ns - offset_lower) / 1_000_000],
        "queueMS": span("background.submit", "background.entered"),
        "authorizationAdmissionMS": span("authorization.begin", "authorization.admitted"),
        "writerPreflightMS": span("writer.preflight.begin", "writer.preflight.end"),
        "writerToPublicationMS": span("writer.preflight.begin", "file.published"),
        "postPublicationWriterMS": span("file.published", "writer.end"),
        "returnToMainMS": span("main.completion.enqueued", "main.completion.entered"),
        "revealRequestMS": span("finder.reveal.request", "finder.reveal.return"),
        "publicationToSelectedUpperMS": (selected_ns + offset_upper - points["file.published"]) / 1_000_000,
        "inputToSelectedUpperMS": (selected_ns - input_ns) / 1_000_000,
        "endpoint": observation["endpoint"], "sampleCount": 1, "percentileAcceptance": False,
        "evidenceSource": source,
        "deliveryCompleteness": "closed-json-sessions" if source == "json" else "external-signpost-validation-required",
        "jsonSessionIDs": session_ids,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--observation", type=Path, required=True)
    parser.add_argument("--menu", type=Path, required=True)
    parser.add_argument("--preparation", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source", choices=("json", "signpost-export"), default="json",
                        help="JSON requires sealed receipts beside reports; legacy JSON lacks complete delivery evidence")
    args = parser.parse_args()
    paths = (args.trace, args.menu, args.preparation)
    reports = [json.loads(path.read_text()) for path in paths]
    receipts = {}
    if args.source == "json":
        for path, report in zip(paths, reports):
            delivery = report.get("delivery")
            session_id = delivery.get("sessionID") if isinstance(delivery, dict) else None
            if not valid_session_id(session_id):
                parser.error("JSON report lacks delivery metadata; legacy/live JSON is not complete session evidence")
            try:
                receipt = json.loads((path.parent / "receipts" / (session_id + ".json")).read_text())
            except (OSError, ValueError):
                parser.error("Missing or unreadable closed-session receipt; drain the controlled JSON capture first")
            if session_id in receipts and receipts[session_id] != receipt:
                parser.error("Conflicting JSON session receipts")
            receipts[session_id] = receipt
    report = assemble(reports[0], json.loads(args.observation.read_text()), reports[1], reports[2],
                      receipts=receipts.values(), source=args.source)
    # Refuse to replace earlier evidence.
    with args.output.open("x") as output:
        output.write(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
