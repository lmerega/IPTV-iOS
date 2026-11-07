# IPTV-iOS — Handoff completo per Claude
Ultimo aggiornamento: 7 novembre 2026. Lingua di lavoro: italiano.

> **LEGGI PRIMA DI CAMBIARE QUALSIASI COSA.** Questo README documenta informazioni verificate, stato effettivo del repository e requisiti del proprietario. Non confondere funzionalita' pianificate, codice locale incompleto, build GitHub riuscite e test superati su dispositivo. Il proprietario vuole che tu finisca il prodotto, produca UNA build ragionevolmente completa e ne organizzi la verifica, NON che chieda di reinstallare decine di prototipi.

## 0. Obiettivo e priorita' dell'utente

Creare un'alternativa iOS a Smarters Player Pro, dall'interfaccia bella, pulita e reattiva, per **iPhone e iPad iOS 18+**, solo uso personale e pochi dispositivi. Necessarie:
- Playlist remote **M3U / M3U8** e portali **Xtream Codes** (live, VOD e serie, se supportati).
- EPG e **catch-up eccellente**: elenco programmi, replay, navigazione oraria accurata, seek, resume, correzioni timezone / offset, fallback ai diversi formati provider.
- **DVR locale** e idealmente timeshift con cache configurabile su disco e poca RAM. Accettata limitazione: registrazioni solo quando l'app e' attiva; no promessa di registrazione in background.
- **AirPlay** se supportato da AVPlayer, rete e formato del flusso.
- **Tailscale fondamentale ma facoltativo nelle Impostazioni**: **utilizzare l'app ufficiale Tailscale gia' configurata** su iPhone/iPad (NON incorporare una VPN in-app salvo successiva richiesta). Consentire uso dei server nella tailnet e dei provider Internet pubblici, test di raggiungibilita', possibilmente apertura della app Tailscale e guida a VPN On Demand.
- UI: mostrare diversi mockup, l'utente non ha ancora scelto un design definitivo.
- Non acquistare un Mac o Apple Developer: compilare tramite **GitHub Actions su runner macOS**; installare IPA su iPhone tramite Sideloadly su Windows.

**Importante**: l'utente ha espresso insoddisfazione verso le POC inutilizzabili: chiede una versione completa da provare, poi iterare. Evitare di chiamare "finito" qualsiasi codice non verificato end-to-end.

## 1. Ambiente / percorsi / account confermati

- PC Windows principale: **LMEHOME** (via Remote Desktop Commander). Controllarne lo stato prima di agire; potrebbe essere offline.
- Cartella repository locale **D:\IPTV-iOS** (NON C:\Users\...\source\repos); repository gia' clonato.
- Tutti i **file IPA scaricati** devono andare sotto **D:\IPTV-iOS\releases\**. Questa cartella e' elencata in `.gitignore`. Non utilizzare D:\IPTV-Builds come destinazione definitiva.
- Repository GitHub: **https://github.com/lmerega/IPTV-iOS** , branch **main**, attualmente **pubblico** (per usare i runner GitHub Actions standard senza costo). GitHub CLI `gh` e Git sono installati, gh gia' autenticato nell'account corretto; NON stampare token o segreti.
- Strumenti Windows verificati: Git 2.56, GitHub CLI 2.103.3, Node.js/npm, Python 3.14, Visual Studio Code. XcodeGen non installato su Windows, viene installato sul runner macOS.
- Sideloadly e' gia' installato in `%LOCALAPPDATA%\Sideloadly\sideloadly.exe`; e' stato avviato con successo e ha rilevato un iPhone via USB. iTunes risulta installato. Installazione e' stata realizzata usando installer ufficiale dal dominio sideloadly.io. La versione dell'interfaccia rilevata era 0.72.
- **NON copiare da qui credenziali Apple, password IPTV, auth keys Tailscale, seriali dispositivo o file *.pem**. Esistono dati sensibili dentro le cartelle Sideloadly dell'utente: non committarli, non leggerli senza necessita'.
- Bundle ID esistente **`io.github.lmerega.iptvpoc`**: **MANTENERLO INVARIATO** per tutti gli aggiornamenti, per non sprecare ulteriori App ID gratuiti e per compatibilita' con l'app gia' installata. Sideloadly puo' applicare a valle un suffisso di team ID durante la firma, e' normale.

