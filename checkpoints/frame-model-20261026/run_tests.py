"""Standard-library-only reproducible suite. No Bugu/Host/audio execution."""
import dataclasses as dc
import hashlib
import itertools as it
import json
import time
from pathlib import Path
from frame_model import Op, Episode, Trace, Plan, Reject, validate, solve, replay
import oracle

RESULTS = {}

def hook_words(c, r):
    # Serial before/after pairs in each role, all global hooks unique.
    for slots in it.combinations(range(2*(c+r)), 2*c):
        ss = set(slots)
        yield tuple("C" if i in ss else "R" for i in range(2*(c+r)))

def make(frames=(1,), reads=(0, 0, 0), expected=None, hooks=None, edges=()):
    if reads[0] & 1:
        outcome, kinds = "odd_sequence", ("seq_read",)
    elif expected is not None and reads[1] != expected:
        outcome, kinds = "frame_mismatch", ("seq_read", "frame_read")
    else:
        outcome = "stable" if reads[0] == reads[2] else "sequence_changed"
        kinds = ("seq_read", "frame_read", "seq_read")
    c = [(f"C{i}", kind, val, 0) for i, (kind, val) in enumerate(zip(kinds, reads))]
    r = []
    for i, f in enumerate(frames):
        r.extend([(f"R{3*i}", "odd", 2*i+1, 0),
                  (f"R{3*i+1}", "frame_write", f, 0),
                  (f"R{3*i+2}", "even", 2*i+2, 0)])
    if hooks is None:
        hooks = tuple("C"*2*len(c) + "R"*2*len(r))
    coords = {role: [i for i, x in enumerate(hooks) if x == role] for role in ("C", "R")}
    ops = []
    for role, entries in (("C", c), ("R", r)):
        for i, (name, kind, value, episode) in enumerate(entries):
            ops.append(Op(name, role, kind, coords[role][2*i], coords[role][2*i+1], value, episode))
    return Trace(tuple(ops), (Episode(0, expected, outcome),), edges)

def result(t):
    try:
        p = solve(t)
    except Reject:
        return None
    # A solve-success/replay-failure is an implementation bug, NOT rejection.
    replay(t, p)
    return p

def rejected(t, contains=None):
    try:
        solve(t)
    except Reject as e:
        assert contains is None or contains in str(e), str(e)
        return str(e)
    raise AssertionError("unexpected acceptance")

def change(t, name, **kw):
    return dc.replace(t, ops=tuple(dc.replace(o, **kw) if o.id == name else o for o in t.ops))

