import json, subprocess, threading, os, time, sys
class LSP:
    def __init__(s,cmd,cwd,env):
        s.p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd=cwd,env=env)
        s.err=[]; threading.Thread(target=s._d,daemon=True).start()
    def _d(s):
        for l in s.p.stderr: s.err.append(l.decode(errors="replace"))
    def _s(s,o):
        d=json.dumps(o).encode(); s.p.stdin.write(f"Content-Length: {len(d)}\r\n\r\n".encode()+d); s.p.stdin.flush()
    def _r(s):
        h={}
        while True:
            ln=s.p.stdout.readline()
            if not ln: return None
            ln=ln.decode().strip()
            if ln=="": break
            k,_,v=ln.partition(":"); h[k.strip().lower()]=v.strip()
        return json.loads(s.p.stdout.read(int(h["content-length"])))
    def req(s,m,p,mid):
        s._s({"jsonrpc":"2.0","id":mid,"method":m,"params":p})
        while True:
            r=s._r()
            if r is None: return None
            if "method" in r and "id" not in r: continue
            if r.get("id")==mid: return r.get("result")
    def notify(s,m,p): s._s({"jsonrpc":"2.0","method":m,"params":p})
cwd="/tmp/parity/ws"
env=dict(os.environ, RUBYLIB="/tmp/prism-src/lib:/tmp/mruby-lsp-new/lib")
c=LSP(["ruby","/tmp/parity/ours_launch.rb",cwd],cwd,env)
c.req("initialize",{"processId":None,"rootUri":f"file://{cwd}","capabilities":{}},1)
c.notify("initialized",{})
time.sleep(2)
text=open("/tmp/parity/ws/foo.rb").read()
c.notify("textDocument/didOpen",{"textDocument":{"uri":"file:///tmp/parity/ws/foo.rb","languageId":"ruby","version":1,"text":text}})
time.sleep(1)
for mid,(ln,ch) in enumerate([(7,9),(0,6)],start=40):
    r=c.req("textDocument/hover",{"textDocument":{"uri":"file:///tmp/parity/ws/foo.rb"},"position":{"line":ln,"character":ch}},mid)
    v=(r or {}).get("contents",{}) if r else {}
    val=v.get("value","") if isinstance(v,dict) else (v or "")
    print(f"@ {ln},{ch}: {'EMPTY' if not val else repr(val)}")
c.p.terminate()
print("ERR:", "".join(c.err[-12:]), file=sys.stderr)
