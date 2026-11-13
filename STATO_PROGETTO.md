# STATO_PROGETTO — Biblioteca dell'Iniziato

Aggiornato: 13/11/2026 ore 13:45 · Esecutore: Claude (Code) · Mandato: dossier Ecce Quam Bonum §13.2

## Decisioni del proprietario (13/11/2026)

- **D1** Repository `biblioteca-iniziato` dedicato, separato da Cantina e Mail; reso **pubblico** per usare i runner macOS gratuiti di GitHub. Solo codice: nessun libro o dato personale (vedi `.gitignore`).
- **D2** Traduzione: **Apple sul telefono** (gratis) come predefinita; **API Claude** solo su scelta esplicita e **solo con budget mensile configurato** (budget 0 = disattivata).
- **D3** Voce: **voce Apple italiana locale** (si consiglia di scaricare una voce Avanzata/Premium).
- **D4** Ricerca mensile dei nuovi testi (lotto 2): **GitHub Actions cron**.
- **D6** (13/11 pomeriggio) Il proprietario giudica il lotto 1 troppo semplice: Studio e Drive anticipati. **IA = Claude via API**, tetto **5 €/mese** (Haiku 5.5 per traduzioni/riassunti, Sonnet 5.5 per domande e analisi). **Google Drive dentro l'app** (OAuth sola lettura).
- **D5** TestFlight con **chiave App Store Connect dedicata** «GitHub Biblioteca» (ID L7R3WR7D57, Amministrazione); segreto unico `ASC_KEY_P8` nel repo. Identificativo `it.biblioteca.iniziato`, scheda app «Biblioteca dell'Iniziato» (id 6834386818). Firma **gestita da Apple** (cloud signing): il team ha già il massimo di certificati di distribuzione e non si toccano quelli di Cantina/Ripulire mail.

## Lotto 1 — primo percorso completo (in corso)

| Parte | Stato | Prova |
|---|---|---|
| Motore testi Python (`pipeline/`): PDF a colonne, EPUB, TXT → pacchetto | Fatto | 9 test verdi su fixture generate; EQB 24 (45 pagine, 302 blocchi, pp. 5 e 40 segnalate da OCR) e EQB 48 (51 pagine, 240 blocchi): ordine colonne **confrontato a vista** con l'originale su pag. 11 (n. 24) e 21 (n. 48) |
| Compilazione iOS e test su simulatore (CI gratuita) | Fatto | 9/9 test superati: normalizzazione, colonne PDF, EPUB, contratto con la pipeline, importazione e deduplica, posizione dopo riavvio, traduzioni invalidate se cambia il testo, **sintesi vocale italiana su file** |
| TestFlight | Fatto | Build 1 caricata e **VALID** da Apple; gruppo interno «Proprietario» con Domenico |
| App: importazione TXT/EPUB/PDF/pacchetto, deduplica per impronta, originale immutabile | Scritto e testato in CI | |
| App: estrazione PDF sul telefono con colonne + OCR Vision per pagine senza testo | Scritto | Test colonne in CI; OCR non ancora provato su scansione reale |
| App: lettura in italiano, originale con un tocco, pagina PDF originale | Scritto | Non ancora provato su iPhone |
| App: traduzione Apple (coda su `translationTask`) e API Claude con budget | Scritto | **Non provabile in CI** (modelli lingua da scaricare sul telefono) |
| App: audio italiano a segmenti persistenti (AAC), avvio a 12 s, riserva fino a 60 s, background, Now Playing, comandi cuffie, interruzioni, ripresa, timer, segnalibri, «Prepara un'ora» | Scritto | Sintesi su file testata in CI se il simulatore ha una voce italiana |
| Misure prova d'ascolto (primo audio, p50/p95/p99, produzione÷consumo, riserva minima, interruzioni) esportabili in JSON | Scritto | — |
| **Prova fisica 60 minuti su iPhone** (schermo bloccato, cambio app, cuffie, telefonata, rete assente) | **Non eseguita** | App installabile da TestFlight: tocca a Domenico; esportare le misure (scheda Ascolta) e caricarle su Drive |

## Studio e Drive (build 2, 13/11/2026)

| Parte | Stato | Prova |
|---|---|---|
| Indice di ricerca SQLite FTS5 su tutti i libri (prefissi, accenti ignorati) | Fatto | Test in CI |
| Riassunto per parti (Haiku) e del libro (Sonnet), con pagine, salvati e non ripagati | Scritto | Sezioni testate in CI; chiamate reali non provate (serve la chiave) |
| Chiedi a un libro / a tutta la biblioteca: parole chiave multilingue (Haiku) → passi FTS5 → risposta Sonnet con fonti [n] apribili | Scritto | idem |
| Esamina tutto il libro: ogni parte letta, copertura dichiarata | Scritto | idem |
| Quaderno delle risposte, condivisione | Scritto | — |
| Budget: costo stimato prima delle operazioni lunghe, contatore per funzione, blocco al tetto | Fatto | Calcolo costi testato in CI |
| Google Drive nell'app: accesso, cartelle, ricerca, import file e cartelle intere | Scritto | **Manca il client OAuth Google** (da creare in Google Cloud Console): finché manca l'app lo dice |
| Interfaccia: guida iniziale, schede Biblioteca/Studio/Ascolta/Impostazioni | Fatto | Build 2 inviata a TestFlight |

## Limiti noti (reali)

- Traduzione Apple: funziona per coppie supportate dopo il download della lingua; **in background** potrebbe non essere disponibile → il lettore traduce in anticipo (30 blocchi) mentre l'app è aperta e, se la traduzione manca, si ferma dichiarando il blocco (mai passaggio all'inglese). Da misurare nella prova fisica.
- Glossario: applicato solo nel prompt API; la traduzione Apple non accetta glossari.
- Passi in ebraico/greco: annunciati, non letti. L'ebraico estratto dai PDF può avere ordine dei caratteri non affidabile (RTL).
- Ricerca, riassunti, quaderno: lotto 3. Fonti e scansione mensile: lotto 2.
- Archivio locale in JSON per libro (SQLite/FTS5 arriva con la ricerca, lotto 3).

## Istruzioni di ripresa

1. `cd pipeline && python -m pytest -q`
2. CI GitHub (`.github/workflows/ci.yml`): build + test iOS su simulatore, gratuiti perché il repo è pubblico.
3. Nuova build: Actions → TestFlight → Run workflow (numero build automatico). `solo_tester` aggiorna gruppo/tester.
4. Prossimo: prova fisica 60 min → correzioni dai dati misurati → lotto 2 (fonti e scansione mensile con approvazione).
