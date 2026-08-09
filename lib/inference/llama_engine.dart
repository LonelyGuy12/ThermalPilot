/// LlamaEngine — wraps llama_cpp_dart with:
///   • Hot-swap between INT4 and INT8 GGUF models
///   • Runtime thread-count changes (via fast model reload for 0.5B models)
///   • Token-per-second measurement during a rotating prompt benchmark loop
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import '../scheduler/thermal_models.dart';

// ── Benchmark prompts ──────────────────────────────────────────────────────────

/// Fixed set of prompts rotated through during the benchmark session.
/// Kept at similar input token lengths (~30–40 tokens) for fair comparison.
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

  // Currently active llama instance (high-level Llama wrapper for synchronous
  // token-by-token generation in a background isolate pattern).
  Llama? _activeLlama;

  // Current config
  ThermalPolicy _currentPolicy = const ThermalPolicy(
    state: ThermalState.cool,
    threads: 4,
    quant: QuantTier.int8,
    ctxLen: 4096,
  );

  ThermalPolicy get currentPolicy => _currentPolicy;

  bool _isGenerating = false;
  bool _initialized = false;
  String _statusMessage = 'Not initialized';

  bool get isGenerating => _isGenerating;
  bool get isInitialized => _initialized;
  String get statusMessage => _statusMessage;

  // Latest measured TPS
  double _lastTps = 0.0;
  double get lastTps => _lastTps;

  // Session cancellation
  bool _cancelRequested = false;

  // ── Init ──────────────────────────────────────────────────────────────────────

  /// Initializes the engine with the COOL policy (INT8, full threads).
  Future<void> initialize(ThermalPolicy initialPolicy) async {
    _currentPolicy = initialPolicy;
    await _loadModel(initialPolicy);
    _initialized = true;
    _statusMessage = 'Ready';
    notifyListeners();
  }

  // ── Policy application ────────────────────────────────────────────────────────

  /// Called by ThermalScheduler when the policy changes.
  /// Reloads the model if thread count or quant tier changed.
  Future<void> applyPolicy(ThermalPolicy policy) async {
    final bool quantChanged = policy.quant != _currentPolicy.quant;
    final bool threadsChanged = policy.threads != _currentPolicy.threads;
    final bool ctxChanged = policy.ctxLen != _currentPolicy.ctxLen;

    _currentPolicy = policy;

    if (quantChanged || threadsChanged || ctxChanged) {
      _statusMessage = 'Reloading model (${policy.quant.displayName}, '
          '${policy.threads}t, ctx=${policy.ctxLen})…';
      notifyListeners();
      await _reloadModel(policy);
      _statusMessage = 'Running (${policy.state.displayName})';
      notifyListeners();
    }
  }

  // ── Benchmark loop ────────────────────────────────────────────────────────────

  /// Runs a rotating prompt loop for [duration], yielding an [InferenceResult]
  /// for each completed inference. Cancelled by calling [cancelSession].
  Stream<InferenceResult> runBenchmarkLoop(Duration duration) async* {
    if (!_initialized || _activeLlama == null) {
      debugPrint('LlamaEngine: not initialized');
      return;
    }
    _cancelRequested = false;
    final deadline = DateTime.now().add(duration);
    int promptIndex = 0;

    while (DateTime.now().isBefore(deadline) && !_cancelRequested) {
      final prompt = kBenchmarkPrompts[promptIndex % kBenchmarkPrompts.length];
      promptIndex++;

      final result = await _runSingleInference(prompt, promptIndex - 1);
      if (result != null) {
        _lastTps = result.tokensPerSec;
        notifyListeners();
        yield result;
      }

      // Brief pause between prompts to let the scheduler tick
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  void cancelSession() {
    _cancelRequested = true;
  }

  // ── Disposal ───────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _activeLlama?.dispose();
    _activeLlama = null;
    super.dispose();
  }

  // ── Private helpers ──────────────────────────────────────────────────────────

  Future<void> _loadModel(ThermalPolicy policy) async {
    _activeLlama?.dispose();
    _activeLlama = null;

    final path = policy.quant == QuantTier.int8 ? _int8Path : _int4Path;
    debugPrint(
        'LlamaEngine: loading ${policy.quant.name} model at $path '
        '(threads=${policy.threads}, ctx=${policy.ctxLen})');

    try {
      final ctxParams = ContextParams()
          ..nCtx = policy.ctxLen
          ..nThreads = policy.threads
          ..nThreadsBatch = policy.threads;

      final llama = Llama(
        path,
        modelParams: ModelParams()..nGpuLayers = 0, // CPU only on mobile
        contextParams: ctxParams,
        samplerParams: SamplerParams()..temp = 0.7,
      );
      _activeLlama = llama;
    } catch (e) {
      _statusMessage = 'Error loading model: $e';
      debugPrint('LlamaEngine error: $e');
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _reloadModel(ThermalPolicy policy) async {
    _isGenerating = false;
    await _loadModel(policy);
  }

  Future<InferenceResult?> _runSingleInference(
      String prompt, int promptIdx) async {
    if (_activeLlama == null || _cancelRequested) return null;

    _isGenerating = true;
    notifyListeners();

    final buffer = StringBuffer();
    final sw = Stopwatch()..start();
    int tokenCount = 0;

    try {
      _activeLlama!.setPrompt(prompt);

      while (!_cancelRequested) {
        final (String token, bool done) = _activeLlama!.getNext();
        buffer.write(token);
        tokenCount++;
        if (done) break;

        // Yield to event loop periodically so UI stays responsive
        if (tokenCount % 10 == 0) {
          await Future.delayed(Duration.zero);
        }
      }
    } catch (e) {
      debugPrint('LlamaEngine inference error: $e');
      _isGenerating = false;
      notifyListeners();
      return null;
    }

    sw.stop();
    _isGenerating = false;
    notifyListeners();

    final elapsedSec = sw.elapsedMilliseconds / 1000.0;
    final tps = elapsedSec > 0 ? tokenCount / elapsedSec : 0.0;

    return InferenceResult(
      promptIndex: promptIdx,
      promptText: prompt,
      responseText: buffer.toString(),
      tokensPerSec: tps,
      tokenCount: tokenCount,
      elapsed: sw.elapsed,
      stateAtGeneration: _currentPolicy.state,
      quantAtGeneration: _currentPolicy.quant,
      threadsAtGeneration: _currentPolicy.threads,
    );
  }
}
