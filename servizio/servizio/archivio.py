"""Archivio di stato su file JSON: scritture atomiche e blocco contro esecuzioni sovrapposte."""
from __future__ import annotations

import json
import os
import time
from contextlib import contextmanager
from pathlib import Path

FILE = {
    "candidati": {}, "approvazioni": {}, "lavori": {}, "esecuzioni": [],
    "checkpoint": {}, "inventario": [], "hash_importati": {},
}


class Occupato(Exception):
    pass


class Archivio:
    def __init__(self, cartella: str | Path):
        self.dir = Path(cartella)
        self.dir.mkdir(parents=True, exist_ok=True)

    def _p(self, nome: str) -> Path:
        return self.dir / f"{nome}.json"

    def leggi(self, nome: str):
        p = self._p(nome)
        if not p.exists():
            import copy
            return copy.deepcopy(FILE[nome])
        return json.loads(p.read_text(encoding="utf-8"))

    def scrivi(self, nome: str, dati) -> None:
        p = self._p(nome)
        tmp = p.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(dati, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
        os.replace(tmp, p)

    @contextmanager
    def blocco(self, nome: str = "servizio", scadenza_s: int = 6 * 3600):
        """Un solo esecutore alla volta; un blocco più vecchio di `scadenza_s` è considerato abbandonato."""
        p = self.dir / f"{nome}.lock"
        try:
            fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            if time.time() - p.stat().st_mtime < scadenza_s:
                raise Occupato(nome)
            p.unlink()
            fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, str(os.getpid()).encode())
        os.close(fd)
        try:
            yield
        finally:
            try:
                p.unlink()
            except FileNotFoundError:
                pass
