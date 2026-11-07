import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("network.tailscaleEnabled") private var useTailscale = false
    @StateObject private var tailnet = TailnetDiagnostics()
    @State private var editing: IPTVSource?
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Sorgenti") {
                    ForEach(model.profiles) { profile in
                        Button { model.select(profile) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(profile.displayName).foregroundStyle(.primary)
                                    Text(profile.kind == "xtream" ? "Xtream Codes" : "Playlist M3U")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.id == model.selectedID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { model.remove(profile) } label: { Label("Elimina", systemImage: "trash") }
                            Button { editing = profile } label: { Label("Modifica", systemImage: "pencil") }.tint(.blue)
                        }
                    }
                    Button("Aggiungi sorgente", systemImage: "plus") { showNew = true }
                }

                if let account = model.account {
                    Section("Account") {
                        LabeledContent("Stato", value: account.status.isEmpty ? "-" : account.status)
                        if let expiry = account.expiry {
                            LabeledContent("Scadenza", value: expiry.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let max = account.maxConnections { LabeledContent("Connessioni massime", value: String(max)) }
                    }
                }

                if model.current != nil {
                    Section("Replay (catch-up)") {
                        Picker("Formato", selection: Binding(
                            get: { model.current?.catchupVariant ?? "auto" },
                            set: { value in model.mutateCurrent { $0.catchupVariant = value } })) {
                            ForEach(CatchupVariant.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        Stepper("Correzione orario: \(model.current?.archiveShiftMinutes ?? 0) min",
                                value: Binding(get: { model.current?.archiveShiftMinutes ?? 0 },
                                               set: { value in model.mutateCurrent { $0.archiveShiftMinutes = value } }),
                                in: -720...720, step: 15)
                        TextField("Fuso orario server (es. Europe/Rome)", text: Binding(
                            get: { model.current?.serverTimeZone ?? "" },
                            set: { value in model.mutateCurrent { $0.serverTimeZone = value } }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Con \"Automatico\" l'app prova i formati noti e memorizza quello che risponde. Il test manuale e' nel player (icona stetoscopio).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Tailscale") {
                    Toggle("Uso Tailscale per server privati", isOn: $useTailscale)
                    if useTailscale {
                        Button("Verifica raggiungibilita' del server") {
                            if let address = model.current?.rawAddress {
                                Task { await tailnet.check(server: address) }
                            }
                        }.disabled(tailnet.checking || model.current == nil)
                        Text(tailnet.state).font(.footnote).foregroundStyle(.secondary)
                        Button("Apri app Tailscale", systemImage: "arrow.up.forward.app") { tailnet.openTailscale() }
                    }
                    Text("L'app usa la VPN gia' attiva nell'app ufficiale Tailscale: non la avvia. Per averla sempre pronta imposta VPN On Demand in Tailscale. I provider pubblici funzionano anche senza.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Informazioni") {
                    LabeledContent("Versione", value: "0.3")
                    Text("DVR e replay sono sperimentali. Le credenziali sono nel Keychain del dispositivo.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Impostazioni")
            .sheet(isPresented: $showNew) { ProfileEditor(profile: nil) }
            .sheet(item: $editing) { ProfileEditor(profile: $0) }
        }
    }
}

struct ProfileEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: IPTVSource

    init(profile: IPTVSource?) {
        _draft = State(initialValue: profile ?? IPTVSource())
    }

    private var valid: Bool {
        draft.kind == "xtream"
            ? !draft.server.isEmpty && !draft.username.isEmpty && !draft.password.isEmpty
            : !draft.playlist.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") { TextField("Nome (facoltativo)", text: $draft.name) }
                Section("Tipo") {
                    Picker("Sorgente", selection: $draft.kind) {
                        Text("Playlist M3U").tag("m3u")
                        Text("Xtream Codes").tag("xtream")
                    }.pickerStyle(.segmented)
                }
                if draft.kind == "m3u" {
                    Section("Playlist") {
                        TextField("https://server/playlist.m3u", text: $draft.playlist)
                            .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                        TextField("URL EPG XMLTV (facoltativo)", text: $draft.epgURL)
                            .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    }
                } else {
                    Section("Account Xtream") {
                        TextField("http://server:porta", text: $draft.server)
                            .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                        TextField("Username", text: $draft.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $draft.password)
                        Picker("Formato live", selection: $draft.streamFormat) {
                            Text("HLS (m3u8)").tag("m3u8")
                            Text("MPEG-TS").tag("ts")
                        }
                    }
                }
                Section {
                    Button("Salva e carica") {
                        if draft.name.isEmpty { draft.name = draft.displayName }
                        model.upsert(draft)
                        dismiss()
                    }.disabled(!valid)
                }
            }
            .navigationTitle("Sorgente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Annulla") { dismiss() } }
        }
    }
}
