#!/usr/bin/env python3
"""Generate docs/media/demo.gif (the README demo): a VS Code-looking\nwalkthrough of mruby-lsp completion -> hover -> go-to-definition into C source.\nUsage: pip install Pillow && python3 docs/media/gen_demo.py\nEdit the SCENE blocks below to change content/pacing (durations are in ms)."""
# Render a VS Code-looking animated GIF demoing mruby-lsp:
# completion -> hover -> go-to-definition into C source. Paced slowly.
from PIL import Image, ImageDraw, ImageFont

W, H = 940, 564
FD = "/usr/share/fonts/truetype/dejavu/"
mono   = ImageFont.truetype(FD + "DejaVuSansMono.ttf", 18)
mono_s = ImageFont.truetype(FD + "DejaVuSansMono.ttf", 15)
ui     = ImageFont.truetype(FD + "DejaVuSans.ttf", 14)
ui_b   = ImageFont.truetype(FD + "DejaVuSans-Bold.ttf", 14)
ui_s   = ImageFont.truetype(FD + "DejaVuSans.ttf", 12)

# VS Code dark theme palette
EDITOR=(30,30,30); ACT=(51,51,51); SIDE=(37,37,38); TABBAR=(45,45,45)
STATUS=(0,122,204); GUT=(133,133,133); FG=(212,212,212)
KW=(86,156,214); STR=(206,145,120); COM=(106,153,85); FUNC=(220,220,170)
TYPE=(78,201,176); CONST=(79,193,255); NUM=(181,206,168)
POP=(37,37,38); BORD=(69,69,69); SEL=(9,71,113); ACCENT=(0,122,204)

X0 = 230               # editor left edge (after activity bar + sidebar)
TAB_H = 34
BODY_Y = TAB_H
STATUS_H = 24
GUT_W = 54
TXT_X = X0 + GUT_W
LINE_H = 26
TOP = BODY_Y + 12

def base():
    img = Image.new("RGB", (W, H), EDITOR)
    d = ImageDraw.Draw(img)
    # activity bar
    d.rectangle([0,0,48,H], fill=ACT)
    for i,(c) in enumerate([(180,180,180),(140,140,140),(140,140,140),(140,140,140)]):
        y=18+i*40
        d.rectangle([16,y,32,y+16], outline=c, width=2)
    # sidebar
    d.rectangle([48,0,X0,H], fill=SIDE)
    d.text((64,12), "EXPLORER", font=ui_s, fill=(160,160,160))
    d.text((64,40), "DEMO", font=ui_b, fill=(200,200,200))
    for i,(nm,sel) in enumerate([("app.rb",True),("cbor.rb",False),("build_config.rb",False)]):
        y=66+i*24
        if sel: d.rectangle([48,y-3,X0,y+19], fill=(55,55,58))
        d.text((80,y), nm, font=ui, fill=(212,212,212) if sel else (170,170,170))
    # tab bar
    d.rectangle([X0,0,W,TAB_H], fill=TABBAR)
    return img,d

def tab(d, name, color=FG):
    d.rectangle([X0,0,X0+150,TAB_H], fill=EDITOR)
    d.rectangle([X0,0,X0+150,2], fill=ACCENT)  # active tab top accent
    d.ellipse([X0+12,13,X0+20,21], fill=(80,160,120))
    d.text((X0+30,9), name, font=ui, fill=color)

def status(d, right="Ln 2, Col 8"):
    y=H-STATUS_H
    d.rectangle([0,y,W,H], fill=STATUS)
    d.text((10,y+4), "⎇ mruby-lsp", font=ui_s, fill=(255,255,255))
    d.text((150,y+4), "Ruby", font=ui_s, fill=(255,255,255))
    d.text((W-110,y+4), right, font=ui_s, fill=(255,255,255))

def line(d, n, runs, y, lineno_color=GUT):
    d.text((X0+14, y), str(n), font=mono_s, fill=lineno_color)
    x = TXT_X
    for text,col in runs:
        d.text((x,y), text, font=mono, fill=col)
        x += mono.getlength(text)
    return x

def caret(d, x, y):
    d.rectangle([x+1,y+1,x+2,y+20], fill=(220,220,220))

def caption(d, text, accent=ACCENT):
    y = H - STATUS_H - 40
    d.rectangle([X0+14, y, W-16, y+30], fill=(45,45,48))
    d.rectangle([X0+14, y, X0+18, y+30], fill=accent)
    d.text((X0+30, y+7), text, font=ui, fill=(230,230,230))

def pointer(d, x, y):
    d.polygon([(x,y),(x,y+18),(x+5,y+13),(x+9,y+20),(x+12,y+18),(x+8,y+11),(x+14,y+11)],
              fill=(255,255,255), outline=(20,20,20))

frames=[]; durs=[]
def add(img, ms): frames.append(img.convert("P", palette=Image.ADAPTIVE, colors=128)); durs.append(ms)

# ---- code content (app.rb) ----
def app_lines(d, l2_runs):
    line(d, 1, [('s ',FG),('= ',FG),('"hello"',STR)], TOP)
    last = line(d, 2, l2_runs, TOP+LINE_H)
    return last

