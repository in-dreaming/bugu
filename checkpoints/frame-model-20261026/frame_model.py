"""Finite SC-witness model, NOT a weak-memory checker or Bugu tape reader.

The evidence may select a schedule but replay reads independent model state.
No expected read is ever assigned to state. Frozen-plan replay never replans.
Only one Service epoch, two serialized roles and at most two publications.
"""
from dataclasses import dataclass, replace
from typing import Optional

MAX_OPS = 12
MAX_NODES = 50000
MAX_VALUE = 7  # explicit finite model, not u64 arithmetic

class Reject(Exception):
    pass

@dataclass(frozen=True)
class Op:
    id: str
    role: str
    kind: str  # odd/frame_write/even/seq_read/frame_read
    before: int
    after: int
    value: int
    episode: int = 0
    epoch: int = 1
    site: str = "service"

@dataclass(frozen=True)
class Episode:
    id: int
    expected_frame: Optional[int]
    outcome: str  # stable/odd_sequence/frame_mismatch/sequence_changed

@dataclass(frozen=True)
class Trace:
    ops: tuple[Op, ...]
    episodes: tuple[Episode, ...]
    edges: tuple[tuple[str, str], ...] = ()  # already audited cross-domain constraints
    epoch: int = 1
    birth: int = -1
    death: int = 10000
    eof: tuple[str, ...] = ("C", "R")
    coverage: str = "scalar-projection-v1"
    held_claims: bool = False

@dataclass(frozen=True)
class Plan:
    order: tuple[str, ...]
    nodes: int

def validate(t: Trace):
    """Validate the *model input*, not a production tape or source coverage."""
    if any(type(x) is not int for x in (t.epoch, t.birth, t.death)):
        raise Reject("integer identity/occurrence required")
    if t.coverage != "scalar-projection-v1" or t.held_claims:
        raise Reject("unsupported coverage or claim-holding gate")
    if t.eof != ("C", "R") or t.epoch < 1 or t.birth >= t.death:
        raise Reject("identity/EOF/lifetime")
    if not 1 <= len(t.ops) <= MAX_OPS:
        raise Reject("operation cap")
    ids = [o.id for o in t.ops]
    if len(set(ids)) != len(ids):
        raise Reject("duplicate event")
    endpoints = []
    for o in t.ops:
        if any(type(x) is not int for x in (o.before, o.after, o.epoch, o.episode)):
            raise Reject("integer identity/occurrence required")
        if o.kind not in {"odd", "frame_write", "even", "seq_read", "frame_read"}:
            raise Reject("unsupported family")
        if o.role != ("R" if o.kind in {"odd", "frame_write", "even"} else "C"):
            raise Reject("wrong role")
        if o.epoch != t.epoch or o.site != "service":
            raise Reject("epoch/site")
        if not t.birth < o.before < o.after < t.death:
            raise Reject("interval outside lifetime")
        if type(o.value) is not int or not 0 <= o.value <= MAX_VALUE:
            raise Reject("value/wrap bound")
        endpoints.extend((o.before, o.after))
    if len(set(endpoints)) != len(endpoints):
        raise Reject("duplicate hook occurrence")
    for role in ("C", "R"):
        chain = [o for o in t.ops if o.role == role]
        if any(a.after >= b.before for a, b in zip(chain, chain[1:])):
            raise Reject("role program order")
    wr = [o for o in t.ops if o.role == "R"]
    if len(wr) % 3 or len(wr) > 6:
        raise Reject("incomplete/publication bound")
    frames = []
    for i in range(0, len(wr), 3):
        a, b, c = wr[i:i+3]
        if [a.kind, b.kind, c.kind] != ["odd", "frame_write", "even"]:
            raise Reject("publication shape")
        if a.value != i//3*2+1 or c.value != i//3*2+2:
            raise Reject("sequence publication")
        frames.append(b.value)
    if frames != sorted(frames):
        raise Reject("frame regression/ABA excluded")
    epids = [e.id for e in t.episodes]
    if any(type(x) is not int for x in epids):
        raise Reject("integer episode identity required")
    if len(epids) != len(set(epids)) or not 1 <= len(epids) <= 2:
        raise Reject("episode identity/bound")
    reads = [o for o in t.ops if o.role == "C"]
    if any(o.episode not in epids for o in reads):
        raise Reject("unknown read episode")
    if [o.episode for o in reads] != sorted([o.episode for o in reads], key=epids.index):
        raise Reject("interleaved control episodes")
    for e in t.episodes:
        ops = [o for o in reads if o.episode == e.id]
        kinds = [o.kind for o in ops]
        if e.expected_frame is not None and (type(e.expected_frame) is not int or not 0 <= e.expected_frame <= MAX_VALUE):
            raise Reject("requested frame bound")
        if not ops or ops[0].kind != "seq_read":
            raise Reject("missing sequence-before")
        s = ops[0].value
        if s & 1:
            expected, shape = "odd_sequence", ["seq_read"]
        else:
            if len(ops) < 2 or ops[1].kind != "frame_read":
                raise Reject("missing frame")
            if e.expected_frame is not None and ops[1].value != e.expected_frame:
                expected, shape = "frame_mismatch", ["seq_read", "frame_read"]
            else:
                if len(ops) != 3:
                    raise Reject("missing final sequence")
                expected = "stable" if s == ops[2].value else "sequence_changed"
                shape = ["seq_read", "frame_read", "seq_read"]
        if kinds != shape or e.outcome != expected:
            raise Reject("branch/extra or missing read")
    if any(a not in ids or b not in ids or a == b for a, b in t.edges):
        raise Reject("edge identity")

