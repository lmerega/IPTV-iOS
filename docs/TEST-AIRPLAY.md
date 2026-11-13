# Prove AirPlay

Prerequisiti: build con AirPlay installata, timeshift attivo (Impostazioni → Timeshift), iPhone e Apple TV
sulla stessa rete Wi-Fi, NordVPN spento sul telefono. In Impostazioni → AirPlay deve comparire "Pronto: Wi-Fi …".

Dopo ogni gruppo di prove manda **un solo log** (triplo tocco sullo stetoscopio, attendi "Inviato") e annota
il numero della prova e l'esito (OK / KO + cosa hai visto).

## A. Diretta e timeshift (canale compatibile, es. Canale 5 FHD o Sky Sport MotoGP FHD)

| # | Azione | Atteso |
|---|---|---|
| A1 | Apri il canale, attendi 30 s, tocca AirPlay → scegli l'Apple TV | La prima volta iOS chiede "Rete locale": **Consenti**. Sul telefono "In riproduzione sulla Apple TV", la TV mostra il canale entro ~10 s, dal punto in cui eri (circa) |
| A2 | Pausa dal telefono per 20 s, poi riprendi | La TV si ferma e riparte dallo stesso punto |
| A3 | -30 s due volte | La TV torna indietro di ~1 minuto |
| A4 | Trascina la barra del timeshift all'inizio | La TV va all'inizio del buffer |
| A5 | Tocca "Diretta" | La TV torna in diretta (6–10 s di ritardo) |
| A6 | Blocca il telefono per 2 minuti | La TV continua; sbloccando, il player e' ancora collegato |
| A7 | Chiudi l'AirPlay (pulsante AirPlay → iPhone) | Il video torna sul telefono con VLC, dallo stesso punto |
| A8 | Rimetti AirPlay e cambia canale con lo swipe verso l'alto | Il nuovo canale si apre sul telefono (AirPlay da riattivare): annota cosa succede |

## B. Canale non compatibile (es. un canale Rai RAW)

| # | Azione | Atteso |
|---|---|---|
| B1 | Apri il canale, tocca AirPlay → Apple TV | Avviso "non va in AirPlay video (audio MP2)…", sulla TV solo audio, il video resta sul telefono |

## C. Registrazioni

| # | Azione | Atteso |
|---|---|---|
| C1 | Registra 3 minuti di un canale compatibile, poi aprila da Registrazioni | Si apre con VLC |
| C2 | Vai al minuto 1, tocca AirPlay → Apple TV | Messaggio "Preparo la registrazione…", poi la TV riparte dal minuto 1 |
| C3 | Barra e ±30 s dal telefono | La TV si sposta |
| C4 | Chiudi l'AirPlay | Torna su VLC dallo stesso punto |
| C5 | Durante una registrazione in corso, apri "Guarda dall'inizio della registrazione" e manda in AirPlay | Funziona come la diretta (A1) |

## D. Film

| # | Azione | Atteso |
|---|---|---|
| D1 | Film MP4: AirPlay dal pulsante del player | La TV riproduce il film; "Riprendi" e "Continua a guardare" restano corretti |
| D2 | Film MKV (se ne trovi uno) | Avviso "non va in AirPlay video", sulla TV solo audio |

## E. Rete e regola della connessione unica

| # | Azione | Atteso |
|---|---|---|
| E1 | Spegni il Wi-Fi del telefono (resta il cellulare) e prova AirPlay | Avviso "AirPlay video richiede il Wi-Fi" |
| E2 | Durante A1, Impostazioni del provider/proxy: verifica che ci sia **una sola** connessione attiva | Una connessione (quella del telefono) |

## Cosa guardare nel log

- `AirPlay: compatibile / non compatibile …` per ogni canale
- `HLS (AirPlay): richieste N, ultima … s fa, spezzoni nel buffer N`: se le richieste restano 0, l'Apple TV non
  raggiunge il telefono (permesso "Rete locale" negato, Wi-Fi ospiti o isolamento tra dispositivi)
- `AirPlay: errore …` con il motivo di AVPlayer
