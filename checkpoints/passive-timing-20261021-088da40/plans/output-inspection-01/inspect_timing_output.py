#!/usr/bin/env python3
"""Read-only schema=1 passive timing inspector. No engine execution or attribution.
Validates timing/association fields, flat lexical form, optional consistency and
retained-tail coverage, not every unrelated diagnostic payload's full schema.
"""
import argparse
from collections import Counter
import hashlib
import json
import pathlib
import re

PREFIXES = ('DEFAULT_HOST_CONTROL_EVENT', 'DEFAULT_HOST_WORKER_EVENT',
            'DEFAULT_HOST_TIMING', 'DEFAULT_HOST_EVENT_TAIL')
LIMIT = 64 * 1024 * 1024

def need(ok, why):
    if not ok: raise ValueError(why)

def field(row, key):
    need(key in row, 'missing field: ' + key)
    return row[key]

def uint(row, key, bits=64):
    value = field(row, key)
    need(re.fullmatch(r'0|[1-9][0-9]*', value) is not None, 'invalid unsigned: ' + key)
    value = int(value)
    need(value < 1 << bits, 'unsigned overflow: ' + key)
    return value

def boolean(row, key):
    value = field(row, key)
    need(value in ('true', 'false'), 'invalid boolean: ' + key)
    return value == 'true'

def present(row, key):
    yes = boolean(row, key + '.present')
    if not yes:
        need(field(row, key) == 'null', 'absent optional must be null: ' + key)
        need(not any(k.startswith(key + '.') and k != key + '.present' for k in row), 'absent optional has child: ' + key)
    else:
        need(row.get(key) != 'null', 'present optional is null: ' + key)
        need(key in row or any(k.startswith(key + '.') and k != key + '.present' for k in row), 'present optional lacks value: ' + key)
    return yes

def sample(row, key):
    if not present(row, key): return None
    return dict(value=uint(row, key + '.value'), available=boolean(row, key + '.available'),
                error_code=uint(row, key + '.error_code', 32))

def usable(value):
    return value is not None and value['available'] and value['error_code'] == 0

def timing(row, prefix, expected_job=None):
    job = uint(row, prefix + '.job') if present(row, prefix + '.job') else None
    begin, end = sample(row, prefix + '.begin'), sample(row, prefix + '.end')
    invalid = boolean(row, prefix + '.pair_invalid')
    nonmono = boolean(row, prefix + '.nonmonotonic')
    if expected_job is not None:
        need(invalid or (job == expected_job and begin is not None and end is not None), 'unflagged invalid Worker pair')
        need(nonmono == (usable(begin) and usable(end) and end['value'] < begin['value']), 'incorrect nonmonotonic flag')
    return dict(job=job, begin=begin, end=end, pair_invalid=invalid, nonmonotonic=nonmono)

def identity(row, prefix):
    # The immutable descriptor, slot incarnation, ordinal and count distinguish
    # reuse; a numeric job alone is never sufficient to assert a complete chain.
    result = {}
    widths = {'slot':16, 'handle.index':16, 'handle.generation':64, 'ordinal':64, 'count':32}
    for name, bits in widths.items(): result[name] = uint(row, prefix + '.' + name, bits)
    for name in ('job','asset','generation','transport_epoch','group','layer','loop_epoch','target_cursor','realize_frame'):
        result['descriptor.' + name] = uint(row, prefix + '.descriptor.' + name)
    op = field(row, prefix + '.descriptor.operation')
    need(op in ('prefetch','decode','seek'), 'unknown job operation')
    need(uint(row, prefix + '.descriptor.operation.code') == {'prefetch':1,'decode':2,'seek':3}[op], 'job operation code')
    result['descriptor.operation'] = op
    return result

def tokens(line):
    need('.{' not in line and '...' not in line and '…' not in line, 'abbreviated diagnostic text')
    words = line.split()
    row = {}
    for word in words[1:]:
        need(word.count('=') == 1, 'non-flat diagnostic token')
        key, value = word.split('=')
        need(re.fullmatch(r'[A-Za-z0-9_.\[\]]+', key) is not None and value != '', 'invalid token')
        need(key not in row, 'duplicate key: ' + key)
        row[key] = value
    need(uint(row, 'schema') == 1, 'unsupported schema')
    for key in row:
        if key.endswith('.present'): present(row, key[:-8])
    return words[0], row

