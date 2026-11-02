#!/usr/bin/env python3
"""build_manuals.py -- the installation guide and the user manual as PDF, in every language.

Content: lang_<code>.py next to this file (INSTALL and USER documents, the same structure in every
language; English is the reference). Each document is a dict: title, subtitle, blocks. Blocks:
  ('h1', text) ('h2', text) ('p', text) ('note', text) ('pre', text)
  ('ul', [items]) ('ol', [items]) ('table', [headers], [rows], [column widths in %])
Inline: **bold**, `code`.
Output: pdf/<CODE>/L_Installation_Guide_<CODE>.pdf and L_User_Manual_<CODE>.pdf, printed by Microsoft
Edge (headless) from HTML, so the Windows fonts cover Cyrillic, Chinese, Korean and Japanese. US Letter, 1-inch margins.
Run from WSL: python3 docs/manuals/build_manuals.py [CODE ...]
"""
import html, importlib, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
LANGS = ['EN', 'SP', 'PT', 'DE', 'UA', 'RU', 'CN', 'KR', 'JP']
EDGE = '/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
FONTS = {
    'CN': '"Microsoft YaHei", "Segoe UI", sans-serif',
    'KR': '"Malgun Gothic", "Segoe UI", sans-serif',
    'JP': '"Yu Gothic", "Meiryo", "MS Gothic", "Segoe UI", sans-serif',
}
DEFAULT_FONT = '"Segoe UI", Arial, sans-serif'
HTML_LANG = {'EN': 'en', 'SP': 'es', 'PT': 'pt', 'DE': 'de', 'UA': 'uk', 'RU': 'ru', 'CN': 'zh-CN', 'KR': 'ko', 'JP': 'ja'}


def winpath(p):
    """/mnt/c/... -> C:\\..."""
    m = re.match(r'^/mnt/([a-z])/(.*)$', p)
    return (m.group(1).upper() + ':\\' + m.group(2).replace('/', '\\')) if m else p


def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', t)
    t = re.sub(r'`(.+?)`', r'<code>\1</code>', t)
    return t


def render(doc, code, footer):
    out = []
    for b in doc['blocks']:
        k = b[0]
        if k in ('h1', 'h2'):
            out.append('<%s>%s</%s>' % (k, inline(b[1]), k))
        elif k == 'p':
            out.append('<p>%s</p>' % inline(b[1]))
        elif k == 'note':
            out.append('<div class="note">%s</div>' % inline(b[1]))
        elif k == 'pre':
            out.append('<pre>%s</pre>' % html.escape(b[1]))
        elif k in ('ul', 'ol'):
            out.append('<%s>%s</%s>' % (k, ''.join('<li>%s</li>' % inline(i) for i in b[1]), k))
        elif k == 'table':
            heads, rows = b[1], b[2]
            widths = b[3] if len(b) > 3 else None
            cols = ''.join('<col style="width:%s%%">' % w for w in widths) if widths else ''
            th = ''.join('<th>%s</th>' % inline(h) for h in heads)
            trs = ''.join('<tr>%s</tr>' % ''.join('<td>%s</td>' % inline(c) for c in r) for r in rows)
            out.append('<table><colgroup>%s</colgroup><thead><tr>%s</tr></thead><tbody>%s</tbody></table>'
                       % (cols, th, trs))
        else:
            raise ValueError('unknown block ' + k)
    font = FONTS.get(code, DEFAULT_FONT)
    css = """
@page { size: Letter; margin: 1in 1in 0.9in 1in;
        @bottom-center { content: "%(footer)s  ·  " counter(page) " / " counter(pages); font-family: %(font)s;
                         font-size: 8.5pt; color: #777; } }
body { font-family: %(font)s; font-size: 10.5pt; line-height: 1.42; color: #1a1a1a; }
h1.title { font-size: 24pt; color: #1F3864; margin: 0 0 4pt 0; }
.subtitle { color: #555; font-size: 10.5pt; margin: 0 0 18pt 0; }
h1 { font-size: 15pt; color: #1F3864; margin: 18pt 0 6pt 0; border-bottom: 1.5pt solid #1F3864; padding-bottom: 2pt;
     break-after: avoid; }
h2 { font-size: 12pt; color: #2E5597; margin: 12pt 0 4pt 0; break-after: avoid; }
p { margin: 4pt 0; }
ul, ol { margin: 4pt 0 4pt 0; padding-left: 20pt; }
li { margin: 2pt 0; }
table { border-collapse: collapse; width: 100%%; margin: 6pt 0 8pt 0; font-size: 9.5pt; table-layout: fixed; }
th { background: #1F3864; color: white; text-align: left; padding: 3pt 5pt; }
td { border: 0.6pt solid #b8c2d6; padding: 3pt 5pt; vertical-align: top; overflow-wrap: anywhere; }
tr:nth-child(even) td { background: #f2f5fa; }
tr { break-inside: avoid; }
code { font-family: Consolas, "Courier New", monospace; font-size: 9.5pt; background: #eef1f6; padding: 0 2pt; }
pre { font-family: Consolas, "Courier New", monospace; font-size: 9pt; background: #f4f6f9; border: 0.6pt solid #ccd;
      padding: 6pt; white-space: pre-wrap; }
.note { border-left: 3pt solid #c55a11; background: #fbf1ea; padding: 4pt 8pt; margin: 6pt 0; }
""" % {'font': font, 'footer': footer.replace('"', '\\"')}
    return ('<!doctype html><html lang="%s"><head><meta charset="utf-8"><title>%s</title><style>%s</style></head>'
            '<body><h1 class="title">%s</h1><div class="subtitle">%s</div>%s</body></html>'
            % (HTML_LANG[code], html.escape(doc['title']), css, inline(doc['title']), inline(doc['subtitle']),
               '\n'.join(out)))


def pdf(html_path, pdf_path):
    if os.path.exists(pdf_path):
        os.remove(pdf_path)
    subprocess.run([EDGE, '--headless', '--disable-gpu', '--no-pdf-header-footer',
                    '--print-to-pdf=' + winpath(pdf_path), 'file:///' + winpath(html_path).replace('\\', '/')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
    if not os.path.exists(pdf_path):
        sys.exit('no PDF: ' + pdf_path)


def main():
    codes = [c.upper() for c in sys.argv[1:]] or LANGS
    sys.path.insert(0, HERE)
    build = os.path.join(HERE, 'build')
    os.makedirs(build, exist_ok=True)
    for code in codes:
        m = importlib.import_module('lang_' + code.lower())
        outdir = os.path.join(HERE, 'pdf', code)
        os.makedirs(outdir, exist_ok=True)
        for doc, name in ((m.INSTALL, 'L_Installation_Guide'), (m.USER, 'L_User_Manual')):
            h = os.path.join(build, '%s_%s.html' % (name, code))
            with open(h, 'w', encoding='utf-8', newline='\n') as f:
                f.write(render(doc, code, doc['title']))
            p = os.path.join(outdir, '%s_%s.pdf' % (name, code))
            pdf(h, p)
            print('%s: %s (%d KB)' % (code, os.path.relpath(p, HERE), os.path.getsize(p) // 1024))


if __name__ == '__main__':
    main()
