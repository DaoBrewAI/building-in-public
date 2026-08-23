# -*- coding: utf-8 -*-
# End-to-end: report HTML -> chunked Chrome print -> merge -> rebuild links -> compress -> verify
#
# Battle-tested template (2026-08-10, direction-portfolio report). ADJUST PER REPORT:
#   SRC_HTML  env var  - path to the canonical report HTML
#   PDF_ZOOM  env var  - print zoom; 0.82 packs pages densely (default HTML at 1.0
#                        leaves big blanks before unbreakable figures)
#   GROUPS             - chunk grouping. Chrome print CRASHES on large SVG-heavy docs,
#                        so print in chunks; but every chunk boundary forces a page
#                        break (= a partial blank page), so make groups AS LARGE AS
#                        PRINT SUCCEEDS. Split only the group that fails.
#   NEEDLES            - unique heading text per internal section anchor (for GoTo
#                        destination lookup; matched with NFKC normalization because
#                        Chrome maps some CJK glyphs to Kangxi radicals)
#   The internal-href regex must cover every in-document anchor pattern used.
import re, json, os, shutil, subprocess, sys, unicodedata

SRC = os.environ.get('SRC_HTML', os.path.expanduser('~/Documents/Daobrew/DaoBrewStrategy/explorations/2026-08-09-direction-portfolio-visual.html'))
OUT = '2026-08-09-direction-portfolio-visual.pdf'
CH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
ZOOM = os.environ.get('PDF_ZOOM', '0.82')

s = open(SRC).read()
s = s.replace('<html lang="zh-CN">', '<html lang="zh-CN" data-theme="light">')
s = s.replace('<details>', '<details open>')
print_css = '''
  @page { size: A4; margin: 8mm 7mm; }
  @media print {
    body { background: #fff; font-size: 12.5px; }
    .wrap { max-width: 100%; padding: 0 2mm 6mm; zoom: ''' + ZOOM + '''; }
    header.doc { padding-top: 6mm; }
    figure, .fig-card, .dir-card, .lack-card, .t-item { break-inside: avoid; }
    tr { break-inside: avoid; }
    section.part { margin-top: 26px; }
    section.sec { margin-top: 18px; }
    figure { margin: 14px 0; }
    details summary { display: none; }
    details[open] summary { border-bottom: none; }
    .fig-card { box-shadow: none; overflow-x: visible; }
  }
'''
s = s.replace('  @media (max-width: 640px) {', '  ' + print_css.strip() + '\n\n  @media (max-width: 640px) {')
s = re.sub(r'href="#(ref-\d+|s\d+|act\d+|fin|apx)"', r'href="https://anchor.internal/\1"', s)
n_internal = len(re.findall(r'href="https://anchor\.internal/', s))
print('internal hrefs:', n_internal, flush=True)

head, rest = s.split('<div class="wrap">', 1)
body_inner, tail = rest.rsplit('</div>\n</body>', 1)
blocks = re.split(r'(?=<!-- =+ [A-Z0-9 ]+ =+ -->)', body_inner)
parts = {}
for b in blocks:
    m = re.search(r'id="(\w+)"', b); bid = m.group(1) if m else 'pre'
    if bid == 'act5':
        secs = re.split(r'(?=<section class="sec")', b)
        parts['act5a'] = secs[0] + secs[1] + secs[2]
        parts['act5b'] = secs[3]
    elif bid == 'apx':
        secs = re.split(r'(?=<section class="sec")', b)
        parts['apx-a'] = secs[0] + secs[1]
        parts['apx-b'] = secs[2]
        parts['apx-c'] = ''.join(secs[3:])
    else:
        parts[bid] = b
GROUPS = [('g1', ['pre', 's0']), ('g2', ['act1', 'act2', 'act3']), ('g3', ['act4', 'act5a']),
          ('g4', ['act5b']), ('g5', ['act6', 'fin']), ('g6', ['apx-a', 'apx-b']), ('g7', ['apx-c'])]
chunks = [(n, ''.join(parts[k] for k in ks)) for n, ks in GROUPS]
print('chunks:', [n for n, _ in chunks], flush=True)

for n, c in chunks:
    open(f'chunk_{n}.html', 'w').write(head + '<div class="wrap">' + c + '</div>\n</body>' + tail)
    pdf = f'{os.getcwd()}/chunk_{n}.pdf'
    if os.path.exists(pdf): os.remove(pdf)
    prof = f'{os.getcwd()}/prof_{n}'
    for attempt in (1, 2):
        try:
            subprocess.run([CH, '--headless=new', '--disable-gpu', '--no-first-run',
                            '--user-data-dir=' + prof, '--no-pdf-header-footer',
                            '--virtual-time-budget=10000', f'--print-to-pdf={pdf}',
                            f'file://{os.getcwd()}/chunk_{n}.html'], capture_output=True, timeout=75)
        except subprocess.TimeoutExpired:
            pass
        if os.path.exists(pdf): break
    shutil.rmtree(prof, ignore_errors=True)
    if not os.path.exists(pdf): sys.exit(f'PRINT FAIL: {n}')
    print(n, 'printed', flush=True)