def group_report(group):
    tail, meta = group['tail'], group['meta']
    need(meta is not None, 'missing DEFAULT_HOST_TIMING')
    for role in ('control','worker'):
        rows = group[role]
        cap = uint(tail, role + '_capacity')
        retained = uint(tail, role + '_retained')
        nxt = uint(tail, role + '_next')
        overwritten = uint(tail, role + '_overwritten')
        boolean(tail, role + '_counter_exhausted')
        need(cap == (256 if role == 'control' else 128) and retained <= cap, 'tail capacity')
        need(len(rows) == retained and nxt >= retained, 'tail missing event rows')
        need([r['ordinal'] for r in rows] == list(range(nxt-retained, nxt)), 'tail ordinal coverage')
        need(overwritten <= nxt, 'tail overwritten bound')
    samples = Counter()
    def count(s):
        samples['absent' if s is None else 'unavailable' if not s['available'] else 'error' if s['error_code'] else 'usable'] += 1
    queued, running, completed, accepted = {}, {}, {}, {}
    for row in group['control']:
        count(row['clock'])
        if row['kind'] == 'queued':
            job = row['identity']['descriptor.job']; need(job not in queued, 'duplicate retained queued job'); queued[job] = row
        elif row['kind'] == 'accepted':
            job = row['identity']['descriptor.job']; need(job not in accepted, 'duplicate retained accepted job'); accepted[job] = row
    bad_pairs = nonmono = 0
    for row in group['worker']:
        job = row['job']
        dest = running if row['kind'] == 'running' else completed
        need(job not in dest, 'duplicate retained Worker stage'); dest[job] = row
        if row['timing'] is not None:
            value = row['timing']; count(value['begin']); count(value['end'])
            bad_pairs += value['pair_invalid']; nonmono += value['nonmonotonic']
    chains = []; mismatches = []; orphan = []
    for job in sorted(set(queued) | set(running) | set(completed) | set(accepted)):
        missing = [name for name, table in [('queued',queued),('running',running),('completed',completed),('accepted',accepted)] if job not in table]
        if missing: orphan.append(dict(job=job, missing=missing)); continue
        q, r, c, a = queued[job], running[job], completed[job], accepted[job]
        if not (q['identity'] == r['identity'] == a['identity']):
            mismatches.append(job); continue
        pair = c['timing']
        if pair is None or pair['pair_invalid'] or pair['job'] != job:
            orphan.append(dict(job=job, missing=['valid_completed_pair'])); continue
        valid = all(usable(s) for s in (q['clock'],pair['begin'],pair['end'],a['clock'])) and not pair['nonmonotonic']
        item = dict(job=job, identity=q['identity'], queue_ordinal=q['ordinal'], running_ordinal=r['ordinal'],
                    completed_ordinal=c['ordinal'], accepted_ordinal=a['ordinal'], samples_usable=valid,
                    queue_sample=q['clock'], begin_sample=pair['begin'], end_sample=pair['end'], accepted_sample=a['clock'])
        if valid:
            item['sample_deltas_ns'] = dict(begin_minus_post_queue=pair['begin']['value']-q['clock']['value'],
                end_minus_begin=pair['end']['value']-pair['begin']['value'], acceptance_minus_end=a['clock']['value']-pair['end']['value'])
        chains.append(item)
    return dict(tail=tail, timing=meta, sample_counts=dict(samples), completed_pair_invalid=bad_pairs,
                completed_nonmonotonic=nonmono, complete_chain_count=len(chains),
                usable_chain_count=sum(c['samples_usable'] for c in chains), chains=chains,
                identity_mismatch_jobs=mismatches, retained_chain_orphans=orphan)

