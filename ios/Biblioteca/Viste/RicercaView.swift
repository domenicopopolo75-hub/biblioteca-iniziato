import SwiftUI

/// Cerca su telefono, Drive e fonti online. Ogni risultato mostra da dove viene; in cima si dichiara cosa è stato interrogato.
struct RicercaView: View {
    @EnvironmentObject var ricerca: Ricerca
    @State private var testo = ""

    var body: some View {
        List {
            if ricerca.inCorso {
                HStack { ProgressView(); Text("Interrogo le fonti…").foregroundStyle(.secondary) }
            }
            if ricerca.ultimaRicerca == nil && !ricerca.inCorso {
                Section {
                    Text("Scrivi una o più parole e premi Cerca. L'app cerca nei libri già sul telefono, su Google Drive e nelle fonti online supportate. Nulla viene scaricato in modo permanente: puoi consultare il materiale, salvarne il riferimento o scegliere di conservarne una copia.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let q = ricerca.ultimaRicerca, !ricerca.inCorso {
                Section {
                    ForEach(ricerca.esiti) { RigaEsito(esito: $0) }
                } header: { Text("Fonti interrogate per «\(q)»") } footer: {
                    Text("La ricerca copre solo le fonti elencate qui, non tutta Internet. Quelle non interrogate o non raggiungibili sono indicate con il motivo.")
                }
                ForEach(Origine.allCases, id: \.self) { o in
                    let gruppo = ricerca.risultati.filter { $0.origine == o }
                    if !gruppo.isEmpty {
                        Section {
                            ForEach(gruppo) { r in RigaRisultato(risultato: r) }
                        } header: { Label("\(o.etichetta) (\(gruppo.count))", systemImage: o.icona) }
                    }
                }
                if ricerca.risultati.isEmpty {
                    Section { Text("Nessun risultato nelle fonti interrogate.").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Cerca fonti")
        .searchable(text: $testo, prompt: "Parole da cercare")
        .onSubmit(of: .search) { Task { await ricerca.cerca(testo) } }
        .navigationDestination(for: Risultato.self) { ConsultaView(risultato: $0) }
    }
}

struct RigaEsito: View {
    let esito: Ricerca.EsitoFonte
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: icona).foregroundStyle(colore)
                Text(esito.nome).font(.subheadline)
                Spacer()
                Text(sintesi).font(.caption).foregroundStyle(colore)
            }
            if let d = dettaglio { Text(d).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    var icona: String {
        switch esito.stato {
        case .interrogata: return "checkmark.circle"
        case .nonRaggiungibile: return "exclamationmark.triangle"
        case .nonInterrogata: return "minus.circle"
        }
    }
    var colore: Color {
        switch esito.stato {
        case .interrogata: return .green
        case .nonRaggiungibile: return .orange
        case .nonInterrogata: return .secondary
        }
    }
    var sintesi: String {
        switch esito.stato {
        case .interrogata(let n): return n == 1 ? "1 risultato" : "\(n) risultati"
        case .nonRaggiungibile: return "non raggiungibile"
        case .nonInterrogata: return "non interrogata"
        }
    }
    var dettaglio: String? {
        switch esito.stato {
        case .interrogata: return esito.dettaglio
        case .nonRaggiungibile(let m), .nonInterrogata(let m): return m
        }
    }
}

struct RigaRisultato: View {
    @EnvironmentObject var libreria: Libreria
    @EnvironmentObject var registro: Registro
    let risultato: Risultato

    var body: some View {
        if risultato.origine == .telefono, let id = risultato.libroId, let libro = libreria.libri.first(where: { $0.id == id }) {
            NavigationLink(value: libro) { contenuto }
        } else {
            NavigationLink(value: risultato) { contenuto }
        }
    }

    var contenuto: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(risultato.titolo).font(.headline).lineLimit(2)
            HStack(spacing: 8) {
                if let a = risultato.autore { Text(a).lineLimit(1) }
                Text(risultato.nomeFonte).lineLimit(1)
                if let f = risultato.formato { Text(f.uppercased()) }
                if let l = risultato.lingua { Text(l) }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if risultato.origine != .telefono, risultato.libroId != nil {
                    Label("Copia sul telefono", systemImage: "iphone").font(.caption2).foregroundStyle(.green)
                }
                if registro.trova(risultato.id) != nil {
                    Label("Riferimento salvato", systemImage: "bookmark.fill").font(.caption2).foregroundStyle(.tint)
                }
                if risultato.accesso == .soloCollegamento {
                    Label("Solo collegamento", systemImage: "link").font(.caption2).foregroundStyle(.orange)
                }
            }
            if let a = risultato.anteprima {
                Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// Consulta un materiale: provenienza, livello di lettura, azioni distinte e testo.
struct ConsultaView: View {
    @EnvironmentObject var consultazione: Consultazione
    @EnvironmentObject var registro: Registro
    @EnvironmentObject var libreria: Libreria
    let risultato: Risultato

    enum Caricamento { case nessuno, inCorso, letto(Consultazione.Letto), errore(String) }
    @State private var stato = Caricamento.nessuno
    @State private var messaggio: String?
    @State private var conservazione = false
    @State private var bloccoAppunto: Blocco?
    @State private var testoAppunto = ""
    @State private var visibili = 60

    var riferimento: Riferimento? { registro.trova(risultato.id) }
    var letto: Consultazione.Letto? { if case .letto(let l) = stato { return l }; return nil }

    var livelloMostrato: LivelloLettura {
        max(riferimento?.livello ?? .riferimento, letto?.livello ?? .riferimento)
    }

    var body: some View {
        List {
            Section("Provenienza") {
                LabeledContent("Fonte", value: risultato.nomeFonte)
                LabeledContent("Dove si trova", value: risultato.origine.etichetta)
                LabeledContent("Autore", value: (riferimento?.autore ?? risultato.autore) ?? "non indicato")
                if let l = riferimento?.lingua ?? risultato.lingua { LabeledContent("Lingua", value: l) }
                if let f = risultato.formato { LabeledContent("Formato", value: f) }
                if (riferimento?.titoloProvvisorio ?? risultato.titoloDaUrl) {
                    Text("Titolo ricavato dall'indirizzo della pagina: non è ancora stato confermato dalla pagina stessa.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let u = URL(string: risultato.collegamento), !risultato.collegamento.isEmpty {
                    Link(destination: u) { Label("Apri la fonte originale", systemImage: "safari") }
                }
            }

            Section {
                Label(livelloMostrato.etichetta, systemImage: icona(livelloMostrato)).font(.subheadline.bold())
                Text(livelloMostrato.spiegazione).font(.footnote).foregroundStyle(.secondary)
                if let d = riferimento?.ultimaConsultazione ?? letto?.data {
                    LabeledContent("Ultima consultazione", value: d.formatted(date: .abbreviated, time: .shortened))
                }
                if let r = riferimento, r.stato != .nonVerificata {
                    Text(r.stato.etichetta + (r.notaStato.map { ": " + $0 } ?? ""))
                        .font(.footnote).foregroundStyle(r.stato == .verificata ? Color.green : Color.orange)
                }
                if let a = letto?.avviso { Text(a).font(.footnote).foregroundStyle(.orange) }
            } header: { Text("Lettura") }

            Section {
                switch stato {
                case .inCorso: HStack { ProgressView(); Text("Recupero temporaneo del testo…") }
                case .errore(let m): Text(m).foregroundStyle(.red).font(.footnote)
                default: EmptyView()
                }
                if risultato.accesso == .consultabile, letto == nil {
                    Button { Task { await carica(aggiorna: true) } } label: { Label("Consulta nell'app", systemImage: "text.book.closed") }
                }
                if letto != nil, riferimento != nil {
                    Button { Task { await carica(aggiorna: true) } } label: { Label("Riverifica la fonte", systemImage: "arrow.triangle.2.circlepath") }
                }
                if riferimento == nil {
                    Button { consultazione.salvaRiferimento(risultato, letto: letto) } label: {
                        Label("Salva riferimento", systemImage: "bookmark")
                    }
                } else {
                    Label("Riferimento salvato", systemImage: "bookmark.fill").foregroundStyle(.tint)
                }
                if let id = riferimento?.copiaId ?? risultato.libroId, let libro = libreria.libri.first(where: { $0.id == id }) {
                    NavigationLink(value: libro) { Label("Copia conservata: apri", systemImage: "checkmark.circle.fill") }
                } else if risultato.accesso == .consultabile {
                    Button { Task { await conserva() } } label: {
                        Label("Conserva una copia", systemImage: "square.and.arrow.down")
                    }.disabled(conservazione)
                }
                if let m = messaggio { Text(m).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Azioni") } footer: {
                Text("Salva riferimento tiene solo scheda e collegamento. Conserva una copia scarica il contenuto e lo tiene sul telefono: è una scelta a parte.")
            }

            if let a = risultato.anteprima, letto == nil {
                Section("Anteprima") {
                    Text(a).font(.footnote)
                    Text("Solo un estratto: il testo non è stato letto.").font(.caption).foregroundStyle(.secondary)
                }
            }

            let note = registro.appunti(per: risultato.id)
            if !note.isEmpty {
                Section("Appunti") {
                    ForEach(note) { n in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(n.nota).font(.subheadline)
                            Text("«\(n.estratto.prefix(120))…»").font(.caption).foregroundStyle(.secondary)
                            Text("\(n.passaggio) · consultato il \(n.consultatoIl.formatted(date: .abbreviated, time: .omitted))"
                                 + ((riferimento?.impronta != nil && n.impronta != riferimento?.impronta) ? " · versione precedente" : ""))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .swipeActions { Button("Elimina", role: .destructive) { registro.rimuovi(appunto: n.id) } }
                    }
                }
            }

            if let l = letto {
                Section {
                    let blocchi = l.pacchetto.blocks
                    ForEach(Array(blocchi.prefix(visibili).enumerated()), id: \.element.id) { i, b in
                        VStack(alignment: .leading, spacing: 2) {
                            let d = b.locator.descrizione(formato: l.pacchetto.edition.format)
                            if i == 0 || d != blocchi[i - 1].locator.descrizione(formato: l.pacchetto.edition.format) {
                                Text(d).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(b.text).font(b.eTitolo ? .headline : (b.eNota ? .footnote.italic() : .body)).textSelection(.enabled)
                        }
                        .contextMenu { Button { bloccoAppunto = b; testoAppunto = "" } label: { Label("Aggiungi appunto", systemImage: "note.text.badge.plus") } }
                    }
                    if blocchi.count > visibili {
                        Button("Mostra altri paragrafi (\(blocchi.count - visibili))") { visibili += 80 }
                    }
                } header: { Text("Testo (tieni premuto un paragrafo per un appunto)") }
            }
        }
        .navigationTitle(riferimento?.titolo ?? risultato.titolo)
        .navigationBarTitleDisplayMode(.inline)
        .task { if risultato.accesso == .consultabile { await carica(aggiorna: false) } }
        .alert("Nuovo appunto", isPresented: Binding(get: { bloccoAppunto != nil }, set: { if !$0 { bloccoAppunto = nil } })) {
            TextField("Nota", text: $testoAppunto)
            Button("Salva") {
                if let b = bloccoAppunto, let l = letto { consultazione.aggiungiAppunto(risultato, letto: l, blocco: b, nota: testoAppunto) }
                bloccoAppunto = nil
            }
            Button("Annulla", role: .cancel) { bloccoAppunto = nil }
        } message: {
            Text("L'appunto conserva fonte, passaggio e data di consultazione e salva anche il riferimento.")
        }
    }

    func icona(_ l: LivelloLettura) -> String {
        switch l {
        case .riferimento: return "link"
        case .anteprima: return "eye"
        case .parziale: return "circle.lefthalf.filled"
        case .completo: return "checkmark.circle"
        }
    }

    func carica(aggiorna: Bool) async {
        if case .letto = stato, !aggiorna { return }
        stato = .inCorso
        do { stato = .letto(try await consultazione.leggi(risultato, aggiorna: aggiorna)) }
        catch { stato = .errore(error.localizedDescription) }
    }

    func conserva() async {
        conservazione = true; defer { conservazione = false }
        do {
            let l = try await consultazione.conserva(risultato)
            messaggio = "Copia conservata: «\(l.titolo)». Un secondo tentativo non crea un doppione."
        } catch { messaggio = error.localizedDescription }
    }
}

/// Elenco dei riferimenti salvati: restano dopo il riavvio e dopo lo svuotamento della memoria temporanea.
struct RiferimentiView: View {
    @EnvironmentObject var registro: Registro
    @State private var daEliminare: Riferimento?

    var body: some View {
        List {
            ForEach(registro.riferimenti) { r in
                NavigationLink { ConsultaView(risultato: r.comeRisultato()) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.titolo).font(.headline).lineLimit(2)
                        Text("\(r.nomeFonte) · \(r.origine.etichetta)").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(r.livello.etichetta)
                            if r.stato == .cambiata || r.stato == .nonRaggiungibile {
                                Label(r.stato.etichetta, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            if r.copiaId != nil { Label("copia", systemImage: "checkmark.circle") }
                            let n = registro.appunti(per: r.id).count
                            if n > 0 { Label("\(n)", systemImage: "note.text") }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .swipeActions { Button("Elimina", role: .destructive) { daEliminare = r } }
            }
        }
        .overlay {
            if registro.riferimenti.isEmpty {
                ContentUnavailableView("Nessun riferimento", systemImage: "bookmark",
                                       description: Text("Cerca un materiale e tocca «Salva riferimento»."))
            }
        }
        .navigationTitle("Riferimenti")
        .alert("Eliminare il riferimento?", isPresented: Binding(get: { daEliminare != nil }, set: { if !$0 { daEliminare = nil } })) {
            Button("Elimina", role: .destructive) { if let r = daEliminare { registro.elimina(r.id) }; daEliminare = nil }
            Button("Annulla", role: .cancel) { daEliminare = nil }
        } message: {
            Text("Verranno eliminati anche i suoi \(daEliminare.map { registro.appunti(per: $0.id).count } ?? 0) appunti. Una copia conservata in biblioteca resta.")
        }
    }
}

/// Sezione delle Impostazioni: memoria temporanea con limite e svuotamento.
struct MemoriaTemporaneaSezione: View {
    @EnvironmentObject var consultazione: Consultazione
    @State private var occupata: Int64 = 0

    var body: some View {
        Section {
            LabeledContent("Occupata", value: ByteCountFormatter.string(fromByteCount: occupata, countStyle: .file))
            LabeledContent("Limite", value: ByteCountFormatter.string(fromByteCount: consultazione.memoria.limiteByte, countStyle: .file))
            Button("Svuota memoria temporanea", role: .destructive) {
                consultazione.memoria.svuota()
                occupata = consultazione.memoria.occupazione
            }
        } header: { Text("Memoria temporanea") } footer: {
            Text("Contiene i testi recuperati per leggerli. Svuotarla non toglie riferimenti, appunti né copie conservate. La preparazione offline dell'ascolto è separata.")
        }
        .onAppear { occupata = consultazione.memoria.occupazione }
    }
}
