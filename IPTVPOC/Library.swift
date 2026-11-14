import Foundation
import SwiftUI
import UserNotifications

// MARK: - Riferimento a un contenuto on demand (film, episodio)

/// Dati del contenuto in riproduzione, per "Riprendi" e "Continua a guardare".
struct MediaRef: Codable, Hashable {
    var id: String              // "movie-123", "episode-456"
    var kind: String            // "movie" o "episode"
    var title: String
    var cover: String?
    var url: URL
    var seriesID: Int?
    var seriesTitle: String?
    var season: Int = 0
    var episode: Int = 0

    var displayTitle: String {
        guard kind == "episode", let seriesTitle else { return title }
        return "\(seriesTitle) · S\(season) E\(episode)"
    }

    init(id: String, kind: String, title: String, cover: String?, url: URL, seriesID: Int? = nil,
         seriesTitle: String? = nil, season: Int = 0, episode: Int = 0) {
        self.id = id; self.kind = kind; self.title = title; self.cover = cover; self.url = url
        self.seriesID = seriesID; self.seriesTitle = seriesTitle; self.season = season; self.episode = episode
    }

    // Su disco l'indirizzo si salva senza utente e password della sorgente: si rimettono quando si legge.
    private enum Keys: String, CodingKey { case id, kind, title, cover, url, seriesID, seriesTitle, season, episode }
    private static let userMark = "~user~"
    private static let passMark = "~pass~"
    /// Credenziali della sorgente in uso (impostate da WatchHistory.use).
    nonisolated(unsafe) static var credentials: (user: String, pass: String)?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        cover = try c.decodeIfPresent(String.self, forKey: .cover)
        let stored = try c.decode(String.self, forKey: .url)
        guard let url = URL(string: MediaRef.restore(stored)) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "url")
        }
        self.url = url
        seriesID = try c.decodeIfPresent(Int.self, forKey: .seriesID)
        seriesTitle = try c.decodeIfPresent(String.self, forKey: .seriesTitle)
        season = try c.decodeIfPresent(Int.self, forKey: .season) ?? 0
        episode = try c.decodeIfPresent(Int.self, forKey: .episode) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(cover, forKey: .cover)
        try c.encode(MediaRef.redact(url), forKey: .url)
        try c.encodeIfPresent(seriesID, forKey: .seriesID)
        try c.encodeIfPresent(seriesTitle, forKey: .seriesTitle)
        try c.encode(season, forKey: .season)
        try c.encode(episode, forKey: .episode)
    }

    /// Toglie utente e password (percorso Xtream /tipo/utente/password/... e parametri username/password).
    /// Il resto dell'indirizzo resta byte per byte com'era.
    static func redact(_ url: URL) -> String {
        guard let creds = credentials, !creds.user.isEmpty,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        var comps = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for i in comps.indices.dropLast() where (comps[i].removingPercentEncoding ?? comps[i]) == creds.user
            && (comps[i + 1].removingPercentEncoding ?? comps[i + 1]) == creds.pass {
            comps[i] = userMark
            comps[i + 1] = passMark
            break
        }
        parts.percentEncodedPath = comps.joined(separator: "/")
        if let items = parts.percentEncodedQueryItems {
            var changed = false
            let updated = items.map { item -> URLQueryItem in
                let value = item.value.map { $0.removingPercentEncoding ?? $0 }
                if item.name == "username" && value == creds.user { changed = true; return URLQueryItem(name: item.name, value: userMark) }
                if item.name == "password" && value == creds.pass { changed = true; return URLQueryItem(name: item.name, value: passMark) }
                return item
            }
            if changed { parts.percentEncodedQueryItems = updated }
        }
        return parts.string ?? url.absoluteString
    }

    /// Rimette utente e password con la codifica giusta per il percorso o per i parametri.
    static func restore(_ text: String) -> String {
        guard text.contains(userMark) || text.contains(passMark), let creds = credentials,
              var parts = URLComponents(string: text) else { return text }
        var segment = CharacterSet.urlPathAllowed
        segment.remove(charactersIn: "/+")
        var query = CharacterSet.urlQueryAllowed
        query.remove(charactersIn: "&=+")
        func encoded(_ value: String, _ allowed: CharacterSet) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        parts.percentEncodedPath = parts.percentEncodedPath
            .replacingOccurrences(of: userMark, with: encoded(creds.user, segment))
            .replacingOccurrences(of: passMark, with: encoded(creds.pass, segment))
        if let items = parts.percentEncodedQueryItems {
            parts.percentEncodedQueryItems = items.map { item in
                switch item.value {
                case userMark?: return URLQueryItem(name: item.name, value: encoded(creds.user, query))
                case passMark?: return URLQueryItem(name: item.name, value: encoded(creds.pass, query))
                default: return item
                }
            }
        }
        return parts.string ?? text
    }
}

