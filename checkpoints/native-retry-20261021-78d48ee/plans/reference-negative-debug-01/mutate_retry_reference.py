#!/usr/bin/env python3
"""Mutate one selected PCM comparison hash; never change execution inputs."""
import argparse, hashlib, importlib.util, json, pathlib, struct
p=pathlib.Path(__file__).with_name('inspect_retry_tape.py');s=importlib.util.spec_from_file_location('inspect_retry',p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
def digest(b):return hashlib.sha256(b).hexdigest()
a=argparse.ArgumentParser();a.add_argument('source',type=pathlib.Path);a.add_argument('destination',type=pathlib.Path);a.add_argument('--occurrence',required=True,type=int);a.add_argument('--expected-sha256',required=True);args=a.parse_args()
m.require(args.source.resolve()!=args.destination.resolve(),'source must be immutable');m.require(not args.destination.exists(),'destination already exists')
b=args.source.read_bytes();m.require(digest(b)==args.expected_sha256,'source hash mismatch');report=m.inspect(b);matches=[p['second'] for p in report['pairs'] if p['second']['occurrence']==args.occurrence];m.require(len(matches)==1,'unique successful retry second occurrence required');entry=matches[0];offset=entry['selected_pcm_hash_offset'];record=entry['record_offset'];m.require(offset is not None,'selected hash missing');length=struct.unpack_from('<I',b,record+4)[0]
c=bytearray(b);before=c[offset];c[offset]^=1;c[record+32:record+64]=hashlib.sha256(c[record+64:record+length]).digest();c[-32:]=hashlib.sha256(c[:-32]).digest();mutant=bytes(c)
mutant_report=m.inspect(mutant);original_records=m.records(b)[1];changed_records=m.records(mutant)[1];m.require(len(original_records)==len(changed_records),'count changed')
changed=[]
for old,new in zip(original_records,changed_records):
 m.require(old[:5]==new[:5],'record identity changed')
 if old[5]!=new[5]:changed.append({'record_offset':old[0],'role':old[1],'class':old[2],'family':old[3],'ordinal':old[4]})
 if old[2]==0 or old[3]==109:m.require(old==new,'Input or Schedule changed')
m.require(changed==[{'record_offset':record,'role':0,'class':1,'family':110,'ordinal':entry['role_ordinal']}],'changed records not exact acceptance reference')
expected_positions={offset}|set(range(record+32,record+64))|set(range(len(b)-32,len(b)))
actual_positions={i for i,(x,y) in enumerate(zip(b,mutant)) if x!=y};m.require(actual_positions<=expected_positions and offset in actual_positions,'unexpected byte changes')
args.destination.parent.mkdir(parents=True,exist_ok=True)
with args.destination.open('xb') as f:f.write(mutant)
m.require(digest(args.source.read_bytes())==args.expected_sha256,'source changed')
manifest={'schema':1,'mutation':'selected.content_hash comparison byte xor1 only; record payload and footer digest recomputed','source':str(args.source.resolve()),'destination':str(args.destination.resolve()),'source_sha256':digest(b),'mutant_sha256':digest(mutant),'script_sha256':digest(pathlib.Path(__file__).read_bytes()),'inspector_sha256':digest(p.read_bytes()),'occurrence':args.occurrence,'record_offset':record,'record_length':length,'selected_pcm_hash_offset':offset,'byte_before':before,'byte_after':c[offset],'changed_records':changed,'changed_byte_count':len(actual_positions),'all_input_and_schedule_records_identical':True,'role_ordinals_counts_identical':True,'envelope_and_acceptance_decoder_verified':True,'native_replay_executed':False,'expected_not_proven':'Zig preflight admits; native comparison fails exactly at the target occurrence and genuine cleanup completes. Python does not establish that result.'}
manifest_path=args.destination.with_suffix('.mutation.json');m.require(not manifest_path.exists(),'manifest already exists');manifest_path.write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest,indent=2))
