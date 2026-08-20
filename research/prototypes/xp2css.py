"""Check: x-pointer element steps -> CSS selector, resolved by an INDEPENDENT
engine (lxml.cssselect), must land on the same element the x-pointer names."""

import re
import sys
import zipfile
from lxml import etree
from lxml.cssselect import CSSSelector

BOXING = {"autoBoxing", "floatBox", "inlineBox", "tabularBox", "pseudoElem"}
STEP = re.compile(r"/([A-Za-z_][\w.:-]*|text\(\))(?:\[(\d+)\])?")


def local(t):
    return etree.QName(t).localname if isinstance(t, str) else None


def opf_path(z):
    c = etree.fromstring(z.read("META-INF/container.xml"))
    return c.find(".//{*}rootfile").get("full-path")


def spine(z):
    opf = opf_path(z)
    pkg = etree.fromstring(z.read(opf))
    man = {i.get("id"): i.get("href") for i in pkg.find("{*}manifest")}
    items = [(r.get("idref"), man[r.get("idref")]) for r in pkg.find("{*}spine")]
    base = opf.rsplit("/", 1)[0] + "/" if "/" in opf else ""
    return [(i, base + h) for i, h in items]


def parse_xp(xp):
    if "." in xp.rsplit("/", 1)[-1]:
        xp = xp.rsplit(".", 1)[0]
    return [(n, int(i) if i else 1) for n, i in STEP.findall(xp)]


def to_css(xp):
    """/body/DocFragment[N]/body/div/p[3] -> (N, 'body > div:nth-of-type(1) > p:nth-of-type(3)')"""
    steps = parse_xp(xp)
    assert steps[0][0] == "body" and steps[1][0] == "DocFragment"
    n = steps[1][1]
    parts = []
    for name, idx in steps[2:]:
        if name == "text()":
            break
        if name in BOXING:
            continue
        parts.append("%s:nth-of-type(%d)" % (name, idx))
    return n, " > ".join(parts)


def xpointer_for(doc, node, n):
    chain, cur = [], node
    while cur is not doc:
        p = cur.getparent()
        kids = [c for c in p if isinstance(c.tag, str)]
        same = [c for c in kids if local(c.tag) == local(cur.tag)]
        chain.append(
            local(cur.tag)
            if len(same) == 1
            else "%s[%d]" % (local(cur.tag), same.index(cur) + 1)
        )
        cur = p
    chain.reverse()
    return "/body/DocFragment[%d]/%s.0" % (n, "/".join(chain))


z = zipfile.ZipFile(sys.argv[1])
items = spine(z)
ok = fail = 0
for n, (idref, href) in enumerate(items, 1):
    try:
        doc = etree.fromstring(z.read(href))
    except Exception:
        continue
    # namespace-strip so cssselect matches plain tag names
    for el in doc.iter():
        if isinstance(el.tag, str):
            el.tag = local(el.tag)
    etree.cleanup_namespaces(doc)
    targets = [
        e for e in doc.iter() if e.tag in ("p", "div", "h1", "h2", "blockquote")
    ][:25]
    for t in targets:
        xp = xpointer_for(doc, t, n)
        fn, css = to_css(xp)
        if not css:
            continue
        try:
            hits = CSSSelector(css)(doc)
        except Exception as e:
            print("SELECTOR ERROR", css, e)
            fail += 1
            continue
        if len(hits) == 1 and hits[0] is t:
            ok += 1
        else:
            fail += 1
            if fail <= 5:
                print("MISMATCH\n  xp :", xp, "\n  css:", css, "\n  hits:", len(hits))
print("resolved identically: %d   mismatched: %d" % (ok, fail))
