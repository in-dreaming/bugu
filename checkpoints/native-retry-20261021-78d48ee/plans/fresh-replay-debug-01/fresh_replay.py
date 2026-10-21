#!/usr/bin/env python3
"""One exact executable fresh process; preserve identity before and after."""
import hashlib,json,os,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve();expected=json.loads(Path(sys.argv[2]).read_text())
def identities():return {n:hashlib.sha256((root/n).read_bytes()).hexdigest() for n in expected}
before=identities();assert before==expected,'artifact identity mismatch before native replay'
env={k:v for k,v in os.environ.items() if not k.startswith('SME_LIVE_SEMANTIC_')};env.update(SME_LIVE_SEMANTIC_MODE='replay',SME_LIVE_SEMANTIC_WORKLOAD='retry',SME_LIVE_SEMANTIC_DIR=str(root))
code=subprocess.call([str(root/'exact-process-elf')],env=env)
after=identities();result={'native_exit':code,'before':before,'after':after,'identity_unchanged':before==after};(root/'fresh-identity-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
raise SystemExit(code if before==after else 99)
