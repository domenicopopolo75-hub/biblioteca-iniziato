# STATO_PROGETTO — Biblioteca dell'Iniziato

Aggiornato: 13/11/2026 · Esecutore: Claude (Code) · Mandato: dossier Ecce Quam Bonum §13.2

## Decisioni del proprietario (13/11/2026)

- **D1** Repository `biblioteca-iniziato` dedicato, separato da Cantina e Mail; reso **pubblico** per usare i runner macOS gratuiti di GitHub. Solo codice: nessun libro o dato personale (vedi `.gitignore`).
- **D2** Traduzione: **Apple sul telefono** (gratis) come predefinita; **API Claude** solo su scelta esplicita e **solo con budget mensile configurato** (budget 0 = disattivata).
- **D3** Voce: **voce Apple italiana locale** (si consiglia di scaricare una voce Avanzata/Premium).
- **D4** Ricerca mensile dei nuovi testi (lotto 2): **GitHub Actions cron**.

## Lotto 1 — primo percorso completo (in corso)

| Parte | Stato | Prova |
|---|---|---|
| Motore testi Python (`pipeline/`): PDF a colonne, EPUB, TXT → pacchetto | Fatto | 9 test verdi su fixture generate; EQB 24 (45 pagine, 302 blocchi, pp. 5 e 40 segnalate da OCR) e EQB 48 (51 pagine, 240 blocchi): ordine colonne **confrontato a vista** con l'originale su pag. 11 (n. 24) e 21 (n. 48) |
| App: importazione TXT/EPUB/PDF/pacchetto, deduplica per impronta, originale immutabile | Scritto | Test unitari in CI (vedi sotto) |
| App: estrazione PDF sul telefono con colonne + OCR Vision per pagine senza testo | Scritto | Test colonne in CI; OCR non ancora provato su scansione reale |
| App: lettura in italiano, originale con un tocco, pagina PDF originale | Scritto | Non ancora provato su iPhone |
| App: traduzione Apple (coda su `translationTask`) e API Claude con budget | Scritto | **Non provabile in CI** (modelli lingua da scaricare sul telefono) |
| App: audio italiano a segmenti persistenti (AAC), avvio a 12 s, riserva fino a 60 s, background, Now Playing, comandi cuffie, interruzioni, ripresa, timer, segnalibri, «Prepara un'ora» | Scritto | Sintesi su file testata in CI se il simulatore ha una voce italiana |
| Misure prova d'ascolto (primo audio, p50/p95/p99, produzione÷consumo, riserva minima, interruzioni) esportabili in JSON | Scritto | — |
| **Prova fisica 60 minuti su iPhone** (schermo bloccato, cambio app, cuffie, telefonata, rete assente) | **Non eseguita** | Serve installazione su iPhone (TestFlight): prossimo passo |

## Limiti noti (reali)

- Traduzione Apple: funziona per coppie supportate dopo il download della lingua; **in background** potrebbe non essere disponibile → il lettore traduce in anticipo (30 blocchi) mentre l'app è aperta e, se la traduzione manca, si ferma dichiarando il blocco (mai passaggio all'inglese). Da misurare nella prova fisica.
- Glossario: applicato solo nel prompt API; la traduzione Apple non accetta glossari.
- Passi in ebraico/greco: annunciati, non letti. L'ebraico estratto dai PDF può avere ordine dei caratteri non affidabile (RTL).
- Ricerca, riassunti, quaderno: lotto 3. Fonti e scansione mensile: lotto 2.
- Archivio locale in JSON per libro (SQLite/FTS5 arriva con la ricerca, lotto 3).

## Istruzioni di ripresa

1. `cd pipeline && python -m pytest -q`
2. CI GitHub (`.github/workflows/ci.yml`): build + test iOS su simulatore, gratuiti perché il repo è pubblico.
3. Prossimo: distribuzione TestFlight (chiave App Store Connect nei segreti di questo repo) → prova fisica 60 min → correzioni → lotto 2.
