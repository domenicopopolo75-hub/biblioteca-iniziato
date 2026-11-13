import SwiftUI

/// Scheda Studio: ricerca gratuita in tutti i libri, domande a tutta la biblioteca, quaderno.
struct StudioView: View {
    @EnvironmentObject var libreria: Libreria
    @EnvironmentObject var studio: Studio

    @State private var testo = ""
    @State private var riscontri: [Indice.Riscontro] = []
    @State private var cercato = false
    @State private var risposta: Risposta?
    @State private var errore: String?

    var body: some View {
        List {
            Section {
                TextField("Parola o domanda: «Tempio», «Cosa dicono Kremmerz e Reghini della volontà?»", text: $testo, axis: .vertical)
                    .lineLimit(1...4)
                HStack {
                    Button { cerca() } label: { Label("Cerca nei testi", systemImage: "magnifyingglass") }
                        .buttonStyle(.bordered).disabled(testo.count < 3)
                    Button { Task { await chiedi() } } label: { Label("Chiedi alla biblioteca", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent).disabled(testo.count < 4 || studio.inCorso != nil || libreria.libri.isEmpty)
                }
                Text("«Cerca» trova le parole in tutti i libri, gratis e senza rete. «Chiedi» sceglie i passi migliori di tutti i libri e li fa analizzare da Claude, con le fonti numerate (pochi centesimi).")
                    .font(.caption).foregroundStyle(.secondary)
                if let s = studio.inCorso { HStack { ProgressView(); Text(s).font(.footnote) } }
                if let e = errore { Text(e).foregroundStyle(.red).font(.footnote) }
            }

            if cercato {
                Section(riscontri.isEmpty ? "Nessun risultato" : "\(riscontri.count) passi trovati") {
                    ForEach(riscontri) { r in
                        if let l = libreria.libri.first(where: { $0.id == r.libro }) {
                            NavigationLink { LetturaView(libro: l, daOrdine: r.ordine) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(l.titolo).font(.caption.bold()).foregroundStyle(.secondary)
                                    Text(r.estratto).font(.footnote)
                                    if let p = libreria.pacchetto(r.libro), r.ordine < p.blocks.count {
                                        Text(p.blocks[r.ordine].locator.descrizione(formato: p.edition.format)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Section("Quaderno") {
                if studio.quaderno.isEmpty {
                    Text("Le risposte che salvi compaiono qui, con le loro fonti.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(studio.quaderno) { r in
                    NavigationLink { RispostaView(risposta: r) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.domanda).lineLimit(2)
                            Text("\(r.ambito) · \(r.data.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in idx.map { studio.quaderno[$0] }.forEach(studio.eliminaDalQuaderno) }
            }
        }
        .navigationTitle("Studio")
        .navigationDestination(item: $risposta) { RispostaView(risposta: $0) }
    }

    func cerca() {
        libreria.assicuraIndice()
        riscontri = libreria.indice.cerca(testo.components(separatedBy: .whitespacesAndNewlines), limite: 60)
        cercato = true
    }

    func chiedi() async {
        errore = nil
        do { risposta = try await studio.chiedi(testo, libri: []) } catch { errore = error.localizedDescription }
    }
}

struct RispostaView: View {
    @EnvironmentObject var libreria: Libreria
    @EnvironmentObject var studio: Studio
    let risposta: Risposta

    var body: some View {
        List {
            Section {
                Text(risposta.domanda).font(.headline)
                Text(risposta.ambito).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(LocalizedStringKey(risposta.testo)).textSelection(.enabled)
            }
            Section("Copertura e costo") {
                Text(risposta.copertura).font(.footnote)
                Text("Costo: \(euro(risposta.costo)) · \(risposta.data.formatted(date: .abbreviated, time: .shortened))").font(.footnote)
                Text("«Dai testi» riporta le fonti; «Interpretazione» è la lettura dell'IA, da verificare.").font(.caption).foregroundStyle(.secondary)
            }
            if !risposta.fonti.isEmpty {
                Section("Fonti citate") {
                    ForEach(risposta.fonti) { f in
                        if let l = libreria.libri.first(where: { $0.id == f.libro }) {
                            NavigationLink { LetturaView(libro: l, daOrdine: f.ordine) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("[\(f.id)] \(f.titolo)\(f.autore.map { " — \($0)" } ?? "")").font(.caption.bold())
                                    Text(f.riferimento).font(.caption2).foregroundStyle(.secondary)
                                    Text(f.estratto).font(.caption).lineLimit(4)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Risposta")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if studio.quaderno.contains(where: { $0.id == risposta.id }) {
                Label("Nel quaderno", systemImage: "bookmark.fill")
            } else {
                Button { studio.salvaNelQuaderno(risposta) } label: { Label("Salva nel quaderno", systemImage: "bookmark") }
            }
            ShareLink(item: "\(risposta.domanda)\n\n\(risposta.testo)\n\nFonti:\n" + risposta.fonti.map { "[\($0.id)] \($0.titolo), \($0.riferimento)" }.joined(separator: "\n"))
        }
    }
}

struct TestoView: View {
    let titolo: String
    let testo: String
    var nota: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringKey(testo)).textSelection(.enabled)
                if let n = nota { Text(n).font(.caption).foregroundStyle(.secondary) }
            }.padding()
        }
        .navigationTitle(titolo)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ShareLink(item: testo) }
    }
}

struct RiassuntiPartiView: View {
    @EnvironmentObject var libreria: Libreria
    @EnvironmentObject var studio: Studio
    let libro: Libro

    var body: some View {
        let fatti = studio.riassuntiSezioni(libro)
        let sezioni = libreria.pacchetto(libro.id).map(Studio.sezioni(di:)) ?? []
        List {
            Section { Text("\(fatti.count) parti riassunte su \(sezioni.count)").font(.footnote) }
            ForEach(sezioni) { s in
                Section {
                    if let r = fatti[s.id] {
                        Text(LocalizedStringKey(r.testo)).font(.footnote).textSelection(.enabled)
                    } else {
                        Text("Non ancora riassunta").font(.footnote).foregroundStyle(.secondary)
                    }
                    NavigationLink("Leggi questa parte") { LetturaView(libro: libro, daOrdine: s.da) }.font(.caption)
                } header: { Text("\(s.titolo) · \(s.riferimento)") }
            }
        }
        .navigationTitle("Riassunti delle parti")
        .navigationBarTitleDisplayMode(.inline)
    }
}
