#!/usr/bin/env python3
"""Synthetic transport/decoder checks only, never native retry evidence."""
import importlib.util, pathlib, hashlib, struct, json
p=pathlib.Path(__file__).with_name('inspect_retry_tape.py')
s=importlib.util.spec_from_file_location('inspector',p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
def default(t):
    if t.startswith('?'):return None
    if t.startswith('u') and t[1:].isdigit():return 0
    if t=='bool':return False
    if t=='hash':return '00'*32
    if t=='error':return 'InvalidState'
    if t in m.ENUMS:return next(iter(m.ENUMS[t].values()))
    if t=='WorkerInput':return {'position':default('Position'),'payload':{'worker':default('Worker')}}
    return {k:default(v) for k,v in m.SCHEMA[t]}
def enc(t,v):
    if t.startswith('?'):return bytes([v is not None])+(enc(t[1:],v) if v is not None else b'')
    if t.startswith('u') and t[1:].isdigit():return v.to_bytes(int(t[1:])//8,'little')
    if t=='bool':return bytes([v])
    if t=='hash':return bytes.fromhex(v)
    if t=='error':return len(v).to_bytes(2,'little')+v.encode()
    if t in m.ENUMS:return enc('u64',next(k for k,x in m.ENUMS[t].items() if x==v))
    if t=='WorkerInput':return enc('Position',v['position'])+enc('u64',2)+enc('Worker',v['payload']['worker'])
    return b''.join(enc(kind,v[name]) for name,kind in m.SCHEMA[t])
def frame(ordinal,fam,cls,payload):
    return b'EVT1'+struct.pack('<IBBHIQII',64+len(payload),0,cls,fam,0,ordinal,len(payload),0)+m.sha(payload)+payload
attempts=[]
for occ in (1,2):
 a=default('Acceptance');a['occurrence']=occ;a['attempt']['evidence']['selected']=default('Selected')
 if occ==1:
  a['attempt']['deferred']=default('Defer');a['attempt']['deferred']['sequence_before']=1057
 else:
  a['attempt']['evidence']['accepted']=default('Accepted');a['attempt']['evidence']['publication']=default('Descriptor')
  a['attempt']['evidence']['outcome']='accepted';a['attempt']['evidence']['effects']['pcm_published']=True;a['attempt']['evidence']['effects']['publication_published']=True
 attempts.append(a)
body=b''
for i,a in enumerate(attempts):
 body+=frame(2*i+1,9,0,struct.pack('<QQH',a['occurrence'],110,0))
 body+=frame(2*i+2,110,1,enc('Acceptance',a))
length=192+len(body)+184
h=b'SMELSB01'+struct.pack('<HHHHQIHH',9,2,192,0,length,65536,4,0)+bytes(128);h+=m.sha(h)
t=b'SMELEND1'+struct.pack('<BBHIQQ',1,15,0,184,length,4)+struct.pack('<12Q',4,0,0,0,2,0,0,0,2,0,0,0)+struct.pack('<Q',len(body))+bytes(16)
b=h+body+t;b+=m.sha(b)
r=m.inspect(b);assert r['same_incoming_adjacent_success_count']==1
for pair in r['pairs']:
 for key in ('first','second'):
  a=pair[key];o=a['selected_pcm_hash_offset'];assert b[o:o+32]==bytes.fromhex(a['attempt']['evidence']['selected']['content_hash'])
for pos in (0,160,200,len(b)-1):
 c=bytearray(b);c[pos]^=1
 try:m.inspect(c)
 except ValueError:pass
 else:raise AssertionError('corruption accepted')
print(json.dumps({'synthetic_only':True,'canonical_pair_decoded':True,'exact_selected_hash_offsets':True,'four_corruptions_rejected':True,'native_coverage':False}))
