import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI

/// Accesso a Google Drive in sola lettura (OAuth 2.0 con PKCE, client iOS senza segreto).
/// Il token di aggiornamento resta nel Portachiavi; nessun dato passa da server terzi.
@MainActor
final class GoogleDrive: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    struct Voce: Identifiable, Hashable, Decodable {
        var id: String
        var name: String
        var mimeType: String
        var size: String?
        var modifiedTime: String?
        var cartella: Bool { mimeType == "application/vnd.google-apps.folder" }
        var documentoGoogle: Bool { mimeType == "application/vnd.google-apps.document" }
        var importabile: Bool {
            documentoGoogle || ["pdf", "epub", "txt", "md", "json"].contains((name as NSString).pathExtension.lowercased())
        }
        var dimensione: String? { size.flatMap { Int64($0) }.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } }
    }

    @Published private(set) var collegato = false
    @Published var errore: String?

    /// Client OAuth iOS creato in Google Cloud per questa app (non è un segreto).
    static var clientID: String? {
        let v = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String
        return (v?.isEmpty ?? true) || v!.contains("$(") ? nil : v
    }
    static var schemaRitorno: String? {
        clientID.map { "com.googleusercontent.apps." + $0.replacingOccurrences(of: ".apps.googleusercontent.com", with: "") }
    }

    private var tokenAccesso: String?
    private var scadenza = Date.distantPast
    private var sessione: ASWebAuthenticationSession?

    override init() {
        super.init()
        collegato = Portachiavi.leggi("google-refresh") != nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    // MARK: accesso

    func accedi() async {
        guard let id = Self.clientID, let schema = Self.schemaRitorno else {
            errore = "Accesso a Google non ancora configurato in questa build."; return
        }
        let verificatore = Self.casuale(64)
        let sfida = Data(SHA256.hash(data: Data(verificatore.utf8))).base64URL
        let redirect = "\(schema):/oauth2redirect"
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [.init(name: "client_id", value: id), .init(name: "redirect_uri", value: redirect),
                        .init(name: "response_type", value: "code"),
                        .init(name: "scope", value: "https://www.googleapis.com/auth/drive.readonly"),
                        .init(name: "code_challenge", value: sfida), .init(name: "code_challenge_method", value: "S256"),
                        .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")]
        do {
            let ritorno: URL = try await withCheckedThrowingContinuation { cont in
                let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: schema) { url, err in
                    if let url { cont.resume(returning: url) } else { cont.resume(throwing: err ?? URLError(.cancelled)) }
                }
                s.presentationContextProvider = self
                s.prefersEphemeralWebBrowserSession = false
                sessione = s
                s.start()
            }
            guard let codice = URLComponents(url: ritorno, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
                errore = "Google non ha restituito l'autorizzazione."; return
            }
            let j = try await token(["client_id": id, "code": codice, "code_verifier": verificatore,
                                     "grant_type": "authorization_code", "redirect_uri": redirect])
            if let r = j["refresh_token"] as? String { Portachiavi.salva(r, per: "google-refresh") }
            registra(j)
            collegato = true
            errore = nil
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { errore = error.localizedDescription }
        }
    }

    func esci() {
        Portachiavi.salva("", per: "google-refresh")
        tokenAccesso = nil
        collegato = false
    }

    private func registra(_ j: [String: Any]) {
        tokenAccesso = j["access_token"] as? String
        scadenza = Date().addingTimeInterval(Double(j["expires_in"] as? Int ?? 3000) - 60)
    }

    private func token(_ campi: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = campi.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (d, r) = try await URLSession.shared.data(for: req)
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        guard (r as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Google", code: 1, userInfo: [NSLocalizedDescriptionKey: "Accesso Google non valido: \(j["error"] ?? "errore"). Riaccedi."])
        }
        return j
    }

    private func accesso() async throws -> String {
        if let t = tokenAccesso, Date() < scadenza { return t }
        guard let id = Self.clientID, let r = Portachiavi.leggi("google-refresh") else {
            collegato = false
            throw NSError(domain: "Google", code: 2, userInfo: [NSLocalizedDescriptionKey: "Accedi a Google Drive."])
        }
        do {
            registra(try await token(["client_id": id, "refresh_token": r, "grant_type": "refresh_token"]))
        } catch { collegato = false; throw error }
        return tokenAccesso!
    }

    // MARK: API Drive

    private func richiesta(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(try await accesso())", forHTTPHeaderField: "Authorization")
        let (d, r) = try await URLSession.shared.data(for: req)
        let h = r as! HTTPURLResponse
        guard h.statusCode == 200 else {
            throw NSError(domain: "Drive", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "Drive ha risposto \(h.statusCode)."])
        }
        return (d, h)
    }

    /// Contenuto di una cartella (`root` = Il mio Drive; `condivisi` = Condivisi con me), cartelle prima.
    func elenca(_ cartella: String) async throws -> [Voce] {
        var out: [Voce] = []
        var pagina: String?
        let q = cartella == "condivisi" ? "sharedWithMe and trashed = false" : "'\(cartella)' in parents and trashed = false"
        repeat {
            var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            c.queryItems = [.init(name: "q", value: q), .init(name: "pageSize", value: "200"),
                            .init(name: "orderBy", value: "folder,name"),
                            .init(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime)"),
                            .init(name: "supportsAllDrives", value: "true"), .init(name: "includeItemsFromAllDrives", value: "true")]
            if let p = pagina { c.queryItems?.append(.init(name: "pageToken", value: p)) }
            let (d, _) = try await richiesta(c.url!)
            struct Elenco: Decodable { var files: [Voce]; var nextPageToken: String? }
            let e = try JSONDecoder().decode(Elenco.self, from: d)
            out += e.files
            pagina = e.nextPageToken
        } while pagina != nil
        return out
    }

    func cerca(_ testo: String) async throws -> [Voce] {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let t = testo.replacingOccurrences(of: "'", with: "\\'")
        c.queryItems = [.init(name: "q", value: "name contains '\(t)' and trashed = false"), .init(name: "pageSize", value: "100"),
                        .init(name: "fields", value: "files(id,name,mimeType,size,modifiedTime)")]
        let (d, _) = try await richiesta(c.url!)
        struct Elenco: Decodable { var files: [Voce] }
        return try JSONDecoder().decode(Elenco.self, from: d).files
    }

    /// Scarica in un file temporaneo. I documenti Google si esportano in testo.
    func scarica(_ v: Voce) async throws -> (URL, String) {
        let url = v.documentoGoogle
            ? URL(string: "https://www.googleapis.com/drive/v3/files/\(v.id)/export?mimeType=text/plain")!
            : URL(string: "https://www.googleapis.com/drive/v3/files/\(v.id)?alt=media&supportsAllDrives=true")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(try await accesso())", forHTTPHeaderField: "Authorization")
        let (tmp, r) = try await URLSession.shared.download(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Drive", code: 3, userInfo: [NSLocalizedDescriptionKey: "Download di «\(v.name)» non riuscito."])
        }
        return (tmp, v.documentoGoogle ? v.name + ".txt" : v.name)
    }

    /// Tutti i file importabili di una cartella e delle sottocartelle.
    func fileImportabili(in cartella: String, profondita: Int = 3) async throws -> [Voce] {
        var out: [Voce] = []
        for v in try await elenca(cartella) {
            if v.cartella, profondita > 0 { out += try await fileImportabili(in: v.id, profondita: profondita - 1) }
            else if v.importabile { out.append(v) }
        }
        return out
    }

    static func casuale(_ n: Int) -> String {
        let car = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in car.randomElement()! })
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Sfoglia Drive e importa file o cartelle intere nella Biblioteca.
struct DriveView: View {
    @EnvironmentObject var drive: GoogleDrive
    @EnvironmentObject var libreria: Libreria
    var cartella = "root"
    var titolo = "Google Drive"

