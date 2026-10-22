#!/usr/bin/env python3
"""Read-only, source-pinned ScanIntervals diagnostic, NOT semantic admission.

No native code, subprocesses, network, replay, writes, or reference-derived
execution. INPUT families 1/2/11 alone establish the inspected event order.
References 101/102/115 supply independently checked coordinates/report values.
After the first CrossedScan, diagnostic continuation counts other overlapping
pairs; it does not model a successful validator execution past that error.
"""
import argparse
import collections
import hashlib
import heapq
import json
import pathlib
import re
import resource
import struct
import sys

EXPECTED_BYTES = 50_481_003
EXPECTED_SHA256 = "33b7d6d99f4cdbe385c4df9bcd80cd2c5377bdad7feb9239d322d81f336cd62f"
SOURCE_TREE = "7f466dd56d0f154647c764eab619f5226d3ff45e"
SOURCE_HASHES = {
    "src/runtime/capture_order.zig": "6a84bea2b086e50cfe7d1bca045c24533c1df29ed074c967d471a44a35cec909",
    "src/runtime/live_semantic_hooks.zig": "b592536bf0afba5737894e6621b234c1e0e9020a431cbdd6b01562b4ca4a34ea",
    "src/music/live_semantic_format.zig": "3d2de2a2e81deac7ff845d2654bf102b74bcc7338686c010fcd11986636a462f",
    "tools/sme_authoring/core/live_semantic_codec.zig": "c4fe9a15f790cd524291a4cfad32d9584879cb188fee9d245ddcd54d5aad7b0d",
}
FILE_CAP = 64 * 1024 * 1024
ADDRESS_SPACE_CAP = 2 * 1024 * 1024 * 1024
MAX_POINTS = 2_000_000  # Combined expanded INPUT plus REFERENCE points.
MAX_SAMPLES = 18  # Plus the two separately reported first-policy conflicts: <=20.
ROLES = ("control", "worker", "render", "ui")  # Wire roles, NOT native enums.
INPUT_FAMILIES = {1, 2, 3, 4, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17}
REFERENCE_FAMILIES = {5, 6, 10, *range(101, 120)}
SCANS = ("worker_jobs", "acceptance_jobs", "scheduler_prepare",
         "scheduler_reconcile", "scheduler_acquire", "render_consumed")
PUBLICATIONS = ("queued", "completed", "published", "acquired", "phase",
                "terminal", "receipt", "cancelled", "slot_open", "slot_close")
OPERATION_ROLES = {"service_worker_scan": 1, "service_acceptance_scan": 0,
                   "service_slot_guard_render_claim": 2,
                   "service_slot_guard_render_release": 2}
POINT_PUBLICATIONS = dict(zip(("service_job_queued", "service_worker_completed",
    "scheduler_publication", "scheduler_acquired", "scheduler_phase",
    "scheduler_terminal", "scheduler_receipt", "service_slot_guard_open",
    "service_slot_guard_close"), (0, 1, 2, 3, 4, 5, 6, 8, 9)))
BOUNDARY_SCANS = dict(zip(("service_worker_scan", "service_acceptance_scan",
    "scheduler_prepare_scan", "scheduler_reconcile_scan", "scheduler_acquire_scan",
    "service_render_consumed_prefix"), range(6)))
JOB_READS = {"service_worker_scan", "service_acceptance_scan"}
SEQUENCE_READS = {"service_availability_readiness_sequence_before",
    "service_availability_readiness_sequence_after",
    "service_availability_acceptance_sequence_before",
    "service_availability_acceptance_sequence_after", "service_readiness_sequence",
    "service_readiness_final_sequence"}
PREFIX_READS = SEQUENCE_READS | {"ring_consumed", "service_initial_entry_consumed",
    "runtime_collection_frame", "runtime_control_accept_frame",
    "runtime_control_collect_frame", "runtime_readiness_outer_before",
    "runtime_readiness_outer_after", "runtime_control_horizon", "scheduler_prepare_horizon"}
PREFIX_WRITES = {"service_render_sequence_odd", "service_render_sequence_even",
    "runtime_render_frame", "runtime_render_commit_horizon", "scheduler_horizon"}
