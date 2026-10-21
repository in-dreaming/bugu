#!/usr/bin/env python3
"""Read-only bounded Host wait association report; not sleep/causality proof."""
import argparse
import hashlib
import json
import pathlib
from collections import Counter
import inspect_timing_output as old
from inspect_timing_output import need, field, uint, boolean, present, tokens, usable

DEPENDENCY_SHA = 'adde6e15ce383e5ba1ecda9339fb292c71ea57d4be1e7458cd0fed9878648c6f'
ROLES = ('control','worker')
REASONS = ('startup','burst_budget','claim_deferred','park','gate_error','control_turn')
MARKERS = ('DEFAULT_HOST_EVENT_TAIL','DEFAULT_HOST_WORKER_EVENT',
           'DEFAULT_HOST_WAIT_TAIL','DEFAULT_HOST_WAIT_EVENT','DEFAULT_HOST_WAIT_STORAGE')

def enum(row,key,names):
    value=field(row,key)
    need(value in names and uint(row,key+'.code') == names.index(value), 'enum mismatch: '+key)
    return value

def observation(row,key):
    if not present(row,key): return None
    p=key+'.point'; s=key+'.sample'
    point=dict(role=enum(row,p+'.role',ROLES),edge=enum(row,p+'.edge',('before','after')),
               reason=enum(row,p+'.reason',REASONS),calls=uint(row,p+'.calls',8),
               worked=uint(row,p+'.worked',8),failed=uint(row,p+'.failed',8),
               deferred=boolean(row,p+'.deferred'),requested_ms=uint(row,p+'.requested_ms',8))
    need(point['calls']<=4 and point['worked']+point['failed']<=point['calls'], 'burst counts')
    need(point['requested_ms'] in (1,16), 'unsupported requested wait')
    ready=boolean(row,s+'.clock_ready')
    clock=dict(value=uint(row,s+'.clock.value'),available=boolean(row,s+'.clock.available'),error_code=uint(row,s+'.clock.error_code',32))
    if not ready: need(clock==dict(value=0,available=False,error_code=0), 'early sample claimed clock access')
    return dict(point=point,clock_ready=ready,clock=clock)

def pair(row,prefix,role,pending=False):
    ident=uint(row,prefix+'.id') if present(row,prefix+'.id') else None
    before,after=observation(row,prefix+'.before'),observation(row,prefix+'.after')
    flags={n:boolean(row,prefix+'.'+n) for n in ('missing_before','missing_after','metadata_mismatch','pair_invalid','nonmonotonic')}
    for value,edge in ((before,'before'),(after,'after')):
        if value is not None: need(value['point']['role']==role and value['point']['edge']==edge,'pair role/edge')
    mismatch=False
    if before and after:
        lhs=dict(before['point']); rhs=dict(after['point']); lhs.pop('edge');rhs.pop('edge')
        mismatch=lhs!=rhs
    nonmono=bool(before and after and before['clock_ready'] and after['clock_ready'] and usable(before['clock']) and usable(after['clock']) and after['clock']['value']<before['clock']['value'])
    if pending:
        need(before is not None and after is None and not any(flags.values()), 'invalid pending representation')
    else:
        need(flags['missing_before']==(before is None) and flags['missing_after']==(after is None), 'missing edge flags')
        need(flags['metadata_mismatch']==mismatch and flags['nonmonotonic']==nonmono,'pair flags mismatch')
        need(flags['pair_invalid']==(before is None or after is None or mismatch or ident is None),'pair_invalid mismatch')
    valid=bool(not pending and not flags['pair_invalid'] and not flags['nonmonotonic'] and before and after and before['clock_ready'] and after['clock_ready'] and usable(before['clock']) and usable(after['clock']))
    return dict(id=ident,before=before,after=after,flags=flags,valid=valid)

def interval_summary(begin,end,waits):
    # Negative deltas remain observations, never fabricated zero durations.
    delta=end-begin
    if delta<0: return dict(observed_interval_ns=delta,negative_interval=True,wait_overlap_ns=None,overlapping_wait_ids=[])
    spans=[];ids=[]
    for item in waits:
        if not item['valid']: continue
        left=max(begin,item['before']['clock']['value']);right=min(end,item['after']['clock']['value'])
        if right>left: spans.append((left,right));ids.append(item['id'])
    merged=[]
    for left,right in sorted(spans):
        if merged and left<=merged[-1][1]: merged[-1]=(merged[-1][0],max(right,merged[-1][1]))
        else: merged.append((left,right))
    return dict(observed_interval_ns=delta,negative_interval=False,wait_overlap_ns=sum(b-a for a,b in merged),overlapping_wait_ids=ids)

def stats(values):
    return dict(count=len(values),minimum=min(values) if values else None,maximum=max(values) if values else None,
                total=sum(values) if values else None)

