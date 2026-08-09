/// Session logger: accumulates time-series entries in memory and
/// exports them as CSV to the app documents directory.
library;

import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'thermal_models.dart';

// ── Data model ─────────────────────────────────────────────────────────────────

class SessionEntry {
  final DateTime ts;
  final ThermalState state;
  final double tokensPerSec;
  final double socTempC; // SoC temperature in °C (from PowerManager status or sysfs)
  final double battTempC; // Battery temperature in °C
  final int battLevel; // 0–100 %
  final int threads; // Active thread count
  final QuantTier quant; // Active quantization tier
  final int ctxLen; // Context length ceiling
  final bool isBaseline; // true = baseline run, false = ThermalPilot run
  final String? event; // Optional free-text event label (e.g. "STATE_CHANGE")

  const SessionEntry({
    required this.ts,
    required this.state,
    required this.tokensPerSec,
    required this.socTempC,
    required this.battTempC,
    required this.battLevel,
    required this.threads,
    required this.quant,
    required this.ctxLen,
    required this.isBaseline,
    this.event,
  });

  String toCsvRow() {
    return [
      ts.toIso8601String(),
      state.name,
      tokensPerSec.toStringAsFixed(2),
      socTempC.toStringAsFixed(1),
      battTempC.toStringAsFixed(1),
      battLevel,
      threads,
      quant.name,
      ctxLen,
      isBaseline ? 'baseline' : 'thermalpilot',
      event ?? '',
    ].join(',');
  }
}

// ── Session stats summary ──────────────────────────────────────────────────────

class SessionStats {
  final double avgTps;
  final double p10Tps;
  final double maxSocTemp;
  final double maxBattTemp;
  final int throttleEvents; // count of downgrade transitions
  final bool isBaseline;
  final Duration duration;

  const SessionStats({
    required this.avgTps,
    required this.p10Tps,
    required this.maxSocTemp,
    required this.maxBattTemp,
    required this.throttleEvents,
    required this.isBaseline,
    required this.duration,
  });
}

// ── Logger ─────────────────────────────────────────────────────────────────────

class SessionLogger {
  final List<SessionEntry> _entries = [];
  DateTime? _sessionStart;
  bool _isBaseline = false;

  void startSession({required bool baseline}) {
    _entries.clear();
    _sessionStart = DateTime.now();
    _isBaseline = baseline;
  }

  void log(SessionEntry entry) {
    _entries.add(entry);
  }

  List<SessionEntry> get entries => List.unmodifiable(_entries);

  /// Computes summary statistics from all logged entries.
  SessionStats computeStats() {
    if (_entries.isEmpty) {
      return SessionStats(
        avgTps: 0,
        p10Tps: 0,
        maxSocTemp: 0,
        maxBattTemp: 0,
        throttleEvents: 0,
        isBaseline: _isBaseline,
        duration: Duration.zero,
      );
    }

    final tpsList = _entries.map((e) => e.tokensPerSec).toList()..sort();
    final avgTps = tpsList.fold(0.0, (a, b) => a + b) / tpsList.length;
    final p10Index = (tpsList.length * 0.1).floor().clamp(0, tpsList.length - 1);
    final p10Tps = tpsList[p10Index];
    final maxSocTemp = _entries.map((e) => e.socTempC).reduce((a, b) => a > b ? a : b);
    final maxBattTemp = _entries.map((e) => e.battTempC).reduce((a, b) => a > b ? a : b);

    // Count state downgrades (COOL→WARM, WARM→HOT, HOT→CRITICAL)
    int throttleEvents = 0;
    for (int i = 1; i < _entries.length; i++) {
      if (_entries[i].state.index > _entries[i - 1].state.index) {
        throttleEvents++;
      }
    }

    final duration = _sessionStart != null
        ? _entries.last.ts.difference(_sessionStart!)
        : Duration.zero;

    return SessionStats(
      avgTps: avgTps,
      p10Tps: p10Tps,
      maxSocTemp: maxSocTemp,
      maxBattTemp: maxBattTemp,
      throttleEvents: throttleEvents,
      isBaseline: _isBaseline,
      duration: duration,
    );
  }

  static const String _csvHeader =
      'timestamp,state,tokens_per_sec,soc_temp_c,batt_temp_c,batt_level,'
      'threads,quant,ctx_len,mode,event';

  /// Exports all entries to a CSV file in app documents directory.
  /// Returns the file path.
  Future<String> exportCsv({String? filenameOverride}) async {
    final dir = await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final filename = filenameOverride ??
        'thermalpilot_${_isBaseline ? "baseline" : "pilot"}'
        '_${now.year}${now.month.toString().padLeft(2, "0")}${now.day.toString().padLeft(2, "0")}'
        '_${now.hour.toString().padLeft(2, "0")}${now.minute.toString().padLeft(2, "0")}.csv';

    final file = File('${dir.path}/$filename');
    final buffer = StringBuffer();
    buffer.writeln(_csvHeader);
    for (final entry in _entries) {
      buffer.writeln(entry.toCsvRow());
    }
    await file.writeAsString(buffer.toString());
    return file.path;
  }
}
