# DualSense Battery

Piccola app per la barra dei menu di macOS che mostra la batteria del controller
PS5 DualSense (anche Edge).

Il widget Batterie e il pannello Bluetooth di macOS spesso restano fermi
sull'ultimo valore letto alla connessione. Questa app legge invece la carica
direttamente dai report HID del controller.

## Cosa fa

- Mostra la percentuale accanto all'icona del controller, con un fulmine quando è in carica.
- Aggiorna il valore ogni 30 secondi e a ogni apertura del menu, senza restare in ascolto continuo.
- Manda una notifica di macOS quando la carica scende sotto il 20%.
- Può aprirsi al login e mostrarsi solo quando il controller è collegato.
- Non interferisce con giochi e sistema: apre il controller in modo non esclusivo.

Il DualSense comunica la carica a passi di 10%: i valori mostrati sono il centro
di ogni fascia (55%, 65%, …).

## Installazione

Servono macOS 14 o successivo e gli strumenti da riga di comando di Xcode
(`xcode-select --install`).

```sh
git clone https://github.com/E2MM/dualsense-battery.git
cd dualsense-battery
bash build.sh --install
```

Lo script compila l'app, la firma in locale, la copia in /Applications e la avvia.
Senza `--install` crea solo `build/DualSense Battery.app`.

## Struttura

| File | Contenuto |
| --- | --- |
| `main.swift` | Tutta l'app: lettura HID, barra dei menu, notifiche |
| `Info.plist` | Metadati del bundle (app senza icona nel Dock) |
| `build.sh` | Compilazione e installazione |
| `AppIcon.icns` | Icona dell'app |
| `tools/make_icon.py` | Rigenera l'icona (richiede Pillow) |

## Come legge la batteria

Il byte di stato si trova all'offset 52 del blocco dati comune ai report di input
(`0x01` via USB, `0x31` via Bluetooth). Il nibble basso è il livello da 0 a 10,
quello alto lo stato di carica. Il layout è lo stesso documentato dal driver
`hid-playstation` del kernel Linux.

In Bluetooth il controller può partire in una modalità "semplice" senza dati di
batteria. In quel caso l'app legge il feature report `0x05`, che attiva i report
completi.

## Problemi

Avvia l'app dal Terminale con i log diagnostici:

```sh
"/Applications/DualSense Battery.app/Contents/MacOS/DualSenseBattery" --debug
```

Se il Terminale risponde "Operation not permitted" sulla cartella del progetto,
spostala fuori da Download, Scrivania e Documenti, oppure dai al Terminale
l'accesso in Impostazioni di Sistema → Privacy e sicurezza → File e cartelle.
