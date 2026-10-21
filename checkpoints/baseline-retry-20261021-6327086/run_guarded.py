#!/usr/bin/env python3
"""One bounded qualification stage; records unknown interruption, never retries."""
import argparse,hashlib,json,os,shutil,signal,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--out',required=True);p.add_argument('--seconds',type=int,default=600);p.add_argument('command',nargs=argparse.REMAINDER);a=p.parse_args()
r=Path(a.repo).resolve();out=Path(a.out).resolve();out.mkdir(parents=True,exist_ok=False);cmd=a.command;cmd=cmd[1:] if cmd[:1]==['--'] else cmd
assert cmd and a.seconds>0
floor=2*1024**3+128*1024**2

def source():
 names=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard'],cwd=r,text=True).splitlines()
 return {n:hashlib.sha256((r/n).read_bytes()).hexdigest() for n in sorted(set(names)) if (r/n).is_file()}
def write(name,value):
 tmp=out/(name+'.tmp');tmp.write_text(json.dumps(value,ensure_ascii=False,indent=2));tmp.replace(out/name)
def processes(pid):
 rows=[x.split(None,5) for x in subprocess.check_output(['ps','-eo','pid=,ppid=,etime=,time=,pcpu=,args='],text=True).splitlines()];keep={pid}
 while True:
  added={int(x[0]) for x in rows if int(x[1]) in keep}-keep
  if not added:break
  keep|=added
 return [x for x in rows if int(x[0]) in keep]
before=source();write('source-before.json',before);env=os.environ.copy();env['ZIG_GLOBAL_CACHE_DIR']=str(r.parent/'cache/global')
write('command.json',{'argv':cmd,'cwd':str(r),'timeout_seconds':a.seconds,'free_disk_floor':floor,'environment':{k:v for k,v in env.items() if k.startswith(('SME_','ZIG_'))}})
if shutil.disk_usage(r).free<floor+1024**3:raise SystemExit('insufficient starting disk margin')
start=time.monotonic();reason=None;minimum=shutil.disk_usage(r).free;last=0
with (out/'raw.log').open('wb') as log:
 child=subprocess.Popen(cmd,cwd=r,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True);write('process.json',{'pid':child.pid,'pgid':child.pid,'result':'pending'})
 while child.poll() is None:
  elapsed=time.monotonic()-start;free=shutil.disk_usage(r).free;minimum=min(minimum,free)
  if elapsed-last>=10:
   write('progress.json',{'elapsed_seconds':elapsed,'free_bytes':free,'log_bytes':(out/'raw.log').stat().st_size,'process_tree':processes(child.pid)});last=elapsed
  if elapsed>a.seconds or free<floor:
   reason='timeout' if elapsed>a.seconds else 'disk floor';os.killpg(child.pid,signal.SIGTERM)
   try:child.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
   break
  time.sleep(1)
 code=child.wait()
after=source();write('source-after.json',after);result={'exit':code,'stop_reason':reason,'elapsed_seconds':time.monotonic()-start,'source_guard_equal':before==after,'minimum_free_bytes':minimum};write('result.json',result);print(json.dumps(result),flush=True)