from pypdf import PdfWriter
import pdfplumber
w = PdfWriter()
for n, _ in chunks: w.append(f'chunk_{n}.pdf')
w.add_metadata({'/Title': '方向组合研究(可视化版):从「方向焦虑」到一个飞轮', '/Author': 'DaoBrew Strategy',
                '/Subject': '九个方向的证据、结构与融资打法 · 含证据链(2026-08-09 live 核查)'})
with open('merged.pdf', 'wb') as f: w.write(f)

NEEDLES = {
 's0': '一页结论(先给地图', 'act1': '第一幕 · 买单语法', 'act2': '第二幕 · 灯下黑', 'act3': '第三幕 · 咨询陷阱',
 'act4': '第四幕 · 合流', 'act5': '第五幕 · 排除法', 's8': 'I 玄学×科技:完整档案', 'act6': '第六幕 · 融资游戏',
 'fin': '终章 · 选方向也是选生活', 'apx': '结构四维分解与可切换性', 's15': '证据链与引用',
}
norm = lambda t: unicodedata.normalize('NFKC', t)
targets = {}
with pdfplumber.open('merged.pdf') as pdf:
    pagechars = []
    for p in pdf.pages:
        chs = [c for c in p.chars if not c['text'].isspace()]
        pagechars.append((p.height, chs, norm(''.join(c['text'] for c in chs))))
    for anchor, needle in NEEDLES.items():
        nd = norm(''.join(needle.split()))
        best = None
        for i, (h, chs, txt) in enumerate(pagechars):
            start = 0
            while True:
                j = txt.find(nd, start)
                if j < 0: break
                c = chs[min(j, len(chs)-1)]
                if best is None or c['size'] > best[0]: best = (c['size'], i, c['top'], h)
                start = j + 1
        assert best, anchor
        targets[anchor] = (best[1], max(0, best[3] - best[2] + 10))
    for i, (h, chs, txt) in enumerate(pagechars):
        for m in re.finditer(r'\[(\d+)\]', txt):
            a = 'ref-' + m.group(1)
            if a not in targets:
                c = chs[min(m.start(), len(chs)-1)]
                targets[a] = (i, max(0, h - c['top'] + 8))
missing = [f'ref-{n}' for n in range(1, 107) if f'ref-{n}' not in targets]
assert not missing, missing

from pypdf.generic import DictionaryObject, NameObject, ArrayObject, NumberObject, NullObject
w = PdfWriter(clone_from='merged.pdf')
replaced = external = 0
for page in w.pages:
    for a in (page.get('/Annots') or []):
        obj = a.get_object(); A = obj.get('/A')
        if not A: continue
        Ao = A.get_object() if hasattr(A, 'get_object') else A
        uri = str(Ao.get('/URI') or '')
        if uri.startswith('https://anchor.internal/'):
            frag = uri.rsplit('/', 1)[-1]
            tp, ty = targets[frag]
            dest = ArrayObject([w.pages[tp].indirect_reference, NameObject('/XYZ'), NullObject(), NumberObject(ty), NullObject()])
            obj[NameObject('/A')] = DictionaryObject({NameObject('/S'): NameObject('/GoTo'), NameObject('/D'): dest})
            replaced += 1
        elif uri.startswith('http'): external += 1
assert replaced == n_internal, (replaced, n_internal)
w.compress_identical_objects(remove_identicals=True, remove_orphans=True)
for p in w.pages: p.compress_content_streams(level=9)
with open(OUT, 'wb') as f: w.write(f)

from pypdf import PdfReader
r = PdfReader(OUT)
goto = uri = stale = 0
for p in r.pages:
    for a in (p.get('/Annots') or []):
        o = a.get_object(); A = o.get('/A')
        if not A: continue
        Ao = A.get_object() if hasattr(A, 'get_object') else A
        if Ao.get('/S') == '/GoTo': goto += 1
        else:
            u = str(Ao.get('/URI') or ''); uri += 1; stale += 'anchor.internal' in u
size = os.path.getsize(OUT)
print(f'DONE pages={len(r.pages)} GoTo={goto} extURI={uri} stale={stale} size={size/1e6:.1f}MB', flush=True)
assert stale == 0 and goto == n_internal and size < 10_000_000
