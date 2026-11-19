# STATO_PROGETTO — Biblioteca dell'Iniziato

Aggiornato: 19/11/2026 · Esecutore: Claude (Code) · Mandato: lotto Riferimenti (ricerca Drive + online, consultazione, copia volontaria)

## Decisioni del proprietario (13/11/2026)

- **D1** Repository `biblioteca-iniziato` dedicato, separato da Cantina e Mail; reso **pubblico** per usare i runner macOS gratuiti di GitHub. Solo codice: nessun libro o dato personale (vedi `.gitignore`).
- **D2** Traduzione: **Apple sul telefono** (gratis) come predefinita; **API Claude** solo su scelta esplicita e **solo con budget mensile configurato** (budget 0 = disattivata).
- **D3** Voce: **voce Apple italiana locale** (si consiglia di scaricare una voce Avanzata/Premium).
- **D4** Ricerca mensile dei nuovi testi (lotto 2): **GitHub Actions cron**.
- **D6** (13/11 pomeriggio) Il proprietario giudica il lotto 1 troppo semplice: Studio e Drive anticipati. **IA = Claude via API**, tetto **5 €/mese** (Haiku 5.5 per traduzioni/riassunti, Sonnet 5.5 per domande e analisi). **Google Drive dentro l'app** (OAuth sola lettura).
- **D7** (19/11) Cercare e studiare su Drive e online **senza scaricare in modo permanente**: salvare un riferimento e conservare una copia sono due decisioni distinte; la copia solo su scelta esplicita.
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
| Google Drive nell'app: accesso, cartelle, ricerca, import file e cartelle intere | Scritto; client OAuth iOS creato (13/11 sera) | Progetto Google Cloud «Biblioteca Iniziato», Drive API attiva, schermata di consenso in modalità **Test** con utente di prova domenicopopolo75@gmail.com. ID client in `ios/project.yml` (non è un segreto). **Non ancora provato su iPhone**; in modalità Test Google fa scadere il rinnovo dell'accesso dopo 7 giorni: se succede, riaccedere (oppure pubblicare l'app «in produzione» come uso personale) |
| Interfaccia: guida iniziale, schede Biblioteca/Studio/Ascolta/Impostazioni | Fatto | Build 2 inviata a TestFlight |

## Lotto 2 — fonti, scansione mensile, approvazione, import (13/11/2026, sera)

Codice in `servizio/` (solo libreria standard, 34 test), flussi in `.github/workflows/`. Esecutore: **GitHub Actions** (D-cron scelto dal proprietario). Stato in ramo `dati` (solo metadati; repository pubblico).

| Requisito (§13.1/§13.2) | Stato | Prova |
|---|---|---|
| Registro 17 fonti + 4 servizi personali con capacità | Fatto (`servizio/fonti.json`) | test registro |
| Adattatori reali | **6 attivi su 17**: Project Gutenberg (catalogo ufficiale CSV), Internet Archive, Libera Conoscenza, O.T.O. Italia, Genoa Lodge, Fuoco Sacro | Scansione reale su GitHub: 6/6 ok (esecuzione 43514761938) |
| Altre 11 fonti | **Non implementate** (Liber Liber, Wikisource, Gallica, e-rara, MDZ, Steiner Archive, Hermetic Library, Sacred Texts, IAPSOP, Cintamani, Pax Pleroma) | Il rapporto dice «parziale» finché mancano |
| robots.txt, timeout, backoff, fonte guasta isolata | Fatto | test + Gutendex (403 Cloudflare) isolato nella prima prova reale, poi sostituito dal catalogo ufficiale |
| Scheduler mensile | Cron **giornaliero** 06:17 UTC che parte solo se dovuta (1° del mese, 07:00 Europe/Rome); un cron saltato si recupera il giorno dopo | Simulazione di 12 mesi nei test; esecuzione reale con `forza` |
| Blocco esecuzioni sovrapposte, recupero blocco abbandonato | Fatto | test |
| Confronto con inventario, dedup, non-duplicato per nuova edizione | Inventario iniziale dal dossier + Drive (da arricchire con l'elenco reale di Drive) | test |
| Pertinenza (soglia) e rapporto limitato ai 40 più pertinenti | Fatto, pesi da tarare | prima scansione reale: 488 nuovi → 40 mostrati |
| Notifica | **Issue GitHub** (arriva in GitHub Mobile / email) | Issue creata dalla scansione reale |
| Approvazione verificata nel servizio; A≠B; candidato modificato invalida; doppio invio idempotente | Fatto | test negativi con fixture |
| Download solo con approvazione valida, verifica formato, hash, dedup, retry idempotenti | Fatto con Drive finto | test (retry, upload già avvenuto, hash duplicato) |
| **Caricamento reale su Drive** | **Scritto, non provato**: mancano le credenziali del servizio (segreti `GOOGLE_CLIENT_ID/SECRET/REFRESH_TOKEN`, `DRIVE_FOLDER_ID`) | `approva-e-importa.yml` registra l'approvazione e segnala che il download non è eseguito |
| **Approvazione dall'app** | **Non fatta**: oggi si approva con il workflow «Approva e importa» (solo proprietario) | — |

Limiti reali: nessun libro nuovo scaricato; nessuna approvazione reale; il ramo `dati` è pubblico (titoli e link di testi pubblici).

## Lotto Riferimenti — ricerca Drive + online (19/11/2026)

Ramo `claude/riferimenti-drive-online-2026-11-19`. CI verde: 43 test iOS (simulatore), 42 test servizio, pipeline.

| Funzione | Stato | Prova |
|---|---|---|
| Ricerca unica: telefono, Drive, online, con provenienza e fonti interrogate/non raggiungibili/non interrogate dichiarate | Fatto | test CI |
| Catalogo riferimenti (titolo, autore se noto, fonte, link, lingua, testo disponibile), persiste al riavvio, nessuna copia | Fatto | test CI |
| Consulta: Drive e articoli HTML (Pax Pleroma), livelli riferimento / anteprima / parziale / completo | Fatto | test CI |
| Fonte cambiata (impronta) o sparita (404/410/403/robots): segnalata, appunti mantenuti; errore di rete non la marca sparita | Fatto | test CI |
| Conserva una copia solo su scelta, senza doppioni (copiaId, provenienza, sha256) | Fatto | test CI |
| Memoria temporanea (Caches, 150 MB, svuotabile senza perdere riferimenti, appunti, copie) | Fatto | test CI |
| Servizio mensile: stato `riferimento`, nessuna approvazione/scarico; workflow con azione `approva` o `salva_riferimento` | Fatto | test servizio |
| Prova su iPhone, OAuth Drive reale, HTML reale di Pax Pleroma | **Da fare** | — |

Fonti nell'app: 6 su 17 interrogabili (Archive, Libera Conoscenza, O.T.O. Italia, Genoa Lodge, Fuoco Sacro, Pax Pleroma); le altre 11 (Gutenberg incluso, catalogo troppo grande) sono dichiarate «non interrogata» con motivo.

## Pendenti dalla revisione 19/11 (NON risolti)

Budget vincolante · citazioni/copertura · checkpoint d'esame · servizio e chiavi privati · stato operativo privato · candidati aggiornabili · proposte/approvazione nell'app (lotto 4b) · allineamento CI/Xcode · cron 06:17 UTC vs 07:00 · scansione «riuscita» se ≥1 fonte · 10 fonti mancanti · OAuth in modalità Test.

Discrepanza nota: STATUS dice 7 fonti attive (con Gutenberg), questo file 6 nell'app.

## Limiti noti (reali)

- Traduzione Apple: funziona per coppie supportate dopo il download della lingua; **in background** potrebbe non essere disponibile → il lettore traduce in anticipo (30 blocchi) mentre l'app è aperta e, se la traduzione manca, si ferma dichiarando il blocco (mai passaggio all'inglese). Da misurare nella prova fisica.
- Glossario: applicato solo nel prompt API; la traduzione Apple non accetta glossari.
- Passi in ebraico/greco: annunciati, non letti. L'ebraico estratto dai PDF può avere ordine dei caratteri non affidabile (RTL).
- Riassunti e quaderno: ancora da fare. Fonti e scansione mensile: lotto 2. Ricerca nella biblioteca (FTS5) e ricerca Drive/online: fatte (vedi lotto Riferimenti).
- Archivio locale in JSON per libro; l'indice SQLite FTS5 è affiancato (già fatto, vedi «Studio e Drive»).

## Istruzioni di ripresa

1. `cd pipeline && python -m pytest -q`
2. CI GitHub (`.github/workflows/ci.yml`): build + test iOS su simulatore, gratuiti perché il repo è pubblico.
3. Nuova build: Actions → TestFlight → Run workflow (numero build automatico). `solo_tester` aggiorna gruppo/tester.
4. Prima: prova iPhone del lotto Riferimenti (cerca «Kremmerz» → consulta un risultato Drive e uno Pax Pleroma → Salva riferimento → riavvia l'app → Conserva una copia due volte → Impostazioni: svuota memoria temporanea). Poi: prova fisica 60 min → correzioni dai dati misurati → lotto 2 (fonti e scansione mensile con approvazione).