## 2. Cosa e' stato REALMENTE verificato

- GitHub Actions compila nativamente un'app SwiftUI con Xcode su `macos-15`, `CODE_SIGNING_ALLOWED=NO`, quindi produce una IPA **non firmata**.
- Prima build riuscita: run **42365897194**, artifact `IPTVPOC-unsigned-3`.
- Seconda build riuscita (M3U/Xtream e catch-up iniziale): run **42367492995**, commit **5734657** (`Add M3U Xtream channel browser and experimental catchup`).
- Link: https://github.com/lmerega/IPTV-iOS/actions/runs/42367492995
- L'IPA della prima build e' stata scaricata e verificata come archivio ZIP integro e con `Payload/IPTVPOC.app/IPTVPOC`. La copia locale `D:\IPTV-iOS\releases\IPTVPOC-unsigned.ipa` e' **quella della PRIMA POC**, **NON** la build moderna. SHA256 verificato della prima copia: `d4d6e426f68ca04bad49341f0be797173451f101fff901e17a4d815cb1df7cc4`, dimensione 35016 byte.
- Il proprietario ha usato Sideloadly con Apple ID gratuito, la registrazione di installazione su PC riportava zero errori, ha autorizzato lo sviluppatore ed e' arrivato all'avvio dell'app. Ha riferito che la POC si avvia, ma non e' concretamente utile. **Non risulta verificato un flusso IPTV live, catch-up, DVR o AirPlay sul dispositivo.**
- Sideloadly indica un numero limitato di **App ID** gratuiti rimasti (l'utente ha riferito 10). Questo NON significa 10 aggiornamenti: riutilizzare lo stesso Bundle ID evita registrazioni di nuove identita' app, compatibilmente col provisioning e con i limiti di Apple. Non sprecare slot con cambi di Bundle ID.
- Modalita' sviluppatore iOS richiesta per questa installazione; una volta attivata normalmente rimane attiva. Con provisioning gratuito rinnovo tipico ogni 7 giorni (Sideloadly Daemon puo' aiutare con rinnovi quando PC e dispositivo sono raggiungibili).

## 3. Stato esatto del codice locale AL MOMENTO DEL PASSAGGIO

**ATTENZIONE: lo stato locale contiene MODIFICHE NON COMMITTATE e NON COMPILATE.** Prima di toccare qualcosa eseguire:

```powershell
git -C D:\IPTV-iOS status --short --branch
git -C D:\IPTV-iOS log -5 --oneline
Get-ChildItem D:\IPTV-iOS\IPTVPOC
```

