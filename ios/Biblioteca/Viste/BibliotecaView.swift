import SwiftUI
import UniformTypeIdentifiers

struct BibliotecaView: View {
    @EnvironmentObject var libreria: Libreria
    @AppStorage("guidaChiusa") private var guidaChiusa = false
    @State private var scegliFile = false
    @State private var apriDrive = false

    static let tipi: [UTType] = [.pdf, UTType(filenameExtension: "epub") ?? .data, .plainText, .json,
                                 UTType(filenameExtension: "md") ?? .plainText]

    var body: some View {
        List {
            if !guidaChiusa {
                Section { GuidaView(chiudi: { guidaChiusa = true }) }
            }
            if let f = libreria.importazioneInCorso {
                HStack { ProgressView(); Text("Importo \(f)…").foregroundStyle(.secondary) }
            }
            if let e = libreria.ultimoErrore {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .onTapGesture { libreria.ultimoErrore = nil }
            }
            Section(libreria.libri.isEmpty ? "" : "\(libreria.libri.count) libri") {
                ForEach(libreria.libri) { l in
                    NavigationLink(value: l) { RigaLibro(libro: l) }
                }
                .onDelete { idx in idx.map { libreria.libri[$0] }.forEach(libreria.elimina) }
            }
        }
        .overlay {
            if libreria.libri.isEmpty && libreria.importazioneInCorso == nil && guidaChiusa {
                ContentUnavailableView("Nessun libro", systemImage: "book.closed",
                                       description: Text("Tocca + per importare da Google Drive o dai File."))
            }
        }
        .navigationTitle("Biblioteca")
        .navigationDestination(for: Libro.self) { LibroView(libro: $0) }
        .navigationDestination(isPresented: $apriDrive) { DriveView() }
        .toolbar {
            Menu {
                Button { apriDrive = true } label: { Label("Da Google Drive", systemImage: "externaldrive.badge.icloud") }
                Button { scegliFile = true } label: { Label("Dai File dell'iPhone", systemImage: "folder") }
                if guidaChiusa { Button { guidaChiusa = false } label: { Label("Mostra la guida", systemImage: "questionmark.circle") } }
            } label: { Label("Aggiungi", systemImage: "plus") }
            .accessibilityIdentifier("importa")
        }
        .fileImporter(isPresented: $scegliFile, allowedContentTypes: Self.tipi, allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            Task { for u in urls { await libreria.importa(u) } }
        }
    }
}