    @State private var voci: [GoogleDrive.Voce] = []
    @State private var caricamento = false
    @State private var importazione: (fatti: Int, totali: Int, nome: String)?
    @State private var esito: String?
    @State private var ricerca = ""

    var body: some View {
        List {
            if !drive.collegato {
                Section {
                    Text("Collega il tuo Google Drive per sfogliare le cartelle (per esempio «06 - Ricerca esoterica») e importare libri con un tocco. Accesso in sola lettura: l'app non modifica nulla sul Drive.")
                    Button { Task { await drive.accedi(); await carica() } } label: {
                        Label("Accedi con Google", systemImage: "person.badge.key")
                    }
                    if GoogleDrive.clientID == nil {
                        Text("Questa build non ha ancora l'accesso Google configurato.").foregroundStyle(.orange).font(.footnote)
                    }
                }
            } else {
                if cartella == "root" {
                    NavigationLink("Condivisi con me") { DriveView(cartella: "condivisi", titolo: "Condivisi con me") }
                }
                if let i = importazione {
                    ProgressView(value: Double(i.fatti), total: Double(max(i.totali, 1))) { Text("Importo \(i.fatti + 1) di \(i.totali): \(i.nome)") }
                }
                if let e = esito { Text(e).font(.footnote).foregroundStyle(.secondary) }
                if cartella != "root" && cartella != "condivisi" && !voci.isEmpty {
                    Button { Task { await importaCartella() } } label: {
                        Label("Importa tutta questa cartella", systemImage: "square.and.arrow.down.on.square")
                    }.disabled(importazione != nil)
                }
                ForEach(voci) { v in
                    if v.cartella {
                        NavigationLink { DriveView(cartella: v.id, titolo: v.name) } label: { Label(v.name, systemImage: "folder") }
                    } else {
                        Button { Task { await importa([v]) } } label: {
                            HStack {
                                Label(v.name, systemImage: v.importabile ? "doc.text" : "doc").lineLimit(2)
                                Spacer()
                                if let d = v.dimensione { Text(d).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(!v.importabile || importazione != nil)
                    }
                }
            }
            if let e = drive.errore { Text(e).foregroundStyle(.red) }
        }
        .overlay { if caricamento { ProgressView() } }
        .navigationTitle(titolo)
        .searchable(text: $ricerca, prompt: "Cerca in tutto il Drive")
        .onSubmit(of: .search) { Task { await cercaDrive() } }
        .task { await carica() }
        .refreshable { await carica() }
    }

    func carica() async {
        guard drive.collegato else { return }
        caricamento = true; defer { caricamento = false }
        do { voci = try await drive.elenca(cartella) } catch { drive.errore = error.localizedDescription }
    }

    func cercaDrive() async {
        guard !ricerca.isEmpty else { await carica(); return }
        caricamento = true; defer { caricamento = false }
        do { voci = try await drive.cerca(ricerca) } catch { drive.errore = error.localizedDescription }
    }

    func importaCartella() async {
        do { await importa(try await drive.fileImportabili(in: cartella)) } catch { drive.errore = error.localizedDescription }
    }

    func importa(_ file: [GoogleDrive.Voce]) async {
        var ok = 0, gia = 0
        let prima = Set(libreria.libri.map(\.id))
        for (i, v) in file.enumerated() {
            importazione = (i, file.count, v.name)
            do {
                let (tmp, nome) = try await drive.scarica(v)
                if let l = await libreria.importa(dati: tmp, nome: nome) { if prima.contains(l.id) { gia += 1 } else { ok += 1 } }
            } catch { drive.errore = error.localizedDescription }
        }
        importazione = nil
        esito = "Importati \(ok) file" + (gia > 0 ? "; \(gia) erano già in biblioteca" : "") + "."
    }
}
