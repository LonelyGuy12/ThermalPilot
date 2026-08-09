import 'dart:async';
import 'package:flutter/material.dart';
import '../utils/model_downloader.dart';
import 'dashboard_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  bool _isBaselineMode = false;
  String? _int4ModelPath;
  String? _int8ModelPath;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Default HuggingFace URLs for Qwen2.5-0.5B-Instruct
  static const _defaultInt4Url =
      'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf';
  static const _defaultInt8Url =
      'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q8_0.gguf';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    // Check if models were previously downloaded
    _checkExistingModels();
  }

  Future<void> _checkExistingModels() async {
    final int4Name = ModelDownloader.fileNameFromUrl(_defaultInt4Url);
    final int8Name = ModelDownloader.fileNameFromUrl(_defaultInt8Url);
    final int4Path = await ModelDownloader.existingModelPath(int4Name);
    final int8Path = await ModelDownloader.existingModelPath(int8Name);
    if (mounted) {
      setState(() {
        _int4ModelPath = int4Path;
        _int8ModelPath = int8Path;
      });
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  bool get _canStart => _int4ModelPath != null || _int8ModelPath != null;

  // If only one model is downloaded, use it for both tiers.
  String get _resolvedInt4Path => _int4ModelPath ?? _int8ModelPath!;
  String get _resolvedInt8Path => _int8ModelPath ?? _int4ModelPath!;
  bool get _usingSingleModel => _int4ModelPath == null || _int8ModelPath == null;

  void _startSession() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DashboardScreen(
          isBaseline: _isBaselineMode,
          int4ModelPath: _resolvedInt4Path,
          int8ModelPath: _resolvedInt8Path,
        ),
      ),
    );
  }

  Future<void> _showModelDialog({required bool isInt4}) async {
    final defaultUrl = isInt4 ? _defaultInt4Url : _defaultInt8Url;
    final currentPath = isInt4 ? _int4ModelPath : _int8ModelPath;
    final label = isInt4 ? 'INT4 Model (Q4_K_M)' : 'INT8 Model (Q8_0)';
    final color = isInt4 ? Colors.orangeAccent : Colors.cyanAccent;

    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ModelSetupSheet(
        title: label,
        defaultUrl: defaultUrl,
        currentPath: currentPath,
        accentColor: color,
      ),
    );

    if (result != null && result.isNotEmpty && mounted) {
      setState(() {
        if (isInt4) {
          _int4ModelPath = result;
        } else {
          _int8ModelPath = result;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 120,
            pinned: true,
            backgroundColor: const Color(0xFF0D1117),
            flexibleSpace: FlexibleSpaceBar(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.thermostat,
                      color: Colors.deepPurpleAccent, size: 22),
                  const SizedBox(width: 8),
                  const Text(
                    'ThermalPilot',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
              centerTitle: false,
              titlePadding:
                  const EdgeInsetsDirectional.only(start: 16, bottom: 16),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeroCard(),
                  const SizedBox(height: 28),
                  _buildSectionLabel('Benchmark Mode'),
                  const SizedBox(height: 12),
                  _buildModeToggle(),
                  const SizedBox(height: 28),
                  _buildSectionLabel('Model Files'),
                  const SizedBox(height: 12),
                  _buildModelCard(
                    label: 'INT4 Model (Q4_K_M)',
                    path: _int4ModelPath,
                    fallbackNote: _int4ModelPath == null && _int8ModelPath != null
                        ? 'Using INT8 model as fallback'
                        : null,
                    color: Colors.orangeAccent,
                    icon: Icons.compress,
                    onTap: () => _showModelDialog(isInt4: true),
                  ),
                  const SizedBox(height: 12),
                  _buildModelCard(
                    label: 'INT8 Model (Q8_0)',
                    path: _int8ModelPath,
                    fallbackNote: _int8ModelPath == null && _int4ModelPath != null
                        ? 'Using INT4 model as fallback'
                        : null,
                    color: Colors.cyanAccent,
                    icon: Icons.memory,
                    onTap: () => _showModelDialog(isInt4: false),
                  ),
                  const SizedBox(height: 36),
                  _buildStartButton(),
                  const SizedBox(height: 40),
                  _buildHintCard(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Reusable widgets (unchanged) ──────────────────────────────────────────────

  Widget _buildHeroCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E1040), Color(0xFF0D2040)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: Colors.deepPurple.withValues(alpha: 0.4)),
        boxShadow: [
          BoxShadow(
            color: Colors.deepPurple.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ScaleTransition(
                scale: _pulseAnimation,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.deepPurpleAccent.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: Colors.deepPurpleAccent, width: 2),
                  ),
                  child: const Icon(Icons.bolt,
                      color: Colors.deepPurpleAccent, size: 28),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Thermal-Aware LLM Scheduler',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Keeps tokens/sec stable under SoC thermal throttling',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(color: Colors.white12),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStat('20 min', 'Session'),
              _buildStat('4 states', 'FSM'),
              _buildStat('2 models', 'Hot-swap'),
              _buildStat('2 s', 'Tick rate'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStat(String value, String label) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.deepPurpleAccent,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
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
        Text(label,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0)),
      ],
    );
  }

  Widget _buildModeToggle() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF161B27),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          _buildModeOption(
            label: '🚀 ThermalPilot',
            sublabel: 'Adaptive scheduler',
            selected: !_isBaselineMode,
            color: Colors.deepPurpleAccent,
            onTap: () => setState(() => _isBaselineMode = false),
          ),
          const SizedBox(width: 4),
          _buildModeOption(
            label: '📊 Baseline',
            sublabel: 'Max threads + INT8',
            selected: _isBaselineMode,
            color: Colors.blueAccent,
            onTap: () => setState(() => _isBaselineMode = true),
          ),
        ],
      ),
    );
  }

  Widget _buildModeOption({
    required String label,
    required String sublabel,
    required bool selected,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: selected ? color : Colors.transparent, width: 1.5),
          ),
          child: Column(
            children: [
              Text(label,
                  style: TextStyle(
                      color: selected ? Colors.white : Colors.white38,
                      fontWeight: FontWeight.w600,
                      fontSize: 14),
                  textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text(sublabel,
                  style: TextStyle(
                      color: selected ? color : Colors.white24, fontSize: 11),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModelCard({
    required String label,
    required String? path,
    required Color color,
    required IconData icon,
    required VoidCallback onTap,
    String? fallbackNote,
  }) {
    final bool isSet = path != null;
    final bool isFallback = path == null && fallbackNote != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF161B27),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSet
                ? color.withValues(alpha: 0.5)
                : isFallback
                    ? Colors.amber.withValues(alpha: 0.4)
                    : Colors.white12,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: (isSet
                        ? color
                        : isFallback
                            ? Colors.amber
                            : Colors.white24)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                color: isSet
                    ? color
                    : isFallback
                        ? Colors.amber
                        : Colors.white38,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: isSet
                              ? Colors.white
                              : isFallback
                                  ? Colors.white70
                                  : Colors.white54,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                  const SizedBox(height: 3),
                  Text(
                    isSet
                        ? path.split('/').last
                        : (fallbackNote ?? 'Tap to download or set path'),
                    style: TextStyle(
                      color: isSet
                          ? color.withValues(alpha: 0.8)
                          : isFallback
                              ? Colors.amber.withValues(alpha: 0.8)
                              : Colors.white24,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              isSet
                  ? Icons.check_circle
                  : isFallback
                      ? Icons.warning_amber_rounded
                      : Icons.download_rounded,
              color: isSet
                  ? color
                  : isFallback
                      ? Colors.amber
                      : Colors.white24,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStartButton() {
    return SizedBox(
      width: double.infinity,
      height: 60,
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: _canStart
                  ? [
                      BoxShadow(
                        color: Colors.deepPurpleAccent.withValues(
                            alpha: 0.4 + 0.2 * _pulseAnimation.value),
                        blurRadius: 24,
                        spreadRadius: 2,
                      ),
                    ]
                  : [],
            ),
            child: child,
          );
        },
        child: ElevatedButton(
          onPressed: _canStart ? _startSession : null,
          style: ElevatedButton.styleFrom(
            backgroundColor:
                _canStart ? Colors.deepPurpleAccent : Colors.white12,
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white38,
            disabledBackgroundColor: Colors.white12,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            elevation: 0,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.play_circle_fill, size: 24),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  _usingSingleModel
                      ? 'Start Session (1 model)'
                      : _isBaselineMode
                          ? 'Start 20-min Baseline Session'
                          : 'Start 20-min ThermalPilot Session',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHintCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Icon(Icons.info_outline, color: Colors.blueAccent, size: 18),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Setup',
                    style: TextStyle(
                        color: Colors.blueAccent,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                SizedBox(height: 6),
                Text(
                  'Tap a model card above to download directly from HuggingFace '
                  'or enter a local file path.\n\n'
                  'Recommended: Qwen2.5-0.5B-Instruct GGUF\n'
                  '• Q4_K_M (~397 MB): for INT4 model\n'
                  '• Q8_0 (~531 MB): for INT8 model',
                  style: TextStyle(
                      color: Colors.white54, fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Model setup bottom sheet — download from URL or set local path
// ══════════════════════════════════════════════════════════════════════════════

class _ModelSetupSheet extends StatefulWidget {
  final String title;
  final String defaultUrl;
  final String? currentPath;
  final Color accentColor;

  const _ModelSetupSheet({
    required this.title,
    required this.defaultUrl,
    this.currentPath,
    required this.accentColor,
  });

  @override
  State<_ModelSetupSheet> createState() => _ModelSetupSheetState();
}

class _ModelSetupSheetState extends State<_ModelSetupSheet> {
  late TextEditingController _urlController;
  late TextEditingController _pathController;
  bool _showPathField = false;

  // Download state
  ModelDownloader? _downloader;
  StreamSubscription<DownloadProgress>? _downloadSub;
  DownloadProgress? _progress;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.defaultUrl);
    _pathController = TextEditingController(text: widget.currentPath ?? '');
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    _downloader?.cancel();
    _urlController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  bool get _isDownloading =>
      _progress != null && _progress!.state == DownloadState.downloading;

  void _startDownload() {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    _downloader = ModelDownloader();
    _downloadSub = _downloader!.download(url).listen((p) {
      if (!mounted) return;
      setState(() => _progress = p);

      if (p.state == DownloadState.completed && p.filePath != null) {
        // Auto-close sheet and return the path
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) Navigator.pop(context, p.filePath);
        });
      }
    });
  }

  void _cancelDownload() {
    _downloader?.cancel();
    setState(() => _progress = null);
  }

  void _setLocalPath() {
    final path = _pathController.text.trim();
    if (path.isNotEmpty) {
      Navigator.pop(context, path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      margin: const EdgeInsets.only(top: 60),
      padding: EdgeInsets.only(bottom: bottomPadding),
      decoration: const BoxDecoration(
        color: Color(0xFF141922),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Title
              Row(
                children: [
                  Icon(Icons.download_rounded,
                      color: widget.accentColor, size: 22),
                  const SizedBox(width: 10),
                  Text(widget.title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 20),

              // URL input
              const Text('HuggingFace URL',
                  style: TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller: _urlController,
                enabled: !_isDownloading,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: 'https://huggingface.co/…/resolve/main/model.gguf',
                  hintStyle: const TextStyle(color: Colors.white24),
                  filled: true,
                  fillColor: const Color(0xFF1A1F2E),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                        color: widget.accentColor.withValues(alpha: 0.3)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: widget.accentColor),
                  ),
                  disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white12),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 16),

              // Download / progress
              if (_progress != null) _buildProgressSection(),
              if (_progress == null || _progress!.state == DownloadState.error)
                _buildDownloadButton(),

              const SizedBox(height: 16),
              const Divider(color: Colors.white12),
              const SizedBox(height: 12),

              // Toggle for local path
              GestureDetector(
                onTap: () =>
                    setState(() => _showPathField = !_showPathField),
                child: Row(
                  children: [
                    Icon(
                        _showPathField
                            ? Icons.expand_less
                            : Icons.expand_more,
                        color: Colors.white38,
                        size: 20),
                    const SizedBox(width: 8),
                    const Text('Or enter a local file path',
                        style:
                            TextStyle(color: Colors.white38, fontSize: 13)),
                  ],
                ),
              ),

              if (_showPathField) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _pathController,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          hintText: '/sdcard/Download/model.gguf',
                          hintStyle:
                              const TextStyle(color: Colors.white24),
                          filled: true,
                          fillColor: const Color(0xFF1A1F2E),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                const BorderSide(color: Colors.white12),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                                color: widget.accentColor),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: _setLocalPath,
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            widget.accentColor.withValues(alpha: 0.2),
                        foregroundColor: widget.accentColor,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Set'),
                    ),
                  ],
                ),
              ],

              // Status: model already loaded
              if (widget.currentPath != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: Colors.green.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_outline,
                          color: Colors.greenAccent, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Current: ${widget.currentPath!.split('/').last}',
                          style: const TextStyle(
                              color: Colors.greenAccent, fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadButton() {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton.icon(
        onPressed: _startDownload,
        style: ElevatedButton.styleFrom(
          backgroundColor: widget.accentColor,
          foregroundColor: Colors.black,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        icon: const Icon(Icons.download_rounded, size: 20),
        label: const Text('Download from HuggingFace',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      ),
    );
  }

  Widget _buildProgressSection() {
    final p = _progress!;
    final isComplete = p.state == DownloadState.completed;
    final isError = p.state == DownloadState.error;
    final isDownloading = p.state == DownloadState.downloading;

    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isComplete
              ? Colors.greenAccent.withValues(alpha: 0.5)
              : isError
                  ? Colors.redAccent.withValues(alpha: 0.5)
                  : widget.accentColor.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // File name + status
          Row(
            children: [
              if (isDownloading)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: widget.accentColor),
                ),
              if (isComplete)
                const Icon(Icons.check_circle,
                    color: Colors.greenAccent, size: 18),
              if (isError)
                const Icon(Icons.error_outline,
                    color: Colors.redAccent, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isComplete
                      ? 'Download complete!'
                      : isError
                          ? 'Download failed'
                          : 'Downloading ${p.fileName}…',
                  style: TextStyle(
                    color: isComplete
                        ? Colors.greenAccent
                        : isError
                            ? Colors.redAccent
                            : Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              if (isDownloading)
                GestureDetector(
                  onTap: _cancelDownload,
                  child: const Icon(Icons.close,
                      color: Colors.white38, size: 20),
                ),
            ],
          ),

          if (isDownloading || isComplete) ...[
            const SizedBox(height: 12),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: p.fraction,
                minHeight: 6,
                backgroundColor: Colors.white12,
                valueColor:
                    AlwaysStoppedAnimation(isComplete
                        ? Colors.greenAccent
                        : widget.accentColor),
              ),
            ),
            const SizedBox(height: 8),
            Text(p.progressText,
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ],

          if (isError && p.error != null) ...[
            const SizedBox(height: 8),
            Text(p.error!,
                style: const TextStyle(
                    color: Colors.redAccent, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}
