# minimal s-expression helpers for KiCad files
import re
def block_at(s, i):
    """return end index (exclusive) of the balanced block starting at s[i]=='('"""
    d=0; j=i; inq=False
    while j < len(s):
        c=s[j]
        if inq:
            if c=='\\': j+=2; continue
            if c=='"': inq=False
        elif c=='"': inq=True
        elif c=='(': d+=1
        elif c==')':
            d-=1
            if d==0: return j+1
        j+=1
    raise ValueError
def find_symbol(s, name):
    m=re.search(r'\(symbol "'+re.escape(name)+r'"', s)
    if not m: return None
    return s[m.start():block_at(s,m.start())]
def pins(symtext):
    out={}
    for m in re.finditer(r'\(pin (\w+) \w+\s*\(at ([-\d.]+) ([-\d.]+) ([-\d.]+)\)\s*\(length ([\d.]+)\)(.*?)\(number "([^"]*)"', symtext, re.S):
        out[m.group(7)]=(float(m.group(2)),float(m.group(3)),int(float(m.group(4))),m.group(1))
    return out
