#!/usr/bin/env python3
"""Prepare the esp-pacs ESP32-C6 SVD for regz.

Input: esp-pacs esp32c6 SVD after `svdtools patch` and
`svdtools convert --expand-properties` (sizes, access and reset values inherited).

regz limitations worked around here, keeping register arrays intact:
  * register-level derivedFrom is not supported -> copy fields from the source register
  * CLINT has 64-bit registers that crash regz; the C3 SVD has no CLINT either -> drop it
  * dim clusters are dropped or truncated -> expand them into named clusters
  * registers derived across peripherals have no size -> add a device-level default
    (done in `add-size` mode, before svdtools inherits properties)

Full pipeline (esp-pacs checkout, svdtools 0.5):
  cd esp-pacs/esp32c6/svd
  svdtools patch patches/esp32c6.yaml
  python3 prep_esp32c6_svd.py add-size esp32c6.base.svd.patched c6.sized.svd
  svdtools convert --input-format xml --output-format xml --expand-properties \
      c6.sized.svd c6.props.svd
  python3 prep_esp32c6_svd.py c6.props.svd ESP32-C6.svd

Known gaps (regz warnings, fields skipped): MCPWM CMPR%s_TE{A,B}, PCNT CH%s_{POS,LCTRL}_MODE.

usage: prep_esp32c6_svd.py [add-size] <in.svd> <out.svd>
"""
import copy
import sys
import xml.etree.ElementTree as ET


def main(src, dst):
    tree = ET.parse(src)
    root = tree.getroot()
    periphs = root.find("peripherals")

    for p in list(periphs):
        if p.findtext("name") == "CLINT":
            periphs.remove(p)

    # name -> peripheral element, following peripheral-level derivedFrom for lookups
    by_name = {p.findtext("name"): p for p in periphs}

    def registers_of(p):
        regs = p.find("registers")
        if regs is None and p.get("derivedFrom"):
            return registers_of(by_name[p.get("derivedFrom")])
        return regs

    def find_register(scope_periph, path):
        parts = path.split(".")
        if len(parts) == 1:
            container = registers_of(scope_periph)
        else:
            container = registers_of(by_name[parts[0]])
            parts = parts[1:]
        for i, part in enumerate(parts):
            last = i == len(parts) - 1
            nxt = None
            for el in container:
                if el.findtext("name") == part:
                    nxt = el
                    break
            if nxt is None:
                raise KeyError(path)
            if last:
                return nxt
            container = nxt

    resolved = 0
    for p in periphs:
        regs = registers_of(p) if p.get("derivedFrom") is None else None
        if regs is None:
            continue
        stack = [regs]
        while stack:
            container = stack.pop()
            for el in container:
                if el.tag == "cluster":
                    stack.append(el)
                if el.tag != "register" or el.get("derivedFrom") is None:
                    continue
                srcreg = find_register(p, el.get("derivedFrom"))
                del el.attrib["derivedFrom"]
                for child in srcreg:
                    if child.tag in ("name", "addressOffset", "dim", "dimIncrement", "dimIndex"):
                        continue
                    if el.find(child.tag) is None:
                        el.append(copy.deepcopy(child))
                resolved += 1

    # regz mishandles dim clusters: it keeps only the last element or emits padding
    # (e.g. PCR.TIMERGROUP%s, SYSTIMER.TRGT%s). Expand every dim cluster into plain
    # named clusters (TIMERGROUP0, TIMERGROUP1, TRGT0, ...). Register arrays are kept.
    def expand_clusters(container):
        count = 0
        for idx, el in enumerate(list(container)):
            if el.tag != "cluster":
                continue
            count += expand_clusters(el)
            if el.find("dim") is None:
                continue
            dim = int(el.findtext("dim"), 0)
            inc = int(el.findtext("dimIncrement"), 0)
            base = int(el.findtext("addressOffset"), 0)
            name = el.findtext("name")
            index_text = el.findtext("dimIndex")
            if index_text and "-" in index_text and "," not in index_text:
                lo, _ = index_text.split("-")
                indices = [str(int(lo) + i) for i in range(dim)]
            elif index_text:
                indices = index_text.split(",")
            else:
                indices = [str(i) for i in range(dim)]
            pos = list(container).index(el)
            container.remove(el)
            for i in range(dim):
                c = copy.deepcopy(el)
                for tag in ("dim", "dimIncrement", "dimIndex"):
                    t = c.find(tag)
                    if t is not None:
                        c.remove(t)
                c.find("name").text = name.replace("[%s]", indices[i]).replace("%s", indices[i])
                c.find("addressOffset").text = hex(base + i * inc)
                container.insert(pos + i, c)
            count += 1
        return count

    expanded = 0
    for p in periphs:
        regs = p.find("registers")
        if regs is not None:
            expanded += expand_clusters(regs)

    # Name the register arrays the HAL indexes the same way as the C3 SVD, so regz
    # generates arrays (`GPIO.PIN[n]`) instead of unrolled registers (`GPIO.PIN0`, ...).
    array_names = {
        ("GPIO", "PIN%s"): "PIN[%s]",
        ("GPIO", "FUNC%s_IN_SEL_CFG"): "FUNC_IN_SEL_CFG[%s]",
        ("GPIO", "FUNC%s_OUT_SEL_CFG"): "FUNC_OUT_SEL_CFG[%s]",
        ("IO_MUX", "GPIO%s"): "GPIO[%s]",
        ("I2C0", "COMD%s"): "COMD[%s]",
    }
    renamed = 0
    for p in periphs:
        regs = p.find("registers")
        if regs is None:
            continue
        for el in regs:
            if el.tag != "register" or el.find("dim") is None:
                continue
            key = (p.findtext("name"), el.findtext("name"))
            if key in array_names:
                el.find("name").text = array_names[key]
                # regz builds arrays from consecutive indices; drop explicit dimIndex lists.
                t = el.find("dimIndex")
                if t is not None:
                    el.remove(t)
                renamed += 1
    assert renamed == len(array_names), renamed

    tree.write(dst, encoding="UTF-8", xml_declaration=True)
    print(f"expanded {expanded} dim clusters", file=sys.stderr)
    print(f"resolved {resolved} derived registers", file=sys.stderr)


def add_size(src, dst):
    s = open(src, encoding="utf-8").read()
    head = s[: s.index("<peripherals>")]
    if "<size>" not in head:
        s = s.replace("<width>32</width>", "<width>32</width>\n  <size>0x20</size>", 1)
    open(dst, "w", encoding="utf-8").write(s)


if __name__ == "__main__":
    if sys.argv[1] == "add-size":
        add_size(sys.argv[2], sys.argv[3])
    else:
        main(sys.argv[1], sys.argv[2])