EXCLUSION_ROLES = {"service_stream_close_claim": 0, "service_stream_close_idle": 0,
    "service_worker_claim": 1, "service_worker_idle": 1,
    "service_service_prepare_claim": 1, "service_service_prepare_idle": 1}


class Invalid(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Invalid(message)


def digest(data):
    return hashlib.sha256(data).digest()


class Decoder:
    """Every read is length checked, including canonical, bounded u64 LEB128."""
    def __init__(self, data):
        self.data, self.at = data, 0

    def raw(self, count):
        require(0 <= count <= len(self.data) - self.at, "truncated payload")
        value = self.data[self.at:self.at + count]
        self.at += count
        return value

    def uint(self, size):
        return int.from_bytes(self.raw(size), "little")

    def boolean(self):
        value = self.uint(1)
        require(value in (0, 1), "noncanonical boolean")
        return value

    def varint(self):
        result = 0
        for i in range(10):
            byte = self.uint(1)
            low = byte & 127
            require(i != 9 or (byte < 128 and low <= 1), "u64 LEB128 overflow")
            result |= low << (7 * i)
            if byte < 128:
                require(i == 0 or low != 0, "noncanonical LEB128")
                return result
        raise Invalid("unterminated LEB128")

    def finish(self):
        require(self.at == len(self.data), "trailing payload bytes")


def bounded_read(path, limit, exact=None):
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    require(len(data) <= limit, "file exceeds hard bound: " + str(path))
    require(exact is None or len(data) == exact, "wrong pinned file size")
    return data


def enum_names(text, name):
    match = re.search(r"pub const " + name + r" = enum\(u8\) \{(.*?)\n\};", text, re.S)
    require(match is not None, "pinned enum not found: " + name)
    body = re.sub(r"//[^\n]*", "", match.group(1))
    result, value = {}, 0
    for item in body.split(","):
        if not item.strip():
            continue
        token = re.fullmatch(r"\s*([a-z_]+)\s*(?:=\s*(0x[0-9a-fA-F]+|[0-9]+))?\s*", item)
        require(token is not None, "unsupported pinned enum syntax")
        if token.group(2):
            value = int(token.group(2), 0)
        require(value <= 255 and value not in result, "invalid pinned enum code")
        result[value] = token.group(1)
        value += 1
    return result


def source_schema(root):
    texts = {}
    for path, expected in SOURCE_HASHES.items():
        data = bounded_read(root / path, 256 * 1024)
        require(digest(data).hex() == expected, "source hash mismatch: " + path)
        texts[path] = data.decode("utf-8")
    hooks = texts["src/runtime/live_semantic_hooks.zig"]
    allowed_body = hooks.split("pub fn allowedSite(site: Site) bool {", 1)[1].split("pub fn allowedPoint", 1)[0]
    allowed = set(re.findall(r"\.([a-z_]+)\s*,", allowed_body))
    return (enum_names(texts["src/runtime/capture_order.zig"], "Site"),
            enum_names(hooks, "Boundary"), allowed)


def framing(data):
    require(len(data) == EXPECTED_BYTES and digest(data).hex() == EXPECTED_SHA256,
            "history does not match pinned original")
    header = Decoder(data[:192])
    require(header.raw(8) == b"SMELSB01", "header magic")
    require((header.uint(2), header.uint(2), header.uint(2), header.uint(2)) == (9, 3, 192, 0), "header profile/version/reserved")
    cap = header.uint(8)
    require(len(data) <= cap <= 512 * 1024 * 1024, "header cap")
    require((header.uint(4), header.uint(2), header.uint(2)) == (65536, 4, 0), "header limits/reserved")
    identities = {name: header.raw(32).hex() for name in ("build", "bank", "config", "source")}
    require(header.raw(32) == digest(data[:160]), "header SHA256")
    header.finish()
    end = len(data) - 184
    trailer = Decoder(data[end:])
    require(trailer.raw(8) == b"SMELEND1", "trailer magic")
    require((trailer.uint(1), trailer.uint(1), trailer.uint(2), trailer.uint(4)) == (1, 15, 0, 184), "trailer closure/reserved")
    require(trailer.uint(8) == len(data), "trailer total bytes")
    total = trailer.uint(8)
    terminal = [[trailer.uint(8) for _ in range(4)] for _ in range(3)]
    require(trailer.uint(8) == end - 192, "trailer record bytes")
    require(trailer.raw(16) == bytes(16), "trailer reserved")
    require(trailer.raw(32) == digest(memoryview(data)[:-32]), "trailer file SHA256")
    trailer.finish()
    counts = [[0] * 4 for _ in range(3)]
    families = collections.Counter()
    for offset, role, cls, family, ordinal, payload in frames(data):
        require(role < 4 and cls < 2, "frame role/class at " + str(offset))
        require(family in (INPUT_FAMILIES if cls == 0 else REFERENCE_FAMILIES), "frame family/class")
        require(ordinal == counts[0][role] + 1, "frame role ordinal")
        require(digest(payload) == data[offset + 32:offset + 64], "frame payload SHA256")
        counts[0][role] += 1
        counts[cls + 1][role] += 1
        families[str(family)] += 1
    require(counts == terminal and sum(counts[0]) == total, "trailer count mismatch")
    return {"passed": True, "frames": total, "roles": counts[0], "inputs": counts[1],
            "references": counts[2], "families": dict(sorted(families.items(), key=lambda x: int(x[0]))),
            "declared_byte_cap": cap, "identities": identities,
            "identity_scope": "Authenticated by the pinned original file SHA256; not independently rebuilt."}


def frames(data):
    at, end, view = 192, len(data) - 184, memoryview(data)
    while at < end:
        require(end - at >= 64, "truncated frame header")
        magic, length, role, cls, family, reserved, ordinal, size, reserved2 = struct.unpack_from("<4sIBBHIQII", data, at)
        require(magic == b"EVT1" and reserved == reserved2 == 0, "frame magic/reserved")
        require(64 <= length <= 64 + 65536 and length <= end - at and size == length - 64, "frame length")
        yield at, role, cls, family, ordinal, view[at + 64:at + length]
        at += length
    require(at == end, "record EOF")


def coordinate(point, schema, packet):
    sites, boundaries, allowed = schema
    site_map = boundaries if point["kind"] == "boundary" else sites
    require(point["site_code"] in site_map and point["edge"] in (0, 1), "coordinate enum")
    point["site"] = site_map[point["site_code"]]
    role, site = point["role"], point["site"]
    require(role < 3 and point["occurrence"] > 0, "point role/occurrence")
    if point["kind"] == "boundary":
        return
    require(site in allowed, "point outside allowedSite")
    if site in {"ring_consumed", "service_initial_entry_consumed", "service_initial_entry_cancel", "ring_produced", "produced_release", "runtime_worker_service_publish"}:
        require(role == 0, "control point role")
    if site in {"runtime_load_state_claim", "runtime_worker_service_read"}:
        require(role == 1, "worker point role")
    if site in {"runtime_load_state_read", "runtime_load_state_publish"}:
        require(role != 2, "load point role")
    if site in EXCLUSION_ROLES:
        require(role == EXCLUSION_ROLES[site], "exclusion role")
    prefix = point["publication_prefix"]
    if prefix is not None:
        require(site not in PREFIX_READS or role == 0, "prefix read role")
        require(site not in PREFIX_WRITES or role == 2, "prefix write role")
        require(prefix == 0 or prefix_supported(point), "noncanonical publication prefix")
    if packet:
        if site in JOB_READS:
            require(role == OPERATION_ROLES[site] and point["index"] < 256 and point["generation"] == 0, "packet job coordinate")
        elif site in {"service_slot_guard_render_claim", "service_slot_guard_render_release", "service_render_consumed"}:
            require(role == 2 and point["index"] < 64, "packet render coordinate")
            require(site != "service_slot_guard_render_claim" or point["generation"] == 0, "packet claim generation")


def prefix_supported(point):
    return point["edge"] == 1 and ((point["role"] == 0 and point["site"] in PREFIX_READS)
        or (point["role"] == 2 and point["site"] in PREFIX_WRITES))


def selected_points(data, role, reference, schema, limits):
    last = 0
    for offset, frame_role, cls, family, ordinal, payload in frames(data):
        if frame_role != role or cls != int(reference):
            continue
        if family not in ({101, 102, 115} if reference else {1, 2, 11}):
            continue
        d = Decoder(payload)
        packet = family in (11, 115)
        count = d.uint(2) if packet else 1
        require(1 <= count <= 512, "packet count")
        for index in range(count):
            p = {"occurrence": d.varint() if packet else d.uint(8),
                 "role": role if packet else d.uint(8),
                 "kind": "boundary" if family in (2, 102) else "point",
                 "site_code": d.uint(2) if packet else d.uint(8),
                 "edge": d.uint(1) if packet else d.uint(8),
                 "index": d.varint() if packet else d.uint(8),
                 "generation": d.varint() if packet else d.uint(8)}
            p["publication_prefix"] = d.varint() if packet else (d.uint(8) if family == 1 else None)
            p.update(frame_offset=offset, frame_ordinal=ordinal, wire_family=family,
                     packet_index=index if packet else None)
            require(p["role"] == role and p["occurrence"] > last, "selected role/occurrence order")
            last = p["occurrence"]
            coordinate(p, schema, packet)
            if reference:
                present = d.boolean()
                bits = d.varint() if packet else (d.uint(8) if present else 0)
                require(present or bits == 0, "noncanonical absent packet reference")
                p["reference_value"] = bits if present else None
                if p["kind"] == "point" and p["site"] in JOB_READS:
                    require((p["edge"] == 0 and not present) or (p["edge"] == 1 and present and bits <= 1), "noncanonical job predicate reference")
            limits[int(reference)] += 1
            require(sum(limits) <= MAX_POINTS, "capacity: combined expanded point hard bound")
            # Selected-job boundary facts intentionally have no boundary INPUT.
            if p["kind"] == "boundary" and p["site"] in {"service_acceptance_selected", "service_worker_selected"}:
                require(reference, "selected-job boundary cannot be an INPUT")
                continue
            yield p
        d.finish()


def paired_role(data, role, schema, limits):
    references = iter(selected_points(data, role, True, schema, limits))
    for p in selected_points(data, role, False, schema, limits):
        r = next(references, None)
        require(r is not None, "missing selected reference")
        require(all(p[k] == r[k] for k in ("occurrence", "role", "kind", "site", "edge", "index", "generation")), "INPUT/REFERENCE coordinate mismatch")
        if r["publication_prefix"] is not None:
            require(p["publication_prefix"] == r["publication_prefix"], "packet prefix mismatch")
        if p["kind"] == "point" and prefix_supported(p):
            require(r["reference_value"] == p["publication_prefix"], "publication prefix reference mismatch")
        p["reference"] = {key: r[key] for key in ("reference_value", "frame_offset", "frame_ordinal", "wire_family", "packet_index")}
        yield p
    require(next(references, None) is None, "unpaired selected reference")


def identity(p):
    return p["role"], p["index"], p["generation"]


def scalar_conflict(read, publication_kind, write):
    if read["index"] != write["index"]:
        return False
    site, role = read["site"], write["role"]
    return ((site == "service_worker_scan" and role == 0 and publication_kind == 0)
        or (site == "service_acceptance_scan" and role == 1 and publication_kind == 1)
        or (site in {"service_slot_guard_render_claim", "service_slot_guard_render_release"}
            and role == 0 and publication_kind in (8, 9)))


def envelope_conflict(scan_kind, publication_kind, role):
    return ((scan_kind == 4 and role == 0 and publication_kind == 2)
        or (scan_kind in (2, 3) and role == 2 and publication_kind in (3, 4, 5, 6, 7)))


class Intervals:
    """ScanIntervals branch/iteration order, with bounded diagnostic continuation."""
    def __init__(self):
        self.scans = [None] * 6
        self.publications = [[None] * 10 for _ in range(3)]
        self.operations = [None] * 3
        self.counts = collections.Counter()
        self.samples = []
        self.first_strict = self.first_native_attempt = None

    def crossed(self, category, read, write, trigger, publication_kind):
        key = category + ":" + read["before"]["site"] + ":" + PUBLICATIONS[publication_kind]
        self.counts[key] += 1
        result = {"category": category, "trigger_occurrence": trigger["occurrence"],
                  "read": read, "write": write, "publication_kind": PUBLICATIONS[publication_kind]}
        if self.first_strict is None:
            self.first_strict = result
        if self.first_native_attempt is None and not (category == "scalar" and read["before"]["site"] in JOB_READS):
            self.first_native_attempt = result
        if len(self.samples) < MAX_SAMPLES:
            self.samples.append(result)

    @staticmethod
    def pair(slots, slot, p, span, exact=False):
        if p["edge"] == 0:
            require(slots[slot] is None, "ScanIntervals InvalidOrder: duplicate before")
            slots[slot] = span
        else:
            active = slots[slot]
            require(active is not None and identity(active["before"]) == identity(p), "ScanIntervals InvalidOrder: unmatched after")
            if exact:
                require(all(active["before"][k] == p[k] for k in ("site", "publication_prefix")), "ScanIntervals InvalidOrder: operation coordinate mismatch")
            active["after"] = p
            slots[slot] = None

    def observe(self, p):
        role, site, edge = p["role"], p["site"], p["edge"]
        span = {"before": p, "after": None} if edge == 0 else None
        if p["kind"] == "point" and site in OPERATION_ROLES:
            require(role == OPERATION_ROLES[site], "ScanIntervals InvalidOrder: operation role")
            if edge == 0:
                require(self.operations[role] is None, "ScanIntervals InvalidOrder: operation already active")
                for row in self.publications:
                    for kind, active in enumerate(row):
                        if active and scalar_conflict(p, kind, active["before"]):
                            self.crossed("scalar", span, active, p, kind)
            self.pair(self.operations, role, p, span, exact=True)
            return
        if p["kind"] == "boundary" and site in BOUNDARY_SCANS:
            kind = BOUNDARY_SCANS[site]
            require(role == (1 if kind == 0 else 2 if kind in (4, 5) else 0), "ScanIntervals InvalidOrder: scan role")
            if edge == 0:
                for publication_role, row in enumerate(self.publications):
                    for publication_kind, active in enumerate(row):
                        if active and envelope_conflict(kind, publication_kind, publication_role):
                            self.crossed("scheduler_envelope", span, active, p, publication_kind)
            self.pair(self.scans, kind, p, span)
            return
        kind = (7 if p["kind"] == "boundary" and site == "scheduler_plan_cancel_release"
                else POINT_PUBLICATIONS.get(site) if p["kind"] == "point" else None)
        if kind is None:
            return
        require(role != 1 or kind == 1, "ScanIntervals InvalidOrder: worker publication")
        expected = 0 if kind in (0, 2, 8, 9) else 1 if kind == 1 else 2 if kind in (3, 4) else role
        require(role == expected, "ScanIntervals InvalidOrder: publication role")
        if edge == 0:
            for scan_kind, active in enumerate(self.scans):
                if active and envelope_conflict(scan_kind, kind, role):
                    self.crossed("scheduler_envelope", active, span, p, kind)
            for active in self.operations:
                if active and scalar_conflict(active["before"], kind, p):
                    self.crossed("scalar", active, span, p, kind)
        self.pair(self.publications[role], kind, p, span)

    def finish(self):
        require(not any(self.scans) and not any(self.operations)
                and not any(any(row) for row in self.publications), "ScanIntervals Incomplete: unclosed interval")


def report_point(p):
    if p is None:
        return None
    result = dict(p)
    result["role"] = ROLES[p["role"]]
    result["edge"] = ("before", "after")[p["edge"]]
    if p["kind"] == "point" and p["site"] in JOB_READS:
        value = p["reference"]["reference_value"]
        result["reference_predicate"] = {
            "expression": "loaded_job_state == " + ("queued" if p["site"] == "service_worker_scan" else "completed"),
            "value": None if value is None else bool(value),
            "scope": "Recorded comparison predicate, not a state label or execution input."}
    return result


def report_conflict(conflict):
    if conflict is None:
        return None
    result = {key: value for key, value in conflict.items() if key not in ("read", "write")}
    for side in ("read", "write"):
        result[side] = {edge: report_point(conflict[side][edge]) for edge in ("before", "after")}
    result["predicate"] = ("Same index; generation deliberately not compared by scalarConflict."
        if conflict["category"] == "scalar" else "Scheduler whole-envelope exclusion; scalar reads are omitted, so slot/generation equality is not required.")
    return result


def inspect(history, source_root):
    schema = source_schema(source_root)
    data = bounded_read(history, FILE_CAP, EXPECTED_BYTES)
    framed = framing(data)
    limits, intervals, count, last = [0, 0], Intervals(), 0, 0
    streams = [paired_role(data, role, schema, limits) for role in range(4)]
    for p in heapq.merge(*streams, key=lambda point: point["occurrence"]):
        require(p["occurrence"] > last, "duplicate/reversed merged INPUT occurrence")
        last = p["occurrence"]
        count += 1
        intervals.observe(p)
    intervals.finish()
    return {
        "schema": "bugu.scan-overlap-inspection/v1",
        "status": "CROSSED_SCAN_DIAGNOSTIC" if intervals.first_strict else "NO_SCAN_INTERVAL_CONFLICT_FOUND",
        "original": {"path": str(history), "bytes": len(data), "sha256": EXPECTED_SHA256},
        "source_tree": SOURCE_TREE, "source_hashes_verified": SOURCE_HASHES,
        "framing": framed,
        "input_order": {"families": [1, 2, 11], "merged_selected_points": count,
                        "decoded_input_points": limits[0], "decoded_reference_points": limits[1],
                        "last_selected_occurrence": last,
                        "scope": "Strictly increasing true INPUT occurrence stamps, not frame order, reference values, or invented atomic order; unrelated event-marker completeness is not checked."},
        "scan_interval_pairs_closed": True,
        "first_crossed_scan_strict": report_conflict(intervals.first_strict),
        "first_crossed_scan_native_attempt_policy": report_conflict(intervals.first_native_attempt),
        "diagnostic_continuation": {
            "scope": "Counts each conflicting interval pair at the later BEFORE edge. Continues after hypothetical rejection solely for diagnosis, not successful admission.",
            "total_conflicting_pairs": sum(intervals.counts.values()),
            "counts_by_kind": dict(sorted(intervals.counts.items())),
            "continuation_sample_limit": MAX_SAMPLES,
            "samples": [report_conflict(item) for item in intervals.samples]},
        "bounds": {"history_bytes": EXPECTED_BYTES, "file_byte_cap": FILE_CAP,
                   "max_expanded_points_combined": MAX_POINTS,
                   "address_space_limit_bytes": resource.getrlimit(resource.RLIMIT_AS),
                   "conflict_examples_total_cap": 20,
                   "storage": "One fixed-size history buffer; four streaming INPUT/REFERENCE pairs; 39 active interval slots; at most 20 conflict examples including first-policy conflicts. No per-point array or dependency graph."},
        "limitations": [
            "Read-only Python analysis only. No native execution, replay, retry, tape mutation, publication, or protocol-policy change.",
            "Only pinned source files, framing, selected coordinate/reference decoding, and isolated ScanIntervals behavior are checked. No claim of full validateInputs, ServiceScanGrammar, payload-overlap, lifecycle, bank/source identity reconstruction, or all-family semantic validation.",
            "The isolated first CrossedScan is not a claim that every earlier native admission stage passed or that replay reached this point.",
            "Reference predicates describe recorded comparisons only. They do not establish actual atomic linearization order or authorize supplying a selected job/state to execution."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", required=True, type=pathlib.Path)
    parser.add_argument("--source-root", required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_AS)
        new_hard = ADDRESS_SPACE_CAP if hard == resource.RLIM_INFINITY else min(hard, ADDRESS_SPACE_CAP)
        new_soft = new_hard if soft == resource.RLIM_INFINITY else min(soft, new_hard)
        resource.setrlimit(resource.RLIMIT_AS, (new_soft, new_hard))
        result = inspect(args.history, args.source_root)
    except MemoryError:
        print('{"status":"CAPACITY_REJECTED","error":"address-space capacity reached; do not rerun or relax bounds"}')
        return 3
    except (Invalid, OSError, UnicodeError, ValueError, struct.error) as error:
        print(json.dumps({"status": "INSPECTION_REJECTED", "error": str(error),
                          "scope": "No native execution or writes were attempted."}, indent=2))
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
