# OBSTimer

Ein Countdown für OBS Studio als **eigene Quelle**. Das Script wird einmal unter **Werkzeuge → Skripte** geladen. Danach fügst du in jeder Szene eine Quelle „OBSTimer“ hinzu, und ein Doppelklick darauf öffnet alle Einstellungen. Als Hintergrund gibt es transparent, einfarbig oder einen von neun animierten Stilen.

![Vorschau der Hintergrund-Stile](docs/vorschau.png)

## Funktionen

- **Zwei Modi:** eine feste Dauer (z. B. 10 Minuten) oder eine Zielzeit (z. B. 20:00 Uhr)
- **Anzeige:** Tage und Stunden lassen sich einzeln ein- und ausblenden, dazu optionale Beschriftungen (Tage/Std/Min/Sek) und ein Textschatten
- **Position:** neun Positionen (oben/Mitte/unten × links/Mitte/rechts) mit einstellbarem Abstand zum Rand
- **Text bei Ablauf**, z. B. „Stream startet jetzt!“
- **Schrift, Größe, Fett/Kursiv und Textfarbe** über die normalen OBS-Dialoge
- **Hintergrund:** transparent, einfarbig (mit Deckkraft und Eckenradius) oder animiert
- **Animierte Stile:** Farbverlauf, Aurora, Wellen, Partikel-Netz, Sternenflug, Bokeh, Neon-Puls, Streifen und Matrix. Für jeden Stil kannst du drei Farben, eine Grundfarbe und die Geschwindigkeit einstellen.
- **Steuerung:** Start/Pause, Zurücksetzen, +1 Minute, −1 Minute, jeweils als Button und als Hotkey
- **Automatik:** Der Timer startet von selbst, sobald die Quelle auf Sendung geht. Bei Ablauf kann OBS automatisch zu einer anderen Szene wechseln.

## Installation

1. Lade `obstimer.lua` und `obstimer.html` herunter und lege beide **in denselben Ordner**.
2. Öffne in OBS **Werkzeuge → Skripte**, klicke auf **+** und wähle `obstimer.lua`.
3. Füge in einer Szene über **+ → OBSTimer** eine Timer-Quelle hinzu. Alternativ klickst du im Skript-Fenster auf „OBSTimer-Quelle in aktueller Szene erstellen“.
4. Mit einem **Doppelklick auf die Quelle** öffnest du die Einstellungen: Zeit, Aussehen und Start/Pause.

Die Hotkeys legst du unter **Einstellungen → Hotkeys** fest. Sie stehen dort unter „OBSTimer: …“ und wirken auf alle OBSTimer-Quellen gleichzeitig.

Du kannst mehrere OBSTimer-Quellen mit unterschiedlichen Einstellungen haben.

## Hinweise

- Die Quelle ist standardmäßig 1920 × 1080 px groß, also so groß wie eine Full-HD-Szene. Der Countdown sitzt darin an der gewählten Position. Breite und Höhe stellst du in der Quelle ein.
- Für die Fehlersuche kannst du in `obstimer.lua` `DEBUG = true` setzen. Dann schreibt das Script jeden Schritt ins OBS-Log.
- Bei Start, Pause und Zurücksetzen lädt die Browserquelle kurz neu. Dadurch beginnt auch die Hintergrund-Animation von vorn.
- Im Modus **Zielzeit** liegt die Uhrzeit immer in der Zukunft. Ist sie heute schon vorbei, zählt der Timer bis zu dieser Uhrzeit am nächsten Tag.
- `obstimer.html` kannst du zum Ausprobieren auch direkt im Browser öffnen, z. B. mit `obstimer.html?state=run&end=9999999999999&bg=anim&anim=aurora`.

## Dateien

| Datei | Zweck |
|---|---|
| `obstimer.lua` | Das OBS-Script: registriert die Quelle „OBSTimer“, Einstellungen, Hotkeys und Timer-Logik |
| `obstimer.html` | Die Anzeige, die intern in jeder OBSTimer-Quelle läuft (Countdown und Hintergründe) |
