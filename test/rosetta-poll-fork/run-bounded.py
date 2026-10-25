import json,os,signal,subprocess,sys,threading,time
from pathlib import Path
name,seconds,*cmd=sys.argv[1:]
started=time.time(); log=Path(name+".log").open("wb")
p=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
def drain():
 for line in iter(p.stdout.readline,b""):
  log.write(line);log.flush();sys.stdout.buffer.write(line);sys.stdout.buffer.flush()
t=threading.Thread(target=drain,daemon=True);t.start();timed_out=False
try:rc=p.wait(timeout=float(seconds))
except subprocess.TimeoutExpired:
 timed_out=True;os.killpg(p.pid,signal.SIGTERM)
 try:rc=p.wait(timeout=2)
 except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);rc=p.wait(timeout=2)
t.join(timeout=2);log.close()
r={"command":cmd,"pid":p.pid,"timeoutSeconds":float(seconds),"timedOut":timed_out,"exitCode":rc,"elapsedSeconds":time.time()-started,"outputReaderDone":not t.is_alive()}
Path(name+".json").write_text(json.dumps(r,indent=2)+"\n");print(json.dumps(r),flush=True)
sys.exit(rc if not timed_out else 124)