/// Punto di visione salvato.
struct WatchEntry: Codable, Identifiable, Hashable {
    var media: MediaRef
    var position: Double
    var duration: Double
    var updated: Date
    var id: String { media.id }
    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
}

/// Memoria delle visioni: punto raggiunto e contenuti finiti, per sorgente.
@MainActor
final class WatchHistory: ObservableObject {
    static let shared = WatchHistory()
    @Published private(set) var entries: [String: WatchEntry] = [:]
    @Published private(set) var watched: Set<String> = []
    /// Ordine in cui i contenuti sono diventati "visti": se ne tengono gli ultimi 3000.
    private var watchedOrder: [String] = []
    private var profileID = ""

    /// Da qui in poi un contenuto si considera visto.
    static let finishedFraction = 0.93

    func use(source: IPTVSource?) {
        let id = source?.id.uuidString ?? ""
        let newCredentials = source.map { (user: $0.username, pass: $0.password) }
        if id == profileID {
            // Stessa sorgente con utente o password cambiati: le visioni passano alle nuove credenziali
            // (si salvano senza quelle vecchie e si rileggono con quelle nuove).
            let old = MediaRef.credentials
            guard old?.user != newCredentials?.user || old?.pass != newCredentials?.pass else { return }
            let data = try? JSONEncoder().encode(Array(entries.values))
            MediaRef.credentials = newCredentials
            if let data, let list = try? JSONDecoder().decode([WatchEntry].self, from: data) {
                entries = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                save()
            }
            return
        }
        MediaRef.credentials = newCredentials
        profileID = id
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "watch.entries." + id),
           let list = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            entries = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        } else {
            entries = [:]
        }
        watchedOrder = defaults.stringArray(forKey: "watch.done." + id) ?? []
        watched = Set(watchedOrder)
    }

    private func save() {
        // Tiene le 60 visioni piu' recenti.
        let list = entries.values.sorted { $0.updated > $1.updated }.prefix(60)
        if let data = try? JSONEncoder().encode(Array(list)) {
            UserDefaults.standard.set(data, forKey: "watch.entries." + profileID)
        }
        UserDefaults.standard.set(watchedOrder, forKey: "watch.done." + profileID)
    }

    /// Salva il punto raggiunto; oltre il 93% il contenuto diventa "visto" ed esce da "Continua a guardare".
    func record(_ media: MediaRef, position: Double, duration: Double) {
        guard duration > 60, position.isFinite, duration.isFinite else { return }
        if position / duration >= Self.finishedFraction {
            entries[media.id] = nil
            markDone(media.id)
        } else if position > 20 {
            entries[media.id] = WatchEntry(media: media, position: position, duration: duration, updated: Date())
        }
        save()
    }

    private func markDone(_ id: String) {
        watched.insert(id)
        watchedOrder.removeAll { $0 == id }
        watchedOrder.append(id)
        if watchedOrder.count > 3000 {
            let dropped = watchedOrder.prefix(watchedOrder.count - 3000)
            watchedOrder.removeFirst(dropped.count)
            for old in dropped { watched.remove(old) }
        }
    }

    func markWatched(_ id: String) {
        entries[id] = nil
        markDone(id)
        save()
    }

    func unmarkWatched(_ id: String) {
        watched.remove(id)
        watchedOrder.removeAll { $0 == id }
        save()
    }

    func remove(_ id: String) {
        entries[id] = nil
        save()
    }

    /// Punto da cui riprendere (nil se non c'e' o se e' quasi all'inizio).
    func resumePosition(_ id: String) -> Double? {
        guard let entry = entries[id], entry.position > 20 else { return nil }
        return entry.position
    }

    func continueWatching(kind: String) -> [WatchEntry] {
        entries.values.filter { $0.media.kind == kind }.sorted { $0.updated > $1.updated }
    }
}

// MARK: - Log della sessione

/// Log che copre tutta la sessione dell'app (tutti i canali e contenuti aperti), non solo il player attuale:
/// un solo invio con il triplo tocco racconta cosa e' successo su ogni canale visto.
@MainActor
final class SessionLog {
    static let shared = SessionLog()
    private(set) var lines: [String] = []
    private var owners: [UUID] = []
    /// Esito della verifica AirPlay per ogni contenuto visto (titolo -> esito), in ordine di visione.
    private(set) var airPlay: [(title: String, verdict: String)] = []

