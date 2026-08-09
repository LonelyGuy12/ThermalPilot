import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../native/thermal_channel.dart';
import '../scheduler/thermal_scheduler.dart';
import '../scheduler/session_logger.dart';
import '../inference/llama_engine.dart';
import 'summary_screen.dart';

// ── Chart colors ─────────────────────────────────────────────────────────────

const Color _kTpsColor = Color(0xFF00E5A0);
const Color _kSocTempColor = Color(0xFFFF6B35);
const Color _kBattTempColor = Color(0xFFFFCC02);
const Color _kStateColor = Color(0xFF7C4DFF);
const Color _kThreadColor = Color(0xFF40C4FF);

class DashboardScreen extends StatefulWidget {
  final bool isBaseline;
  final String int4ModelPath;
  final String int8ModelPath;

  const DashboardScreen({
    super.key,
    required this.isBaseline,
    required this.int4ModelPath,
    required this.int8ModelPath,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {
  // Core objects
  late ThermalChannel _thermalChannel;
  late SessionLogger _logger;
  late ThermalScheduler _scheduler;
  late LlamaEngine _engine;

  // Session control
  StreamSubscription<InferenceResult>? _inferenceSubscription;
  bool _sessionStarted = false;
  bool _sessionEnded = false;
  DateTime? _sessionStart;
  Duration _elapsed = Duration.zero;
  Timer? _clockTimer;

  // Chart data (max 600 points = 20 min at 2 s intervals)
  static const int _maxPoints = 600;
  final List<FlSpot> _tpsSpots = [];
  final List<FlSpot> _socTempSpots = [];
  final List<FlSpot> _battTempSpots = [];
  final List<FlSpot> _stateSpots = [];
  final List<FlSpot> _threadSpots = [];

  // Latest values for stats strip
  double _currentTps = 0;
  double _peakTps = 0;
  int _promptCount = 0;

  // Animation for entry
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  static const Duration _sessionDuration = Duration(minutes: 20);

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(
        parent: _fadeController, curve: Curves.easeOut);
    _fadeController.forward();

    _thermalChannel = ThermalChannel();
    _logger = SessionLogger();
    _scheduler = ThermalScheduler(channel: _thermalChannel, logger: _logger);
    _engine = LlamaEngine(
      int4ModelPath: widget.int4ModelPath,
      int8ModelPath: widget.int8ModelPath,
    );

    _startSession();
  }

  Future<void> _startSession() async {
    _logger.startSession(baseline: widget.isBaseline);

    // Wire scheduler → engine
    _scheduler.onPolicyChanged = (policy) {
      _engine.onPolicyChanged(policy);
    };

    // Wire engine result callback → chart updates
    _engine.onResult = _onInferenceResult;
    _engine.onError = (e) {
      if (mounted) _showError(e);
    };

    try {
      await _engine.initialize();
    } catch (e) {
      if (mounted) {
        _showError('Failed to load model: $e');
      }
      return;
    }

    // Start scheduler
    await _scheduler.start(baseline: widget.isBaseline);

    setState(() {
      _sessionStarted = true;
      _sessionStart = DateTime.now();
    });

    // Clock timer
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _elapsed = DateTime.now().difference(_sessionStart!);
        });
        if (_elapsed >= _sessionDuration) {
          _endSession();
        }
      }
    });

    // Listen for scheduler sensor updates to update charts
    _scheduler.addListener(_onSchedulerUpdate);

    // Start inference loop (runs until stop() is called)
    _engine.startBenchmarkLoop();
  }

  void _onSchedulerUpdate() {
    if (!mounted) return;
    final now = _elapsedSeconds();
    setState(() {
      _addSpot(_socTempSpots, now, _scheduler.socTempC);
      _addSpot(_battTempSpots, now, _scheduler.battTempC);
      _addSpot(_stateSpots, now, _scheduler.state.index.toDouble());
      _addSpot(_threadSpots, now, _scheduler.policy.threads.toDouble());
    });
  }

  void _onInferenceResult(InferenceResult result) {
    if (!mounted) return;
    final now = _elapsedSeconds();
    setState(() {
      _currentTps = result.tokensPerSec;
      if (_currentTps > _peakTps) _peakTps = _currentTps;
      _promptCount++;
      _addSpot(_tpsSpots, now, _currentTps);

      // Patch TPS into latest logger entry
      _scheduler.updateLastTps(_currentTps);
    });
  }

  void _addSpot(List<FlSpot> spots, double x, double y) {
    spots.add(FlSpot(x, y));
    if (spots.length > _maxPoints) spots.removeAt(0);
  }

  double _elapsedSeconds() =>
      _sessionStart != null
          ? DateTime.now().difference(_sessionStart!).inMilliseconds / 1000.0
          : 0.0;

  void _endSession() {
    _inferenceSubscription?.cancel();
    _scheduler.stop();
    _clockTimer?.cancel();
    _engine.stop();

    if (!_sessionEnded && mounted) {
      setState(() => _sessionEnded = true);
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SummaryScreen(
              stats: _logger.computeStats(),
              logger: _logger,
            ),
          ));
        }
      });
    }
  }

  void _showError(String msg) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F2E),
        title: const Text('Error', style: TextStyle(color: Colors.redAccent)),
        content: Text(msg, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('Back', style: TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _inferenceSubscription?.cancel();
    _clockTimer?.cancel();
    _scheduler.removeListener(_onSchedulerUpdate);
    _scheduler.dispose();
    _engine.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1117),
        foregroundColor: Colors.white,
        title: Row(
          children: [
            const Icon(Icons.bar_chart_rounded, color: Colors.deepPurpleAccent, size: 20),
            const SizedBox(width: 8),
            const Text('Live Dashboard',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const Spacer(),
            _ModeChip(isBaseline: widget.isBaseline),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _sessionEnded ? null : _endSession,
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('Stop'),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
          ),
        ],
      ),
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: Column(
          children: [
            // Stats strip
            _buildStatsStrip(),

            // CRITICAL warning banner
            if (_scheduler.state.isCritical && _sessionStarted)
              _buildCriticalBanner(),

            // Charts
            Expanded(
              child: !_sessionStarted
                  ? _buildLoadingState()
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _buildChartCard(
                            title: 'Tokens / Second',
                            icon: Icons.speed,
                            color: _kTpsColor,
                            child: _buildTpsChart(),
                          ),
                          const SizedBox(height: 16),
                          _buildChartCard(
                            title: 'Temperature (°C)',
                            icon: Icons.device_thermostat,
                            color: _kSocTempColor,
                            child: _buildTempChart(),
                          ),
                          const SizedBox(height: 16),
                          _buildChartCard(
                            title: 'Policy State & Threads',
                            icon: Icons.settings_suggest,
                            color: _kStateColor,
                            child: _buildPolicyChart(),
                          ),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsStrip() {
    final elapsed = _elapsed;
    final remaining = _sessionDuration - elapsed;
    final remainingClamped =
        remaining.isNegative ? Duration.zero : remaining;

    return Container(
      color: const Color(0xFF0D1117),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          _StatCell(
            label: 'TPS',
            value: _currentTps.toStringAsFixed(1),
            color: _kTpsColor,
            icon: Icons.bolt,
          ),
          _StatCell(
            label: 'Peak TPS',
            value: _peakTps.toStringAsFixed(1),
            color: Colors.white,
            icon: Icons.trending_up,
          ),
          _StatCell(
            label: 'Prompts',
            value: '$_promptCount',
            color: Colors.white60,
            icon: Icons.chat_bubble_outline,
          ),
          _StatCell(
            label: 'State',
            value: _scheduler.state.displayName,
            color: _stateColor(_scheduler.state),
            icon: Icons.thermostat,
          ),
          _StatCell(
            label: 'Remain',
            value: _formatDuration(remainingClamped),
            color: Colors.white60,
            icon: Icons.timer_outlined,
          ),
        ],
      ),
    );
  }

  Widget _buildCriticalBanner() {
    return Container(
      width: double.infinity,
      color: Colors.red.shade900.withValues(alpha: 0.85),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: const [
          Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '⚠️  CRITICAL thermal state — reduced to INT4, minimum threads, ctx=512',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.deepPurpleAccent),
          SizedBox(height: 20),
          Text('Loading model…',
              style: TextStyle(color: Colors.white54, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _buildChartCard({
    required String title,
    required IconData icon,
    required Color color,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161B27),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                Icon(icon, color: color, size: 16),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(height: 160, child: child),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ── TPS Chart ─────────────────────────────────────────────────────────────────

  Widget _buildTpsChart() {
    final spots = _tpsSpots.isEmpty
        ? [const FlSpot(0, 0)]
        : _tpsSpots;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: LineChart(
        LineChartData(
          gridData: _defaultGrid(),
          titlesData: _defaultTitles('t/s'),
          borderData: FlBorderData(show: false),
          clipData: const FlClipData.all(),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.3,
              color: _kTpsColor,
              barWidth: 2.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  colors: [
                    _kTpsColor.withValues(alpha: 0.25),
                    _kTpsColor.withValues(alpha: 0.0),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ],
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => spots
                  .map((s) => LineTooltipItem(
                        '${s.y.toStringAsFixed(1)} t/s',
                        const TextStyle(color: Colors.white, fontSize: 11),
                      ))
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }

  // ── Temp Chart ─────────────────────────────────────────────────────────────────

  Widget _buildTempChart() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: LineChart(
        LineChartData(
          gridData: _defaultGrid(),
          titlesData: _defaultTitles('°C'),
          borderData: FlBorderData(show: false),
          clipData: const FlClipData.all(),
          lineBarsData: [
            LineChartBarData(
              spots: _socTempSpots.isEmpty
                  ? [const FlSpot(0, 40)]
                  : _socTempSpots,
              isCurved: true,
              color: _kSocTempColor,
              barWidth: 2.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  colors: [
                    _kSocTempColor.withValues(alpha: 0.2),
                    _kSocTempColor.withValues(alpha: 0.0),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            LineChartBarData(
              spots: _battTempSpots.isEmpty
                  ? [const FlSpot(0, 35)]
                  : _battTempSpots,
              isCurved: true,
              color: _kBattTempColor,
              barWidth: 2.0,
              dotData: const FlDotData(show: false),
              dashArray: [4, 3],
            ),
          ],
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => [
                LineTooltipItem('SoC: ${spots[0].y.toStringAsFixed(0)}°C',
                    const TextStyle(color: _kSocTempColor, fontSize: 11)),
                if (spots.length > 1)
                  LineTooltipItem('Batt: ${spots[1].y.toStringAsFixed(0)}°C',
                      const TextStyle(color: _kBattTempColor, fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Policy Chart ──────────────────────────────────────────────────────────────

  Widget _buildPolicyChart() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: LineChart(
        LineChartData(
          gridData: _defaultGrid(),
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 120,
                getTitlesWidget: (v, _) => Text(
                  '${(v / 60).toStringAsFixed(0)}m',
                  style: const TextStyle(color: Colors.white30, fontSize: 9),
                ),
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 1,
                getTitlesWidget: (v, _) {
                  const names = ['COOL', 'WARM', 'HOT', 'CRIT'];
                  final idx = v.toInt();
                  if (idx < 0 || idx >= names.length) return const SizedBox();
                  return Text(
                    names[idx],
                    style: TextStyle(
                      color: _stateColorByIndex(idx),
                      fontSize: 8,
                      fontWeight: FontWeight.w600,
                    ),
                  );
                },
                reservedSize: 36,
              ),
            ),
            rightTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 2,
                getTitlesWidget: (v, _) => Text(
                  '${v.toInt()}t',
                  style: const TextStyle(color: _kThreadColor, fontSize: 9),
                ),
                reservedSize: 28,
              ),
            ),
            topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
          ),
          borderData: FlBorderData(show: false),
          clipData: const FlClipData.all(),
          minY: -0.5,
          maxY: 3.5,
          lineBarsData: [
            // State step chart
            LineChartBarData(
              spots: _stateSpots.isEmpty
                  ? [const FlSpot(0, 0)]
                  : _stateSpots,
              isStepLineChart: true,
              color: _kStateColor,
              barWidth: 3,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  colors: [
                    _kStateColor.withValues(alpha: 0.2),
                    _kStateColor.withValues(alpha: 0.0),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Chart helpers ─────────────────────────────────────────────────────────────

  FlGridData _defaultGrid() => FlGridData(
        show: true,
        drawVerticalLine: false,
        horizontalInterval: null,
        getDrawingHorizontalLine: (_) =>
            FlLine(color: Colors.white.withValues(alpha: 0.04), strokeWidth: 1),
      );

  FlTitlesData _defaultTitles(String unit) => FlTitlesData(
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 120,
            getTitlesWidget: (v, _) => Text(
              '${(v / 60).toStringAsFixed(0)}m',
              style: const TextStyle(color: Colors.white30, fontSize: 9),
            ),
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (v, _) => Text(
              v.toStringAsFixed(0),
              style: const TextStyle(color: Colors.white30, fontSize: 9),
            ),
            reservedSize: 28,
          ),
        ),
        rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false)),
        topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false)),
      );

  // ── Utility ──────────────────────────────────────────────────────────────────

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Color _stateColor(ThermalState s) => switch (s) {
        ThermalState.cool => const Color(0xFF00E5A0),
        ThermalState.warm => const Color(0xFFFFCC02),
        ThermalState.hot => const Color(0xFFFF6B35),
        ThermalState.critical => const Color(0xFFFF1744),
      };

  Color _stateColorByIndex(int i) => switch (i) {
        0 => const Color(0xFF00E5A0),
        1 => const Color(0xFFFFCC02),
        2 => const Color(0xFFFF6B35),
        3 => const Color(0xFFFF1744),
        _ => Colors.white,
      };
}

// ── Small reusable widgets ─────────────────────────────────────────────────────

class _ModeChip extends StatelessWidget {
  final bool isBaseline;
  const _ModeChip({required this.isBaseline});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: (isBaseline ? Colors.blueAccent : Colors.deepPurpleAccent)
            .withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isBaseline ? Colors.blueAccent : Colors.deepPurpleAccent,
          width: 1,
        ),
      ),
      child: Text(
        isBaseline ? 'BASELINE' : 'THERMALPILOT',
        style: TextStyle(
          color: isBaseline ? Colors.blueAccent : Colors.deepPurpleAccent,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _StatCell({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: Colors.white30, fontSize: 9),
          ),
        ],
      ),
    );
  }
}
