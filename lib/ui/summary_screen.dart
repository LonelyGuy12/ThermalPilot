import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../scheduler/session_logger.dart';

class SummaryScreen extends StatefulWidget {
  final SessionStats stats;
  final SessionLogger logger;

  const SummaryScreen({
    super.key,
    required this.stats,
    required this.logger,
  });

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _exporting = false;
  String? _exportPath;
  String? _exportError;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _exportCsv() async {
    setState(() {
      _exporting = true;
      _exportError = null;
    });
    try {
      final path = await widget.logger.exportCsv();
      setState(() {
        _exportPath = path;
        _exporting = false;
      });
      // Offer to share the file
      await Share.shareXFiles(
        [XFile(path)],
        subject: 'ThermalPilot Session Log',
        text: 'ThermalPilot benchmark session CSV export',
      );
    } catch (e) {
      setState(() {
        _exporting = false;
        _exportError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = widget.stats;
    final mode = stats.isBaseline ? 'Baseline' : 'ThermalPilot';
    final modeColor =
        stats.isBaseline ? Colors.blueAccent : Colors.deepPurpleAccent;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1117),
        foregroundColor: Colors.white,
        title: const Text('Session Summary',
            style: TextStyle(fontWeight: FontWeight.w700)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              Navigator.of(context).popUntil((r) => r.isFirst),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, child) => Opacity(
            opacity: _controller.value,
            child: Transform.translate(
              offset: Offset(0, 30 * (1 - _controller.value)),
              child: child,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Mode header
              _buildModeHeader(mode, modeColor, stats),
              const SizedBox(height: 24),

              // Main stats grid
              _buildSectionLabel('Performance'),
              const SizedBox(height: 12),
              _buildStatsGrid(stats, modeColor),
              const SizedBox(height: 24),

              // Thermal stats
              _buildSectionLabel('Thermal'),
              const SizedBox(height: 12),
              _buildThermalRow(stats),
              const SizedBox(height: 24),

              // Throttle events
              _buildSectionLabel('Throttle Events'),
              const SizedBox(height: 12),
              _buildThrottleCard(stats),
              const SizedBox(height: 32),

              // Export button
              _buildExportSection(),
              const SizedBox(height: 16),

              // Run another session hint
              _buildRunAgainCard(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeHeader(
      String mode, Color modeColor, SessionStats stats) {
    final duration = stats.duration;
    final mm = duration.inMinutes.toString().padLeft(2, '0');
    final ss = (duration.inSeconds % 60).toString().padLeft(2, '0');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            modeColor.withValues(alpha: 0.15),
            modeColor.withValues(alpha: 0.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: modeColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: modeColor.withValues(alpha: 0.15),
              shape: BoxShape.circle,
              border: Border.all(color: modeColor, width: 2),
            ),
            child: Icon(
              stats.isBaseline ? Icons.bar_chart : Icons.thermostat,
              color: modeColor,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$mode Session Complete',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Duration: $mm:$ss  •  ${widget.logger.entries.length} data points',
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 16,
          decoration: BoxDecoration(
            color: Colors.deepPurpleAccent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Colors.white60,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _buildStatsGrid(SessionStats stats, Color accent) {
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            label: 'Avg TPS',
            value: stats.avgTps.toStringAsFixed(1),
            unit: 'tok/s',
            color: const Color(0xFF00E5A0),
            icon: Icons.speed,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            label: 'P10 TPS',
            value: stats.p10Tps.toStringAsFixed(1),
            unit: 'tok/s',
            color: Colors.tealAccent,
            icon: Icons.trending_down,
          ),
        ),
      ],
    );
  }

  Widget _buildThermalRow(SessionStats stats) {
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            label: 'Max SoC Temp',
            value: stats.maxSocTemp.toStringAsFixed(0),
            unit: '°C',
            color: const Color(0xFFFF6B35),
            icon: Icons.whatshot,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            label: 'Max Batt Temp',
            value: stats.maxBattTemp.toStringAsFixed(0),
            unit: '°C',
            color: const Color(0xFFFFCC02),
            icon: Icons.battery_alert,
          ),
        ),
      ],
    );
  }

  Widget _buildThrottleCard(SessionStats stats) {
    final count = stats.throttleEvents;
    final color = count == 0
        ? const Color(0xFF00E5A0)
        : count < 3
            ? const Color(0xFFFFCC02)
            : const Color(0xFFFF6B35);
    final label = stats.isBaseline
        ? 'Thermal throttles detected'
        : 'ThermalPilot-managed transitions';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Text(
            '$count',
            style: TextStyle(
              color: color,
              fontSize: 40,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  stats.isBaseline
                      ? 'Higher = more performance degradation'
                      : 'Adaptive adjustments prevented thermal collapse',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExportSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton.icon(
          onPressed: _exporting ? null : _exportCsv,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepPurple.shade700,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
          icon: _exporting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : const Icon(Icons.download_rounded),
          label: Text(_exporting ? 'Exporting…' : 'Export CSV'),
        ),
        if (_exportPath != null) ...[
          const SizedBox(height: 10),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle_outline,
                    color: Colors.greenAccent, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _exportPath!.split('/').last,
                    style: const TextStyle(
                        color: Colors.greenAccent, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_exportError != null) ...[
          const SizedBox(height: 10),
          Text(
            'Export failed: $_exportError',
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildRunAgainCard(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF161B27),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: const [
            Icon(Icons.refresh, color: Colors.white38, size: 20),
            SizedBox(width: 12),
            Text(
              'Run another session for comparison',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            Spacer(),
            Icon(Icons.chevron_right, color: Colors.white24),
          ],
        ),
      ),
    );
  }
}

// ── Stat card widget ──────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color color;
  final IconData icon;

  const _StatCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B27),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
          const SizedBox(height: 10),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: TextStyle(
                    color: color,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                  ),
                ),
                TextSpan(
                  text: ' $unit',
                  style: TextStyle(
                    color: color.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