def inspect(text):
    timing_reports=old.inspect(text)['reports']
    groups=[];current=None
    for line in text.splitlines():
        hits=[(line.find(m+' '),m) for m in MARKERS if m+' ' in line]
        if not hits: continue
        need(len(hits)==1,'interleaved wait markers')
        line=line[hits[0][0]:];need(len(line)<=131072,'line bound')
        marker,row=tokens(line)
        if marker=='DEFAULT_HOST_EVENT_TAIL':
            current=dict(tails={},events={r:[] for r in ROLES},storage=None,completed=[])
            groups.append(current);continue
        need(current is not None,'wait event before native report')
        if marker=='DEFAULT_HOST_WORKER_EVENT':
            if field(row,'event.kind')=='completed':
                need(present(row,'event.timing'),'completed missing timing')
                job=uint(row,'event.job');value=old.timing(row,'event.timing',job)
                current['completed'].append(dict(job=job,ordinal=uint(row,'ordinal'),timing=value))
            continue
        if marker=='DEFAULT_HOST_WAIT_STORAGE':
            need(current['storage'] is None,'duplicate wait storage')
            values={n:uint(row,'storage.'+n) for n in ('before_bytes','after_bytes','added_bytes','pair_tails_bytes','control_capacity','worker_capacity','wait_capacity_per_role')}
            need(values['after_bytes']>=values['before_bytes'] and values['after_bytes']-values['before_bytes']==values['added_bytes'],'wait storage delta')
            need(values['added_bytes']>=values['pair_tails_bytes'] and (values['control_capacity'],values['worker_capacity'],values['wait_capacity_per_role'])==(256,128,64),'wait storage/capacity')
            current['storage']=values;continue
        role=field(row,'role');need(role in ROLES,'wait role')
        if marker=='DEFAULT_HOST_WAIT_TAIL':
            need(role not in current['tails'],'duplicate role tail')
            values={n:uint(row,'wait.'+n) for n in ('capacity','retained','next','overwritten','next_id')}
            values.update({n:boolean(row,'wait.'+n) for n in ('tail_counter_exhausted','id_exhausted')})
            need(values['capacity']==64 and values['retained']<=64 and values['next']>=values['retained'],'wait tail capacity')
            need(not boolean(row,'wait.completeness_asserted') and boolean(row,'wait.interval_not_pure_sleep') and boolean(row,'wait.after_not_sleep_success'),'wait limitations')
            enum(row,'wait.units',('ns',))
            values['pending']=pair(row,'wait.pending',role,True) if present(row,'wait.pending') else None
            current['tails'][role]=values
        else:
            need(role in current['tails'],'event before role tail')
            value=pair(row,'pair',role);value['ordinal']=uint(row,'ordinal')
            current['events'][role].append(value)
    need(len(groups)==len(timing_reports),'report grouping')
    reports=[]
    for group,legacy in zip(groups,timing_reports):
        need(set(group['tails'])==set(ROLES) and group['storage'] is not None,'missing role/storage')
        need(group['storage']['after_bytes']==int(legacy['tail']['storage_bytes']),'cross-report storage')
        coverage={};wait_stats={}
        for role in ROLES:
            tail=group['tails'][role];events=group['events'][role]
            need(len(events)==tail['retained'] and [v['ordinal'] for v in events]==list(range(tail['next']-tail['retained'],tail['next'])),'wait retained coverage')
            ids=[v['id'] for v in events if v['id'] is not None]
            need(all(a<b for a,b in zip(ids,ids[1:])) and all(i<tail['next_id'] for i in ids),'wait id order')
            counts=Counter();durations=[];ratios=[];reasons=Counter()
            for value in events:
                for name,flag in value['flags'].items(): counts[name]+=flag
                counts['valid']+=value['valid']
                for side in ('before','after'):
                    obs=value[side]
                    category='missing' if obs is None else 'clock_not_ready' if not obs['clock_ready'] else 'unavailable' if not obs['clock']['available'] else 'clock_error' if obs['clock']['error_code'] else 'usable'
                    counts[category]+=1
                if value['valid']:
                    point=value['before']['point'];reasons[point['reason']]+=1
                    duration=value['after']['clock']['value']-value['before']['clock']['value'];durations.append(duration)
                    ratios.append(dict(id=value['id'],reason=point['reason'],requested_ms=point['requested_ms'],observed_interval_ns=duration,calls=point['calls'],worked=point['worked'],failed=point['failed'],deferred=point['deferred']))
            coverage[role]=dict(capacity=tail['capacity'],retained=tail['retained'],overwritten=tail['overwritten'],tail_counter_exhausted=tail['tail_counter_exhausted'],id_exhausted=tail['id_exhausted'],pending=tail['pending'] is not None,counts=dict(counts))
            wait_stats[role]=dict(observed_ns=stats(durations),reasons=dict(reasons),largest_observed=sorted(ratios,key=lambda v:v['observed_interval_ns'],reverse=True)[:8])
        gaps=[]
        for first,second in zip(group['completed'],group['completed'][1:]):
            x,y=first['timing'],second['timing']
            if x['pair_invalid'] or y['pair_invalid'] or x['nonmonotonic'] or y['nonmonotonic'] or not usable(x['end']) or not usable(y['begin']): continue
            gaps.append(dict(previous_job=first['job'],next_job=second['job'],**interval_summary(x['end']['value'],y['begin']['value'],group['events']['worker'])))
        accepted=[]
        for chain in legacy['chains']:
            if chain['samples_usable']:
                accepted.append(dict(job=chain['job'],**interval_summary(chain['end_sample']['value'],chain['accepted_sample']['value'],group['events']['control'])))
        reports.append(dict(storage=group['storage'],coverage=coverage,wait_summary=wait_stats,
                            worker_gap_count=len(gaps),largest_worker_gaps=sorted(gaps,key=lambda v:v['observed_interval_ns'],reverse=True)[:8],
                            negative_worker_gaps=sum(v['negative_interval'] for v in gaps),
                            complete_job_chains=legacy['complete_chain_count'],usable_job_chains=legacy['usable_chain_count'],
                            control_acceptance_interval_count=len(accepted),negative_control_intervals=sum(v['negative_interval'] for v in accepted),largest_control_acceptance_intervals=sorted(accepted,key=lambda v:v['observed_interval_ns'],reverse=True)[:8]))
    return dict(schema=1,reports=reports,limitations=[
        'Intervals include callback/clock sampling overhead, blocking and rescheduling; after does not prove successful sleep.',
        'Retained tails only. Missing, erroneous, early and overwritten samples do not become zero.',
        'Worker gaps are between adjacent retained completed-job observations, not a complete global schedule.',
        'Control acceptance associations require the earlier inspector full immutable identity chain.',
        'Overlap is observed clock-domain interval association, not a causal explanation, CPU time or pure kernel sleep.',
        'No engine execution, replay, OS-timer attribution, throughput guarantee or underrun fix is established.'])

