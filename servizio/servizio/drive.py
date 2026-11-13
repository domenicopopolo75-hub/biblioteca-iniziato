"""Caricamento su Google Drive, idempotente per chiave (appProperties). Mai sovrascrive."""
from __future__ import annotations

import json
import os
import urllib.parse
import urllib.request


class DriveFinto:
    """Solo per i test: stessa interfaccia, memoria al posto di Drive."""

    def __init__(self):
        self.file: dict[str, tuple[str, bytes]] = {}
        self.chiamate = 0

    def carica(self, nome: str, dati: bytes, chiave: str, formato: str) -> str:
        self.chiamate += 1
        for k, (n, _) in self.file.items():
            if k == chiave:
                return f"fake:{k}"
        self.file[chiave] = (nome, dati)
        return f"fake:{chiave}"


class GoogleDrive:
    """Credenziali dai segreti del servizio (mai nell'app né nel repository)."""

    def __init__(self, cartella_id: str | None = None):
        self.cartella = cartella_id or os.environ["DRIVE_FOLDER_ID"]
        self._token: str | None = None

    def _accesso(self) -> str:
        if not self._token:
            corpo = urllib.parse.urlencode({
                "client_id": os.environ["GOOGLE_CLIENT_ID"], "client_secret": os.environ["GOOGLE_CLIENT_SECRET"],
                "refresh_token": os.environ["GOOGLE_REFRESH_TOKEN"], "grant_type": "refresh_token"}).encode()
            with urllib.request.urlopen(urllib.request.Request("https://oauth2.googleapis.com/token", corpo)) as r:
                self._token = json.load(r)["access_token"]
        return self._token

    def _json(self, req: urllib.request.Request) -> dict:
        req.add_header("Authorization", f"Bearer {self._accesso()}")
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)

    def carica(self, nome: str, dati: bytes, chiave: str, formato: str) -> str:
        q = (f"appProperties has {{ key='chiave' and value='{chiave}' }} and "
             f"'{self.cartella}' in parents and trashed=false")
        trovati = self._json(urllib.request.Request(
            "https://www.googleapis.com/drive/v3/files?" + urllib.parse.urlencode({"q": q, "fields": "files(id)"})))
        if trovati.get("files"):
            return trovati["files"][0]["id"]  # già caricato: retry senza duplicati
        meta = json.dumps({"name": nome, "parents": [self.cartella], "appProperties": {"chiave": chiave}}).encode()
        mime = {"pdf": "application/pdf", "epub": "application/epub+zip"}.get(formato, "application/octet-stream")
        b = "----biblioteca"
        corpo = (f"--{b}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".encode() + meta +
                 f"\r\n--{b}\r\nContent-Type: {mime}\r\n\r\n".encode() + dati + f"\r\n--{b}--".encode())
        req = urllib.request.Request(
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id", corpo,
            {"Content-Type": f"multipart/related; boundary={b}"})
        return self._json(req)["id"]
