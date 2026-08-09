/// ThermalPilot state-machine scheduler.
///
/// Runs a periodic Timer every [kSchedulerIntervalMs] ms that:
///   1. Reads PowerManager thermal status and battery from the native channel.
///   2. Applies hysteresis before transitioning states.
///   3. Fires [onPolicyChanged] when a transition occurs.
///   4. Logs every reading to [SessionLogger].
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import '../native/thermal_channel.dart';
import 'session_logger.dart';
import 'thermal_models.dart';

export 'thermal_models.dart';

// ── Named constants — tune these per device ────────────────────────────────────

/// Scheduler tick interval in milliseconds.
const int kSchedulerIntervalMs = 2000;

/// PowerManager THERMAL_STATUS_* threshold for WARM state.
/// 2 = THERMAL_STATUS_MODERATE
const int kWarmStatusThreshold = 2;

/// PowerManager THERMAL_STATUS_* threshold for HOT state.
/// 3 = THERMAL_STATUS_SEVERE
const int kHotStatusThreshold = 3;

/// PowerManager THERMAL_STATUS_* threshold for CRITICAL state.
/// 4 = THERMAL_STATUS_CRITICAL
const int kCritStatusThreshold = 4;

/// Consecutive readings required before downgrading (hotter direction).
const int kDowngradeConsecutive = 2;

/// Consecutive readings required before upgrading (cooler direction).
const int kUpgradeConsecutive = 3;

/// Context length ceilings per state.
const int kCoolCtxLen = 4096;
const int kWarmCtxLen = 2048;
const int kHotCtxLen = 1024;
const int kCritCtxLen = 512;

/// Thread-count offsets relative to CPU topology.
const int kCritThreadsAbsolute = 1;

// ── Scheduler ─────────────────────────────────────────────────────────────────

class ThermalScheduler extends ChangeNotifier {
  ThermalScheduler({
    required ThermalChannel channel,
    required SessionLogger logger,
  })  : // ignore: prefer_initializing_formals
        _channel = channel,
        // ignore: prefer_initializing_formals
        _logger = logger;

  final ThermalChannel _channel;
  final SessionLogger _logger;

  // Current published policy
  ThermalPolicy _policy = const ThermalPolicy(
    state: ThermalState.cool,
    threads: 4,
    quant: QuantTier.int8,
    ctxLen: kCoolCtxLen,
  );

  ThermalPolicy get policy => _policy;
  ThermalState get state => _policy.state;

  // CPU topology (set once at session start)
  List<int> _bigCores = [];
  List<int> _littleCores = [];

  // Hysteresis counters
  int _consecutiveWarmer = 0;
  int _consecutiveCooler = 0;

  // Sensor readings (exposed for UI)
  double _socTempC = 0.0;
  double _battTempC = 0.0;
  int _battLevel = -1;
  int _rawThermalStatus = 0;

  double get socTempC => _socTempC;
  double get battTempC => _battTempC;
  int get battLevel => _battLevel;
  int get rawThermalStatus => _rawThermalStatus;

  // Session control
  Timer? _timer;
  bool _isRunning = false;
  bool _isBaseline = false;

  bool get isRunning => _isRunning;

  /// Callback fired whenever the policy changes (for LlamaEngine to react).
  void Function(ThermalPolicy)? onPolicyChanged;

  // ── Public API ───────────────────────────────────────────────────────────────

  Future<void> start({required bool baseline}) async {
    if (_isRunning) return;
    _isBaseline = baseline;
    _consecutiveWarmer = 0;
    _consecutiveCooler = 0;

    // Seed CPU topology once
    final topology = await _channel.getCpuTopology();
    _splitTopology(topology);

    _isRunning = true;
    _timer = Timer.periodic(
      const Duration(milliseconds: kSchedulerIntervalMs),
      (_) => _tick(),
    );
    // Run first tick immediately
    await _tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _isRunning = false;
  }

  // ── Private tick ─────────────────────────────────────────────────────────────