Alla verifica del 7 novembre:
- `main` su commit `5734657` sincronizzato con `origin/main`: e' l'**ultima build GitHub confermata riuscita**.
- `IPTVPOC/ContentView.swift`: e' la UI v0.2 gia' pushata, con singola sorgente, lista canali, ricerca, gruppi, AVPlayer e catch-up Xtream sperimentale. Non e' la UI finale.
- `IPTVPOC/IPTVService.swift`: **modificato localmente**, **non commit**, parser M3U e Xtream esteso con metadati logo, tvg-id, archive template e gestione tipi JSON flessibile. Deve essere compilato e corretto.
- `IPTVPOC/DVR.swift`: **nuovo file locale NON tracciato**, esperimento DVR HLS MPEG-TS con lettura playlist e download segmenti, limiti spazio, UI delle registrazioni. Non collegato completamente alla UI, non compilato/testato. Non promettere supporto a TS diretto, HLS fMP4, DRM, AES, discontinuita', registrazioni in background, buffer circolare senza svilupparli.
- `IPTVPOC/IPTVExtras.swift`: **nuovo locale NON tracciato**, API Xtream categorie, EPG breve e catch-up, VOD e serie, XMLTV basilare. Non ancora collegato alla UI, non compilato/testato. **Probabile necessaria importazione di FoundationXML per XMLParser su Swift/iOS**: verificare compilando. Verificare anche l'implementazione del recupero URL, parsing valori JSON misti, fusi orari e archivi.
- `IPTVPOC/TailnetDiagnostics.swift`: **nuovo locale NON tracciato**, utility sperimentale NWConnection per sondare host/porta e tentativo apertura Tailscale. Non collegata alla UI. Verificare URL scheme Tailscale realmente supportato e dichiarazioni di schemi consentiti; la verifica reachability NON attesta che Tailscale sia connesso, ma solo che quell'host/porta sia raggiungibile.
- `IPTVPOC/IPTVPOCApp.swift`: entrypoint SwiftUI minimale, versionato.
- `project.yml`: progetto XcodeGen, iOS 18+, famiglia iPhone/iPad 1,2, Bundle ID `io.github.lmerega.iptvpoc`, code signing disabilitato in CI. Attenzione: necessita' di configurare **ATS** per eventuali server IPTV HTTP; la chiave nel progetto e' dichiarata ma va verificato nell'Info.plist risultante, possibilmente limitare eccezioni.
- `.github/workflows/build-ios.yml`: workflow CI su `push` a main e `workflow_dispatch`, runner `macos-15`, `brew install xcodegen`, build release dispositivo senza firma, packaging `Payload/` e upload artifact con retention 7 giorni.
- `.gitignore`: ignora `/releases/`.
- Questo README precedente era obsoleto (parlava di repository privato e singola sorgente); la presente versione ne sostituisce interamente il contenuto.

**Non esiste ancora** un completo sistema multi-profile salvato nel Keychain, nonostante fosse stato ipotizzato. Non e' stato scritto/compilato un flusso integrato per VOD, serie, EPG navigabile, DVR e Tailscale. La versione che l'utente ha sull'iPhone e' ancora la POC iniziale.

## 4. Architettura desiderata (proposta, rifinire)

- Swift 5 / SwiftUI nativo; AVKit/AVPlayer come motore primario, con test di compatibilita' flussi HLS e fallback esplicito soltanto se necessario (es. libVLC, valutando peso, licenze e codici di firma).
- `Models`: IPTVProfile, IPTVChannel, GuideProgram, VODItem, Episode, Recording, PlaybackState.
- `Services`: XtreamService, M3UParser, XMLTV/EPGService, CatchupResolver, PlaybackManager, NetworkDiagnostics, DVRManager.
- `Storage`: credenziali sempre in Keychain; preferiti, ultime visioni e impostazioni in storage locale appropriato. Supportare piu' playlist / account, rinominare e rimuovere.
- `Views`: Home, TV Live (filtri e preferiti), EPG / Guida, Catch-up, Film, Serie, Registrazioni, Impostazioni, schermata Dettaglio canale e player full-screen iPhone/iPad.
- Player: AVPlayer, selezione stream, scrubbing, controlli +/-30 s per catch-up, stato buffering/errori, possibile PiP/AirPlay, chiusura e cleanup.
- Tailscale: app ufficiale del dispositivo, **opzionale**. Per sorgenti private: hostname MagicDNS o IP 100.x, reachability, messaggi diagnostici che non confondano 'VPN attiva' e 'server raggiungibile', eventuale guida On Demand. Non promettere di accendere la VPN di un'altra app; non cambiare la VPN di sistema senza richiesta. Server pubblici devono funzionare senza Tailscale.
- DVR: prima ottenere una registrazione locale funzionante in foreground. Distingui registrazione permanente e timeshift; garantire limitazione spazio e gestione annullamento/errori. Non inserire registrazioni di contenuti protetti/cifrati o supporto DRM bypass. Eventuale servizio DVR su server solo in futuro.
- EPG: Xtream short EPG e/o XMLTV con parsing robusto, mapping tvg-id, timezone e correzione offset configurabile, UI timeline, catch-up con parametri effettivi del provider; archivi variabili (Xtream timeshift, append, flussonic, shift, URL custom). Il provider dell'utente supporta catch-up ma nei player attuali funziona male: analizzare con esempi reali **senza esporre password**.
- Sicurezza: HTTPS preferibile, validare redirect, non registrare URL con username/password, attenzione ai token nei messaggi di errore e negli screenshot; limiti parsing playlist XML grandi, caching e memory management. Nessun contenuto IPTV incluso nell'app.