    func add(_ title: String, _ text: String, owner: UUID) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        lines.append("\(stamp) [\(title)] \(text)")
        owners.append(owner)
        if lines.count > 600 {
            lines.removeFirst(lines.count - 600)
            owners.removeFirst(owners.count - 600)
        }
    }

    /// Righe degli altri player (canali e contenuti aperti prima di quello attuale, anche se e' lo stesso canale).
    func lines(excluding owner: UUID) -> [String] {
        zip(lines, owners).filter { $0.1 != owner }.map { $0.0 }
    }

    func recordAirPlay(_ title: String, _ verdict: String) {
        airPlay.removeAll { $0.title == title }
        airPlay.append((title, verdict))
        if airPlay.count > 30 { airPlay.removeFirst(airPlay.count - 30) }
    }
}

// MARK: - Avanzamento dei download

/// Download in corso dal provider (canali, film, serie, guida), con byte ricevuti e totali.
@MainActor
final class DownloadProgress: ObservableObject {
    static let shared = DownloadProgress()
    struct Item: Identifiable {
        let id: String
        var received: Int64
        var expected: Int64
        /// Conteggio di elementi (es. canali) invece che di byte.
        var unit: String? = nil
        var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
    }
    @Published private(set) var items: [Item] = []
    private var lastUpdate: [String: Date] = [:]

    func update(_ label: String, received: Int64, expected: Int64, unit: String? = nil) {
        // Al massimo 4 aggiornamenti al secondo per voce, anche quando la dimensione totale non e' nota
        // (prima in quel caso passava ogni pezzetto e l'interfaccia si bloccava con file grandi).
        if let last = lastUpdate[label], Date().timeIntervalSince(last) < 0.25,
           expected <= 0 || received < expected { return }
        lastUpdate[label] = Date()
        if let index = items.firstIndex(where: { $0.id == label }) {
            items[index].received = received
            items[index].expected = expected
        } else {
            items.append(Item(id: label, received: received, expected: expected, unit: unit))
        }
    }

    func finish(_ label: String) {
        items.removeAll { $0.id == label }
        lastUpdate[label] = nil
    }
}

/// Striscia con le fasi del caricamento e le barre dei download in corso.
struct LoadingBanner: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var downloads = DownloadProgress.shared

    var body: some View {
        if model.isLoading || model.loadingStep != nil || !downloads.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let step = model.loadingStep {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(step).font(.footnote)
                    }
                }
                ForEach(downloads.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        if let fraction = item.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        Text(item.unit.map { "\(item.id): \(item.received) di \(item.expected) \($0)" }
                             ?? (item.expected > 0
                                 ? "\(item.id): \(Self.size(item.received)) di \(Self.size(item.expected))"
                                 : "\(item.id): \(Self.size(item.received))"))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal).padding(.bottom, 4)
        }
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// "Lista aggiornata 2 ore fa", con avviso arancione oltre una settimana.
struct CatalogAgeLabel: View {
    let date: Date?
    let what: String

    var body: some View {
        if let date {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                let old = Date().timeIntervalSince(date) > 7 * 86400
                Label("\(what) aggiornati \(date.formatted(.relative(presentation: .named)))",
                      systemImage: old ? "exclamationmark.arrow.circlepath" : "clock")
                    .font(.caption)
                    .foregroundStyle(old ? Color.orange : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
        }
    }
}

// MARK: - Guida breve dei canali (ora in onda / a seguire)

/// Le righe dei canali ricevono la guida una alla volta: gli aggiornamenti vengono raccolti e applicati
/// insieme ogni 0,3 secondi, cosi' lo scorrimento resta fluido anche su elenchi lunghi.
@MainActor
final class NowNextStore: ObservableObject {
    static let shared = NowNextStore()
    @Published private(set) var items: [String: [GuideProgram]] = [:]
    private var pending: [String: [GuideProgram]] = [:]
    private var flushScheduled = false

    func set(_ channelID: String, _ programs: [GuideProgram]) {
        pending[channelID] = programs
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            items.merge(pending) { _, new in new }
            pending = [:]
            flushScheduled = false
        }
    }

