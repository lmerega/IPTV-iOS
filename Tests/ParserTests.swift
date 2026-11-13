import XCTest
@testable import IPTVPOC

final class ParserTests: XCTestCase {
    func testM3UParsing() {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-id="uno.it" tvg-logo="http://example.invalid/l.png" group-title="Rete, Test" catchup="default" catchup-days="3" catchup-source="http://example.invalid/c/{utc}",Canale Uno
        http://example.invalid/live/1.m3u8
        #EXTINF:-1 group-title="Sport",Canale Due
        http://example.invalid/live/2.m3u8
        """
        let list = IPTVService.parseM3U(text, base: nil)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].name, "Canale Uno")
        XCTAssertEqual(list[0].group, "Rete, Test")
        XCTAssertEqual(list[0].epgID, "uno.it")
        XCTAssertTrue(list[0].archive)
        XCTAssertEqual(list[0].archiveDays, 3)
        XCTAssertFalse(list[1].archive)
        XCTAssertNotEqual(list[0].id, list[1].id)
    }

    func testXtreamFlexibleJSON() throws {
        let json = #"[{"stream_id":"12","name":"A","category_id":5,"tv_archive":"1","tv_archive_duration":3}]"#
        let list = try JSONDecoder().decode([XtreamStream].self, from: Data(json.utf8))
        XCTAssertEqual(list[0].stream_id, 12)
        XCTAssertEqual(list[0].category_id, "5")
        XCTAssertEqual(list[0].tv_archive, 1)
        XCTAssertEqual(list[0].tv_archive_duration, 3)
    }

    private func xtreamSource() -> IPTVSource {
        var s = IPTVSource()
        s.kind = "xtream"; s.server = "http://example.invalid:8080"
        s.username = "u"; s.password = "p"; s.serverTimeZone = "UTC"
        return s
    }

    private func channel(_ source: IPTVSource) throws -> IPTVChannel {
        IPTVChannel(id: "x10", name: "C", group: "g",
                    url: try IPTVService.streamURL(source, kind: "live", id: 10, ext: "m3u8"),
                    streamID: 10, archive: true)
    }

    func testXtreamCatchupURLs() throws {
        let source = xtreamSource()
        let ch = try channel(source)
        let start = Date(timeIntervalSince1970: 1_767_323_040) // 2026-01-02 03:04:00 UTC
        let ts = CatchupResolver.url(variant: .ts, source: source, channel: ch, start: start, duration: 3600)
        XCTAssertEqual(ts?.absoluteString, "http://example.invalid:8080/timeshift/u/p/60/2026-01-02:03-04/10.ts")
        let php = CatchupResolver.url(variant: .php, source: source, channel: ch, start: start, duration: 3600)
        XCTAssertEqual(php?.path, "/streaming/timeshift.php")
        XCTAssertTrue(php?.query?.contains("duration=60") ?? false)
    }

    func testCatchupShiftAndTimezone() throws {
        var source = xtreamSource()
        source.serverTimeZone = "Europe/Rome"
        source.archiveShiftMinutes = 30
        let ch = try channel(source)
        let start = Date(timeIntervalSince1970: 1_767_323_040)
        let url = CatchupResolver.url(variant: .m3u8, source: source, channel: ch, start: start, duration: 600)
        XCTAssertEqual(url?.lastPathComponent, "10.m3u8")
        XCTAssertTrue(url?.absoluteString.contains("/10/2026-01-02:04-34/") ?? false)
    }

    func testM3UTemplate() {
        var source = IPTVSource()
        source.serverTimeZone = "UTC"
        let ch = IPTVChannel(id: "m1", name: "C", group: "g", url: URL(string: "http://example.invalid/l.m3u8")!,
                             streamID: nil, archive: true,
                             archiveTemplate: "http://example.invalid/c?s={utc}&d={duration}&y={Y}")
        let url = CatchupResolver.url(variant: .auto, source: source, channel: ch,
                                      start: Date(timeIntervalSince1970: 1_767_323_040), duration: 600)
        XCTAssertEqual(url?.absoluteString, "http://example.invalid/c?s=1767323040&d=600&y=2026")
    }

    func testHLSConversion() {
        let text = "#EXTM3U\n#EXTINF:-1,Uno\nhttp://example.invalid:80/live/u/p/123.ts\n#EXTINF:-1,Due\nhttp://example.invalid/stream/abc.ts\n"
        let list = IPTVService.parseM3U(text, base: nil, preferHLS: true)
        XCTAssertEqual(list[0].url.absoluteString, "http://example.invalid:80/live/u/p/123.m3u8")
        XCTAssertEqual(list[0].altURL?.lastPathComponent, "123.ts")
        XCTAssertEqual(list[1].url.lastPathComponent, "abc.ts")
        XCTAssertNil(list[1].altURL)
    }

    func testTSSyncDetectionWithOffset() {
        var data = Data(repeating: 0, count: 700)
        for index in stride(from: 37, to: 700, by: 188) { data[index] = 0x47 }
        XCTAssertTrue(CatchupResolver.hasTSSync(data))
        XCTAssertFalse(CatchupResolver.hasTSSync(Data(repeating: 1, count: 700)))
    }

    func testApplyFormatSwapsURLs() {
        let hls = URL(string: "http://example.invalid/live/u/p/1.m3u8")!
        let ts = URL(string: "http://example.invalid/live/u/p/1.ts")!
        let channel = IPTVChannel(id: "x1", name: "C", group: "g", url: hls, streamID: 1, archive: false, altURL: ts)
        let swapped = IPTVService.applyFormat([channel], hls: false)
        XCTAssertEqual(swapped[0].url, ts)
        XCTAssertEqual(swapped[0].altURL, hls)
        XCTAssertEqual(IPTVService.applyFormat(swapped, hls: false)[0].url, ts)
    }

    func testStreamInfoSummary() {
        XCTAssertEqual(StreamInfo.codecName(NSNumber(value: UInt32(0x34363268))), "H.264") // "h264"
        let text = StreamInfo.summary(width: 1920, height: 1080, fps: 50, videoCodec: "H.264",
                                      audio: StreamInfo.audioLabel(codec: "MPEG audio", channels: 2, rate: 48000), bitrate: 0)
        XCTAssertEqual(text, "FHD 1920×1080 · 50 fps · H.264 · Audio MPEG audio stereo 48 kHz")
        XCTAssertNil(StreamInfo.summary(width: 0, height: 0, fps: 0, videoCodec: "", audio: "", bitrate: 0))
    }

    func testTimeshiftBufferWrapAround() throws {
        let buffer = TimeshiftBuffer()
        buffer.reset(capacity: 64_000_000)
        let chunkSize = 1_000_000
        for index in 0..<70 {
            buffer.append(Data(repeating: UInt8(index % 251), count: chunkSize))
        }
        XCTAssertEqual(buffer.end, 70_000_000)
        XCTAssertGreaterThan(buffer.oldest, 6_000_000)
        // l'ultimo blocco attraversa il confine tra due segmenti
        let last = buffer.read(offset: 69_000_000, max: chunkSize, timeout: 0.1)
        XCTAssertEqual(last.data.count, chunkSize)
        XCTAssertTrue(last.data.allSatisfy { $0 == 69 })
        XCTAssertEqual(last.next, 70_000_000)
        // un offset ormai sovrascritto viene portato al dato piu' vecchio disponibile
        let old = buffer.read(offset: 0, max: 10, timeout: 0.1)
        XCTAssertEqual(old.next - Int64(old.data.count), buffer.oldest)
        // riducendo la dimensione si cancellano i segmenti piu' vecchi senza azzerare
        let endBefore = buffer.end
        buffer.setCapacity(16_000_000)
        XCTAssertEqual(buffer.end, endBefore)
        XCTAssertLessThanOrEqual(buffer.bytesOnDisk, 16_000_000 + TimeshiftBuffer.segmentSize)
        let tail = buffer.read(offset: 69_500_000, max: 1000, timeout: 0.1)
        XCTAssertEqual(tail.data.count, 1000)
        buffer.reset(capacity: 64_000_000)
    }

    private func pcrPacket(pid: Int, seconds: Double) -> Data {
        var packet = [UInt8](repeating: 0xff, count: 188)
        packet[0] = 0x47
        packet[1] = UInt8((pid >> 8) & 0x1f)
        packet[2] = UInt8(pid & 0xff)
        packet[3] = 0x20
        packet[4] = 183
        packet[5] = 0x10
        let base = UInt64(seconds * 90_000)
        packet[6] = UInt8((base >> 25) & 0xff)
        packet[7] = UInt8((base >> 17) & 0xff)
        packet[8] = UInt8((base >> 9) & 0xff)
        packet[9] = UInt8((base >> 1) & 0xff)
        packet[10] = UInt8((base & 1) << 7)
        return Data(packet)
    }

    func testTimeshiftTimelineUsesPCR() throws {
        let buffer = TimeshiftBuffer()
        buffer.reset(capacity: 64_000_000)
        var stream = Data()
        for step in 0...6 { stream.append(pcrPacket(pid: 256, seconds: 100 + Double(step) * 0.5)) }
        // arrivo "a raffica" e con un pacchetto spezzato tra due blocchi
        buffer.append(stream.prefix(300))
        buffer.append(stream.dropFirst(300))
        let range = try XCTUnwrap(buffer.dateRange)
        XCTAssertEqual(range.upperBound.timeIntervalSince(range.lowerBound), 3.0, accuracy: 0.01)
        XCTAssertEqual(buffer.offset(at: range.lowerBound.addingTimeInterval(1.5)), 3 * 188)
        XCTAssertEqual(buffer.liveDate, range.upperBound)
        buffer.reset(capacity: 64_000_000)
    }

    func testOnDemandCatalogRecentAndSearch() {
        func item(_ id: Int, _ title: String, _ category: String, _ added: Double) -> OnDemandItem {
            OnDemandItem(id: "movie-\(id)", title: title, category: category, cover: nil, url: nil,
                         seriesID: nil, added: added)
        }
        let catalog = OnDemandCatalog([item(1, "Città Futura", "Drammatico", 100),
                                       item(2, "Commedia Sexy", "Commedia", 300),
                                       item(1, "Città Futura", "Drammatico", 100),
                                       item(3, "Senza data", "Commedia", 0)])
        XCTAssertEqual(catalog.items.count, 3)
        XCTAssertEqual(Array(catalog.categories.prefix(2)), [OnDemandCatalog.all, OnDemandCatalog.recent])
        XCTAssertEqual(catalog.filter(category: OnDemandCatalog.recent, query: "").map(\.id), ["movie-2", "movie-1"])
        XCTAssertEqual(catalog.filter(category: OnDemandCatalog.all, query: "citta").map(\.id), ["movie-1"])
        XCTAssertEqual(catalog.filter(category: "Commedia", query: "").count, 2)
        XCTAssertEqual(catalog.counts["Commedia"], 2)
    }

    func testAPICacheReadWriteInvalidate() {
        let url = URL(string: "http://example.invalid/player_api.php?action=test&nonce=\(UUID().uuidString)")!
        XCTAssertNil(APICache.read(url, policy: .catalog))
        APICache.write(url, data: Data("[1]".utf8))
        XCTAssertEqual(APICache.read(url, policy: .catalog), Data("[1]".utf8))
        XCTAssertFalse(APICache.file(for: url).lastPathComponent.contains("example"))
        XCTAssertNil(APICache.read(url, policy: .maxAge(-1)))
        Thread.sleep(forTimeInterval: 0.05)
        APICache.invalidateAll()
        XCTAssertNil(APICache.read(url, policy: .catalog))
        XCTAssertEqual(APICache.readStale(url), Data("[1]".utf8))
        try? FileManager.default.removeItem(at: APICache.file(for: url))
    }

    func testHiddenCategoriesAndMediaTitle() {
        func item(_ id: Int, _ category: String) -> OnDemandItem {
            OnDemandItem(id: "movie-\(id)", title: "Titolo \(id)", category: category, cover: nil, url: nil,
                         seriesID: nil, added: Double(id))
        }
        let catalog = OnDemandCatalog([item(1, "Italia"), item(2, "Estero"), item(3, "Italia")])
        XCTAssertEqual(catalog.filter(category: OnDemandCatalog.all, query: "", hidden: ["Estero"]).count, 2)
        XCTAssertEqual(catalog.filter(category: OnDemandCatalog.recent, query: "", hidden: ["Italia"]).map(\.id), ["movie-2"])
        let url = URL(string: "http://example.invalid/series/1.mp4")!
        let episode = MediaRef(id: "episode-1", kind: "episode", title: "Pilota", cover: nil, url: url,
                               seriesID: 7, seriesTitle: "Serie", season: 2, episode: 5)
        XCTAssertEqual(episode.displayTitle, "Serie · S2 E5")
        XCTAssertEqual(Expiry.daysLeft(Date().addingTimeInterval(3 * 86400 + 60)), 3)
        XCTAssertNil(Expiry.daysLeft(nil))
    }

    @MainActor
    func testWatchHistoryResumeAndFinish() {
        let history = WatchHistory.shared
        history.use(profile: UUID())
        let url = URL(string: "http://example.invalid/movie/1.mp4")!
        let movie = MediaRef(id: "movie-test", kind: "movie", title: "Film", cover: nil, url: url)
        history.record(movie, position: 600, duration: 6000)
        XCTAssertEqual(history.resumePosition("movie-test"), 600)
        XCTAssertEqual(history.continueWatching(kind: "movie").map(\.id), ["movie-test"])
        history.record(movie, position: 5900, duration: 6000)
        XCTAssertNil(history.resumePosition("movie-test"))
        XCTAssertTrue(history.watched.contains("movie-test"))
    }

    func testAirPlayCompatibility() {
        XCTAssertTrue(StreamInfo.airPlayCompatibility(video: ["H.264"], audio: ["AAC"]).ok)
        XCTAssertTrue(StreamInfo.airPlayCompatibility(video: ["H.264"], audio: ["AC-3"]).ok)
        let alt = StreamInfo.airPlayCompatibility(video: ["H.264"], audio: ["MPEG audio", "AC-3"])
        XCTAssertTrue(alt.ok)
        XCTAssertTrue(alt.detail.contains("AC-3"))
        let mp2 = StreamInfo.airPlayCompatibility(video: ["H.264"], audio: ["MPEG audio"])
        XCTAssertFalse(mp2.ok)
        XCTAssertTrue(mp2.detail.contains("MP2"))
        XCTAssertFalse(StreamInfo.airPlayCompatibility(video: ["HEVC"], audio: ["AAC"]).ok)
        XCTAssertFalse(StreamInfo.airPlayCompatibility(video: ["MPEG-2"], audio: ["MPEG audio"]).ok)
    }

    func testGzip() throws {
        let b64 = "H4sIAAAAAAAC/7MpKbOzKSjKTy9KzM1NVUjOSMzLS82xVUpUUiguSSwqsVUyMjAyMzA0MDIwNjAxMFDQNgACkGR+AZKcCZKcnU1JZklOql2IjT6EYaMPtwDILimzAwBDsZ5qdQAAAA=="
        let gz = try XCTUnwrap(Data(base64Encoded: b64))
        let xml = try XCTUnwrap(IPTVExtras.gunzip(gz))
        XCTAssertTrue(String(decoding: xml, as: UTF8.self).hasPrefix("<tv>"))
    }

    func testProgramParsingBase64Title() throws {
        let source = xtreamSource()
        let ch = try channel(source)
        let entry: [String: Any] = ["id": "1", "title": "Tm90aXppZQ==",
                                    "start_timestamp": "1767323040", "stop_timestamp": "1767326640", "has_archive": 1]
        let program = try XCTUnwrap(IPTVExtras.parseProgram(entry, channel: ch, zone: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(program.title, "Notizie")
        XCTAssertTrue(program.hasArchive)
    }
}