/// Spiega in poche righe cosa fa l'app e dove si trova ogni funzione.
struct GuidaView: View {
    var chiudi: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Come funziona").font(.headline)
                Spacer()
                Button("Chiudi", action: chiudi).font(.caption)
            }
            voce("plus.circle", "Aggiungi libri", "Tocca + › Da Google Drive: sfogli le tue cartelle e importi un file o una cartella intera. Va bene anche dai File.")
            voce("text.book.closed", "Leggi", "Apri un libro › Leggi in italiano. Se è in un'altra lingua viene tradotto; l'originale resta a un tocco.")
            voce("headphones", "Ascolta", "Apri un libro › Ascolta: voce italiana anche a schermo bloccato, riprende da dove eri.")
            voce("sparkles", "Studia", "Apri un libro › Studia: riassunto del libro e delle sue parti, domande sul testo con le pagine citate, esame di tutto il libro.")
            voce("magnifyingglass", "Studio", "Scheda Studio: cerca una parola in tutti i libri (gratis) o fai una domanda a tutta la biblioteca, per esempio «Cosa dicono Kremmerz e Reghini della volontà?». Le risposte si salvano nel Quaderno.")
            voce("eurosign.circle", "Costi", "Riassunti, domande e traduzioni di qualità usano Claude: l'app mostra il costo e non supera il tetto mensile (Impostazioni).")
        }
        .padding(.vertical, 4)
    }

    func voce(_ icona: String, _ titolo: String, _ testo: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icona).frame(width: 22).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(titolo).font(.subheadline.bold())
                Text(testo).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct RigaLibro: View {
    let libro: Libro
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(libro.titolo).font(.headline).lineLimit(2)
            HStack(spacing: 8) {
                if let a = libro.autore { Text(a).lineLimit(1) }
                Text(libro.formato.uppercased())
                Text(Locale(identifier: "it").localizedString(forLanguageCode: libro.lingua ?? "") ?? "lingua ?")
                if libro.daTradurre { Image(systemName: "character.bubble") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LibroView: View {
    @EnvironmentObject var libreria: Libreria
    @EnvironmentObject var lettore: Lettore
    @EnvironmentObject var studio: Studio
    let libro: Libro

    @State private var riassunto: RiassuntoSalvato?
    @State private var domanda = ""
    @State private var risposta: Risposta?
    @State private var errore: String?
    @State private var conferma: Conferma?

    struct Conferma: Identifiable { let id = UUID(); let titolo: String; let costo: Double; let azione: () -> Void }

    var body: some View {
        let pos = libreria.posizione(libro.id)
        List {
            Section {
                NavigationLink { LetturaView(libro: libro, daOrdine: pos.ordine) } label: {
                    Riga(icona: "text.book.closed", titolo: "Leggi in italiano",
                         testo: libro.daTradurre ? "Traduzione italiana; l'originale a un tocco su ogni paragrafo." : "Testo con pagine dell'originale.")
                }
                Button { lettore.ascolta(libro) } label: {
                    Riga(icona: "play.circle", titolo: pos.ordine > 0 ? "Ascolta (riprendi)" : "Ascolta in italiano",
                         testo: "Voce italiana anche a schermo bloccato. Controlli nella scheda Ascolta.")
                }
                .accessibilityIdentifier("ascolta")
                Button { lettore.preparaOffline(libro, minuti: 60) } label: {
                    Riga(icona: "arrow.down.circle", titolo: "Prepara un'ora per dopo", testo: "Traduce e registra 60 minuti per ascoltare senza rete.")
                }
            }

            Section {
                if let r = riassunto ?? studio.riassuntoLibro(libro) {
                    NavigationLink { TestoView(titolo: "Riassunto", testo: r.testo, nota: nota(r)) } label: {
                        Riga(icona: "doc.text.magnifyingglass", titolo: "Riassunto del libro", testo: String(r.testo.prefix(140)) + "…")
                    }
                    NavigationLink { RiassuntiPartiView(libro: libro) } label: {
                        Riga(icona: "list.bullet.rectangle", titolo: "Riassunti delle parti", testo: "\(studio.riassuntiSezioni(libro).count) parti riassunte, con le pagine.")
                    }
                } else {
                    Button {
                        let c = studio.stimaRiassunto(libro)
                        conferma = Conferma(titolo: "Riassumere tutto il libro?", costo: c) { Task { await riassumi() } }
                    } label: {
                        Riga(icona: "doc.text.magnifyingglass", titolo: "Riassumi il libro",
                             testo: "Riassunto di ogni parte e del libro intero, con le pagine. Circa \(euro(studio.stimaRiassunto(libro))).")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Chiedi a questo libro", systemImage: "questionmark.bubble").font(.subheadline.bold())
                    TextField("Es.: che cosa dice dell'equilibrio degli opposti?", text: $domanda, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    HStack {
                        Button("Risposta rapida") { Task { await chiedi() } }
                            .buttonStyle(.borderedProminent).disabled(domanda.count < 4 || studio.inCorso != nil)
                        Button("Esamina tutto il libro") {
                            let c = studio.stimaEsame(libro)
                            conferma = Conferma(titolo: "Leggere tutto il libro per questa domanda?", costo: c) { Task { await esamina() } }
                        }
                        .buttonStyle(.bordered).disabled(domanda.count < 4 || studio.inCorso != nil)
                    }
                    Text("Rapida: cerca i passi pertinenti e li fa analizzare (pochi centesimi). Esamina tutto: legge ogni parte del libro, più lenta e completa (circa \(euro(studio.stimaEsame(libro)))).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let s = studio.inCorso {
                    VStack(alignment: .leading) {
                        HStack { ProgressView(); Text(s).font(.footnote) }
                        if let a = studio.avanzamento { ProgressView(value: Double(a.fatti), total: Double(max(a.totali, 1))) { Text("Parte \(a.fatti) di \(a.totali)").font(.caption) } }
                    }
                }
                if let e = errore { Text(e).foregroundStyle(.red).font(.footnote) }
            } header: { Text("Studia") }

            Section("Edizione") {
                LabeledContent("File", value: libro.nomeOriginale)
                LabeledContent("Lingua", value: Locale(identifier: "it").localizedString(forLanguageCode: libro.lingua ?? "") ?? "non rilevata")
                LabeledContent(libro.formato == "epub" ? "Sezioni con testo" : "Pagine con testo", value: "\(libro.unitaConTesto) su \(libro.unitaTotali)")
                if libro.unitaOCR > 0 { LabeledContent("Pagine lette da immagine (OCR)", value: "\(libro.unitaOCR)") }
                if libro.unitaSenzaTesto > 0 { LabeledContent("Pagine illeggibili", value: "\(libro.unitaSenzaTesto)").foregroundStyle(.orange) }
            }
            let s = libreria.segnalibri(libro.id)
            if !s.isEmpty {
                Section("Segnalibri") {
                    ForEach(s) { sb in
                        Button { lettore.ascolta(libro, da: sb.ordine) } label: {
                            Text("Blocco \(sb.ordine + 1) · \(sb.creato.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                }
            }
        }
        .navigationTitle(libro.titolo)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $risposta) { RispostaView(risposta: $0) }
        .alert(item: $conferma) { c in
            Alert(title: Text(c.titolo), message: Text("Costo stimato: \(euro(c.costo)). Budget rimasto questo mese: \(euro(Budget.carica().residuo))."),
                  primaryButton: .default(Text("Procedi"), action: c.azione), secondaryButton: .cancel(Text("Annulla")))
        }
    }

    func nota(_ r: RiassuntoSalvato) -> String {
        "Generato con \(r.modello) il \(r.data.formatted(date: .abbreviated, time: .omitted)) · costo \(euro(r.costo))"
    }

    func riassumi() async {
        errore = nil
        do { riassunto = try await studio.riassumi(libro) } catch { errore = error.localizedDescription }
    }
    func chiedi() async {
        errore = nil
        do { risposta = try await studio.chiedi(domanda, libri: [libro]) } catch { errore = error.localizedDescription }
    }
    func esamina() async {
        errore = nil
        do { risposta = try await studio.esamina(domanda, libro: libro) } catch { errore = error.localizedDescription }
    }
}

func euro(_ v: Double) -> String { v < 0.01 ? "meno di 1 centesimo" : String(format: "%.2f €", v) }

struct Riga: View {
    let icona: String, titolo: String, testo: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icona).font(.title3).frame(width: 28).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(titolo).foregroundStyle(.primary)
                Text(testo).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}