    /// C'e' gia' una guida valida: almeno un programma salvato non e' ancora finito (altrimenti va riscaricata).
    func has(_ channelID: String) -> Bool {
        if pending[channelID] != nil { return true }
        guard let list = items[channelID] else { return false }
        return list.contains { $0.end > Date() }
    }

    func clear() {
        items = [:]
        pending = [:]
    }
}

// MARK: - Registrazioni programmate

/// Registrazione programmata arrivata mentre si guarda un altro contenuto.
struct ScheduledConflict: Identifiable {
    let item: ScheduledRecording
    let channel: IPTVChannel
    var id: UUID { item.id }
}

struct ScheduledRecording: Codable, Identifiable, Hashable {
    var id = UUID()
    var channelID: String
    var channelName: String
    var title: String
    var start: Date
    var end: Date
    /// Sorgente a cui appartiene il canale (nil per quelle create prima della 1.0).
    var sourceID: UUID? = nil
}

/// Registrazioni programmate dalla guida. iOS non puo' svegliare l'app: all'ora giusta arriva una notifica
/// e, se l'app e' aperta (o viene aperta prima della fine del programma), la registrazione parte da sola.
@MainActor
final class RecordingScheduler: ObservableObject {
    static let shared = RecordingScheduler()
    @Published private(set) var items: [ScheduledRecording] = []
    private var timer: Timer?
    /// Trova il canale dal suo identificativo (fornito da AppModel).
    var channelLookup: ((String) -> IPTVChannel?)?
    /// Decide se la registrazione puo' partire ora (una sola connessione: non mentre si guarda altro).
    var canStart: ((ScheduledRecording, IPTVChannel) -> Bool)?
    /// Sorgente in uso (fornita da AppModel): le programmate di altre sorgenti aspettano.
    var currentSource: (() -> UUID?)?

    private let key = "scheduled.recordings"
    /// Margini: si parte 1 minuto prima e si finisce 3 minuti dopo l'orario della guida.
    static let leadIn: TimeInterval = 60
    static let tail: TimeInterval = 180

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([ScheduledRecording].self, from: data) {
            items = list.filter { $0.end > Date() }.sorted { $0.start < $1.start }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }

    func isScheduled(_ program: GuideProgram, channel: IPTVChannel) -> Bool {
        items.contains { $0.channelID == channel.id && $0.start == program.start }
    }

    func schedule(_ program: GuideProgram, channel: IPTVChannel) {
        guard program.end > Date(), !isScheduled(program, channel: channel) else { return }
        let item = ScheduledRecording(channelID: channel.id, channelName: channel.name, title: program.title,
                                      start: program.start, end: program.end, sourceID: currentSource?())
        items.append(item)
        items.sort { $0.start < $1.start }
        save()
        Notifier.schedule(id: item.id.uuidString,
                          title: "Registrazione: \(item.title)",
                          body: "\(item.channelName) alle \(item.start.formatted(date: .omitted, time: .shortened)). Apri l'app per registrare.",
                          at: item.start.addingTimeInterval(-Self.leadIn - 60))
        check()
    }

    /// Canali M3U con id cambiato (versioni precedenti): le programmate passano al nuovo id.
    func migrate(_ renamed: [String: String]) {
        var changed = false
        for index in items.indices {
            if let id = renamed[items[index].channelID] { items[index].channelID = id; changed = true }
        }
        if changed { save() }
    }

    /// Elimina le programmate di una sorgente rimossa.
    func removeAll(source: UUID) {
        for item in items where item.sourceID == source { Notifier.cancel(id: item.id.uuidString) }
        items.removeAll { $0.sourceID == source }
        save()
    }

    func cancel(_ item: ScheduledRecording) {
        items.removeAll { $0.id == item.id }
        save()
        Notifier.cancel(id: item.id.uuidString)
    }

    /// Avvia le registrazioni il cui orario e' arrivato (chiamato ogni 20 s e al ritorno in primo piano).
    func check() {
        let now = Date()
        let expired = items.filter { $0.end.addingTimeInterval(Self.tail) <= now }
        if !expired.isEmpty {
            items.removeAll { item in expired.contains(item) }
            save()
        }
        let dvr = DVRManager.shared
        let source = currentSource?()
        let ready = items.filter { $0.start.addingTimeInterval(-Self.leadIn) <= now && ($0.sourceID == nil || $0.sourceID == source) }
        // Programma successivo sullo stesso canale gia' in registrazione: si allunga quella in corso,
        // invece di aspettarne la fine (si perdevano circa 4 minuti tra le due).
        if dvr.isRecording, let recording = dvr.recordingChannel,
           let next = ready.first(where: { $0.channelID == recording.id }) {
            let newStop = next.end.addingTimeInterval(Self.tail)
            if (dvr.stopDate ?? .distantFuture) < newStop { dvr.setStopDate(newStop) }
            items.removeAll { $0.id == next.id }
            save()
            dvr.status = "Registrazione programmata: \(next.title)"
            return
        }
        guard !dvr.isRecording,
              let due = ready.first,
              let channel = channelLookup?(due.channelID) else { return }
        if let canStart, !canStart(due, channel) { return }
        items.removeAll { $0.id == due.id }
        save()
        dvr.start(channel: channel, stopAt: due.end.addingTimeInterval(Self.tail))
        dvr.status = "Registrazione programmata: \(due.title)"
    }
}

