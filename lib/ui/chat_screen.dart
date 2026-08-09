import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart' as ll;
import '../native/thermal_channel.dart';

// ── Data model ─────────────────────────────────────────────────────────────────

enum _Role { user, assistant }

class _ChatMessage {
  final _Role role;
  final String text;
  final bool isStreaming;

  const _ChatMessage({
    required this.role,
    required this.text,
    this.isStreaming = false,
  });

  _ChatMessage copyWith({String? text, bool? isStreaming}) => _ChatMessage(
        role: role,
        text: text ?? this.text,
        isStreaming: isStreaming ?? this.isStreaming,
      );
}

// ── Screen ─────────────────────────────────────────────────────────────────────

class ChatScreen extends StatefulWidget {
  final String modelPath;

  const ChatScreen({super.key, required this.modelPath});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // Engine
  ll.LlamaEngine? _engine;
  ll.EngineChat? _chat;
  StreamSubscription<ll.GenerationEvent>? _genSub;

  // Thermal channel (for the app bar badge)
  final _thermalChannel = ThermalChannel();
  int _thermalStatus = 0; // 0=cool, 1=light, 2=moderate, 3=severe, 4=critical
  Timer? _thermalTimer;

  // UI state
  final List<_ChatMessage> _messages = [];
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _engineLoading = true;
  bool _generating = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadEngine();
    _thermalTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _refreshThermal();
    });
  }

  Future<void> _refreshThermal() async {
    try {
      final status = await _thermalChannel.getThermalStatus();
      if (mounted) setState(() => _thermalStatus = status);
    } catch (_) {}
  }

  Future<void> _loadEngine() async {
    try {
      _engine = await ll.LlamaEngine.spawn(
        modelParams: ll.ModelParams(path: widget.modelPath),
        contextParams: const ll.ContextParams(
          nCtx: 2048,
          nThreads: 4,
          nThreadsBatch: 4,
        ),
      );
      _chat = await _engine!.createChat();
      _chat!.addSystem(
        'You are a helpful, concise AI assistant running on a mobile device. '
        'Keep answers short and clear.',
      );
      setState(() => _engineLoading = false);
    } catch (e) {
      setState(() {
        _engineLoading = false;
        _loadError = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _thermalTimer?.cancel();
    _genSub?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _engine?.dispose();
    super.dispose();
  }

  // ── Send ──────────────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _generating || _chat == null) return;

    _inputCtrl.clear();
    setState(() {
      _messages.add(_ChatMessage(role: _Role.user, text: text));
      _messages.add(
          _ChatMessage(role: _Role.assistant, text: '', isStreaming: true));
      _generating = true;
    });
    _scrollToBottom();

    _chat!.addUser(text);

    final stream = _chat!.generate(
      maxTokens: 512,
      sampler: const ll.SamplerParams(temperature: 0.7, topP: 0.9),
      shiftPolicy: ll.ContextShiftPolicy.auto,
      shift: const ll.ContextShift(nKeep: -1),
    );

    final buf = StringBuffer();
    _genSub = stream.listen(
      (event) {
        if (event is ll.TokenEvent) {
          buf.write(event.text);
          if (mounted) {
            setState(() {
              _messages[_messages.length - 1] =
                  _messages.last.copyWith(text: buf.toString());
            });
            _scrollToBottom();
          }
        }
      },
      onDone: () {
        if (mounted) {
          setState(() {
            _messages[_messages.length - 1] = _messages.last.copyWith(
              text: buf.toString(),
              isStreaming: false,
            );
            _generating = false;
          });
          _scrollToBottom();
        }
      },
      onError: (e) {
        if (mounted) {
          setState(() {
            _messages[_messages.length - 1] = _messages.last.copyWith(
              text: '⚠ Error: $e',
              isStreaming: false,
            );
            _generating = false;
          });
        }
      },
      cancelOnError: true,
    );
  }

  void _stopGeneration() {
    _genSub?.cancel();
    _genSub = null;
    if (mounted) {
      setState(() {
        if (_messages.isNotEmpty && _messages.last.isStreaming) {
          _messages[_messages.length - 1] =
              _messages.last.copyWith(isStreaming: false);
        }
        _generating = false;
      });
    }
  }

  void _clearChat() {
    _stopGeneration();
    _chat?.clearHistory();
    _chat?.addSystem(
      'You are a helpful, concise AI assistant running on a mobile device. '
      'Keep answers short and clear.',
    );
    setState(() => _messages.clear());
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── UI ────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1117),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white70),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            const Icon(Icons.chat_bubble_outline,
                color: Colors.deepPurpleAccent, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Chat',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700),
                  ),
                  Text(
                    widget.modelPath.split('/').last,
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Thermal badge
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _ThermalBadge(status: _thermalStatus),
          ),
          // Clear chat button
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white38, size: 20),
            tooltip: 'Clear chat',
            onPressed: _messages.isEmpty ? null : _clearChat,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessageList()),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    if (_engineLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.deepPurpleAccent),
            ),
            const SizedBox(height: 16),
            Text(
              'Loading model…',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              widget.modelPath.split('/').last,
              style: const TextStyle(color: Colors.white24, fontSize: 11),
            ),
          ],
        ),
      );
    }

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
              const SizedBox(height: 12),
              const Text('Failed to load model',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(_loadError!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    if (_messages.isEmpty) {
      return _buildEmptyState();
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (_, i) => _buildBubble(_messages[i]),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.deepPurpleAccent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border:
                  Border.all(color: Colors.deepPurpleAccent.withValues(alpha: 0.3)),
            ),
            child: const Icon(Icons.auto_awesome,
                color: Colors.deepPurpleAccent, size: 36),
          ),
          const SizedBox(height: 20),
          const Text('On-device AI Chat',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'Running fully on your device.\nNo internet connection required.',
            style: TextStyle(color: Colors.white38, fontSize: 13, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          // Suggested prompts
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _buildSuggestion('What is thermal throttling?'),
              _buildSuggestion('How does quantization work?'),
              _buildSuggestion('Tell me about ARM big.LITTLE'),
              _buildSuggestion('What is a transformer model?'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestion(String text) {
    return GestureDetector(
      onTap: () {
        _inputCtrl.text = text;
        _send();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.deepPurple.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: Colors.deepPurple.withValues(alpha: 0.3)),
        ),
        child: Text(text,
            style:
                const TextStyle(color: Colors.deepPurpleAccent, fontSize: 12)),
      ),
    );
  }

  Widget _buildBubble(_ChatMessage msg) {
    final isUser = msg.role == _Role.user;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(right: 8, bottom: 2),
              decoration: BoxDecoration(
                color: Colors.deepPurpleAccent.withValues(alpha: 0.2),
                shape: BoxShape.circle,
                border: Border.all(
                    color: Colors.deepPurpleAccent.withValues(alpha: 0.5),
                    width: 1),
              ),
              child: const Icon(Icons.auto_awesome,
                  color: Colors.deepPurpleAccent, size: 15),
            ),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: msg.text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied to clipboard'),
                    duration: Duration(seconds: 1),
                    backgroundColor: Color(0xFF1E2840),
                  ),
                );
              },
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78,
                ),
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isUser
                      ? Colors.deepPurpleAccent.withValues(alpha: 0.85)
                      : const Color(0xFF1A1F2E),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(isUser ? 18 : 4),
                    bottomRight: Radius.circular(isUser ? 4 : 18),
                  ),
                  border: isUser
                      ? null
                      : Border.all(
                          color: Colors.white.withValues(alpha: 0.06)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: msg.isStreaming && msg.text.isEmpty
                    ? const _TypingIndicator()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            msg.text,
                            style: TextStyle(
                              color:
                                  isUser ? Colors.white : Colors.white.withValues(alpha: 0.9),
                              fontSize: 14.5,
                              height: 1.45,
                            ),
                          ),
                          if (msg.isStreaming) ...[
                            const SizedBox(height: 6),
                            const _CursorBlink(),
                          ],
                        ],
                      ),
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 36), // balance avatar gap
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.07))),
      ),
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 10,
        bottom: MediaQuery.of(context).viewInsets.bottom > 0
            ? 10
            : MediaQuery.of(context).padding.bottom + 10,
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 120),
              decoration: BoxDecoration(
                color: const Color(0xFF161B27),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: _generating
                        ? Colors.deepPurpleAccent.withValues(alpha: 0.5)
                        : Colors.white.withValues(alpha: 0.08)),
              ),
              child: TextField(
                controller: _inputCtrl,
                enabled: !_engineLoading && _loadError == null,
                maxLines: null,
                style: const TextStyle(color: Colors.white, fontSize: 14.5),
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Message…',
                  hintStyle: TextStyle(color: Colors.white24),
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Send / Stop button
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _generating
                ? GestureDetector(
                    key: const ValueKey('stop'),
                    onTap: _stopGeneration,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.redAccent.withValues(alpha: 0.5)),
                      ),
                      child: const Icon(Icons.stop_rounded,
                          color: Colors.redAccent, size: 22),
                    ),
                  )
                : GestureDetector(
                    key: const ValueKey('send'),
                    onTap: _inputCtrl.text.isEmpty ? null : _send,
                    child: ListenableBuilder(
                      listenable: _inputCtrl,
                      builder: (_, _) {
                        final hasText = _inputCtrl.text.trim().isNotEmpty;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: hasText
                                ? Colors.deepPurpleAccent
                                : Colors.white12,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.arrow_upward_rounded,
                              color:
                                  hasText ? Colors.white : Colors.white24,
                              size: 22),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Helper widgets ─────────────────────────────────────────────────────────────

/// Animated three-dot typing indicator.
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _ctrl,
            builder: (_, _) {
              final phase = (_ctrl.value - i * 0.15).clamp(0.0, 1.0);
              final opacity = (phase < 0.5 ? phase * 2 : (1 - phase) * 2)
                  .clamp(0.3, 1.0);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2.5),
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Colors.white54,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

/// Blinking text cursor at end of streaming output.
class _CursorBlink extends StatefulWidget {
  const _CursorBlink();

  @override
  State<_CursorBlink> createState() => _CursorBlinkState();
}

class _CursorBlinkState extends State<_CursorBlink>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl,
      child: Container(
        width: 2,
        height: 14,
        decoration: BoxDecoration(
          color: Colors.deepPurpleAccent,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

/// App bar thermal status badge.
class _ThermalBadge extends StatelessWidget {
  final int status; // 0–4

  const _ThermalBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      0 => ('COOL', const Color(0xFF4CAF50)),
      1 => ('LIGHT', const Color(0xFF8BC34A)),
      2 => ('WARM', const Color(0xFFFFC107)),
      3 => ('HOT', const Color(0xFFFF5722)),
      _ => ('CRIT', const Color(0xFFF44336)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.thermostat, color: color, size: 12),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5)),
        ],
      ),
    );
  }
}
