"""Accesso alla rete: robots.txt sempre rispettato, timeout, backoff, richieste condizionali."""
from __future__ import annotations

import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser

UA = "BibliotecaIniziato/0.1 (uso personale; +https://github.com/domenicopopolo75-hub/biblioteca-iniziato)"


class ErroreRete(Exception):
    pass


class BloccatoDaRobots(ErroreRete):
    pass


class Fetcher:
    def __init__(self, timeout: int = 60, tentativi: int = 3, pausa: float = 1.0, max_byte: int = 300 * 1024 * 1024):
        self.timeout, self.tentativi, self.pausa, self.max_byte = timeout, tentativi, pausa, max_byte
        self._robots: dict[str, urllib.robotparser.RobotFileParser | None] = {}

    def consentito(self, url: str) -> bool:
        p = urllib.parse.urlsplit(url)
        base = f"{p.scheme}://{p.netloc}"
        if base not in self._robots:
            rp = urllib.robotparser.RobotFileParser()
            try:
                r = self._get(base + "/robots.txt", controlla_robots=False)
                rp.parse(r.decode("utf-8", "replace").splitlines())
                self._robots[base] = rp
            except ErroreRete:
                # nessun robots.txt raggiungibile (404): consentito; errori di rete: lo segnala la richiesta vera
                self._robots[base] = None
        rp = self._robots[base]
        return True if rp is None else rp.can_fetch(UA, url)

    def _get(self, url: str, controlla_robots: bool = True, intestazioni: dict | None = None) -> bytes:
        if controlla_robots and not self.consentito(url):
            raise BloccatoDaRobots(url)
        ultimo: Exception | None = None
        for n in range(self.tentativi):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA, **(intestazioni or {})})
                with urllib.request.urlopen(req, timeout=self.timeout) as r:
                    dati = r.read(self.max_byte + 1)
                if len(dati) > self.max_byte:
                    raise ErroreRete(f"file oltre il limite di {self.max_byte} byte: {url}")
                return dati
            except urllib.error.HTTPError as e:
                ultimo = e
                if e.code in (403, 404, 410):  # inutile riprovare
                    break
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                ultimo = e
            time.sleep(self.pausa * (2 ** n))
        raise ErroreRete(f"{url}: {ultimo}")

    def get(self, url: str) -> bytes:
        return self._get(url)

    def get_testo(self, url: str) -> str:
        return self.get(url).decode("utf-8", "replace")
