"""Pagine di elenco con collegamenti diretti a PDF/EPUB (Libera Conoscenza, O.T.O., Genoa Lodge, ...)."""
from __future__ import annotations

import re
import urllib.parse
from html.parser import HTMLParser

from ..modello import nuovo_candidato

ESTENSIONI = (".pdf", ".epub")


class _Link(HTMLParser):
    def __init__(self):
        super().__init__()
        self.link: list[tuple[str, str]] = []
        self._href: str | None = None
        self._testo: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self._href = dict(attrs).get("href")
            self._testo = []

    def handle_data(self, data):
        if self._href is not None:
            self._testo.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self._href is not None:
            self.link.append((self._href, " ".join("".join(self._testo).split())))
            self._href = None


def estrai(html: str, base: str) -> list[tuple[str, str]]:
    p = _Link()
    p.feed(html)
    out = []
    for href, testo in p.link:
        url = urllib.parse.urljoin(base, href)
        if urllib.parse.urlsplit(url).path.lower().endswith(ESTENSIONI):
            nome = urllib.parse.unquote(urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1])
            out.append((url, testo or re.sub(r"\.(pdf|epub)$", "", nome, flags=re.I).replace("_", " ")))
    return out


def cerca(fonte: dict, ricerche: list[str], fetcher, adesso: str, ultimo_controllo: str | None) -> list[dict]:
    html = fetcher.get_testo(fonte["url"])
    lingua = (fonte.get("parametri") or {}).get("lingua", "")
    out = []
    for url, titolo in estrai(html, fonte["url"]):
        fmt = urllib.parse.urlsplit(url).path.lower().rsplit(".", 1)[-1]
        out.append(nuovo_candidato(
            fonte["id"], url, adesso, titolo=titolo, lingua=lingua, formato=fmt,
            url_scheda=fonte["url"], url_download=url, integrale=None, verifica="catalogo",
            motivo=f"Collegamento diretto trovato in {fonte['nome']}",
        ))
    return out
