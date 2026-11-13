"""Pagine di elenco con collegamenti diretti a PDF/EPUB (Libera Conoscenza, O.T.O., Genoa Lodge, ...)."""
from __future__ import annotations

import re
import urllib.parse
from html.parser import HTMLParser

from ..modello import nuovo_candidato

ESTENSIONI = (".pdf", ".epub")


GENERICO = re.compile(
    r"^(download|scarica|scaricare|presentazione|clicca|qui|pdf|leggi|apri|link|testo|articolo|estratto|"
    r"(la |il |lo |l')?(prima|seconda|terza|\d+[ao]?) (conferenza|capitolo)|(del|della|dello|di) .*)", re.I)
RUMORE = re.compile(r"\((pdf|epub)\)|\bdownload\b|\bscarica\b\s*(\([^)]*\))?|\([\d.,]+\s*[kmg]b\)", re.I)


def titolo_pulito(testo: str, url: str, contesto: str) -> str:
    t = " ".join(RUMORE.sub(" ", testo).split()).strip(" -–:()")
    nome = urllib.parse.unquote(urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1])
    nome = re.sub(r"\.(pdf|epub)$", "", nome, flags=re.I).replace("_", " ").replace("-", " ").strip()
    if len(t) < 6 or GENERICO.match(t):
        base = contesto or nome
        return f"{base} — {t}" if contesto and len(t) >= 3 else base
    return t


class _Link(HTMLParser):
    def __init__(self):
        super().__init__()
        self.link: list[tuple[str, str, str]] = []
        self._href: str | None = None
        self._testo: list[str] = []
        self._intest = False
        self._h: list[str] = []
        self.contesto = ""

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self._href = dict(attrs).get("href")
            self._testo = []
        elif tag in ("h1", "h2", "h3", "h4", "h5"):
            self._intest, self._h = True, []

    def handle_data(self, data):
        if self._href is not None:
            self._testo.append(data)
        if self._intest:
            self._h.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self._href is not None:
            self.link.append((self._href, " ".join("".join(self._testo).split()), self.contesto))
            self._href = None
        elif tag in ("h1", "h2", "h3", "h4", "h5") and self._intest:
            self._intest = False
            self.contesto = " ".join("".join(self._h).split())


def estrai(html: str, base: str) -> list[tuple[str, str]]:
    p = _Link()
    p.feed(html)
    out = []
    for href, testo, contesto in p.link:
        url = urllib.parse.urljoin(base, href)
        if urllib.parse.urlsplit(url).path.lower().endswith(ESTENSIONI):
            out.append((url, titolo_pulito(testo, url, contesto)))
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
