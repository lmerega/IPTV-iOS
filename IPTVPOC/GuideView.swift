import SwiftUI

struct GuideView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var onlyReplay = true

    private var filtered: [IPTVChannel] {
        model.channels.filter { channel in
            (!onlyReplay || channel.archive)
                && (search.isEmpty || channel.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { channel in
                NavigationLink(value: channel) { ChannelRow(channel: channel) }
            }
            .listStyle(.plain)
            .navigationTitle("Guida e replay")
            .navigationDestination(for: IPTVChannel.self) { ChannelGuideView(channel: $0) }
            .searchable(text: $search, prompt: "Cerca un canale")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle("Solo replay", isOn: $onlyReplay).toggleStyle(.button)
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
            if program.isLive {
                Label("Ora", systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.red)
            } else if model.canReplay(program, channel: channel) {
                Image(systemName: "play.circle").foregroundStyle(.tint)
            }
        }
    }

    private func open(_ program: GuideProgram) {
        if program.isLive { model.play(channel) }
        else if model.canReplay(program, channel: channel) { model.playReplay(channel, program) }
    }
}