def predecessors(t):
    p = {o.id: set() for o in t.ops}
    # All known nonoverlapping intervals impose order. Overlap alone does not.
    for a in t.ops:
        for b in t.ops:
            if a.after < b.before:
                p[b.id].add(a.id)
    for role in ("C", "R"):
        chain = [o for o in t.ops if o.role == role]
        for a, b in zip(chain, chain[1:]):
            p[b.id].add(a.id)
    for a, b in t.edges:
        p[b].add(a)
    return p

def apply(o, state, mutate_read=None):
    seq, frame = state
    if o.kind == "odd":
        if seq & 1 or seq + 1 != o.value:
            return None
        return seq + 1, frame
    if o.kind == "even":
        if not seq & 1 or seq + 1 != o.value:
            return None
        return seq + 1, frame
    if o.kind == "frame_write":
        if not seq & 1:
            return None
        return seq, o.value
    actual = seq if o.kind == "seq_read" else frame
    if mutate_read == o.id:
        actual ^= 1
    return state if actual == o.value else None

def solve(t: Trace, node_cap=MAX_NODES):
    validate(t)
    pred = predecessors(t)
    ops = {o.id: o for o in t.ops}
    visited = set()
    nodes = 0
    def visit(done, state, order):
        nonlocal nodes
        nodes += 1
        if nodes > node_cap:
            raise Reject("solver budget exhausted")
        if len(done) == len(ops):
            return order
        key = (done, state)
        if key in visited:
            return None
        visited.add(key)
        for name in sorted(ops):
            if name in done or not pred[name] <= done:
                continue
            nxt = apply(ops[name], state)
            if nxt is not None:
                result = visit(done | {name}, nxt, order + (name,))
                if result is not None:
                    return result
        return None
    result = visit(frozenset(), (0, 0), ())
    if result is None:
        raise Reject("no legal finite SC witness")
    return Plan(result, nodes)

def replay(t: Trace, plan: Plan, mutate_read=None):
    """One already frozen schedule; mismatch is terminal, no solver call."""
    validate(t)
    ops = {o.id: o for o in t.ops}
    if len(plan.order) != len(ops) or set(plan.order) != set(ops):
        raise Reject("plan missing/extra event")
    pred, done, state = predecessors(t), set(), (0, 0)
    for name in plan.order:
        if not pred[name] <= done:
            raise Reject("plan violates order")
        nxt = apply(ops[name], state, mutate_read)
        if nxt is None:
            raise Reject("ReplayMismatch")
        state = nxt
        done.add(name)
    return state
