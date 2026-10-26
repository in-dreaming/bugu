"""Independent bounded oracle: enumerate every role-chain shuffle.
Does NOT import solver, state-transition routine, or predecessor builder.
The caller supplies structurally valid model input; structural rejection has
separate named tests. Each complete shuffle is interpreted from scratch.
"""
def shuffles(a, b):
    if not a:
        yield tuple(b)
    elif not b:
        yield tuple(a)
    else:
        for tail in shuffles(a[1:], b):
            yield (a[0],) + tail
        for tail in shuffles(a, b[1:]):
            yield (b[0],) + tail

def witnesses(t):
    cs = [o for o in t.ops if o.role == "C"]
    rs = [o for o in t.ops if o.role == "R"]
    for order in shuffles(cs, rs):
        positions = {o.id: i for i, o in enumerate(order)}
        if any(positions[a] >= positions[b] for a, b in t.edges):
            continue
        bad = False
        for i, a in enumerate(order):
            for b in order[i+1:]:
                if b.after < a.before:
                    bad = True
        if bad:
            continue
        memory = {"sequence": 0, "frame": 0}
        observations = {}
        for o in order:
            if o.kind in ("odd", "even"):
                want_parity = 0 if o.kind == "odd" else 1
                if memory["sequence"] % 2 != want_parity:
                    bad = True
                    break
                memory["sequence"] += 1
                if memory["sequence"] != o.value:
                    bad = True
                    break
            elif o.kind == "frame_write":
                if memory["sequence"] % 2 != 1:
                    bad = True
                    break
                memory["frame"] = o.value
            else:
                got = memory["sequence" if o.kind == "seq_read" else "frame"]
                observations[o.id] = got
                if got != o.value:
                    bad = True
                    break
        if not bad:
            yield tuple(o.id for o in order)

def accepts(t):
    return next(witnesses(t), None) is not None