def named_tests():
    cases = []
    def check(name, fn):
        fn()
        cases.append(name)
    base = make()
    check("stable_before_publication", lambda: replay(base, solve(base)))
    after = make(reads=(2,1,2), hooks=tuple("R"*6+"C"*6))
    check("stable_after_publication", lambda: replay(after, solve(after)))
    odd = make(reads=(1,), hooks=tuple("RRCCRRRR"))
    check("odd_early_exit_no_frame_or_final", lambda: replay(odd, solve(odd)))
    mismatch = make(reads=(0,0), expected=1)
    check("frame_mismatch_early_exit_no_final", lambda: replay(mismatch, solve(mismatch)))
    changed = make(reads=(0,1,2), hooks=tuple("CCRRRRRRCCCC"))
    check("changed_sequence_actual_return", lambda: replay(changed, solve(changed)))
    check("future_frame_rejected", lambda: rejected(make(reads=(0,2,0))))
    check("wrong_sequence_and_frame_combination", lambda: rejected(make(reads=(2,0,2), hooks=tuple("R"*6+"C"*6))))
    check("wrong_role", lambda: rejected(change(base,"R1",role="C"),"wrong role"))
    check("missing_eof", lambda: rejected(dc.replace(base,eof=("C",)),"EOF"))
    check("duplicate_eof", lambda: rejected(dc.replace(base,eof=("C","R","R")),"EOF"))
    check("duplicate_event", lambda: rejected(dc.replace(base,ops=base.ops+(base.ops[0],)),"duplicate event"))
    check("missing_before_read", lambda: rejected(dc.replace(base,ops=base.ops[1:]),"missing"))
    check("missing_final_read", lambda: rejected(dc.replace(base,ops=tuple(o for o in base.ops if o.id != "C2")),"missing final"))
    check("extra_frame_after_odd", lambda: rejected(change(base,"C0",value=1),"branch"))
    check("role_order", lambda: rejected(dc.replace(base,ops=(base.ops[1],base.ops[0])+base.ops[2:]),"role program"))
    check("bad_generation", lambda: rejected(change(base,"C1",epoch=2),"epoch"))
    check("destroyed_object", lambda: rejected(dc.replace(base,death=base.ops[1].after),"lifetime"))
    check("before_birth", lambda: rejected(dc.replace(base,birth=0),"lifetime"))
    check("unknown_site_crossfade", lambda: rejected(change(base,"C1",site="crossfade"),"site"))
    check("consumed_is_unsupported", lambda: rejected(change(base,"C1",kind="consumed_read"),"family"))
    check("held_claim_gate_excluded", lambda: rejected(dc.replace(base,held_claims=True),"claim"))
    check("wrap_bound", lambda: rejected(change(base,"R1",value=8),"bound"))
    check("frame_regression_ABA_excluded", lambda: rejected(make(frames=(2,1)),"regression"))
    check("incomplete_writer", lambda: rejected(dc.replace(base,ops=base.ops[:-1]),"incomplete"))
    check("invalid_publication_sequence", lambda: rejected(change(base,"R0",value=3),"sequence publication"))
    check("duplicate_hook", lambda: rejected(change(base,"R0",before=base.ops[0].before),"duplicate hook"))
    check("unclosed_interval", lambda: rejected(change(base,"C1",after=base.ops[1].before),"interval"))
    check("noninteger_hook_rejected", lambda: rejected(change(base,"C1",before=2.1),"integer"))
    check("boolean_value_rejected", lambda: rejected(change(base,"C1",value=True),"value"))
    # Both individual edge sets are compatible, but their union is cyclic.
    overlap = make(frames=(0,), reads=(0,0,2), hooks=tuple("CCCRRRRRRCCC"))
    a = dc.replace(overlap, edges=(("C1","R1"),))
    b = dc.replace(overlap, edges=(("R1","C1"),))
    assert result(a) and result(b)
    check("joint_cycle_local_domains_individually_feasible", lambda: rejected(dc.replace(overlap,edges=a.edges+b.edges)))
    # Every publication identity remains, even when values repeat.
    repeat = make(frames=(1,1),reads=(4,1,4),hooks=tuple("R"*12+"C"*6))
    check("repeated_frame_value_distinct_writes", lambda: replay(repeat, solve(repeat)))
    assert len([x for x in solve(repeat).order if x.startswith("R")]) == 6
    # A broad overlap can span two complete writer episodes.
    spanning = make(frames=(1,2),reads=(0,1,4),hooks=tuple("CCC"+"R"*12+"CCC"))
    check("one_frame_read_spans_two_writes", lambda: replay(spanning, solve(spanning)))
    check("initial_zero_repeated_publication", lambda: replay(make(frames=(0,)), solve(make(frames=(0,)))))
    first = make()
    second = tuple(dc.replace(o,id="D"+o.id[1:],before=o.before+20,after=o.after+20,
                  value=2 if o.kind=="seq_read" else 1,episode=1)
                  for o in first.ops if o.role=="C")
    two = dc.replace(first,ops=first.ops+second,episodes=first.episodes+(Episode(1,None,"stable"),))
    check("two_serial_control_episodes",lambda: replay(two,solve(two)))
    p = solve(base)
    try:
        replay(base,p,mutate_read="C1")
    except Reject as e:
        assert str(e) == "ReplayMismatch"
    else:
        raise AssertionError("mutated actual read was masked")
    cases.append("mutated_actual_read_terminal_failure_no_replan")
    try:
        solve(base,node_cap=1)
    except Reject as e:
        assert "budget" in str(e)
    else:
        raise AssertionError("budget not bounded")
    cases.append("solver_work_cap_rejected")
    try:
        replay(base,Plan(p.order[:-1],0))
    except Reject:
        pass
    else:
        raise AssertionError("short plan")
    cases.append("missing_plan_operation_rejected")
    return cases

def exhaustive():
    checked = accepted = rejected_count = 0
    max_nodes = 0
    digest = hashlib.sha256()
    # Exhaust all hooks and evidence in this DECLARED finite universe:
    # one publication to 0/1; one reader with odd, mismatch, or three-read path.
    # sequence evidence 0..2, frame evidence 0..2 (including impossible future).
    profiles = []
    for s in range(3):
        if s & 1:
            profiles.append(((s,),None))
        else:
            for f in range(3):
                for end in range(3):
                    profiles.append(((s,f,end),None))
                profiles.append(((s,f), (f+1)%3))
    # 25 path/evidence profiles, with each profile's own exact hook length.
    for write in (0,1):
        for reads, expected in profiles:
            n = len(reads)
            for hooks in hook_words(n,3):
                t = make((write,),reads,expected,hooks)
                validate(t)
                want = oracle.accepts(t)
                p = result(t)
                got = p is not None
                assert got == want, (t,want,p)
                if p:
                    # Planner is deterministic and every frozen plan belongs to
                    # independently enumerated witnesses.
                    assert p.order == solve(t).order
                    assert p.order in set(oracle.witnesses(t))
                    max_nodes = max(max_nodes,p.nodes)
                checked += 1
                accepted += got
                rejected_count += not got
                digest.update(bytes([got]))
    return dict(universe="1 writer episode; 1 reader; all hook shuffles; write=0/1; seq=0..2; frame=0..2; declared branches",profiles=len(profiles),cases=checked,accepted=accepted,rejected=rejected_count,max_accept_solver_nodes=max_nodes,decision_sha256=digest.hexdigest(),seed=None)

def main():
    start = time.monotonic()
    cases = named_tests()
    data = exhaustive()
    result_data = {"status":"PASS","scope":"finite SC-witness scalar projection, not production/weak-memory proof", "named_count":len(cases),"named_tests":cases,"exhaustive":data,"duration_seconds":round(time.monotonic()-start,3)}
    Path("results.json").write_text(json.dumps(result_data,indent=2,ensure_ascii=False)+"\n")
    print(json.dumps(result_data,ensure_ascii=False))

if __name__ == "__main__":
    main()
