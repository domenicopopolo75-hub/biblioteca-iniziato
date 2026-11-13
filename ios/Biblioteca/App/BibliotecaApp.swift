import SwiftUI

@main
struct BibliotecaApp: App {
    @StateObject private var libreria: Libreria
    @StateObject private var traduttore: TraduttoreApple
    @StateObject private var lettore: Lettore
    @StateObject private var impostazioni = Impostazioni()

    init() {
        let l = Libreria()
        let t = TraduttoreApple()
        _libreria = StateObject(wrappedValue: l)
        _traduttore = StateObject(wrappedValue: t)
        _lettore = StateObject(wrappedValue: Lettore(libreria: l, apple: t))
    }

    var body: some Scene {
        WindowGroup {
            Radice()
                .environmentObject(libreria)
                .environmentObject(lettore)
                .environmentObject(traduttore)
                .environmentObject(impostazioni)
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
    @AppStorage("usaAPI") var usaAPI = false { didSet { versione += 1 } }
    @AppStorage("avvioSecondi") var avvioSecondi = 12.0 { didSet { versione += 1 } }
    @AppStorage("riservaSecondi") var riservaSecondi = 60.0 { didSet { versione += 1 } }
    @Published var versione = 0

    func applica(a l: Lettore) {
        l.leggiNote = leggiNote
        l.annunciaScrittiNonLatini = annunciaScritti
        l.identificativoVoce = voce.isEmpty ? nil : voce
        l.usaAPI = usaAPI
        l.avvioSecondi = avvioSecondi
        l.riservaObiettivo = max(riservaSecondi, avvioSecondi)
    }
}

struct Radice: View {
    @EnvironmentObject var lettore: Lettore
    @State private var scheda = 0

    var body: some View {
        TabView(selection: $scheda) {
            NavigationStack { BibliotecaView() }
                .tabItem { Label("Biblioteca", systemImage: "books.vertical") }.tag(0)
            NavigationStack { AscoltaView() }
                .tabItem { Label("Ascolta", systemImage: "headphones") }.tag(1)
            NavigationStack { InArrivoView(titolo: "Ricerca", testo: "Ricerca esatta e per concetti, riassunti con riferimenti, esame integrale con copertura e quaderno: lotto 3 del piano.") }
                .tabItem { Label("Ricerca", systemImage: "magnifyingglass") }.tag(2)
            NavigationStack { FontiView() }
                .tabItem { Label("Fonti", systemImage: "globe") }.tag(3)
        }
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