def inspect(text):
    groups = []; current = None
    for lineno, line in enumerate(text.splitlines(), 1):
        # Zig's test runner may prefix the first stderr line with test progress.
        positions = [(line.find(p + ' '), p) for p in PREFIXES if p + ' ' in line]
        if not positions: continue
        need(len(positions) == 1, 'interleaved diagnostic markers')
        line = line[positions[0][0]:]
        need(len(line) <= 131072, 'line bound')
        marker, row = tokens(line)
        if marker == 'DEFAULT_HOST_EVENT_TAIL':
            if current is not None: groups.append(group_report(current))
            for name in ('selected_hooks_only','global_order','replay_certificate','supply_return_observer','reached_locals_only','null_availability_not_zero','acceptance_states_coherent','timing_perturbation','incomplete','installed','setup_failed'):
                boolean(row,name)
            for name in ('storage_bytes','worker_lookup_max_slots','acceptance_states_capacity','worker_identity_missing','control_after_failure_omitted'):
                uint(row,name)
            field(row,'acceptance_states_encoding')
            current = dict(tail=row,meta=None,control=[],worker=[])
            continue
        need(current is not None, 'event without tail header')
        if marker == 'DEFAULT_HOST_TIMING':
            need(current['meta'] is None, 'duplicate timing header')
            need(field(row,'timing.units') == 'ns' and uint(row,'timing.units.code') == 0, 'timing units')
            domain = field(row,'timing.domain')
            need(domain in ('linux_monotonic','windows_qpc_scaled','unsupported'), 'clock domain')
            need(uint(row,'timing.domain.code') == ('linux_monotonic','windows_qpc_scaled','unsupported').index(domain), 'clock domain code')
            boolean(row,'timing.clock_available')
            need(not boolean(row,'timing.completeness_asserted'), 'unsupported completeness claim')
            for name in ('post_store_observation_not_store','worker_sample_interval_not_cpu_time','worker_begin_may_precede_queued_observation','no_completion_has_no_clock_sample'):
                need(boolean(row,'timing.'+name), 'missing timing limitation')
            uint(row,'timing.worker_timing_orphans')
            pending = timing(row,'timing.pending_worker_timing')
            before, after, added, control, worker = [uint(row,'timing.'+name) for name in ('storage_before_bytes','storage_after_bytes','storage_added_bytes','control_tail_added_bytes','worker_tail_added_bytes')]
            need(after >= before and after-before == added and added >= control+worker, 'storage delta mismatch')
            need(after == uint(current['tail'],'storage_bytes'), 'storage total mismatch')
            current['meta'] = dict(fields=row,pending_worker_timing=pending,storage_delta=added)
            continue
        ordinal = uint(row,'ordinal')
        if marker == 'DEFAULT_HOST_WORKER_EVENT':
            kind = field(row,'event.kind'); need(kind in ('running','completed'), 'Worker kind')
            need(uint(row,'event.kind.code') == (0 if kind == 'running' else 1), 'Worker kind code')
            job = uint(row,'event.job')
            ident = identity(row,'event.identity') if present(row,'event.identity') else None
            pair = timing(row,'event.timing',job) if present(row,'event.timing') else None
            need(kind != 'running' or pair is None, 'running carries timing')
            need(kind != 'completed' or pair is not None, 'completed missing timing')
            if ident is not None: need(ident['descriptor.job'] == job, 'Worker identity job mismatch')
            current['worker'].append(dict(ordinal=ordinal,kind=kind,job=job,identity=ident,timing=pair))
            continue
        for name in ('accepted_control_frame','control_tick','input_order'): uint(row,'position.'+name)
        clock = sample(row,'observed_clock'); tag = field(row,'event.tag')
        need(tag in ('supply','supply_return','acceptance','public_worker','admission','tick'), 'Control event kind')
        event = dict(ordinal=ordinal,kind=tag,clock=clock)
        if tag == 'supply':
            stage = field(row,'event.supply.point.stage'); uint(row,'event.supply.point.stage.code')
            has_queued = present(row,'event.supply.queued')
            if stage == 'request_queued':
                need(has_queued and clock is not None, 'queued missing identity/clock')
                ident = identity(row,'event.supply.queued')
                need(ident['handle.index'] == uint(row,'event.supply.point.handle.index',16) and ident['handle.generation'] == uint(row,'event.supply.point.handle.generation'), 'queued handle mismatch')
                event.update(kind='queued',identity=ident)
            else: need(not has_queued and clock is None, 'nonqueued timing/identity')
        elif tag == 'acceptance':
            selected = present(row,'event.acceptance.selected')
            accepted = present(row,'event.acceptance.accepted')
            need((clock is not None) == selected, 'acceptance clock/selection mismatch')
            field(row,'event.acceptance.outcome'); uint(row,'event.acceptance.outcome.code')
            if selected:
                ident = identity(row,'event.acceptance.selected.identity')
                if accepted:
                    need(uint(row,'event.acceptance.accepted.worker.job') == ident['descriptor.job'], 'accepted job mismatch')
                    need(uint(row,'event.acceptance.accepted.handle.index',16) == ident['handle.index'] and uint(row,'event.acceptance.accepted.handle.generation') == ident['handle.generation'], 'accepted handle mismatch')
                    event.update(kind='accepted',identity=ident)
            else: need(not accepted, 'accepted without selected')
        else: need(clock is None, 'unexpected Control clock')
        current['control'].append(event)
    need(current is not None, 'no timing diagnostic report')
    groups.append(group_report(current))
    return dict(schema=1,reports=groups,limitations=[
        'Only retained diagnostic rows; overwrite, omission and missing identities limit coverage.',
        'Only timing/association schema is checked; unrelated event payloads are not fully semantically validated.',
        'Post-queue observation is after the real store; Worker begin may precede it. Signed deltas are not rejected.',
        'Worker sample interval is not CPU time, sleep duration, store linearization, Render admission, or underrun causation.',
        'No cross-role global order, native qualification or replay certificate is established.'])


