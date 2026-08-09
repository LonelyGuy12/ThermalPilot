/// LlamaEngine — wraps llama_cpp_dart 0.9.0-dev with:
///   • Hot-swap between INT4 and INT8 GGUF models (engine re-spawn on policy change)
///   • Runtime thread-count changes via ContextParams.nThreads
///   • Token-per-second measurement during a rotating prompt benchmark loop
///   • Off-thread inference via llama_cpp_dart's built-in isolate worker
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' as ll;
import '../scheduler/thermal_models.dart';

// ── Benchmark prompts ──────────────────────────────────────────────────────────

const List<String> kBenchmarkPrompts = [
  'Explain the concept of thermal throttling in mobile processors in two sentences.',
  'What are the main differences between big and LITTLE CPU cores in ARM architecture?',
  'Describe how quantization reduces the memory footprint of large language models.',
  'What is the purpose of a context window in transformer-based language models?',
  'Explain why sustained performance matters more than peak performance on mobile devices.',
  'How does battery temperature affect CPU governor behavior on Android phones?',
  'What trade-offs does INT4 quantization make compared to INT8 for on-device inference?',
  'Describe the relationship between token generation speed and SoC thermal dissipation.',
  'Why is hysteresis important in a thermal management state machine?',
  'What metrics would you use to compare two inference schedulers in a 20-minute benchmark?',
];

// ── Result model ───────────────────────────────────────────────────────────────

class InferenceResult {
  final int promptIndex;
  final String promptText;
  final String responseText;
  final double tokensPerSec;
  final int tokenCount;
  final Duration elapsed;
  final ThermalState stateAtGeneration;
  final QuantTier quantAtGeneration;
  final int threadsAtGeneration;

  const InferenceResult({
    required this.promptIndex,
    required this.promptText,
    required this.responseText,
    required this.tokensPerSec,
    required this.tokenCount,
    required this.elapsed,
    required this.stateAtGeneration,
    required this.quantAtGeneration,
    required this.threadsAtGeneration,
  });
}

// ── Engine ─────────────────────────────────────────────────────────────────────

class LlamaEngine extends ChangeNotifier {
  LlamaEngine({
    required String int4ModelPath,
    required String int8ModelPath,
  })  : _int4Path = int4ModelPath,
        _int8Path = int8ModelPath;

  final String _int4Path;
  final String _int8Path;

  /// The llama_cpp_dart 0.9.0 isolate-backed engine.
  ll.LlamaEngine? _engine;

  /// Active session handle.
  ll.EngineSession? _session;

  bool _isRunning = false;
  bool _generationActive = false;

  // Current config
  ThermalPolicy _currentPolicy = const ThermalPolicy(
    state: ThermalState.cool,
    threads: 4,
    quant: QuantTier.int8,
    ctxLen: 4096,
  );

  ThermalPolicy get currentPolicy => _currentPolicy;

  // Benchmark state
  int _promptIndex = 0;
  double _lastTps = 0.0;
  final List<InferenceResult> _results = [];
  bool _stopRequested = false;

  List<InferenceResult> get results => List.unmodifiable(_results);
  double get lastTps => _lastTps;
  bool get isRunning => _isRunning;

  // Callbacks
  void Function(InferenceResult)? onResult;
  void Function(String)? onError;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    await _loadEngine(_currentPolicy);
  }

  Future<void> _loadEngine(ThermalPolicy policy) async {
    // Tear down previous engine if any
    await _teardown();

    final modelPath = policy.quant == QuantTier.int4 ? _int4Path : _int8Path;
    debugPrint('[LlamaEngine] Loading model: $modelPath '
        'threads=${policy.threads} ctx=${policy.ctxLen}');

    try {
      _engine = await ll.LlamaEngine.spawn(
        modelParams: ll.ModelParams(path: modelPath),
        contextParams: ll.ContextParams(
          nCtx: policy.ctxLen,
          nThreads: policy.threads,
          nThreadsBatch: policy.threads,
        ),
      );
      _session = await _engine!.createSession();
      debugPrint('[LlamaEngine] Engine ready.');
    } catch (e) {
      debugPrint('[LlamaEngine] Failed to load engine: $e');
      onError?.call('Failed to load model: $e');
      rethrow;
    }
  }

  Future<void> _teardown() async {
    _generationActive = false;
    try {
      await _session?.dispose();
    } catch (_) {}
    try {
      await _engine?.dispose();
    } catch (_) {}
    _session = null;
    _engine = null;
  }

  // ── Policy changes (called by ThermalScheduler) ───────────────────────────

  Future<void> onPolicyChanged(ThermalPolicy newPolicy) async {
    final oldPolicy = _currentPolicy;
    _currentPolicy = newPolicy;

    final needsReload = newPolicy.quant != oldPolicy.quant ||
        newPolicy.threads != oldPolicy.threads ||
        newPolicy.ctxLen != oldPolicy.ctxLen;

    if (!needsReload) return;

    debugPrint('[LlamaEngine] Policy change → quant=${newPolicy.quant.name} '
        'threads=${newPolicy.threads} ctx=${newPolicy.ctxLen}');

    _generationActive = false;
    await _loadEngine(newPolicy);
    notifyListeners();
  }

  // ── Benchmark loop ─────────────────────────────────────────────────────────

  Future<void> startBenchmarkLoop() async {
    _isRunning = true;
    _stopRequested = false;
    notifyListeners();

    while (!_stopRequested) {
      if (_session == null || _engine == null) {
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }

      final prompt =
          kBenchmarkPrompts[_promptIndex % kBenchmarkPrompts.length];
      _promptIndex++;

      await _runSingleInference(prompt);
    }

    _isRunning = false;
    notifyListeners();
  }

  Future<void> _runSingleInference(String prompt) async {
    final session = _session;
    if (session == null) return;

    _generationActive = true;
    final sw = Stopwatch()..start();
    final buffer = StringBuffer();
    int tokenCount = 0;

    try {
      final stream = session.generate(
        prompt: prompt,
        addSpecial: true,
        sampler: const ll.SamplerParams(temperature: 0.7, topP: 0.95),
        maxTokens: 128,
      );

      await for (final event in stream) {
        if (!_generationActive || _stopRequested) break;

        if (event is ll.TokenEvent) {
          buffer.write(event.text);
          tokenCount++;
        } else if (event is ll.DoneEvent) {
          break;
        }
      }
    } catch (e) {
      debugPrint('[LlamaEngine] Generation error: $e');
      if (_stopRequested) return;
      onError?.call('Inference error: $e');
      return;
    } finally {
      _generationActive = false;
    }

    sw.stop();
    if (tokenCount == 0 || _stopRequested) return;

    final elapsed = sw.elapsed;
    final tps = tokenCount / elapsed.inMilliseconds * 1000.0;
    _lastTps = tps;

    final result = InferenceResult(
      promptIndex: _promptIndex - 1,
      promptText: prompt,
      responseText: buffer.toString(),
      tokensPerSec: tps,
      tokenCount: tokenCount,
      elapsed: elapsed,
      stateAtGeneration: _currentPolicy.state,
      quantAtGeneration: _currentPolicy.quant,
      threadsAtGeneration: _currentPolicy.threads,
    );

    _results.add(result);
    onResult?.call(result);
    notifyListeners();
  }

  void stop() {
    _stopRequested = true;
    _generationActive = false;
  }

  @override
  Future<void> dispose() async {
    stop();
    await _teardown();
    super.dispose();
  }
}
