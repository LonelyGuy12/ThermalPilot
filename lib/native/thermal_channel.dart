/// Dart-side wrapper for the com.thermalpilot/thermal MethodChannel.
/// Calls into the Kotlin native layer for sensor readings.
library;

import 'package:flutter/services.dart';

// ── Data models ────────────────────────────────────────────────────────────────

class BatteryInfo {
  final int level; // 0–100 %
  final double tempC; // °C

  const BatteryInfo({required this.level, required this.tempC});

  factory BatteryInfo.fromMap(Map<dynamic, dynamic> m) => BatteryInfo(
        level: (m['level'] as int?) ?? -1,
        tempC: (m['temperature'] as num?)?.toDouble() ?? 0.0,
      );

  factory BatteryInfo.unknown() => const BatteryInfo(level: -1, tempC: 0.0);
}

// ── Channel wrapper ─────────────────────────────────────────────────────────────

class ThermalChannel {
  static const _channel = MethodChannel('com.thermalpilot/thermal');

  /// PowerManager thermal status integer (API 29+):
  ///   0 = NONE/COOL, 2 = MODERATE/WARM, 3 = SEVERE/HOT, 4 = CRITICAL
  Future<int> getThermalStatus() async {
    try {
      final int status =
          await _channel.invokeMethod<int>('getThermalStatus') ?? 0;
      return status;
    } catch (_) {
      return 0;
    }
  }

  /// Battery level (%) and temperature (°C).
  Future<BatteryInfo> getBatteryInfo() async {
    try {
      final Map<dynamic, dynamic> result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('getBatteryInfo') ??
              {};
      return BatteryInfo.fromMap(result);
    } catch (_) {
      return BatteryInfo.unknown();
    }
  }

  /// CPU core indices sorted by max frequency descending (big cores first).
  Future<List<int>> getCpuTopology() async {
    try {
      final List<dynamic> raw =
          await _channel.invokeMethod<List<dynamic>>('getCpuTopology') ?? [];
      return raw.cast<int>();
    } catch (_) {
      // Fallback: assume 4 big + 4 little on common Arm SoCs
      return [4, 5, 6, 7, 0, 1, 2, 3];
    }
  }

  /// Raw sysfs thermal zone temps in milli-°C.
  /// May return empty map on locked-down devices (Android 10+).
  Future<Map<String, int>> getSysfsTemps() async {
    try {
      final Map<dynamic, dynamic> raw =
          await _channel
              .invokeMethod<Map<dynamic, dynamic>>('getSysfsTemps') ??
              {};
      return raw.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }
}