def self_test():
    # Flat formatter-style synthetic fragments, not an engine/tape fixture.
    normal='DEFAULT_HOST_WORKER_EVENT schema=1 ordinal=2 event.kind=completed event.kind.code=1 event.job=7 event.identity.present=false event.identity=null event.timing.present=true event.timing.job.present=true event.timing.job=7 event.timing.begin.present=true event.timing.begin.value=0 event.timing.begin.available=true event.timing.begin.error_code=0 event.timing.end.present=true event.timing.end.value=12 event.timing.end.available=true event.timing.end.error_code=0 event.timing.pair_invalid=false event.timing.nonmonotonic=false'
    _, row=tokens(normal); result=timing(row,'event.timing',7)
    need(result['begin']['value']==0 and usable(result['begin']), 'zero sample lost')
    malformed=[normal.replace(' event.timing.end.error_code=0',''),normal.replace('end.available=true','end.available=1'),normal+' event.job=8',normal+' omitted=.{...}',normal.replace('begin.value=0','begin.value=-1')]
    for text in malformed:
        try:
            _, value=tokens(text); timing(value,'event.timing',7)
        except ValueError: pass
        else: raise AssertionError('malformed synthetic timing accepted')
    absent='DEFAULT_HOST_WORKER_EVENT schema=1 event.timing.job.present=false event.timing.job=null event.timing.begin.present=false event.timing.begin=null event.timing.end.present=false event.timing.end=null event.timing.pair_invalid=true event.timing.nonmonotonic=false'
    _, row=tokens(absent); need(timing(row,'event.timing',7)['pair_invalid'],'missing pair flag')
    return dict(synthetic_cases=7,native_execution=False,scope='lexical, timing fields, missing/error/optional validation; not full report fixture')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log',type=pathlib.Path,nargs='?')
    parser.add_argument('--self-test',action='store_true')
    args=parser.parse_args()
    need(args.self_test != (args.log is not None),'choose log OR --self-test')
    if args.self_test: result=self_test()
    else:
        need(args.log.stat().st_size<=LIMIT,'log bound')
        raw=args.log.read_bytes(); result=inspect(raw.decode('utf-8',errors='strict'))
        result['input_sha256']=hashlib.sha256(raw).hexdigest()
    print(json.dumps(result,indent=2))
