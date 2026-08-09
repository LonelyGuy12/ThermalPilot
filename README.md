# ThermalPilot

> **A thermal-and-battery-aware on-device LLM inference scheduler for Android.**  
> Keeps tokens/sec stable under SoC thermal throttling by dynamically adjusting thread count, quantization tier, and context length — all while running a real-time live dashboard.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Flutter UI (Dart)                                          │
│  ┌──────────────┐  ┌───────────────────┐  ┌─────────────┐  │
│  │  HomeScreen  │  │  DashboardScreen  │  │SummaryScreen│  │
│  └──────────────┘  └───────────────────┘  └─────────────┘  │
│           fl_chart time-series (TPS / Temp / Policy)        │
│                                                             │
│  ┌─────────────────────────┐   ┌──────────────────────┐     │
│  │  ThermalScheduler (FSM) │   │  LlamaEngine         │     │
│  │  2-second Timer loop    │──▶│  llama_cpp_dart       │     │
│  │  COOL/WARM/HOT/CRITICAL │   │  INT4 ↔ INT8 hot-swap│     │
│  └────────────┬────────────┘   └──────────────────────┘     │
│               │ MethodChannel                               │
│  ─────────────┼────────────────────────────── NATIVE ─────  │
│               ▼                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  MainActivity.kt  (Kotlin)                           │   │
│  │  • PowerManager.addThermalStatusListener (API 29+)   │   │
│  │  • /sys/class/thermal/thermal_zone*/temp (fallback)  │   │
│  │  • BatteryManager ACTION_BATTERY_CHANGED             │   │
│  │  • /sys/devices/system/cpu/*/cpufreq/scaling_max_freq│   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Scheduler State Machine

```
            ┌──── 2 consecutive hotter readings ────►
  COOL ──────┤                                        WARM
            └──── 3 consecutive cooler readings ─────
  
            ┌──── 2 consecutive hotter readings ────►
  WARM ──────┤                                        HOT
            └──── 3 consecutive cooler readings ─────
  
            ┌──── 2 consecutive hotter readings ────►
  HOT  ──────┤                                        CRITICAL
            └──── 3 consecutive cooler readings ─────
```

| State    | Threads      | Quant | Context | Notes                          |
|----------|-------------|-------|---------|--------------------------------|
| COOL     | All big cores| INT8  | 4096    | Full performance               |
| WARM     | Big-1        | INT8  | 2048    | Slightly reduced               |
| HOT      | Little cores | INT4  | 1024    | Aggressive reduction           |
| CRITICAL | 1            | INT4  | 512     | UI warning shown               |

---

## Project Structure

```
lib/
├── main.dart                        # App entry, theme, routes
├── native/
│   └── thermal_channel.dart         # MethodChannel Dart wrapper
├── scheduler/
│   ├── thermal_scheduler.dart       # FSM + policy (all constants here)
│   └── session_logger.dart          # CSV logging + stats
├── inference/
│   └── llama_engine.dart            # llama_cpp_dart wrapper, hot-swap
└── ui/
    ├── home_screen.dart             # Mode select, model paths, start
    ├── dashboard_screen.dart        # Live fl_chart dashboard
    └── summary_screen.dart          # Stats, CSV export

android/app/src/main/kotlin/com/thermalpilot/thermal_pilot/
└── MainActivity.kt                  # Kotlin native: thermal/battery/CPU
```

---

## Setup & Build

### Prerequisites

| Tool | Version |
|------|---------|
| Flutter SDK | ≥ 3.19 |
| Dart SDK | ≥ 3.3 |
| Android NDK | ≥ r25 (via Android Studio) |
| Target device | ARM64 Android, API 29+ (Android 10+) |

### 1. Clone & install dependencies

```bash
git clone <your-repo-url> ThermalPilot
cd ThermalPilot
flutter pub get
```

### 2. Download GGUF model files

ThermalPilot requires **two** quantizations of a small model. We recommend Qwen2.5-0.5B-Instruct:

**INT4 model (Q4_K_M, ~397 MB):**
```
https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
```

**INT8 model (Q8_0, ~531 MB):**
```
https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q8_0.gguf
```

Download them to your Android device:

```bash
# On your device or via adb:
adb shell mkdir -p /sdcard/Download
adb push qwen2.5-0.5b-instruct-q4_k_m.gguf /sdcard/Download/
adb push qwen2.5-0.5b-instruct-q8_0.gguf /sdcard/Download/
```

### 3. Build and install the APK

```bash
flutter build apk --release --target-platform android-arm64
adb install build/app/outputs/flutter-apk/app-release.apk
```

Or for a debug build during development:
```bash
flutter run --device-id <your-device-id>
```

### 4. In-app setup

1. Open **ThermalPilot**
2. Tap **INT4 Model** → enter path: `/sdcard/Download/qwen2.5-0.5b-instruct-q4_k_m.gguf`
3. Tap **INT8 Model** → enter path: `/sdcard/Download/qwen2.5-0.5b-instruct-q8_0.gguf`
4. Select **ThermalPilot** or **Baseline** mode
5. Tap **Start 20-min Session**

### 5. Exporting results

After each session, the Summary screen shows per-session stats. Tap **Export CSV** to save and share a full time-series log including timestamps, TPS, temps, policy state, thread count, quant tier, and context length.

---

## Tuning Policy Thresholds

All thresholds are named constants at the top of [`lib/scheduler/thermal_scheduler.dart`](lib/scheduler/thermal_scheduler.dart):

```dart
const int kWarmStatusThreshold  = 2;  // PowerManager THERMAL_STATUS_MODERATE
const int kHotStatusThreshold   = 3;  // PowerManager THERMAL_STATUS_SEVERE
const int kCritStatusThreshold  = 4;  // PowerManager THERMAL_STATUS_CRITICAL
const int kDowngradeConsecutive = 2;  // readings before hotter transition
const int kUpgradeConsecutive   = 3;  // readings before cooler transition
const int kCoolCtxLen  = 4096;
const int kWarmCtxLen  = 2048;
const int kHotCtxLen   = 1024;
const int kCritCtxLen  = 512;
```

Increase `kDowngradeConsecutive` to make the scheduler less reactive; decrease it to respond faster to heating.

---

## Benchmark Methodology

1. **Baseline run**: Start a 20-min session in **Baseline** mode. Fixed max threads, INT8 model, no scheduler. Record CSV.
2. **ThermalPilot run**: Start a 20-min session in **ThermalPilot** mode. Adaptive. Record CSV.
3. Compare the two CSVs (or summary screen stats) for:
   - Avg TPS — ThermalPilot should be within ±10% of baseline in the first half, then significantly higher in the second half as baseline throttles
   - P10 TPS (worst-case floor) — ThermalPilot should show a higher floor
   - Max temperature — ThermalPilot should stay lower
   - Throttle events — ThermalPilot transitions are *managed* (not crashes)

---

## Benchmark Results

> **[PLACEHOLDER — fill in after real device testing]**

### Device: _(e.g. Pixel 8 / Snapdragon 8 Gen 3)_

| Metric | Baseline | ThermalPilot | Δ |
|--------|---------|--------------|---|
| Avg tokens/sec | ___ | ___ | ___ |
| P10 tokens/sec | ___ | ___ | ___ |
| Max SoC temp (°C) | ___ | ___ | ___ |
| Max batt temp (°C) | ___ | ___ | ___ |
| Throttle events | ___ | ___ | ___ |

### Charts

> _(Insert screenshot of fl_chart dashboard comparison here)_

### Observations

> _(Notes on thermal behavior, which SoC features triggered PowerManager status changes, etc.)_

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| "Failed to load model" | Check model path; ensure `/sdcard/Download/*.gguf` exists |
| Thermal status always 0 | Normal on some emulators; sysfs fallback activates automatically |
| Build fails with NDK error | Run `flutter doctor`, ensure NDK r25+ installed via Android Studio SDK Manager |
| Very low TPS on first run | GGUF models cold-load into RAM; subsequent prompts are faster |
| `MANAGE_EXTERNAL_STORAGE` dialog | Accept the permission to allow reading GGUF files from Downloads |

---

## License

MIT License. llama.cpp is MIT. Qwen2.5 model weights are under [Qwen License](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/blob/main/LICENSE).
