#!/usr/bin/env python3
"""Create one local negative fixture; never change original INPUT or scheduling."""
import argparse,hashlib,json,pathlib,struct
p=argparse.ArgumentParser();p.add_argument('--original',required=True);p.add_argument('--output',required=True);a=p.parse_args()
src=pathlib.Path(a.original);dst=pathlib.Path(a.output)
b=bytearray((src/'history.bin').read_bytes());bank=(src/'bank.bin').read_bytes()
assert hashlib.sha256(b).hexdigest()=='3f1162e730513205f18f95bcd4f352e5d70560a16b9b6d90f0f7e4dba7f716a6'
assert hashlib.sha256(bank).hexdigest()=='558609800513d7734313d842245b19b7d6ff4e6039aa170b4824b2ba20a6c224'
assert b[:8]==b'SMELSB01' and struct.unpack_from('<H',b,10)[0]==4
assert b[-184:-176]==b'SMELEND1' and hashlib.sha256(b[:-32]).digest()==b[-32:]
end=len(b)-184;offset=192;chosen=None;frames=0
while offset<end:
 assert b[offset:offset+4]==b'EVT1'
 length=struct.unpack_from('<I',b,offset+4)[0];size=struct.unpack_from('<I',b,offset+24)[0]
 assert length==size+64 and offset+length<=end
 start=offset+64;payload=bytes(b[start:start+size]);assert hashlib.sha256(payload).digest()==b[offset+32:offset+64]
 role=b[offset+8];cls=b[offset+9];family=struct.unpack_from('<H',b,offset+10)[0]
 if chosen is None and role==2 and cls==1 and family==114:
  occurrence,disposition=struct.unpack_from('<QQ',payload,0)
  present=payload[24];assert present in (0,1);head=25+8*present
  channels,samples=struct.unpack_from('<HI',payload,head);head+=6
  assert channels==2 and head+samples*4==len(payload)
  if disposition==0:
   for i in range(samples):
    bits=struct.unpack_from('<I',payload,head+4*i)[0]
    if bits & 0x7fffffff and bits & 0x7f800000 != 0x7f800000:
     at=start+head+4*i;struct.pack_into('<I',b,at,bits^1)
     b[offset+32:offset+64]=hashlib.sha256(b[start:start+size]).digest()
     chosen=dict(role=role,family=family,class_code=cls,occurrence=occurrence,frame_offset=offset,payload_byte=head+4*i,sample_index=i,before_bits=bits,after_bits=bits^1)
     break
 frames+=1;offset+=length
assert offset==end and chosen is not None
b[-32:]=hashlib.sha256(b[:-32]).digest()
dst.mkdir(parents=False,exist_ok=False);(dst/'bank.bin').write_bytes(bank);(dst/'history.bin').write_bytes(b)
report=dict(scope='Only one finite submitted PCM reference sample bit changed; frame and file hashes recomputed. All INPUT frames, scheduling coordinates, bank, counts and original files unchanged.',complete_frames=frames,mutation=chosen,history_bytes=len(b),history_sha256=hashlib.sha256(b).hexdigest(),bank_sha256=hashlib.sha256(bank).hexdigest())
(dst/'mutation.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
