/// Shared enums and data types used by both the scheduler and session logger.
/// Kept in a separate file to avoid circular imports.
library;

// ── Enums ──────────────────────────────────────────────────────────────────────

enum ThermalState {
  cool,
  warm,
  hot,
  critical;

  String get displayName => switch (this) {
        ThermalState.cool => 'COOL',
        ThermalState.warm => 'WARM',
        ThermalState.hot => 'HOT',
        ThermalState.critical => 'CRITICAL',
      };

  /// true when device is in the most dangerous thermal state.
  bool get isCritical => this == ThermalState.critical;
}

enum QuantTier {
  int8,
  int4;

  String get displayName => switch (this) {
        QuantTier.int8 => 'INT8 (Q8_0)',
        QuantTier.int4 => 'INT4 (Q4_K_M)',
      };
}

// ── Policy output ──────────────────────────────────────────────────────────────

class ThermalPolicy {
  final ThermalState state;
  final int threads; // resolved absolute thread count
  final QuantTier quant;
  final int ctxLen;

  const ThermalPolicy({
    required this.state,
    required this.threads,
    required this.quant,
    required this.ctxLen,
  });

  @override
  String toString() =>
      'ThermalPolicy(state=$state, threads=$threads, quant=$quant, ctx=$ctxLen)';
}
