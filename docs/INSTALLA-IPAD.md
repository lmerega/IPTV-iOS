# Installare IPTVPOC su iPad con Sideloadly (Windows)

Vale per iPadOS 18 o successivo, con Apple ID gratuito già usato per l'iPhone.
File: `releases\IPTVPOC-0.7.2-build22.ipa`. Bundle ID da lasciare invariato: `io.github.lmerega.iptvpoc`.

Requisiti sul PC: Sideloadly, Apple Devices (o iTunes) e Bonjour installati. Usare il cavo USB.

## Passi

1. Collegare l'iPad al PC via USB, sbloccarlo e toccare **Autorizza** / "Autorizza questo computer" sull'iPad, poi inserire il codice.
2. Attivare la **Modalità sviluppatore** su iPad: Impostazioni > Privacy e sicurezza > Modalità sviluppatore. La voce compare dopo il primo tentativo di installazione o dopo aver collegato l'iPad a Sideloadly. Attivarla, riavviare l'iPad e confermare.
3. In Sideloadly: selezionare l'iPad nell'elenco dei dispositivi, trascinare l'IPA nella finestra, inserire lo stesso Apple ID dell'iPhone. Nelle opzioni avanzate non spuntare nessuna modifica del Bundle ID, poi premere Start. Se viene chiesto il codice di verifica a due fattori, inserirlo.
4. Sull'iPad: Impostazioni > Generali > VPN e gestione dispositivi, aprire il profilo dello sviluppatore con il proprio Apple ID e premere **Autorizza**.
5. Per rinnovare senza cavo: in Apple Devices (o iTunes) abilitare "Mostra questo iPad quando è collegato al Wi-Fi". Funziona solo se PC e iPad sono sulla stessa rete e il PC è acceso.

## Limiti dell'account gratuito

- La firma vale 7 giorni. Dopo 7 giorni l'app non si apre finché non viene reinstallata o rinnovata con Sideloadly.
- Massimo 3 app sideloaded per dispositivo.
- Massimo 10 App ID a settimana per Apple ID.
- Reinstallando con lo stesso Bundle ID i dati dell'app restano.

## Problemi comuni

- **"Could not find device"**: sbloccare l'iPad, controllare il cavo USB, riautorizzare il computer, riaprire Sideloadly.
- **Errore di limite App ID**: attendere la settimana successiva oppure usare un Apple ID diverso. Non cambiare il Bundle ID per aggirarlo.
- **L'app non si apre dopo l'installazione**: il profilo dello sviluppatore non è stato autorizzato oppure la Modalità sviluppatore è spenta. Ripetere i passi 2 e 4.
