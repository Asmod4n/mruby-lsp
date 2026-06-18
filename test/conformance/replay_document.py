# Whole-document features: no position param. Drive didOpen then the request.
import json,subprocess,threading,os,time,sys,glob
RLSRC=os.environ.get("RLSRC", os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor", "ruby-lsp"))
FEATURE=sys.argv[1]; METHOD=sys.argv[2]

# OUT OF SCOPE BY DESIGN: a vector whose fixture is a .rake (or any non-.rb host
# file) tests host-CRuby tooling. There is NO Rake in mruby -- .rake/mrbgem.rake/
# build_config.rb run in host CRuby at build time and never enter the mruby VM,
# our only source of truth. Declining these is correct, not a failure. We detect
# the divergence by fixture extension so it can never silently flip to a FAIL if
# fixture resolution is later widened.
def fixture_for(name):
    rb=f"{RLSRC}/test/fixtures/{name}.rb"
    if os.path.exists(rb): return rb, None
    others=[g for g in glob.glob(f"{RLSRC}/test/fixtures/{name}.*") if not g.endswith(".rb")]
    if others: return None, "out-of-scope: host-tooling fixture (no Rake in mruby): "+os.path.basename(others[0])
    return None, None  # no fixture at all -> unscoreable, silent

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
env=dict(os.environ,RUBYLIB="/tmp/prism-src/lib:/tmp/mruby-lsp-new/lib")
p=lsp(env)
req(p,"initialize",{"processId":None,"rootUri":"file:///tmp/parity/ws","capabilities":{"general":{"positionEncodings":["utf-8"]}}},1)
send(p,{"jsonrpc":"2.0","method":"initialized","params":{}}); time.sleep(1.5)
passed=fail=0; fails=[]; oos=[]
for exp in sorted(glob.glob(f"{RLSRC}/test/expectations/{FEATURE}/*.exp.json")):
    name=os.path.basename(exp)[:-len(".exp.json")]
    fix,reason=fixture_for(name)
    if fix is None:
        if reason: oos.append((name,reason))
        continue
    try: expected=json.load(open(exp)).get("result")
    except: continue
    src=open(fix).read()
    uri=f"file:///tmp/parity/ws/__{name}.rb"
    send(p,{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"ruby","version":1,"text":src}}}); time.sleep(0.2)
    got=req(p,METHOD,{"textDocument":{"uri":uri}},1000)
    send(p,{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":uri}}})
    g=got
    # SEMANTIC: ruby-lsp stores token OBJECTS; our server returns the LSP wire
    # form {data:[flat 5-int groups]}. Decode ours to the same object shape so
    # the comparison is semantic, not shape-coincidental.
    if isinstance(got,dict) and "data" in got:
        d=got["data"]; toks=[]
        for k in range(0,len(d),5):
            toks.append({"delta_line":d[k],"delta_start_char":d[k+1],"length":d[k+2],"token_type":d[k+3],"token_modifiers":d[k+4]})
        g=toks
    if json.loads(json.dumps(g))==expected: passed+=1
    else: fail+=1; fails.append((name,expected,got))
print(f"{FEATURE}: PASS {passed}  FAIL {fail}  OUT-OF-SCOPE {len(oos)}")
for (name,exp,got) in fails[:3]:
    print(f"  FAIL {name}: exp {json.dumps(exp)[:120]} | got {json.dumps(got)[:120]}")
for (name,reason) in oos:
    print(f"  SKIP {name}: {reason}")
p.terminate()
