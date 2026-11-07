import SwiftUI

struct GuideView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @SceneStorage("guide.onlyReplay") private var onlyReplay = true
    @SceneStorage("guide.grid") private var gridMode = false

    private var filtered: [IPTVChannel] {
        model.visibleChannels.filter { channel in
            (!onlyReplay || channel.archive)
                && (search.isEmpty || channel.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if gridMode {
                    GuideGridView(channels: filtered)
                } else {
                    List {
                        Section {
                            ForEach(filtered) { channel in
                                NavigationLink(value: channel) { ChannelRow(channel: channel) }
                            }
                        } header: {
                            Text(onlyReplay
                                 ? "\(filtered.count) canali con replay (di \(model.channels.count))"
                                 : "\(filtered.count) canali")
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Guida")
            .navigationDestination(for: IPTVChannel.self) { ChannelGuideView(channel: $0) }
            .searchable(text: $search, prompt: "Cerca un canale")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("Vista", selection: $gridMode) {
                        Image(systemName: "list.bullet").tag(false)
                        Image(systemName: "square.grid.3x1.below.line.grid.1x2").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Vista elenco o griglia")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Filtro", selection: $onlyReplay) {
                            Text("Solo canali con replay").tag(true)
                            Text("Tutti i canali").tag(false)
                        }
                    } label: {
                        Label("Filtro", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .overlay {
                if model.channels.isEmpty {
                    ContentUnavailableView("Nessun canale", systemImage: "calendar",
                                           description: Text("Aggiungi una sorgente nella scheda Impostazioni."))
                }
            }
        }
    }
}

struct ChannelGuideView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var scheduler = RecordingScheduler.shared
    let channel: IPTVChannel
    @State private var programs: [GuideProgram] = []
    @State private var loading = true

    private var days: [(Date, [GuideProgram])] {
        let grouped = Dictionary(grouping: programs) { Calendar.current.startOfDay(for: $0.start) }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(days, id: \.0) { day, items in
                    Section(day.formatted(.dateTime.weekday(.wide).day().month())) {
                        ForEach(items) { program in
                            Button { open(program) } label: { row(program) }.id(program.id)
                                .swipeActions {
                                    if program.end > Date() { scheduleButton(program) }
                                }
                                .contextMenu {
                                    if program.end > Date() { scheduleButton(program) }
                                }
                        }
                    }
                }
            }
            .onChange(of: programs) { _, list in
                if let live = list.first(where: { $0.isLive }) {
                    proxy.scrollTo(live.id, anchor: .center)
                }
            }
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading { ProgressView() }
            else if programs.isEmpty {
                ContentUnavailableView("Guida non disponibile", systemImage: "calendar.badge.exclamationmark",
                                       description: Text("Il provider non fornisce EPG per questo canale."))
            }
        }
        .task(id: model.guideRevision) {
            programs = await model.guide(for: channel)
            loading = false
        }
    }

    private func row(_ program: GuideProgram) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(program.start.formatted(date: .omitted, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(program.title).foregroundStyle(.primary)
            }
            Spacer()
            if scheduler.isScheduled(program, channel: channel) {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
            }
            if program.isLive {
                Label("Ora", systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.red)
            } else if model.canReplay(program, channel: channel) {
                Image(systemName: "play.circle").foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder private func scheduleButton(_ program: GuideProgram) -> some View {
        if scheduler.isScheduled(program, channel: channel) {
            Button("Annulla registrazione", systemImage: "xmark.circle", role: .destructive) {
                if let item = scheduler.items.first(where: { $0.channelID == channel.id && $0.start == program.start }) {
                    scheduler.cancel(item)
                }
            }
        } else {
            Button("Programma registrazione", systemImage: "record.circle") {
                scheduler.schedule(program, channel: channel)
            }
            .tint(.red)
        }
    }

    private func open(_ program: GuideProgram) {
        if program.isLive { model.play(channel) }
        else if model.canReplay(program, channel: channel) { model.playReplay(channel, program) }
    }
}
