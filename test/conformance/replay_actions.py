# Code actions, both halves: the OFFER (textDocument/codeAction) and the
# RESOLVE (codeAction/resolve). Both vector families carry their request
# params verbatim (uri file:///fake incl. context diagnostics with embedded
# quickfixes), so each vector didOpens its fixture AT that uri and sends the
# recorded params unchanged. Usage:
#   replay_actions.py code_actions          -> textDocument/codeAction
#   replay_actions.py code_action_resolve   -> codeAction/resolve
import json,subprocess,threading,os,time,sys,glob
RLSRC=os.environ.get("RLSRC", os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor", "ruby-lsp"))
FEATURE=sys.argv[1]
METHOD="textDocument/codeAction" if FEATURE=="code_actions" else "codeAction/resolve"
def lsp(env):
    p=subprocess.Popen(["ruby","/tmp/parity/ours_launch.rb","/tmp/parity/ws"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd="/tmp/parity/ws",env=env)
    threading.Thread(target=lambda:[None for _ in p.stderr],daemon=True).start(); return p
def send(p,o):
    d=json.dumps(o).encode(); p.stdin.write(f"Content-Length: {len(d)}\r\n\r\n".encode()+d); p.stdin.flush()
def read(p):
    h={}
    while True:
        ln=p.stdout.readline()
        if not ln: return None
        ln=ln.decode().strip()
        if ln=="": break
        k,_,v=ln.partition(":"); h[k.strip().lower()]=v.strip()
    return json.loads(p.stdout.read(int(h["content-length"])))
def req(p,m,par,mid):
    send(p,{"jsonrpc":"2.0","id":mid,"method":m,"params":par})
    while True:
        r=read(p)
        if r is None: return None
        if "method" in r and "id" in r:
            # server->client request (e.g. the unsandboxed-consent dialog):
            # answer it -- ids are server-numbered and may collide with ours.
            acts=(r.get("params") or {}).get("actions") or []
            res=acts[0] if r["method"]=="window/showMessageRequest" and acts else None
            send(p,{"jsonrpc":"2.0","id":r["id"],"result":res}); continue
        if "method" in r: continue
        if r.get("id")==mid: return r.get("result")
env=dict(os.environ,RUBYLIB="/tmp/prism-src/lib:/tmp/mruby-lsp-new/lib")
p=lsp(env)
req(p,"initialize",{"processId":None,"rootUri":"file:///tmp/parity/ws","capabilities":{"window":{"showMessage":{},"showMessageRequest":{"messageActionItem":{}}},"general":{"positionEncodings":["utf-8"]}}},1)
send(p,{"jsonrpc":"2.0","method":"initialized","params":{}}); time.sleep(1.5)
passed=fail=0; fails=[]
for exp in sorted(glob.glob(f"{RLSRC}/test/expectations/{FEATURE}/*.exp.json")):
    name=os.path.basename(exp)[:-len(".exp.json")]
    fix=f"{RLSRC}/test/fixtures/{name}.rb"
    if not os.path.exists(fix): continue
    vec=json.load(open(exp)); expected=vec.get("result"); params=vec.get("params")
    uri=params.get("textDocument",{}).get("uri") or params.get("data",{}).get("uri") or "file:///fake"
    src=open(fix).read()
    send(p,{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"ruby","version":1,"text":src}}}); time.sleep(0.15)
    got=req(p,METHOD,params,1000)
    send(p,{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":uri}}})
    if json.loads(json.dumps(got))==expected: passed+=1
    else: fail+=1; fails.append((name,expected,got))
print(f"{FEATURE}: PASS {passed}  FAIL {fail}")
for (name,exp_,got) in fails[:4]:
    print(f"  FAIL {name}")
    print(f"    exp: {json.dumps(exp_)[:220]}")
    print(f"    got: {json.dumps(got)[:220]}")
p.terminate()
# A real exit code, not a printed summary a caller has to scrape: any FAIL, or
# a suspiciously empty run (wrong RLSRC / no fixtures matched), is red.
sys.exit(0 if fail==0 and passed>0 else 1)
