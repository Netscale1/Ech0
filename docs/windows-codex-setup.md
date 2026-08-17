# Ech0: setup microfono Windows → Mac

Questa guida configura il percorso:

`microfono Windows → Ech0Windows → LAN fidata → Ech0Mac → Ech0 Virtual Microphone → app Mac`

Ech0Windows resta connesso ma apre il microfono Windows soltanto quando Core Audio segnala che un processo Mac sta realmente acquisendo dal dispositivo d’ingresso preparato da Ech0Mac. Il rilevamento è di sistema e non contiene logica specifica per Codex.

## Requisiti

- Mac con macOS 13 o successivo.
- PC x64 con Windows 10 22H2 o Windows 11.
- Mac e PC sulla stessa LAN privata e fidata.
- `BlackHole 2ch` installato sul Mac.
- L’app Mac desiderata configurata per usare `Ech0 Virtual Microphone` come ingresso.
- .NET 10 SDK soltanto sulla macchina che esegue la build Windows; il PC di destinazione non richiede .NET.

Il protocollo v3 autentica il Mac, cifra pairing, controlli e audio con AES-GCM e salva su Windows il pin della chiave del ricevitore. Non esporre comunque la porta `48484/TCP` direttamente su Internet: il trasporto è progettato e verificato per la LAN locale.

## 1. Preparare il Mac

Installare [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole), poi verificare in **Configurazione MIDI Audio** che il device sia presente.

Dalla root del repository:

```sh
swift test --package-path macos
./scripts/build-macos-app.sh
open dist/macos/Ech0Mac.app
```

Lo script crea il bundle in `dist/macos/Ech0Mac.app`. Se nel portachiavi esiste un’identità `Apple Development`, viene usata automaticamente. È possibile sceglierne una esplicitamente con `ECH0_CODESIGN_IDENTITY`.

Al primo avvio:

1. Aprire **Pairing** e copiare il codice di sicurezza Base32 per il nuovo dispositivo e l’indirizzo del Mac.
2. Abilitare **Launch at login** se Ech0Mac deve partire con macOS.
3. Nell’app Mac desiderata selezionare `Ech0 Virtual Microphone` come ingresso e concedere a quell’app il permesso **Microfono**.

Ech0Mac non richiede Accessibilità e non registra né salva l’audio.

## 2. Preparare Windows

Per una build self-contained x64 di sviluppo:

```sh
./scripts/build-windows.sh
```

Lo script esegue prima tutti i test C# e produce:

- `dist/windows/Ech0Windows-win-x64.zip`: prima installazione non firmata per test;
- `dist/windows/SHA256SUMS`: hash SHA-256.

Una release distribuibile e il relativo `Ech0Windows-update.zip` devono essere creati su Windows con `scripts/release-windows.ps1`, un certificato Authenticode e un timestamp server configurati. Il gate esegue test, firma e verifica sia l’eseguibile sia lo script di update. I dettagli sono in `docs/release.md`.

Sul PC Windows:

1. Estrarre `Ech0Windows-win-x64.zip` in una cartella locale.
2. Avviare `Ech0Windows.exe` dalla sessione interattiva dell’utente.
3. Lasciare attiva la discovery automatica, oppure inserire manualmente IP del Mac e porta `48484`.
4. Inserire il codice mostrato da Ech0Mac.
5. Abilitare **Start Ech0 with Windows**.