// MARK: - Riprendi replay

/// Punto raggiunto nei replay (differita): si offre "Riprendi" riaprendo lo stesso programma.
enum ReplayResume {
    private static let key = "replay.positions"

    private static func id(_ channelID: String, _ program: GuideProgram) -> String {
        channelID + "|" + String(Int(program.start.timeIntervalSince1970))
    }

    static func save(channelID: String, program: GuideProgram, position: Double) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        let total = program.end.timeIntervalSince(program.start)
        let entry = id(channelID, program)
        // Quasi finito (o appena iniziato): niente da riprendere.
        // Primo minuto: non si tocca il punto salvato (l'offerta "Riprendi" puo' essere ancora sullo schermo).
        if position < 60 { return }
        if total > 0 && position / total > 0.93 {
            map[entry] = nil
        } else {
            map[entry] = [position, Date().timeIntervalSince1970]
        }
        // Tiene i 50 piu' recenti, al massimo per 8 giorni (oltre l'archivio non c'e' piu').
        let limit = Date().addingTimeInterval(-8 * 86400).timeIntervalSince1970
        let kept = map.filter { ($0.value.last ?? 0) > limit }.sorted { ($0.value.last ?? 0) > ($1.value.last ?? 0) }.prefix(50)
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) }), forKey: key)
    }

    static func position(channelID: String, program: GuideProgram) -> Double? {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]]
        return map?[id(channelID, program)]?.first
    }
}

// MARK: - Notifiche locali

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func schedule(id: String, title: String, body: String, at date: Date) {
        requestPermission()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let fireDate = max(date, Date().addingTimeInterval(5))
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}

// MARK: - Scadenze (abbonamento e firma dell'app)

enum Expiry {
    /// Scadenza della firma: data `ExpirationDate` del profilo incluso da Sideloadly (embedded.mobileprovision).
    static let signingDate: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }()

    static func daysLeft(_ date: Date?) -> Int? {
        guard let date else { return nil }
        return Int((date.timeIntervalSinceNow / 86400).rounded(.down))
    }

    /// Notifiche: firma (1 giorno prima) e abbonamento (3 giorni prima).
    static func scheduleReminders(subscription: Date?) {
        if let signing = signingDate, signing > Date().addingTimeInterval(3600) {
            Notifier.schedule(id: "expiry.signing", title: "L'app scade domani",
                              body: "Rinnova l'installazione con Sideloadly per continuare a usarla.",
                              at: signing.addingTimeInterval(-86400))
        }
        if let subscription, subscription > Date().addingTimeInterval(3 * 86400) {
            Notifier.schedule(id: "expiry.subscription", title: "Abbonamento IPTV in scadenza",
                              body: "Il tuo abbonamento scade il \(subscription.formatted(date: .abbreviated, time: .omitted)).",
                              at: subscription.addingTimeInterval(-3 * 86400))
        }
    }
}

/// Striscia di avviso per le scadenze vicine (firma entro 2 giorni, abbonamento entro 7).
struct ExpiryBanner: View {
    @EnvironmentObject private var model: AppModel

    private var text: String? {
        if let days = Expiry.daysLeft(Expiry.signingDate), days <= 2 {
            return days <= 0 ? "L'installazione dell'app scade oggi: rinnovala con Sideloadly."
                             : "L'installazione dell'app scade tra \(days) giorni: rinnovala con Sideloadly."
        }
        if let days = Expiry.daysLeft(model.account?.expiry), days <= 7 {
            return days <= 0 ? "L'abbonamento IPTV scade oggi." : "L'abbonamento IPTV scade tra \(days) giorni."
        }
        return nil
    }

    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.yellow, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal).padding(.bottom, 4)
        }
    }
}
