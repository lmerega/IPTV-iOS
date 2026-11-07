import SwiftUI
import AVKit
import Network

struct ContentView: View {
    @AppStorage("demo.url") private var streamURL = ""
    @AppStorage("network.tailscaleEnabled") private var tailscaleEnabled = false
    @State private var player: AVPlayer?
    @State private var status = "Pronto per il test"
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("IPTV POC").font(.largeTitle.bold())
                        Text("Prova di riproduzione su iPhone e iPad")
                            .foregroundStyle(.secondary)
                    }

                    GroupBox("Player") {
                        VStack(spacing: 12) {
                            if let player {
                                VideoPlayer(player: player)
                                    .frame(minHeight: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .accessibilityLabel("Riproduzione video")
                            } else {
                                ContentUnavailableView("Nessun video", systemImage: "play.rectangle", description: Text("Inserisci un URL HLS di test."))
                                    .frame(minHeight: 220)
                            }
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    GroupBox("Sorgente di test") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("https://esempio.it/live/stream.m3u8", text: $streamURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .privacySensitive()
                            HStack {
                                Button("Riproduci", systemImage: "play.fill", action: play)
                                    .buttonStyle(.borderedProminent)
                                Button("Ferma", systemImage: "stop.fill", action: stop)
                                    .buttonStyle(.bordered)
                            }
                        }
                    }

                    GroupBox("Connettività") {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(tailscaleEnabled ? "Verifica Tailscale attiva" : "Tailscale facoltativo", systemImage: "network")
                            Text("La POC usa la connessione di rete già configurata su iOS: non attiva direttamente la VPN di Tailscale.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Impostazioni") { showSettings = true }
                        }
                    }

                    Text("POC-001: per ora solo URL HLS diretti. Import M3U, accesso Xtream, DVR e catch-up arriveranno dopo i primi test su dispositivo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: 750)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("IPTV")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    Form {
                        Toggle("Abilita diagnostica Tailscale", isOn: $tailscaleEnabled)
                        Text("Con la VPN ufficiale già attiva, gli URL di un server nella tailnet possono essere utilizzati come gli altri indirizzi di rete. La spunta non stabilisce una VPN.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .navigationTitle("Rete")
                    .toolbar { Button("Chiudi") { showSettings = false } }
                }
            }
        }
    }

    private func play() {
        guard let url = URL(string: streamURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil
        else {
            status = "URL non valido: usa http o https."
            return
        }
        player?.pause()
        player = AVPlayer(url: url)
        player?.allowsExternalPlayback = true
        player?.play()
        status = "Tentativo di riproduzione avviato. Se lo streaming non parte, verifica codec, URL, VPN e connettività."
    }

    private func stop() {
        player?.pause()
        player = nil
        status = "Riproduzione interrotta."
    }
}
