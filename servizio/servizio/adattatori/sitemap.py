"""Siti di articoli senza catalogo (es. Pax Pleroma): pagine dalla sitemap o, se manca, dai link interni.

Ogni pagina è un candidato in formato HTML; non si scarica nulla finché il proprietario non approva."""
from __future__ import annotations

import re
import urllib.parse
import xml.etree.ElementTree as ET
from html.parser import HTMLParser

from ..modello import nuovo_candidato
from ..rete import ErroreRete

ESCLUSI = ("terms", "privacy", "cookie", "condizioni", "login", "cart", "wp-", "feed", "tag/", "category/")
NS = "{http://www.sitemaps.org/schemas/sitemap/0.9}"


def canonico(url: str) -> str:
    """http/https, www e slash finale non creano pagine diverse."""
    p = urllib.parse.urlsplit(url)
    host = p.netloc.lower().removeprefix("www.")
    return f"https://{host}{p.path.rstrip('/') or '/'}"


def titolo_da_url(url: str) -> str:
    slug = urllib.parse.unquote(urllib.parse.urlsplit(url).path.strip("/").rsplit("/", 1)[-1])
    return re.sub(r"\s+", " ", re.sub(r"[-_]+", " ", slug)).strip().capitalize() or "Pagina iniziale"


def da_sitemap(xml: str, fetcher, profondita: int = 0) -> list[tuple[str, str]]:
    radice = ET.fromstring(xml)
    out: list[tuple[str, str]] = []
    if radice.tag.endswith("sitemapindex") and profondita < 2:
        for s in radice.findall(f"{NS}sitemap/{NS}loc"):
            try:
                out += da_sitemap(fetcher.get_testo(s.text.strip()), fetcher, profondita + 1)
            except ErroreRete:
                continue  # una sotto-mappa guasta non blocca le altre
        return out
    for u in radice.findall(f"{NS}url"):
        loc = u.findtext(f"{NS}loc")
        if loc:
            out.append((loc.strip(), (u.findtext(f"{NS}lastmod") or "")[:10]))
    return out


class _Interni(HTMLParser):
    def __init__(self):
        super().__init__()
        self.href: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a" and dict(attrs).get("href"):
            self.href.append(dict(attrs)["href"])


def da_link_interni(html: str, base: str) -> list[tuple[str, str]]:
    p = _Interni()
    p.feed(html)
    host = urllib.parse.urlsplit(base).netloc.lower().removeprefix("www.")
    out = []
    for h in p.href:
        u = urllib.parse.urljoin(base, h.split("#")[0])
        sp = urllib.parse.urlsplit(u)
        if sp.scheme in ("http", "https") and sp.netloc.lower().removeprefix("www.") == host and not sp.query:
            out.append((u, ""))
    return out


def cerca(fonte: dict, ricerche: list[str], fetcher, adesso: str, ultimo_controllo: str | None) -> list[dict]:
    base = fonte["url"]
    radice = f"{urllib.parse.urlsplit(base).scheme}://{urllib.parse.urlsplit(base).netloc}"
    escludi = tuple((fonte.get("parametri") or {}).get("escludi", ())) + ESCLUSI
    try:
        pagine = da_sitemap(fetcher.get_testo(radice + "/sitemap.xml"), fetcher)
        metodo = "sitemap"
    except (ErroreRete, ET.ParseError):
        pagine = da_link_interni(fetcher.get_testo(base), base)
        metodo = "link interni"
    visti: dict[str, dict] = {}
    scartati: set[str] = set()
    for url, lastmod in pagine:
        c = canonico(url)
        if c in visti or c in scartati or any(x in c.lower() for x in escludi) or c.rstrip("/").endswith(("/home", "/index")):
            continue
        if ultimo_controllo and lastmod and lastmod <= ultimo_controllo[:10]:
            scartati.add(c)  # incrementale: la pagina non è cambiata; anche le sue varianti restano fuori
            continue
        visti[c] = nuovo_candidato(
            fonte["id"], c, adesso, titolo=titolo_da_url(c), lingua=(fonte.get("parametri") or {}).get("lingua", ""),
            formato="html", url_scheda=c, url_download=c, integrale=None, verifica="catalogo",
            motivo=f"Pagina del sito {fonte['nome']} (trovata da {metodo})")
    return list(visti.values())
