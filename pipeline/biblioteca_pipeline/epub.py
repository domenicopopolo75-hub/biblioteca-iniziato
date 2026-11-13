"""Estrazione EPUB (2 e 3) con la sola libreria standard.

Ordine = spine dell'OPF. Locator: `page_index` = posizione nello spine, `href` = file interno.
Nessuna pagina inventata.
"""
from __future__ import annotations

import posixpath
import zipfile
from html.parser import HTMLParser
from xml.etree import ElementTree as ET

from .normalizza import normalizza, script_dominante

_BLOCCHI = {"p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre", "dd", "dt",
            "figcaption", "td", "th"}
_TITOLI = {"h1", "h2", "h3", "h4", "h5", "h6"}
_SALTA = {"script", "style", "head", "title"}


class _Paragrafi(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.out: list[tuple[str, str]] = []  # (kind, testo)
        self._buf: list[str] = []
        self._tipo = "paragraph"
        self._salta = 0
        self._nota = 0

    def _chiudi(self) -> None:
        t = "".join(self._buf)
        if t.strip():
            self.out.append((self._tipo, t))
        self._buf = []
        self._tipo = "paragraph"

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in _SALTA:
            self._salta += 1
        if tag in _BLOCCHI or tag in ("div", "section", "aside", "br"):
            if tag == "br":
                self._buf.append("\n")
                return
            self._chiudi()
            if tag in _TITOLI:
                self._tipo = "heading"
            tipo_epub = (a.get("epub:type") or "") + " " + (a.get("class") or "")
            if tag == "aside" or "footnote" in tipo_epub or "endnote" in tipo_epub:
                self._nota += 1
            if self._nota:
                self._tipo = "note"

    def handle_endtag(self, tag):
        if tag in _SALTA:
            self._salta = max(0, self._salta - 1)
        if tag in _BLOCCHI or tag in ("div", "section", "aside", "body"):
            if self._nota and self._tipo != "heading":
                self._tipo = "note"
            self._chiudi()
            if tag == "aside" and self._nota:
                self._nota -= 1

    def handle_data(self, data):
        if not self._salta:
            self._buf.append(data)


def _opf(z: zipfile.ZipFile) -> str:
    root = ET.fromstring(z.read("META-INF/container.xml"))
    for el in root.iter():
        if el.tag.endswith("rootfile"):
            return el.attrib["full-path"]
    raise ValueError("container.xml senza rootfile")


def estrai_epub(percorso: str) -> dict:
    with zipfile.ZipFile(percorso) as z:
        opf_path = _opf(z)
        base = posixpath.dirname(opf_path)
        opf = ET.fromstring(z.read(opf_path))
        ns = {"o": "http://www.idpf.org/2007/opf", "dc": "http://purl.org/dc/elements/1.1/"}
        manifest = {i.attrib["id"]: i.attrib["href"] for i in opf.iterfind(".//o:manifest/o:item", ns)}
        spine = [i.attrib["idref"] for i in opf.iterfind(".//o:spine/o:itemref", ns)]
        meta = {
            "title": (opf.findtext(".//dc:title", default="", namespaces=ns) or "").strip() or None,
            "author": (opf.findtext(".//dc:creator", default="", namespaces=ns) or "").strip() or None,
            "language": (opf.findtext(".//dc:language", default="", namespaces=ns) or "").strip() or None,
        }
        blocks, vuote, order, capitolo = [], [], 0, None
        for idx, idref in enumerate(spine):
            href = manifest.get(idref)
            if not href:
                vuote.append(idx)
                continue
            percorso_interno = posixpath.normpath(posixpath.join(base, href))
            p = _Paragrafi()
            p.feed(z.read(percorso_interno).decode("utf-8", errors="replace"))
            p.close()
            p._chiudi()
            if not p.out:
                vuote.append(idx)
                continue
            for n, (kind, raw) in enumerate(p.out):
                testo = normalizza(raw)
                if not testo:
                    continue
                if kind == "heading":
                    capitolo = testo
                blocks.append({
                    "id": f"s{idx:04d}-b{n:04d}", "order": order, "kind": kind,
                    "locator": {"page_index": idx, "printed_page": None, "column": 0, "bbox": None,
                                "chapter": capitolo, "href": href},
                    "lang": script_dominante(testo) or meta["language"], "text_raw": raw, "text": testo,
                })
                order += 1
    return {
        "meta": meta,
        "pages_total": len(spine),
        "coverage": {"units_total": len(spine), "units_with_text": len(spine) - len(vuote),
                     "units_empty": vuote, "units_need_ocr": []},
        "blocks": blocks,
    }
