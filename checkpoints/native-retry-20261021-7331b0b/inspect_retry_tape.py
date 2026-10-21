#!/usr/bin/env python3
"""Read-only profile9/wire2 retry evidence inspector, reconstructed 2026-10-21.
Schema: live_semantic_codec.Encoder.put / CompactAcceptanceEvidence;
streaming/{acceptance_observation,music_stream,ring,visibility}.zig;
music/{trace_schema,trace_readiness,live_semantic_format}.zig.
Not an engine, replay, identity admission, or full semantic preflight validator.
"""
import argparse, hashlib, json, pathlib, struct

def require(ok, message):
    if not ok: raise ValueError(message)
def fields(spec): return [tuple(x.split(':')) for x in spec.split()]
SCHEMA = {
 'Position':fields('accepted_control_frame:u64 control_tick:u64 input_order:u64'),
 'Handle':fields('index:u16 generation:u64'),
 'Cut':fields('sequence:u64 frame:u64 consumed:u64 produced:u64 available:u64'),
 'Defer':fields('reason:DeferReason handle:Handle observed_frame:?u64 sequence_before:?u64 sequence_after:?u64'),
 'Job':fields('job:u64 asset:u64 generation:u64 transport_epoch:u64 operation:Operation group:u64 layer:u64 loop_epoch:u64 target_cursor:u64 realize_frame:u64'),
 'Selected':fields('slot:u16 handle:Handle descriptor:Job ordinal:u64 count:u32 outcome:Readiness failure_code:u16 content_hash:hash'),
 'Availability':fields('attached:bool requested_frame:?u64 sequence_before:?u64 frame:?u64 consumed:?u64 produced:?u64 sequence_after:?u64 available:?u64 error_code:u32'),
 'PublicationCut':fields('head:u64 tail:u64 capacity:u64'),
 'Worker':fields('job:u64 asset:u64 generation:u64 transport_epoch:u64 operation:Operation state:Readiness pcm_start:u64 pcm_end:u64 available_frames:u64 channel_count:u16 content_hash:hash readiness_version:u64 failure_code:u16 group:u64 layer:u64 loop_epoch:u64 target_cursor:u64 realize_frame:u64 job_descriptor_hash:hash'),
 'Coordinate':fields('cursor:u64 loop_epoch:u64'),
 'ReadCut':fields('consumed:u64 produced:u64'),
 'PublishObservation':fields('availability:?ReadCut write:?u64 end:?u64'),
 'Descriptor':fields('version:u16 batch_id:u64 stream_slot:u16 stream_generation:u64 asset:u64 asset_generation:u64 transport_epoch:u64 profile_id:u64 profile_hash:hash publication_ordinal:u64 worker_job:u64 job_descriptor_hash:hash prefix_start:u64 prefix_end:u64 target_cursor:u64 loop_epoch:u64 channels:u8 pcm_hash:hash'),
 'Effects':fields('stale_completion_counted:bool pcm_published:bool publication_published:bool stream_failed:bool stream_cancelled:bool job_released:bool throughput_observation_attempted:bool'),
 'Accepted':fields('input:WorkerInput handle:Handle stale:bool'),
 'Evidence':fields('position:Position batch_id:u64 runtime_attached:bool replay_mode:bool selected:?Selected availability:Availability ring_capacity:?u32 publication_preflight:?PublicationCut publication_commit:?PublicationCut last_batch_id:?u64 next_snapshot:?u64 cancel:?bool stopped:?bool generation:?u64 transport_epoch:?u64 stale:?bool actual_worker:?Worker coordinate:?Coordinate ring_produced:?u64 ring_writable:?ReadCut ring_publish:PublishObservation publication:?Descriptor outcome:Outcome error_code:u32 effects:Effects accepted:?Accepted'),
 'Attempt':fields('incoming:Position cut:?Cut deferred:?Defer evidence:Evidence returned_error:?error'),
 'Acceptance':fields('occurrence:u64 attempt:Attempt effective_frame:u64'),
}
ENUMS = {'DeferReason':{0:'odd_sequence',1:'sequence_changed'}, 'Operation':{1:'prefetch',2:'decode',3:'seek'}, 'Readiness':{1:'not_ready',2:'ready',3:'failed',4:'cancelled'}, 'Outcome':dict(enumerate(['not_started','no_completion','availability_unavailable','ring_capacity','publication_capacity','accepted','failed']))}
class Decoder:
    def __init__(self,b): self.b=b; self.p=0; self.selected_pcm_hash_offset=None
    def raw(self,n):
        require(self.p+n<=len(self.b),'truncated canonical payload')
        v=self.b[self.p:self.p+n]; self.p+=n; return v
    def get(self,t):
        if t.startswith('?'): return self.get(t[1:]) if self.get('bool') else None
        if t in ('u8','u16','u32','u64'): return int.from_bytes(self.raw(int(t[1:])//8),'little')
        if t=='bool':
            v=self.get('u8'); require(v in (0,1),'invalid boolean'); return bool(v)
        if t=='hash': return self.raw(32).hex()
        if t=='error': return self.raw(self.get('u16')).decode('ascii')
        if t in ENUMS:
            v=self.get('u64'); require(v in ENUMS[t],f'invalid enum {t}: {v}'); return ENUMS[t][v]
        if t=='WorkerInput':
            p=self.get('Position'); tag=self.get('u64')
            require(tag==2,'accepted Input must be actual worker variant; unsupported schema otherwise')
            return {'position':p,'payload':{'worker':self.get('Worker')}}
        result={}
        for name,kind in SCHEMA[t]:
            if t=='Selected' and name=='content_hash': self.selected_pcm_hash_offset=self.p
            result[name]=self.get(kind)
        return result
    def finish(self): require(self.p==len(self.b),f'trailing canonical bytes: {len(self.b)-self.p}')
def sha(b): return hashlib.sha256(b).digest()
def records(b):
    require(376<=len(b)<=512*1024*1024,'file bound')
    d=Decoder(b[:192]); require(d.raw(8)==b'SMELSB01','magic')
    require([d.get('u16') for _ in range(4)]==[9,2,192,0],'profile/version/header')
    cap=d.get('u64'); require(len(b)<=cap<=512*1024*1024,'declared file cap')
    require([d.get('u32'),d.get('u16'),d.get('u16')]==[65536,4,0],'header schema')
    identities={k:d.raw(32).hex() for k in ('build','bank','config','source')}
    require(d.raw(32)==sha(b[:160]),'header hash'); d.finish()
    end=len(b)-184; d=Decoder(b[end:]); require(d.raw(8)==b'SMELEND1','footer magic')
    require([d.get('u8'),d.get('u8'),d.get('u16'),d.get('u32')]==[1,15,0,184],'footer status')
    require(d.get('u64')==len(b),'footer length'); total=d.get('u64')
    expected=[[d.get('u64') for _ in range(4)] for _ in range(3)]
    require(d.get('u64')==end-192,'record bytes'); require(d.raw(16)==bytes(16),'footer reserved')
    require(d.raw(32)==sha(b[:-32]),'whole file hash'); d.finish()
    counts=[[0]*4 for _ in range(3)]; result=[]; off=192
    input_families={1,2,3,4,7,8,9,11,12,13,14,15,16,17}
    known=set(range(1,18))|set(range(101,120))
    while off<end:
        d=Decoder(b[off:off+64]); require(d.raw(4)==b'EVT1','record magic')
        size=d.get('u32'); role=d.get('u8'); cls=d.get('u8'); fam=d.get('u16')
        require(role<4 and cls<2 and fam in known,'record role/class/family')
        require(cls==(0 if fam in input_families else 1),'family class')
        require(d.get('u32')==0,'record reserved'); ordinal=d.get('u64'); n=d.get('u32')
        require(d.get('u32')==0,'record reserved2'); digest=d.raw(32); d.finish()
        require(size==64+n and n<=65536 and off+size<=end,'record bounds')
        payload=b[off+64:off+size]; require(sha(payload)==digest,'payload hash')
        require(ordinal==counts[0][role]+1,'role ordinal'); counts[0][role]+=1; counts[1+cls][role]+=1
        result.append((off,role,cls,fam,ordinal,payload)); off+=size
    require(off==end and counts==expected and len(result)==total,'footer count/EOF')
    return identities,result

def inspect(b):
    identities,rs=records(b); attempts=[]; markers={}
    for off,role,cls,fam,ordinal,payload in rs:
        if fam==9:
            d=Decoder(payload); occ=d.get('u64'); family=d.get('u64'); tag=d.get('u16'); d.finish()
            if family==110:
                require(role==0 and tag==0 and occ not in markers,'acceptance marker identity')
                markers[occ]=off
        if fam==110:
            require(role==0,'acceptance role'); d=Decoder(payload); a=d.get('Acceptance'); d.finish()
            a.update(record_offset=off,payload_offset=off+64,role_ordinal=ordinal,selected_pcm_hash_offset=(off+64+d.selected_pcm_hash_offset if d.selected_pcm_hash_offset is not None else None)); attempts.append(a)
    previous=0
    for a in attempts:
        occ=a['occurrence']; require(occ>previous and occ in markers,'acceptance occurrence/marker'); previous=occ
        a['input_marker_record_offset']=markers.pop(occ)
    require(not markers,'missing acceptance reference')
    pairs=[]
    for a,second in zip(attempts,attempts[1:]):
        x,y=a['attempt'],second['attempt']
        if x['deferred'] and x['evidence']['accepted'] is None and x['incoming']==y['incoming'] and y['evidence']['accepted'] is not None:
            sx,sy=x['evidence']['selected'],y['evidence']['selected']
            pairs.append({'first':a,'second':second,'same_selected':sx==sy,'same_selected_job': bool(sx and sy and sx['descriptor']['job']==sy['descriptor']['job']), 'second_pcm_and_publication_effects': y['evidence']['effects']['pcm_published'] and y['evidence']['effects']['publication_published']})
    return {'schema':1,'file_sha256':sha(b).hex(),'identities':identities,'envelope_verified':True,'acceptance_count':len(attempts),'typed_defer_count':sum(a['attempt']['deferred'] is not None for a in attempts),'same_incoming_adjacent_success_count':len(pairs),'pairs':pairs,'limitations':['Read-only reference evidence; does not execute or inject engine state.','Envelope and acceptance schema checked; authoritative Zig Reader/validateInputs identity and full semantic admission still required.','Adjacent means adjacent Control acceptance references, not adjacent global events.','Same selected job and publication effects are reported separately; accepted alone may be stale/cancelled.','No wall-time inference, Windows claim, audio admission claim or fresh replay proof from this report.']}

def main():
    p=argparse.ArgumentParser(); p.add_argument('tape',type=pathlib.Path); p.add_argument('--output',type=pathlib.Path); a=p.parse_args()
    require(a.tape.stat().st_size<=512*1024*1024,'file too large')
    report=inspect(a.tape.read_bytes()); text=json.dumps(report,indent=2)+'\n'
    if a.output:
        require(a.output.resolve()!=a.tape.resolve(),'output must not overwrite tape'); a.output.write_text(text)
    else: print(text,end='')
if __name__=='__main__': main()
