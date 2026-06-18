# Faithful conformance replay: expected RESULTS are never modified. Only the
# REQUEST shape is adapted per LSP method spec (positional vs positions[] vs
# whole-document), so each test actually exercises our server.
import json,subprocess,threading,os,time,sys,glob
RLSRC=os.environ.get("RLSRC", os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor", "ruby-lsp"))
FEATURE=sys.argv[1]; METHOD=sys.argv[2]; SHAPE=sys.argv[3]  # position | positions | document
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
        if "method" in r and "id" not in r: continue
        if r.get("id")==mid: return r.get("result")
def build_params(uri, exp_params, shape):
    pos=None
    for a in (exp_params or []):
        if isinstance(a,dict) and "line" in a: pos=a; break
    base={"textDocument":{"uri":uri}}
    if shape=="document": return base
    if shape=="positions":
        if pos is None: return None
        base["positions"]=[pos]; return base
    if pos is None: return None
    base["position"]=pos; return base
env=dict(os.environ,RUBYLIB="/tmp/prism-src/lib:/tmp/mruby-lsp-new/lib")
p=lsp(env)
req(p,"initialize",{"processId":None,"rootUri":"file:///tmp/parity/ws","capabilities":{"general":{"positionEncodings":["utf-8"]}}},1)
send(p,{"jsonrpc":"2.0","method":"initialized","params":{}}); time.sleep(1.5)
passed=fail=skip=0; fails=[]
for exp in sorted(glob.glob(f"{RLSRC}/test/expectations/{FEATURE}/*.exp.json")):
    name=os.path.basename(exp)[:-len(".exp.json")]
    fix=f"{RLSRC}/test/fixtures/{name}.rb"
    if not os.path.exists(fix): continue
    try: data=json.load(open(exp))
    except: skip+=1; continue
    expected=data.get("result")
    uri=f"file:///tmp/parity/ws/__{name}.rb"
    params=build_params(uri, data.get("params"), SHAPE)
    if params is None: skip+=1; continue
    src=open(fix).read()
    send(p,{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"ruby","version":1,"text":src}}}); time.sleep(0.15)
    got=req(p,METHOD,params,1000)
    send(p,{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":uri}}})
    if json.loads(json.dumps(got))==expected: passed+=1
    else: fail+=1; fails.append((name,expected,got))
print(f"{FEATURE}: PASS {passed}  FAIL {fail}  SKIP {skip}")
for (name,exp,got) in fails[:int(sys.argv[4]) if len(sys.argv)>4 else 2]:
    print(f"  FAIL {name}")
    print(f"    exp: {json.dumps(exp)[:150]}")
    print(f"    got: {json.dumps(got)[:150]}")
p.terminate()
