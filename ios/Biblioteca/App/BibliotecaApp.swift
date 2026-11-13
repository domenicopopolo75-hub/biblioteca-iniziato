import SwiftUI

@main
struct BibliotecaApp: App {
    @StateObject private var libreria: Libreria
    @StateObject private var traduttore: TraduttoreApple
    @StateObject private var lettore: Lettore
    @StateObject private var impostazioni = Impostazioni()
    @StateObject private var studio: Studio
    @StateObject private var drive = GoogleDrive()

    init() {
        let l = Libreria()
        let t = TraduttoreApple()
        _libreria = StateObject(wrappedValue: l)
        _traduttore = StateObject(wrappedValue: t)
        _lettore = StateObject(wrappedValue: Lettore(libreria: l, apple: t))
        _studio = StateObject(wrappedValue: Studio(libreria: l))
    }

    var body: some Scene {
        WindowGroup {
            Radice()
                .environmentObject(libreria)
                .environmentObject(lettore)
                .environmentObject(traduttore)
                .environmentObject(impostazioni)
                .environmentObject(studio)
                .environmentObject(drive)
                .modifier(HostTraduzioneApple(traduttore: traduttore))
                .onAppear { impostazioni.applica(a: lettore) }
                .onChange(of: impostazioni.versione) { impostazioni.applica(a: lettore) }
                .onOpenURL { url in Task { await libreria.importa(url) } }
        }
    }
}

/// Preferenze dell'utente, applicate al lettore.
@MainActor
final class Impostazioni: ObservableObject {
    @AppStorage("leggiNote") var leggiNote = true { didSet { versione += 1 } }
    @AppStorage("annunciaScritti") var annunciaScritti = true { didSet { versione += 1 } }
    @AppStorage("voce") var voce = "" { didSet { versione += 1 } }
    @AppStorage("usaAPI") var usaAPI = true { didSet { versione += 1 } }
    @AppStorage("avvioSecondi") var avvioSecondi = 12.0 { didSet { versione += 1 } }
    @AppStorage("riservaSecondi") var riservaSecondi = 60.0 { didSet { versione += 1 } }
    @Published var versione = 0

    func applica(a l: Lettore) {
        l.leggiNote = leggiNote
        l.annunciaScrittiNonLatini = annunciaScritti
        l.identificativoVoce = voce.isEmpty ? nil : voce
        l.usaAPI = usaAPI && ClienteClaude.chiavePresente
        l.avvioSecondi = avvioSecondi
        l.riservaObiettivo = max(riservaSecondi, avvioSecondi)
    }
}

struct Radice: View {
    @EnvironmentObject var lettore: Lettore
    @EnvironmentObject var impostazioni: Impostazioni
    @EnvironmentObject var libreria: Libreria
    @State private var scheda = 0

    var body: some View {
        TabView(selection: $scheda) {
            NavigationStack { BibliotecaView() }
                .tabItem { Label("Biblioteca", systemImage: "books.vertical") }.tag(0)
            NavigationStack { StudioView() }
                .tabItem { Label("Studio", systemImage: "sparkles") }.tag(1)
            NavigationStack { AscoltaView() }
                .tabItem { Label("Ascolta", systemImage: "headphones") }.tag(2)
            NavigationStack { ImpostazioniView() }
                .tabItem { Label("Impostazioni", systemImage: "gearshape") }.tag(3)
        }
        .onChange(of: lettore.libro?.id) { if lettore.libro != nil, lettore.stato == .preparazione { scheda = 2 } }
        .onAppear { impostazioni.applica(a: lettore); Task.detached { await MainActor.run { libreria.assicuraIndice() } } }
    }
}

struct InArrivoView: View {
    let titolo: String
    let testo: String
    var body: some View {
        ContentUnavailableView(titolo, systemImage: "hammer", description: Text(testo))
            .navigationTitle(titolo)
    }
}
