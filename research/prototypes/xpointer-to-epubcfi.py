"""Prototype: KOReader x-pointer -> epubcfi, element-granularity.

Mirrors what a Rust version in stump_core would do:
  - crengine toStringV2 grammar: /body/DocFragment[N]/body/div[2]/p[3]/text()[2].14
  - DocFragment[N] -> spine index N-1 (crengine >= 20240114 makes one per spine item)
  - element step name[k] -> CFI step 2*(position among *element* children)
    (epub.js walkToNode resolves element steps against container.children)
"""

import re
import sys
import zipfile
import xml.etree.ElementTree as ET

BOXING = {"autoBoxing", "floatBox", "inlineBox", "tabularBox", "pseudoElem"}
STEP = re.compile(r"/([A-Za-z_][\w.:-]*|text\(\))(?:\[(\d+)\])?")


def local(tag):
    return tag.rsplit("}", 1)[-1]


def opf_path(z):
    c = ET.fromstring(z.read("META-INF/container.xml"))
    return c.find(".//{*}rootfile").attrib["full-path"]


def spine(z):
    opf = opf_path(z)
    pkg = ET.fromstring(z.read(opf))
    manifest = {i.attrib["id"]: i.attrib["href"] for i in pkg.find("{*}manifest")}
    spine_el = pkg.find("{*}spine")
    # CFI step for <spine> itself: 2 * (its 1-based position among package element children)
    spine_step = 2 * (list(pkg).index(spine_el) + 1)
    items = [(r.attrib["idref"], manifest[r.attrib["idref"]]) for r in spine_el]
    base = opf.rsplit("/", 1)[0] + "/" if "/" in opf else ""
    return spine_step, [(idref, base + href) for idref, href in items]


def parse_xpointer(xp):
    steps, tail = [], None
    if "." in xp.rsplit("/", 1)[-1]:
        xp, off = xp.rsplit(".", 1)
        tail = int(off)
    for name, idx in STEP.findall(xp):
        steps.append((name, int(idx) if idx else 1))
    return steps, tail


def convert(epub, xp):
    z = zipfile.ZipFile(epub)
    spine_step, items = spine(z)
    steps, _off = parse_xpointer(xp)
    # /body/DocFragment[N]/...
    assert steps[0][0] == "body" and steps[1][0] == "DocFragment", steps[:2]
    n = steps[1][1]
    idref, href = items[n - 1]
    doc = ET.fromstring(z.read(href))
    # walk the rest of the path against the real XHTML, starting at <html>
    node, out = doc, []
    for name, idx in steps[2:]:
        if name == "text()":  # element granularity: stop before text steps
            break
        if name in BOXING:  # V1 pointers carry crengine's synthetic boxes
            continue
        kids = [c for c in node if isinstance(c.tag, str)]
        matches = [c for c in kids if local(c.tag) == name]
        if len(matches) < idx:
            break  # soft failure: keep the deepest resolved ancestor
        target = matches[idx - 1]
        out.append(2 * (kids.index(target) + 1))
        node = target
    return "epubcfi(/%d/%d[%s]!%s)" % (
        spine_step,
        2 * n,
        idref,
        "".join("/%d" % s for s in out),
    )


def xpointer_for_node(doc, node, n):
    """Emit the x-pointer crengine's toStringV2 would produce for a node, so the
    round-trip can be exercised without a device."""
    parent = {c: p for p in doc.iter() for c in p}
    chain, cur = [], node
    while cur is not doc:
        p = parent[cur]
        kids = [c for c in p if isinstance(c.tag, str)]
        same = [c for c in kids if local(c.tag) == local(cur.tag)]
        idx = same.index(cur) + 1
        chain.append(
            local(cur.tag) if len(same) == 1 else "%s[%d]" % (local(cur.tag), idx)
        )
        cur = p
    chain.reverse()
    return "/body/DocFragment[%d]/%s.0" % (n, "/".join(chain))


if __name__ == "__main__":
    epub = sys.argv[1]
    z = zipfile.ZipFile(epub)
    step, items = spine(z)
    print("spine step /%d, %d items" % (step, len(items)))
    for i, (idref, href) in enumerate(items[:3], 1):
        print("  DocFragment[%d] -> %s (%s)" % (i, idref, href))
    for n in range(1, len(items) + 1):
        doc = ET.fromstring(z.read(items[n - 1][1]))
        ps = [
            e
            for e in doc.iter()
            if local(e.tag) == "p" and len("".join(e.itertext()).strip()) > 40
        ]
        if len(ps) < 3:
            continue
        xp = xpointer_for_node(doc, ps[2], n)
        print("\nDocFragment[%d] %s" % (n, items[n - 1][0]))
        print("  x-pointer :", xp)
        print("  epubcfi   :", convert(epub, xp))
        print("  text      :", repr("".join(ps[2].itertext())[:70]))
        break