## 5. Modalita' di lavoro consigliata a Claude

1. Eseguire una verifica dell'ambiente LMEHOME e di `git status`; **preservare le modifiche WIP locali**. Preferibilmente creare branch `feature/full-player` o fare commit WIP chiaro prima delle modifiche importanti, per non perdere il lavoro; attenzione ai workflow di build che si attivano su main.
2. Eseguire audit del Swift esistente (compilabilita', actor isolation / Swift concurrency, Keychain, secure logging, M3U/Xtream API variabili).
3. Stabilizzare model layer e UI con reale supporto multi-sorgente, barra schede, TV Live, EPG, VOD, Serie, DVR, Impostazioni e Tailscale.
4. Creare test automatici con fixture **sintetiche prive di segreti**: parser M3U (#EXTINF, tvg-id, catchup-source, group), Xtream JSON numeri/stringhe, base64, archivio UTC, XMLTV timezone, DVR playlist HLS e policy di pulizia. Inserire un target di test XcodeGen e far girare CI quando possibile.
5. **Evitare dipendenze di terze parti pesanti** fino a validazione codec/routing, salvo richiesta.
6. Prima di qualsiasi installazione, fare commit/push, eseguire **GitHub Actions** e correggere gli errori di compilazione; eseguire controlli statici, test e analizzare logs. Non assumere che la presenza dell'IPA attesti il funzionamento.
7. Solo quando la build e' coerente e utilizza **lo stesso Bundle ID**, scaricare l'IPA con un nome versionato in `D:\IPTV-iOS\releases\`; verificarne ZIP, struttura `Payload/*.app`, Info.plist e hash SHA256. Conservare una copia dell'ultima IPA riuscita e evitare di sovrascriverla senza backup.
8. Chiedere all'utente di firmare e installare sul dispositivo con Sideloadly; NON digitare o memorizzare credenziali Apple. Raccogliere risultati su flussi reali, Tailscale, catch-up, AirPlay, registrazioni. Non chiedere URL privati con token o password in chat.
9. Documentare ogni limitazione o mancanza con evidenza e non dichiarare "versione finale" cio' che non e' stato testato.
10. Prima di cambiare visibilita' del repository, nome app, Bundle ID, impostazioni VPN o metodi di firma, confrontarsi con l'utente.

## 6. Build, CI e scaricamento: comandi utili su LMEHOME

Il codice sorgente e' in **D:\IPTV-iOS**. Esempi PowerShell:

```powershell
cd D:\IPTV-iOS
git status
git diff --check
git add IPTVPOC project.yml .github README.md
git commit -m "Implement complete IPTV test build"
git push origin main
gh run list --repo lmerega/IPTV-iOS --limit 5
gh run view <RUN_ID> --repo lmerega/IPTV-iOS
gh run view <RUN_ID> --repo lmerega/IPTV-iOS --log-failed
# Dopo che la build e' SUCCESS:
New-Item -ItemType Directory -Force D:\IPTV-iOS\releases
gh run download <RUN_ID> --repo lmerega/IPTV-iOS --name <ARTIFACT_NAME> --dir D:\IPTV-iOS\releases
```

N.B.: `gh run download` estrae il contenuto dell'artifact ZIP: l'IPA vera sara' dentro `releases`. Rinominarla indicando build e versione. Non scaricare IPA da fonti sconosciute. Se la build fallisce, consultare i log del JOB, non provare a installare l'IPA precedente fingendo che sia quella nuova.

Verifica IPA con Python standard su Windows:

```powershell
python -c "import zipfile,pathlib,hashlib; p=pathlib.Path(r'D:\IPTV-iOS\releases\IPTVPOC-unsigned.ipa'); z=zipfile.ZipFile(p); print('ZIP',z.testzip()); print('APP',[x for x in z.namelist() if x.endswith('.app/Info.plist')]); print('SHA256',hashlib.sha256(p.read_bytes()).hexdigest())"
```

Configurazione CI: `.github/workflows/build-ios.yml`. Se serve estendere la validazione, aggiungere unit test e `xcodebuild test` su simulatore, oltre alla build per `generic/platform=iOS`. GitHub Actions in repo pubblico usa runner standard gratuiti secondo le condizioni della piattaforma e disponibilita'.

## 7. Installazione / aggiornamenti dell'IPA su iPhone (senza Mac)

**Situazione comprovata:** iPhone collegato via USB a LMEHOME; Windows rileva Apple Mobile Device; Sideloadly ha firmato/installato una prima IPA; iOS ha richiesto trust dello sviluppatore e successivamente Modalita' sviluppatore; utente ha riferito che la POC parte.

Procedura per aggiornamento:
1. Verificare build GitHub **verde** e scaricare nuova IPA in `D:\IPTV-iOS\releases`.
2. Su LMEHOME avviare `%LOCALAPPDATA%\Sideloadly\sideloadly.exe`, collegare/sbloccare iPhone, confermare eventuale richiesta "Autorizza questo computer".
3. In Sideloadly scegliere l'iPhone, trascinare IPA corretta, inserire Apple ID **solo localmente nella app di installazione** e premere Start. Non fornire credenziali in chat o su GitHub.
4. Se iOS lo richiede: Impostazioni > Generali > VPN e gestione dispositivo > autorizzare lo sviluppatore; Impostazioni > Privacy e sicurezza > Modalita' sviluppatore e conferme di riavvio. Questi passaggi sono gia' stati affrontati una volta.
5. Riutilizzare **sempre bundle ID e Apple ID di firma** dell'installazione precedente, quando possibile, per un aggiornamento in-place e limitare uso degli slot App ID.
6. Free provisioning: firma tipicamente valida 7 giorni; possibile rinnovo con Sideloadly Daemon quando PC e iPhone sono disponibili, non garantito in tutte le condizioni.
7. Testare il lancio. In caso di crash, ottenere diagnostiche dispositivo / Console tramite strumenti appropriati, senza chiedere dati sensibili. Non reinstallare ripetutamente per tentativi alla cieca.

Altre opzioni di sideload discusse: AltStore Classic, SideStore; non sono state installate. SideStore potrebbe introdurre conflitti di VPN locale con Tailscale; preferenza attuale Sideloadly, gia' funzionante.

## 8. Matrice di test DA COMPLETARE

**Build / packaging**
- [x] Workflow compilazione SwiftUI base su GitHub Actions; artifact IPA generato.
- [x] IPA base integra, archiviata in releases.
- [x] App POC base installata e avviata su iPhone (riportato dall'utente).
- [ ] Branch/prodotto integrato aggiornato compila senza warning bloccanti.
- [ ] Unit test parser/EPG/network passano su CI.
- [ ] Nuova IPA versionata corretta installata in-place conservando App ID.

**Live / UI**
- [ ] Configurazione M3U reale da iPhone; elenco, ricerca, filtri, logos.
- [ ] Xtream Codes reale: login, categorie nomi, stream, credenziali Keychain.
- [ ] Playback HLS live: video, audio, buffering, errori di codec/URL.
- [ ] Playback su iPad: sidebar, landscape, safe area, split view.
- [ ] Preferiti e cronologia/resume.

**Tailscale (obbligatorio ma opzionale come impostazione)**
- [ ] Server privato in tailnet raggiungibile con Tailscale ufficiale connesso.
- [ ] Mancanza rete privata rilevata con messaggio utile, non crash.
- [ ] Un provider pubblico funziona senza attivare Tailscale.
- [ ] Switch nelle Impostazioni e, se desiderato, pulsante di apertura dell'app Tailscale.
- [ ] Comportamento VPN On Demand e MagicDNS verificato manualmente su iPhone, senza falsa promessa di avvio automatico da un'altra app.

**EPG / Catch-up**
- [ ] XMLTV: mappings, XML grande, date/timezone, aggiornamento.
- [ ] Xtream: EPG corretta con categorie e replay.
- [ ] Programmi di ieri e giorni scorsi, seek +30/-30 s, resume, offset e DST.
- [ ] Più protocolli replay; diagnosticare casi reali del provider.

**DVR / extras**
- [ ] File registrato su disco e riproducibile; limiti spazio effettivi, stop e gestione errori.
- [ ] Timeshift/ring buffer dedicato (non esiste ancora).
- [ ] AirPlay su dispositivo compatibile, anche su tailnet con eventuali limiti della raggiungibilita' lato TV.
- [ ] VOD, Serie, sottotitoli e tracce audio ove supportati.

## 9. Problemi tecnici da anticipare (non ignorare)

- Molti IPTV Xtream offrono MPEG-TS diretto oltre a HLS. AVPlayer non riproduce necessariamente ogni TS diretto; fallback codec/engine da valutare. Modello `streamFormat` configurabile.
- DVR corrente e' **sperimentale**: no supporto criptazione HLS/DRM, segmenti fMP4, byte-range, discontinuity, rate limiting o memoria/timeout completo. Assicurarsi che registrazione locale non violi i diritti sui contenuti. Possibili limiti di connessioni simultanee del provider.
- EPG XMLTV spesso e' .gz; parser corrente non gestisce .gz e usa intero Data in memoria. Pianificare decompressione/streaming e cache.
- La API `get_short_epg` puo' restituire dati diversi; `get_simple_data_table` varia per provider; `has_archive`, `stream_id` ecc. possono essere numeri o stringhe.
- Il modello in Keychain precedente memorizza una singola sorgente; multi-sorgente da implementare e migrare senza perdere le impostazioni esistenti.
- La diagnostica Tailscale deve misurare host/porta effettivi, non dedurre "VPN attiva" da NWConnection o controllo di IP. Lo switch e' preferenza per source/routing e messaggi, non abilitazione VPN.
- App Transport Security: alcuni server usano HTTP. Gestire eccezioni con attenzione; testare target iOS effettivo.
- Sideloadly installa app **firmate**. L'IPA CI e' unsigned: GitHub non firma da solo con Apple ID gratuito.
- Il repo e' **PUBBLICO**. MAI pushare playlist personali, account, query API con credenziali, token, log sanitizzati male, profili Sideloadly o file sensibili. Eseguire controlli prima di push. Non mettere in README dati reali del proprietario oltre ai riferimenti tecnici indispensabili.

## 10. Stato desiderato per il prossimo rilascio

E' richiesto un prodotto utilizzabile dall'utente al primo test, con almeno: aggiunta sorgenti M3U/Xtream, elenco live e categorie, player, schermata EPG/catch-up ragionevole, DVR foreground di base, AirPlay se disponibile, impostazioni Tailscale ufficiale con reachability, UI iPhone+iPad, build CI verde, IPA pronta in releases. Per le funzioni non realmente affidabili, marcarle "sperimentale" nella UI, scrivere limiti e raccogliere feedback.

**Non affermare che la versione e' finale finche' non hai verificato build, installazione e comportamento con i flussi reali.**

## 11. Azione immediata per Claude

1. Leggi `git status` e tutti i file `IPTVPOC/*.swift` (soprattutto i tre WIP non tracciati); salvaguardali.
2. Correggi i problemi di compilazione e architettura; integra UI completa e test.
3. Mantieni `PRODUCT_BUNDLE_IDENTIFIER=io.github.lmerega.iptvpoc`.
4. Esegui build automatizzata prima di ogni richiesta di installazione.
5. Scarica artifact verificato in `D:\IPTV-iOS\releases`, con nome versione/build; non cancellare la vecchia IPA utile.
6. Fai installare all'utente una sola build il piu' possibile completa per il primo test reale; raccogli log, iterare in seguito.

Fine handoff.