def scene_app(l2_runs, cap, right="Ln 2, Col 1", show_caret=True, popup=None, popup_at="s.", hover=False, ptr=None, ms=2200):
    img,d = base(); tab(d,"app.rb"); status(d, right=right)
    last = app_lines(d, l2_runs)
    if show_caret: caret(d, last, TOP+LINE_H)
    if popup is not None: draw_popup(d, popup, int(TXT_X+mono.getlength(popup_at)), TOP+LINE_H+24)
    if hover: draw_hover(d, TXT_X, TOP+LINE_H)
    if cap: caption(d, cap)
    if ptr: pointer(d, *ptr)
    add(img, ms)

def draw_popup(d, sel_idx, px, py):
    rows = [("upcase","string.c"),("upcase!","string.c"),("unpack","string.c")]
    w=304; rh=26; h=rh*len(rows)+6
    d.rectangle([px,py,px+w,py+h], fill=POP, outline=BORD, width=1)
    for i,(name,det) in enumerate(rows):
        ry=py+3+i*rh
        if i==sel_idx: d.rectangle([px+1,ry,px+w-1,ry+rh], fill=SEL)
        d.rectangle([px+8,ry+6,px+22,ry+20], fill=(197,134,192))  # method icon
        d.text((px+18,ry+4), "m", font=ui_s, fill=(30,30,30))
        d.text((px+34,ry+4), name, font=mono_s, fill=FG)
        d.text((px+w-90,ry+5), det, font=ui_s, fill=GUT)

def draw_hover(d, lx, ly):
    # box below the line (line is near the top, so above would clip)
    bw, bh = 430, 116
    bx = lx; by = ly + LINE_H + 6
    d.rectangle([bx,by,bx+bw,by+bh], fill=POP, outline=BORD, width=1)
    d.text((bx+12,by+10), "upcase()", font=mono_s, fill=FUNC)
    d.line([bx+10,by+38,bx+bw-10,by+38], fill=BORD)
    d.text((bx+12,by+46), "String#upcase", font=ui, fill=FG)
    d.text((bx+12+ui.getlength("String#upcase ")+6,by+46), "string.c", font=ui, fill=CONST)
    d.text((bx+12,by+72), "Returns a copy of str with all lowercase", font=ui_s, fill=(190,190,190))
    d.text((bx+12,by+90), "letters replaced by uppercase.", font=ui_s, fill=(190,190,190))

# ===== SCENE 1: intro + typing =====
scene_app([('s',FG)], "Completion · Hover · Go to Definition — from your project's live mruby VM", right="Ln 2, Col 2", ms=2000)
scene_app([('s.',FG)], None, right="Ln 2, Col 3", ms=380)
scene_app([('s.u',FG)], None, right="Ln 2, Col 4", ms=420)
# popup appears at prefix "u" (upcase/upcase!/unpack all match), upcase selected
scene_app([('s.u',FG)], "Completion comes from the compiled VM — only what your build has",
          right="Ln 2, Col 4", popup=0, popup_at="s.",
          ptr=(int(TXT_X+mono.getlength("s."))+40, TOP+LINE_H+24+10), ms=2600)
# accepted
scene_app([('s.',FG),('upcase',FUNC)], "Accepted — String#upcase", right="Ln 2, Col 9", ms=1100)

# ===== SCENE 2: hover =====
def scene_hover(ms=2800):
    img,d = base(); tab(d,"app.rb"); status(d)
    line(d,1,[('s ',FG),('= ',FG),('"hello"',STR)],TOP)
    line(d,2,[('s.',FG),('upcase',FUNC)],TOP+LINE_H)
    draw_hover(d, TXT_X+int(mono.getlength("s.")), TOP+LINE_H)
    pointer(d, TXT_X+int(mono.getlength("s.upc")), TOP+LINE_H+4)
    caption(d, "Hover: the real signature, C source link, and doc")
    add(img, ms)
scene_hover()

# ===== SCENE 3: go to definition into string.c =====
def scene_def(ms=3000):
    img,d = base(); tab(d,"string.c", color=FG); status(d, right="Ln 3099, Col 1")
    cl = [
        (3097, [('/* call-seq: str.upcase -> new_str */',COM)]),
        (3098, [('mrb_value',TYPE)]),
        (3099, [('mrb_str_upcase',FUNC),('(',FG),('mrb_state ',TYPE),('*mrb, ',FG),('mrb_value ',TYPE),('self',FG),(')',FG)]),
        (3100, [('{',FG)]),
        (3101, [('  struct RString ',TYPE),('*s = ',FG),('mrb_str_ptr',FUNC),('(self);',FG)]),
        (3102, [('  ',FG),('return',KW),(' mrb_str_upcase_bang(mrb, s);',FG)]),
        (3103, [('}',FG)]),
    ]
    for i,(n,runs) in enumerate(cl):
        y=TOP+i*LINE_H
        if n==3099: d.rectangle([X0,y-3,W,y+LINE_H-4], fill=(40,48,64))  # current-line highlight
        line(d, n, runs, y, lineno_color=(120,120,120) if n!=3099 else (200,200,200))
    caption(d, "Go to Definition → jumps into string.c (real C source)")
    add(img, ms)
scene_def()

import os
_out=os.path.join(os.path.dirname(os.path.abspath(__file__)),"demo.gif")
frames[0].save(_out, save_all=True,
               append_images=frames[1:], duration=durs, loop=0, optimize=True, disposal=2)
print("frames:", len(frames), "total ms:", sum(durs))
