# SleepSpeak 🌙

> **Smart, privacy-first sleep talk & noise recorder for Flutter.**  
> Automatically records overnight sleep audio, analyzes noise spikes (sleep talking, snoring, movement), and lets you quickly scrub through detected audio events without cloud dependencies.

> [!NOTE]
> 🤖 **Vibecoded Project:** Dieses gesamte Projekt wurde mit **Vibecoding** entwickelt und ist meine allererste Erfahrung im Erstellen einer vollständigen App mit AI-gestütztem Vibecoding!

### 🌐 Live Web Demo: [https://zaryar.github.io/SleepSpeak/](https://zaryar.github.io/SleepSpeak/)
Teste die Schlafanalyse, den interaktiven Wellenform-Scrubber und den Schwellenwert-Filter direkt online im Browser!

---

## ✨ Features

- **🎙️ Overnight Sleep Recording:** Efficient 16kHz mono WAV recording designed for all-night battery efficiency and Android 14+ Doze Mode compatibility.
- **⏰ Startverzögerung (Einschlaf-Timer):** Einstellbare Einschlaf-Verzögerung von 1 bis 30 Minuten (mit 10 Min Standard) für geräuschloses Aktivieren der Aufnahme beim Einschlafen.
- **🤖 KI-Geräuscherkennung & Dynamische Emojis:** Multimodale Audio-Analyse mit Google Gemini:
  - Differenziert **Schlafreden (🗣️)**, **Schnarchen (😴)**, **Bettbewegungen (🛏️)**, **Verkehr/Autos (🚗)**, **Haushaltsgeräusche (🚪)**, **Husten/Niesen (🤧)** und **Haustiere (🐾)**.
  - Deutsche Transkription von gesprochenen Wörtern („...“) und Kontext-Erklärung („✨ Deutliches Flüstern beim Aufwachen“).
- **⚡ Highlights Auto-Skip Player:** Spielt alle erkannten Geräusche nahtlos nacheinander ab – ohne stundenlange Stille – wahlweise mit 1.0x, 1.25x, 1.5x oder 2.0x Geschwindigkeit.
- **🏷️ Clip-Tagging & 🛡️ 7-Tage-Löschschutz:**
  - Markiere Clips mit Sternchen oder Tags (`⭐ Favorit`, `🤣 Lustig`, `🔒 Behalten`, `👻 Gruselig`, `💬 Schlafreden`).
  - Getaggte und favorisierte Clips werden dauerhaft vor der automatischen 7-Tage-Bereinigung geschützt.
- **🎛️ Smarte Grundrauschen-Kalibrierung:**
  - 1-Click **„🪄 Auto-Filter (+1 dB)“** oder **„🎯 Hier messen (+1 dB)“** für stumme Nächte ohne Hintergrundrauschen.
  - Empfindlichkeitsregler erweitert bis **-75 dB**.
- **📤 1-Click WhatsApp-Export:** Schneidet und exportiert einzelne erkannte Audio-Clips direkt an Freunde oder Gruppen.
- **📊 Interaktive Wellenform & Timeline:** Flüssiges Audio-Scrubbing mit direkten Sprungmarken für jedes Geräusch.
- **🛡️ 100% Offline & Local-First:** Alle Audioaufnahmen und Metadaten bleiben standardmäßig vollständig auf dem Gerät.
- **⚡ Android Doze-Mode & Crash-Schutz:**
  - Periodisches Auto-Flushing auf die Festplatte alle 30 Sekunden.
  - Notfall-Autosave bei kritischem Akkustand unter 5%.

---

## 📱 Tech Stack & Packages

- **Framework:** Flutter (Dart 3+)
- **Audio Recording:** `record`
- **Audio Playback:** `just_audio`
- **AI Classification:** Google Gemini Multimodal Audio API (`gemini-3-flash-preview` / `gemini-3.5-flash-lite`)
- **Background Execution:** `wakelock_plus`, `flutter_local_notifications`
- **System Monitoring:** `battery_plus`, `permission_handler`
- **Storage & Sharing:** `path_provider`, `shared_preferences`, `share_plus`, `intl`

---

## 🚀 Getting Started

### Installation & Run

1. **Clone the repository:**
   ```bash
   git clone https://github.com/zaryar/SleepSpeak.git
   cd SleepSpeak
   ```

2. **Install dependencies:**
   ```bash
   flutter pub get
   ```

3. **Run tests:**
   ```bash
   flutter test
   ```

4. **Build Release APK:**
   ```bash
   flutter build apk --release
   ```

---

## 🔒 Permissions & Privacy

This application requires the following device permissions:

| Permission | Purpose |
| :--- | :--- |
| `RECORD_AUDIO` | Required to record sleep sounds during the night. |
| `FOREGROUND_SERVICE_MICROPHONE` | Required on Android 14+ to keep recording active when the screen turns off. |
| `WAKE_LOCK` | Prevents CPU sleep from interrupting active recordings. |
| `POST_NOTIFICATIONS` | Displays a persistent notification while recording is running. |

**Privacy Guarantee:** No audio data, timestamps, or usage logs are ever transmitted over the network. Everything is processed and stored locally in the application's sandboxed document directory.

---

## 📄 License

This project is open source and available under the [MIT License](LICENSE).
