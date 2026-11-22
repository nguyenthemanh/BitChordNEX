import json
import sys
path = sys.argv[1]
d = json.load(open(path, encoding='utf-8'))
out = []

def walk(n):
    if isinstance(n, dict):
        a = n.get('attributes') or {}
        t = a.get('text') or ''
        if t:
            out.append('%s %s' % (a.get('bounds'), t[:120]))
        for c in n.get('children') or []:
            walk(c)
    elif isinstance(n, list):
        for c in n:
            walk(c)

walk(d)
print('\n'.join(out))
