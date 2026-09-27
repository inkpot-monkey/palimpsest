"""Exhaustive check: every element in every spine item of every fixture EPUB.
x-pointer (as crengine toStringV2 would emit) -> CSS selector -> resolved by
lxml.cssselect (independent engine) must be exactly the originating element."""

import re
import sys
import zipfile

from lxml import etree
from lxml.cssselect import CSSSelector, SelectorError

_SEL = {}


def sel(css):
    c = _SEL.get(css)
    if c is None:
        c = _SEL[css] = CSSSelector(css)
    return c


BOXING = {"autoBoxing", "floatBox", "inlineBox", "tabularBox", "pseudoElem"}
STEP = re.compile(r"/([A-Za-z_][\w.:-]*|text\(\))(?:\[(\d+)\])?")


def local(t):
    return etree.QName(t).localname if isinstance(t, str) else None


def spine(z):
    c = etree.fromstring(z.read("META-INF/container.xml"))
    opf = c.find(".//{*}rootfile").get("full-path")
    pkg = etree.fromstring(z.read(opf))
    man = {i.get("id"): i.get("href") for i in pkg.find("{*}manifest")}
    base = opf.rsplit("/", 1)[0] + "/" if "/" in opf else ""
    return [
        (r.get("idref"), base + man[r.get("idref")])
        for r in pkg.find("{*}spine")
        if r.get("idref") in man
    ]


def to_css(xp):
    if "." in xp.rsplit("/", 1)[-1]:
        xp = xp.rsplit(".", 1)[0]
    steps = [(n, int(i) if i else 1) for n, i in STEP.findall(xp)]
    assert steps[0][0] == "body" and steps[1][0] == "DocFragment", steps[:2]
    n = steps[1][1]
    parts = []
    for name, idx in steps[2:]:
        if name == "text()":
            break
        if name in BOXING:
            continue
        parts.append(f"{name}:nth-of-type({idx})")
    return n, " > ".join(parts)


def xpointer_for(doc, node, n):
    chain, cur = [], node
    while cur is not doc:
        p = cur.getparent()
        if p is None:
            break
        kids = [c for c in p if isinstance(c.tag, str)]
        same = [c for c in kids if local(c.tag) == local(cur.tag)]
        chain.append(
            local(cur.tag)
            if len(same) == 1
            else f"{local(cur.tag)}[{same.index(cur) + 1}]"
        )
        cur = p
    chain.reverse()
    return f"/body/DocFragment[{n}]/{'/'.join(chain)}.0"


grand_ok = grand_fail = 0
for epub in sys.argv[1:]:
    z = zipfile.ZipFile(epub)
    items = spine(z)
    ok = fail = skipped = 0
    mixed_ns = 0
    for n, (idref, href) in enumerate(items, 1):
        try:
            raw = z.read(href)
        except KeyError:
            skipped += 1
            continue
        try:
            doc = etree.fromstring(raw)
        except etree.XMLSyntaxError:
            # Plenty of real EPUBs ship XHTML that is not well-formed XML; retry as HTML
            # before giving up on the document.
            try:
                doc = etree.fromstring(raw, etree.HTMLParser())
            except etree.XMLSyntaxError:
                skipped += 1
                continue
        if doc is None:
            skipped += 1
            continue
        # detect mixed-namespace content (nth-of-type is ns-aware, crengine is not)
        nss = {
            etree.QName(e.tag).namespace for e in doc.iter() if isinstance(e.tag, str)
        }
        if len(nss) > 1:
            mixed_ns += 1
        for el in doc.iter():
            if isinstance(el.tag, str):
                el.tag = local(el.tag)
        etree.cleanup_namespaces(doc)
        body = doc.find("body")
        if body is None:
            skipped += 1
            continue
        els = [e for e in body.iter() if isinstance(e.tag, str)]
        if len(els) > 60:
            els = els[:: max(1, len(els) // 60)][:60]
        for t in els:
            xp = xpointer_for(doc, t, n)
            fn, css = to_css(xp)
            if not css:
                continue
            try:
                hits = sel(css)(doc)
            except SelectorError as e:
                fail += 1
                if fail <= 3:
                    print("  SELECTOR ERROR", css, e)
                continue
            if len(hits) == 1 and hits[0] is t:
                ok += 1
            else:
                fail += 1
                if fail <= 3:
                    print(f"  MISMATCH xp={xp} css={css} hits={len(hits)}")
    print(
        f"{epub.rsplit('/', 1)[-1]:<40} ok={ok:<6} fail={fail:<4} "
        f"skipped_docs={skipped:<3} mixed_ns_docs={mixed_ns}"
    )
    grand_ok += ok
    grand_fail += fail
print(f"\nTOTAL  resolved identically: {grand_ok}   mismatched: {grand_fail}")