def self_test():
    def make(ready=True,end=20):
        row={'schema':'1','pair.id.present':'true','pair.id':'0'}
        for side,value in [('before',10),('after',end)]:
            key='pair.'+side;row[key+'.present']='true'
            for name,tag,code in [('role','worker',1),('edge',side,0 if side=='before' else 1),('reason','burst_budget',1)]:
                row[key+'.point.'+name]=tag;row[key+'.point.'+name+'.code']=str(code)
            for name,value_ in [('calls',4),('worked',4),('failed',0),('requested_ms',1)]:row[key+'.point.'+name]=str(value_)
            row[key+'.point.deferred']='false';row[key+'.sample.clock_ready']=str(ready).lower()
            row[key+'.sample.clock.value']=str(value if ready else 0);row[key+'.sample.clock.available']=str(ready).lower();row[key+'.sample.clock.error_code']='0'
        for name in ('missing_before','missing_after','metadata_mismatch','pair_invalid','nonmonotonic'):row['pair.'+name]='false'
        row['pair.nonmonotonic']=str(ready and end<10).lower()
        return 'DEFAULT_HOST_WAIT_EVENT '+' '.join(k+'='+v for k,v in row.items())
    line=make();_,row=tokens(line);need(pair(row,'pair','worker')['valid'],'valid pair')
    _,row=tokens(make(False));need(not pair(row,'pair','worker')['valid'],'early clock')
    _,row=tokens(make(True,9));need(pair(row,'pair','worker')['flags']['nonmonotonic'],'negative pair')
    need(interval_summary(20,10,[])['wait_overlap_ns'] is None,'negative gap replaced with zero')
    for bad in [line.replace('pair.after.sample.clock.error_code=0',''),line.replace('point.worked=4','point.worked=-1'),line+' pair.id=2',line+' omitted=.{...}']:
        try:
            _,row=tokens(bad);pair(row,'pair','worker')
        except ValueError:pass
        else:raise AssertionError('malformed pair accepted')
    return dict(synthetic_cases=8,native_execution=False,full_log_qualification=False)

if __name__=='__main__':
    need(hashlib.sha256(pathlib.Path(old.__file__).read_bytes()).hexdigest()==DEPENDENCY_SHA,'fixed timing dependency SHA mismatch')
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('log',type=pathlib.Path,nargs='?');p.add_argument('--self-test',action='store_true');a=p.parse_args()
    need(a.self_test!=(a.log is not None),'choose log OR --self-test')
    if a.self_test:report=self_test()
    else:
        need(a.log.stat().st_size<=old.LIMIT,'log size bound');raw=a.log.read_bytes()
        report=inspect(raw.decode('utf-8',errors='strict'));report['input_sha256']=hashlib.sha256(raw).hexdigest()
    print(json.dumps(report,indent=2))
