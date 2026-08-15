# SleepSpeak 🌙

> **Smart, privacy-first sleep talk & noise recorder for Flutter.**  
> Automatically records overnight sleep audio, analyzes noise spikes (sleep talking, snoring, movement), and lets you quickly scrub through detected audio events without cloud dependencies.

> [!NOTE]
> 🤖 **Vibecoded Project:** Dieses gesamte Projekt wurde mit **Vibecoding** entwickelt und ist meine allererste Erfahrung im Erstellen einer vollständigen App mit AI-gestütztem Vibecoding!

### 🌐 Live Web Demo: [https://zaryar.github.io/SleepSpeak/](https://zaryar.github.io/SleepSpeak/)
Teste die Schlafanalyse, den interaktiven Wellenform-Scrubber und den Schwellenwert-Filter direkt online im Browser!

---

## ✨ Features

- **🎙️ Overnight Sleep Recording:** Efficient 16kHz mono WAV recording designed for all-night battery efficiency.
- **📊 Real-time & Post-hoc Noise Detection:** Identifies noise events based on configurable dB thresholds (e.g. -38 dB) and groups nearby audio spikes.
- **📈 Interactive Waveform & Timeline:** Interactive audio scrubbing with timestamp markers for all detected events.
- **🛡️ 100% Offline & Local-First:** All audio recordings and metadata stay entirely on the device. Zero network requests, zero telemetry, zero cloud storage.
- **⚡ Android Doze-Mode & Crash Resiliency:** 
  - Periodic background flush (every 30s) prevents data loss.
  - Emergency auto-save when battery drops below 5%.
  - Post-recording WAV analyzer reconstructs amplitude histories even if Doze mode paused background sampling.
- **🧹 Automatic Retention Management:** Automatically cleans up unstarred recordings older than 7 days to preserve storage.

---

## 📱 Tech Stack & Packages

- **Framework:** Flutter (Dart 3+)
- **Audio Recording:** `record`
- **Audio Playback:** `just_audio`
- **Background Execution:** `wakelock_plus`, `flutter_local_notifications`
- **System Monitoring:** `battery_plus`, `permission_handler`
- **Storage:** `path_provider`, `shared_preferences`, `intl`

---

## 🚀 Getting Started

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.22+ recommended)
- Android Studio / VS Code with Flutter extension
- Android device or emulator with microphone support

### Installation & Run

1. **Clone the repository:**
   ```bash
   git clone https://github.com/<your-username>/sleep-recorder.git
   cd sleep-recorder
   ```

2. **Install dependencies:**
   ```bash
   flutter pub get
   ```

3. **Run the app:**
   ```bash
   flutter run
   ```

4. **Run tests:**
   ```bash
   flutter test
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