  Future<void> _tick() async {
    // 1. Read sensors in parallel
    final results = await Future.wait<dynamic>([
      _channel.getThermalStatus(),
      _channel.getBatteryInfo(),
    ]);

    final int rawStatus = results[0] as int;
    final BatteryInfo batt = results[1] as BatteryInfo;

    _rawThermalStatus = rawStatus;
    _battTempC = batt.tempC;
    _battLevel = batt.level;
    _socTempC = _estimateSocTemp(rawStatus);

    // 2. Target state from raw status
    final ThermalState targetState = _statusToState(rawStatus);

    // 3. Apply hysteresis
    final ThermalState newState = _applyHysteresis(targetState);

    // 4. Compute policy
    final ThermalPolicy newPolicy = _buildPolicy(newState);

    // 5. Fire callback if changed
    final bool policyChanged = newPolicy.state != _policy.state ||
        newPolicy.threads != _policy.threads ||
        newPolicy.quant != _policy.quant ||
        newPolicy.ctxLen != _policy.ctxLen;

    if (policyChanged) {
      _policy = newPolicy;
      onPolicyChanged?.call(newPolicy);
    }

    // 6. Log sensor snapshot
    _logger.log(SessionEntry(
      ts: DateTime.now(),
      state: newPolicy.state,
      tokensPerSec: 0.0, // patched in by updateLastTps()
      socTempC: _socTempC,
      battTempC: _battTempC,
      battLevel: _battLevel,
      threads: newPolicy.threads,
      quant: newPolicy.quant,
      ctxLen: newPolicy.ctxLen,
      isBaseline: _isBaseline,
      event: policyChanged ? 'STATE_CHANGE' : null,
    ));

    notifyListeners();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  ThermalState _statusToState(int status) {
    if (status >= kCritStatusThreshold) return ThermalState.critical;
    if (status >= kHotStatusThreshold) return ThermalState.hot;
    if (status >= kWarmStatusThreshold) return ThermalState.warm;
    return ThermalState.cool;
  }

  ThermalState _applyHysteresis(ThermalState targetState) {
    final int currentIdx = _policy.state.index;
    final int targetIdx = targetState.index;

    if (targetIdx > currentIdx) {
      _consecutiveCooler = 0;
      _consecutiveWarmer++;
      if (_consecutiveWarmer >= kDowngradeConsecutive) {
        _consecutiveWarmer = 0;
        return targetState;
      }
      return _policy.state;
    } else if (targetIdx < currentIdx) {
      _consecutiveWarmer = 0;
      _consecutiveCooler++;
      if (_consecutiveCooler >= kUpgradeConsecutive) {
        _consecutiveCooler = 0;
        return targetState;
      }
      return _policy.state;
    } else {
      _consecutiveWarmer = 0;
      _consecutiveCooler = 0;
      return targetState;
    }
  }

  ThermalPolicy _buildPolicy(ThermalState state) {
    if (_isBaseline) {
      return ThermalPolicy(
        state: ThermalState.cool,
        threads: _allBigCores(),
        quant: QuantTier.int8,
        ctxLen: kCoolCtxLen,
      );
    }

    return switch (state) {
      ThermalState.cool => ThermalPolicy(
          state: state,
          threads: _allBigCores(),
          quant: QuantTier.int8,
          ctxLen: kCoolCtxLen,
        ),
      ThermalState.warm => ThermalPolicy(
          state: state,
          threads: (_allBigCores() - 1).clamp(1, 16),
          quant: QuantTier.int8,
          ctxLen: kWarmCtxLen,
        ),
      ThermalState.hot => ThermalPolicy(
          state: state,
          threads: _littleCoreCount().clamp(1, 8),
          quant: QuantTier.int4,
          ctxLen: kHotCtxLen,
        ),
      ThermalState.critical => ThermalPolicy(
          state: state,
          threads: kCritThreadsAbsolute,
          quant: QuantTier.int4,
          ctxLen: kCritCtxLen,
        ),
    };
  }

  void _splitTopology(List<int> sortedCores) {
    if (sortedCores.isEmpty) {
      _bigCores = [0, 1, 2, 3];
      _littleCores = [];
      return;
    }
    final bigCount = (sortedCores.length / 2).ceil();
    _bigCores = sortedCores.take(bigCount).toList();
    _littleCores = sortedCores.skip(bigCount).toList();
    debugPrint(
        'ThermalPilot topology — big: $_bigCores  little: $_littleCores');
  }

  int _allBigCores() => _bigCores.isEmpty ? 4 : _bigCores.length;
  int _littleCoreCount() => _littleCores.isEmpty ? 2 : _littleCores.length;

  double _estimateSocTemp(int status) => switch (status) {
        0 => 38.0,
        1 => 45.0,
        2 => 55.0,
        3 => 65.0,
        4 => 75.0,
        5 => 85.0,
        6 => 95.0,
        _ => 40.0,
      };

  /// Called by LlamaEngine (via the dashboard) to patch the latest TPS
  /// into the most recently logged scheduler entry.
  void updateLastTps(double tps) {
    if (_logger.entries.isEmpty) return;
    final last = _logger.entries.last;
    _logger.log(SessionEntry(
      ts: last.ts,
      state: last.state,
      tokensPerSec: tps,
      socTempC: last.socTempC,
      battTempC: last.battTempC,
      battLevel: last.battLevel,
      threads: last.threads,
      quant: last.quant,
      ctxLen: last.ctxLen,
      isBaseline: last.isBaseline,
      event: last.event,
    ));
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
