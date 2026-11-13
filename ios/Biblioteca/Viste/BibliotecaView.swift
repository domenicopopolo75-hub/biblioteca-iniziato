import SwiftUI
import UniformTypeIdentifiers

struct BibliotecaView: View {
    @EnvironmentObject var libreria: Libreria
    @State private var scegli = false

    static let tipi: [UTType] = [.pdf, UTType(filenameExtension: "epub") ?? .data, .plainText, .json,
                                 UTType(filenameExtension: "md") ?? .plainText]

    var body: some View {
        List {
            if let f = libreria.importazioneInCorso {
                HStack { ProgressView(); Text("Importo \(f)…").foregroundStyle(.secondary) }
            }
            if let e = libreria.ultimoErrore {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .onTapGesture { libreria.ultimoErrore = nil }
            }
            ForEach(libreria.libri) { l in
                NavigationLink(value: l) { RigaLibro(libro: l) }
            }
            .onDelete { idx in idx.map { libreria.libri[$0] }.forEach(libreria.elimina) }
        }
        .overlay {
            if libreria.libri.isEmpty && libreria.importazioneInCorso == nil {
                ContentUnavailableView("Nessun libro", systemImage: "book.closed",
                                       description: Text("Importa un PDF, un EPUB o un testo dai File (anche da Drive)."))
            }
        }
        .navigationTitle("Biblioteca")
        .navigationDestination(for: Libro.self) { LibroView(libro: $0) }
        .toolbar {
            Button { scegli = true } label: { Label("Importa", systemImage: "plus") }
                .accessibilityIdentifier("importa")
        }
        .fileImporter(isPresented: $scegli, allowedContentTypes: Self.tipi, allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            Task { for u in urls { await libreria.importa(u) } }
        }
    }
}

struct RigaLibro: View {
    let libro: Libro
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(libro.titolo).font(.headline).lineLimit(2)
            HStack(spacing: 8) {
                if let a = libro.autore { Text(a) }
                Text(libro.formato.uppercased())
                Text(Locale.current.localizedString(forLanguageCode: libro.lingua ?? "") ?? "lingua ?")
                if libro.daTradurre { Image(systemName: "character.bubble") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LibroView: View {
    @EnvironmentObject var libreria: Libreria
    @EnvironmentObject var lettore: Lettore
    let libro: Libro

    var body: some View {
        let pos = libreria.posizione(libro.id)
        List {
            Section {
                NavigationLink { LetturaView(libro: libro) } label: {
                    Label("Leggi in italiano", systemImage: "text.book.closed")
                }
                Button {
                    lettore.ascolta(libro)
                } label: {
                    Label(pos.ordine > 0 ? "Ascolta in italiano (riprendi)" : "Ascolta in italiano", systemImage: "play.circle")
                }
                .accessibilityIdentifier("ascolta")
                Button { lettore.preparaOffline(libro, minuti: 60) } label: {
                    Label("Prepara un'ora per dopo", systemImage: "arrow.down.circle")
                }
                NavigationLink {
                    InArrivoView(titolo: "Studia questo testo", testo: "Riassunti per capitoli, ricerca di passaggi ed esame completo: lotto 3.")
                } label: { Label("Studia questo testo", systemImage: "graduationcap") }
            }
            Section("Edizione") {
                LabeledContent("File", value: libro.nomeOriginale)
                LabeledContent("Formato", value: libro.formato.uppercased())
                LabeledContent("Lingua", value: libro.lingua ?? "non rilevata")
                LabeledContent("Blocchi di testo", value: "\(libro.blocchi)")
                LabeledContent(libro.formato == "epub" ? "Sezioni con testo" : "Pagine con testo",
                               value: "\(libro.unitaConTesto) su \(libro.unitaTotali)")
                if libro.unitaOCR > 0 { LabeledContent("Pagine da OCR", value: "\(libro.unitaOCR)") }
                if libro.unitaSenzaTesto > 0 {
                    LabeledContent("Pagine illeggibili", value: "\(libro.unitaSenzaTesto)").foregroundStyle(.orange)
                }
                LabeledContent("Impronta", value: String(libro.id.prefix(12)))
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
    }
}