La prima configurazione copia l’eseguibile in `%LOCALAPPDATA%\Ech0` e registra l’avvio per l’utente corrente in `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. Non servono UAC, driver o privilegi amministrativi.

Per aggiornare un’installazione esistente, usare soltanto lo ZIP prodotto dal percorso firmato, estrarlo e avviare `Update-Ech0.cmd`. L’updater verifica SHA-256, firma e publisher atteso; arresta soltanto il processo eseguito dal percorso installato in `%LOCALAPPDATA%\Ech0`, sostituisce il file e lo riavvia.

## 3. Discovery e pairing

Ech0Mac pubblica il servizio DNS-SD `_ech0._tcp.local`. Ech0Windows prova prima la discovery nativa Windows e permette sempre un fallback manuale con:

- indirizzo IP del Mac;
- porta `48484`;
- codice di sicurezza Base32 mostrato dal Mac.

Dopo il pairing, Windows conserva il `receiverId`, il pin SHA-256 della chiave di firma del Mac, un `senderId` e un segreto casuale. Segreto e codice eventualmente pendente vengono serializzati soltanto nei rispettivi campi protetti con DPAPI `CurrentUser`; sul Mac viene conservato soltanto l’hash del segreto Windows e la chiave privata del ricevitore ha permessi owner-only. Il codice viene eliminato da Windows dopo la conferma. Una sessione trusted accetta soltanto lo stesso receiver ID e lo stesso pin; una vecchia associazione v2 priva di pin richiede intenzionalmente un nuovo pairing una tantum.

Nelle impostazioni Windows, un Mac associato appare come `Connected · Trusted` oppure `Trusted · not reachable`; il campo del codice compare soltanto quando serve un nuovo pairing. **Change Mac** conserva l’associazione precedente finché il nuovo Mac non conferma la fiducia. **Reset pairing** elimina invece subito l’associazione locale.

Se il Mac dimentica SE7EN, la sessione viene chiusa immediatamente. Windows ferma il microfono e i retry, mostra `Pairing required` nella tray e una notifica. Aprire le impostazioni e inserire il codice corrente del Mac per autorizzare nuove credenziali.

Windows invia un heartbeat ogni secondo. Se un crash, una sospensione o un cambio rete lascia una socket incompleta, Ech0Mac libera automaticamente lo slot sender dopo 5 secondi e consente la riconnessione successiva.

## 4. Attivazione automatica

Ech0Mac osserva i Process Objects pubblici di Core Audio. La richiesta diventa attiva quando almeno un processo dichiara contemporaneamente I/O d’ingresso in esecuzione e l’uso del device ID preparato da Ech0Mac. Normalmente il device è `Ech0 Virtual Microphone`; `BlackHole 2ch` resta il fallback di compatibilità.

Quando la richiesta diventa attiva, Ech0Mac invia `captureDemand`. Ech0Windows apre l’ingresso predefinito Windows in WASAPI shared mode e normalizza l’audio in PCM16 mono, 48 kHz, frame da 20 ms. Quando l’ultimo consumer chiude l’ingresso, l’agent chiude WASAPI dopo il breve debounce e il Mac svuota il buffer.

Il segnale rappresenta I/O audio reale, non l’intento privato dell’interfaccia dell’app. Per esempio, un registratore che apre il microfono per mostrare l’anteprima è già un consumer prima che venga premuto “Registra”. Il pulsante manuale compare soltanto se il monitor Core Audio non è disponibile.

## 5. Verifica finale

Con Ech0Mac connesso a Windows:

1. Senza consumer, Ech0Mac deve mostrare `Automatic` e Windows deve essere inattivo.
2. Aprire il microfono in QuickTime Player, Codex o un’altra app: Ech0Mac deve mostrare `Streaming` e il contatore dei frame deve crescere.
3. Parlare e verificare il meter di Ech0Mac e la ricezione nell’app.
4. Chiudere l’acquisizione: entro pochi secondi Ech0Mac deve tornare inattivo, con buffer a `0 ms`.
5. Aprire contemporaneamente una seconda app sullo stesso ingresso: la cattura deve restare attiva finché non chiude l’ultimo consumer.
6. Selezionare un ingresso Mac diverso da quello mostrato da Ech0: non deve partire alcuna cattura.
7. Spegnere le cuffie wireless Windows: Ech0Windows deve attendere il ritorno dell’endpoint, senza passare silenziosamente a un altro microfono.

Controlli locali:

```sh
swift test --package-path macos
./scripts/build-windows.sh
```

I test C# vanno eseguiti su Windows con il runtime/SDK appropriato:

```powershell
dotnet test windows/Ech0Windows.Tests/Ech0Windows.Tests.csproj -c Release
```

## Troubleshooting

### Ech0 rileva un consumer ma Windows non cattura

Controllare che Windows esegua l’ultima build. Usare `Ech0Windows-update.zip` e avviare `Update-Ech0.cmd`, poi verificare che l’agent torni nella tray e si riconnetta.

### Si sente la propria voce nelle cuffie

Questo ritorno è normalmente prodotto dall’audio di Parsec, non dal monitor Core Audio. Disabilitare l’audio di ritorno del host Parsec e lasciare Ech0 responsabile soltanto del percorso microfono.

### Codex non riceve audio

Verificare che Codex usi il dispositivo mostrato da Ech0Mac, normalmente `Ech0 Virtual Microphone`, e che l’app abbia il permesso Microfono. Ech0Mac deve mostrare frame ricevuti e il meter deve muoversi quando si parla.

### Nessuna discovery Windows

Verificare che Mac e PC siano sulla stessa LAN, consentire Ech0Windows nel firewall privato Windows e usare l’inserimento manuale dell’IP del Mac e della porta `48484`.

### Il codice Windows è diverso da quello del Mac

Dopo il primo pairing Windows non deve mostrare alcun codice: il codice del Mac serve soltanto ai nuovi dispositivi. Se Windows mostra `Pairing required`, usare il codice corrente visibile sul Mac. Non copiare o sincronizzare manualmente codici per un dispositivo che appare già `Trusted`.

## Limiti intenzionali

- Un solo sender attivo alla volta.
- Nessun relay Internet o fallback cloud.
- Nessuna registrazione locale dell’audio.
- Nessuna modifica al microfono predefinito, volume, mute o modalità esclusiva Windows.
- La porta TCP resta destinata alla LAN locale e non a un’esposizione Internet diretta.
