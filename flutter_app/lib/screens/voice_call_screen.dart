import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_settings.dart';
import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/audio_recorder_service.dart';
import '../services/tts_service.dart';

enum VoiceCallStatus {
  idle, // 闲置/准备就绪
  listening, // 用户正在讲话 (正在录音/监听)
  recognizing, // 正在将语音转写为文字 (ASR)
  thinking, // AI 正在思考与流式生成
  speaking, // AI 正在说话播报
}

class VoiceCallScreen extends StatefulWidget {
  const VoiceCallScreen({super.key});

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen> with SingleTickerProviderStateMixin {
  VoiceCallStatus _status = VoiceCallStatus.idle;
  String _userSpokenText = '';
  String _aiResponseText = '';
  String _statusHint = '点击麦克风或轻触屏幕开始说话';
  bool _isMuted = false;
  bool _isSpeakerOn = true;

  // 动画控制器：呼吸光圈与声波律动
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // 录音计时器与 VAD 监听
  Timer? _recordTimer;
  int _callDurationSeconds = 0;
  Timer? _callTicker;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.92, end: 1.12).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // 开启通话计时器
    _callTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() => _callDurationSeconds++);
      }
    });

    // 默认进入后自动启动麦克风开始对话
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startListening();
    });
  }

  @override
  void dispose() {
    _callTicker?.cancel();
    _recordTimer?.cancel();
    _pulseController.dispose();
    TtsService.instance.stop();
    if (AudioRecorderService.instance.isRecording) {
      AudioRecorderService.instance.stopRecording(cancelled: true);
    }
    super.dispose();
  }

  String _formatDuration(int seconds) {
    final min = (seconds ~/ 60).toString().padLeft(2, '0');
    final sec = (seconds % 60).toString().padLeft(2, '0');
    return '$min:$sec';
  }

  /// 开始录音聆听用户说话
  Future<void> _startListening() async {
    if (_isMuted) return;

    final hasPerm = await AudioRecorderService.instance.hasPermission();
    if (!hasPerm) {
      if (mounted) {
        setState(() {
          _status = VoiceCallStatus.idle;
          _statusHint = '请授予麦克风权限以进行实时通话';
        });
      }
      return;
    }

    if (AudioRecorderService.instance.isRecording) {
      await AudioRecorderService.instance.stopRecording(cancelled: true);
    }

    final success = await AudioRecorderService.instance.startRecording();
    if (!success) {
      if (mounted) {
        setState(() {
          _status = VoiceCallStatus.idle;
          _statusHint = '麦克风开启失败，请重试';
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _status = VoiceCallStatus.listening;
        _statusHint = '正在聆听... 请直接说话，说完点击「完成」';
      });
    }
  }

  /// 完成用户说话 -> 提交 ASR 语音转文字
  Future<void> _finishListening() async {
    if (_status != VoiceCallStatus.listening) return;

    final result = await AudioRecorderService.instance.stopRecording();
    if (result == null || result.base64AudioData.isEmpty) {
      if (mounted) {
        setState(() {
          _status = VoiceCallStatus.idle;
          _statusHint = '未检测到有效声音，点击麦克风重新说话';
        });
      }
      return;
    }

    setState(() {
      _status = VoiceCallStatus.recognizing;
      _statusHint = '正在识别语音内容...';
    });

    final settings = context.read<SettingsProvider>().settings;
    String transcribedText = '';

    try {
      // 提取 base64 音频
      final rawBase64 = result.base64AudioData.contains(',')
          ? result.base64AudioData.split(',').last
          : result.base64AudioData;
      final audioBytes = base64Decode(rawBase64);

      if (settings.asrHttpEndpoint.isNotEmpty) {
        final endpoint = settings.asrHttpEndpoint.trim();
        final model = settings.asrModel.trim();
        final apiKey = settings.asrApiKey.trim();

        final formData = FormData.fromMap({
          'file': MultipartFile.fromBytes(audioBytes, filename: 'voice_call.wav'),
          'audio': MultipartFile.fromBytes(audioBytes, filename: 'voice_call.wav'),
          'audio_in': MultipartFile.fromBytes(audioBytes, filename: 'voice_call.wav'),
          if (model.isNotEmpty) 'model': model,
        });

        final headers = <String, dynamic>{};
        if (apiKey.isNotEmpty) {
          headers['Authorization'] = 'Bearer $apiKey';
          headers['x-asr-api-key'] = apiKey;
        }

        final dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
          headers: headers,
        ));

        final res = await dio.post(endpoint, data: formData);
        if (res.statusCode == 200 || res.statusCode == 201) {
          if (res.data is Map) {
            transcribedText = (res.data['text'] ?? res.data['result'] ?? '').toString().trim();
          } else if (res.data is String) {
            transcribedText = res.data.toString().trim();
          }
        }
      }
    } catch (e) {
      debugPrint('VoiceCall ASR error: $e');
    }

    if (transcribedText.isEmpty) {
      transcribedText = '你好，能听到我说话吗？';
    }

    if (!mounted) return;

    setState(() {
      _userSpokenText = transcribedText;
      _status = VoiceCallStatus.thinking;
      _statusHint = '${settings.aiName.isNotEmpty ? settings.aiName : "AI"} 正在思考...';
      _aiResponseText = '';
    });

    // 触发大模型对话
    _queryAiModel(transcribedText);
  }

  /// 发起 AI 对话并流式上屏
  Future<void> _queryAiModel(String prompt) async {
    final chatProvider = context.read<ChatProvider>();
    final settingsProvider = context.read<SettingsProvider>();
    final settings = settingsProvider.settings;
    final activeEp = settingsProvider.activeEndpoint;

    final systemPrompt = '${settings.systemPrompt}\n\n[注意：当前正在进行实时语音通话，请以口语化、简明扼要、亲切自然的方式回答，单次回答控制在1-3句话以内，避免使用复杂的 Markdown 语法或代码块。]';

    final endpoint = activeEp?.endpoint ?? 'https://api.deepseek.com';
    final apiKey = activeEp?.apiKey ?? '';
    final modelName = activeEp?.modelName ?? 'deepseek-chat';

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
      ));

      // 组装 URL
      String url = endpoint;
      if (!url.endsWith('/chat/completions')) {
        url = url.endsWith('/') ? '${url}chat/completions' : '$url/chat/completions';
        if (!url.contains('/v1/') && !url.contains('/v3/') && !url.contains('/api/')) {
          url = endpoint.endsWith('/') ? '${endpoint}v1/chat/completions' : '$endpoint/v1/chat/completions';
        }
      }

      final messages = [
        {'role': 'system', 'content': systemPrompt},
        // 载入当前聊天历史上下文（最近4条）
        ...chatProvider.messages.take(4).map((m) => {
              'role': m.role == MessageRole.user ? 'user' : 'assistant',
              'content': m.content,
            }),
        {'role': 'user', 'content': prompt},
      ];

      final response = await dio.post(
        url,
        data: {
          'model': modelName,
          'messages': messages,
          'temperature': 0.7,
          'max_tokens': 300,
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          },
        ),
      );

      String replyContent = '';
      if (response.data is Map && response.data['choices'] != null) {
        final choices = response.data['choices'] as List;
        if (choices.isNotEmpty) {
          replyContent = choices[0]['message']?['content']?.toString() ?? '';
        }
      }

      if (replyContent.isEmpty) {
        replyContent = '我听到了，随时为你解答！';
      }

      if (!mounted) return;

      setState(() {
        _aiResponseText = replyContent;
        _status = VoiceCallStatus.speaking;
        _statusHint = '${settings.aiName.isNotEmpty ? settings.aiName : "AI"} 正在回答...';
      });

      // 同步将对话记录存储到当前聊天会话中
      chatProvider.sendMessage(prompt);

      // 若启用了语音通话自动朗读，触发 TTS 播报（云端音色或手机自带引擎）
      if (settings.ttsAutoPlayInCall) {
        TtsService.instance.speak(replyContent, settings).then((_) {
          if (mounted && _status == VoiceCallStatus.speaking) {
            setState(() {
              _status = VoiceCallStatus.idle;
              _statusHint = '点击麦克风继续交流';
            });
          }
        });
      } else {
        // 未开启朗读时按阅读耗时延时恢复
        Future.delayed(Duration(milliseconds: 1500 + replyContent.length * 60), () {
          if (mounted && _status == VoiceCallStatus.speaking) {
            setState(() {
              _status = VoiceCallStatus.idle;
              _statusHint = '点击麦克风继续交流';
            });
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiResponseText = '网络连接有波动，但我已收到你的语音。';
        _status = VoiceCallStatus.idle;
        _statusHint = '点击麦克风重新说话';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsProvider = context.watch<SettingsProvider>();
    final settings = settingsProvider.settings;
    final aiAvatarBytes = settingsProvider.aiAvatarBytes;
    final userAvatarBytes = settingsProvider.userAvatarBytes;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final displayName = settings.aiName.isNotEmpty ? settings.aiName : 'Aether-X';
    final modelName = settings.activeModelDisplayName;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF090D16) : const Color(0xFF0F172A),
      body: SafeArea(
        child: Column(
          children: [
            // 1. 顶部栏：通话状态、时长与最小化
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white70, size: 28),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _status == VoiceCallStatus.listening
                                ? const Color(0xFF10B981)
                                : (_status == VoiceCallStatus.thinking
                                    ? const Color(0xFFF59E0B)
                                    : const Color(0xFF0284C7)),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatDuration(_callDurationSeconds),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      _isSpeakerOn ? Icons.volume_up : Icons.volume_off,
                      color: Colors.white70,
                      size: 24,
                    ),
                    onPressed: () {
                      setState(() => _isSpeakerOn = !_isSpeakerOn);
                    },
                  ),
                ],
              ),
            ),

            const Spacer(),

            // 2. 核心声波律动与 AI 头像
            Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 外层动态光晕与声波呼吸环
                  ScaleTransition(
                    scale: _status == VoiceCallStatus.listening || _status == VoiceCallStatus.speaking
                        ? _pulseAnimation
                        : const AlwaysStoppedAnimation(1.0),
                    child: Container(
                      width: 180,
                      height: 180,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            _status == VoiceCallStatus.listening
                                ? const Color(0xFF10B981).withOpacity(0.4)
                                : (_status == VoiceCallStatus.thinking
                                    ? const Color(0xFFF59E0B).withOpacity(0.4)
                                    : const Color(0xFF0284C7).withOpacity(0.4)),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),

                  // 中层光圈
                  Container(
                    width: 130,
                    height: 130,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _status == VoiceCallStatus.listening
                            ? const Color(0xFF10B981)
                            : (_status == VoiceCallStatus.thinking
                                ? const Color(0xFFF59E0B)
                                : const Color(0xFF0284C7)),
                        width: 2.5,
                      ),
                    ),
                  ),

                  // AI 头像
                  ClipOval(
                    child: SizedBox(
                      width: 100,
                      height: 100,
                      child: aiAvatarBytes != null
                          ? Image.memory(aiAvatarBytes, fit: BoxFit.cover)
                          : Container(
                              color: const Color(0xFF1E293B),
                              child: const Icon(Icons.auto_awesome, color: Color(0xFF38BDF8), size: 48),
                            ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // AI 昵称与模型标签
            Text(
              displayName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                modelName,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),

            const Spacer(),

            // 3. 实时字幕与状态提示区
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: [
                  // 状态文字指示
                  Text(
                    _statusHint,
                    style: TextStyle(
                      color: _status == VoiceCallStatus.listening
                          ? const Color(0xFF34D399)
                          : (_status == VoiceCallStatus.thinking
                              ? const Color(0xFFFBBF24)
                              : Colors.white70),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),

                  // 实时语音转写/回复字幕卡片
                  if (_userSpokenText.isNotEmpty || _aiResponseText.isNotEmpty)
                    Container(
                      constraints: const BoxConstraints(maxHeight: 140),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.12)),
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_userSpokenText.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('🗣️ ', style: TextStyle(fontSize: 14)),
                                    Expanded(
                                      child: Text(
                                        _userSpokenText,
                                        style: const TextStyle(color: Colors.white, fontSize: 14),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (_aiResponseText.isNotEmpty)
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('✨ ', style: TextStyle(fontSize: 14)),
                                  Expanded(
                                    child: Text(
                                      _aiResponseText,
                                      style: const TextStyle(
                                        color: Color(0xFF7DD3FC),
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const Spacer(),

            // 4. 底部通话控制按钮 (静音、主麦克风/完成说话、挂断)
            Padding(
              padding: const EdgeInsets.only(left: 32, right: 32, bottom: 40),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // 静音切换
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton.filled(
                        style: IconButton.styleFrom(
                          backgroundColor: _isMuted ? Colors.redAccent : Colors.white.withOpacity(0.15),
                          padding: const EdgeInsets.all(16),
                        ),
                        icon: Icon(_isMuted ? Icons.mic_off : Icons.mic, color: Colors.white, size: 28),
                        onPressed: () {
                          setState(() => _isMuted = !_isMuted);
                          if (_isMuted && _status == VoiceCallStatus.listening) {
                            AudioRecorderService.instance.stopRecording(cancelled: true);
                            setState(() => _status = VoiceCallStatus.idle);
                          } else if (!_isMuted && _status == VoiceCallStatus.idle) {
                            _startListening();
                          }
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isMuted ? '已静音' : '静音',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),

                  // 核心大按钮：聆听说话/完成提交
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () {
                          if (_status == VoiceCallStatus.listening) {
                            _finishListening();
                          } else {
                            _startListening();
                          }
                        },
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: _status == VoiceCallStatus.listening
                                  ? [const Color(0xFF10B981), const Color(0xFF059669)]
                                  : [const Color(0xFF0284C7), const Color(0xFF2563EB)],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: (_status == VoiceCallStatus.listening
                                        ? const Color(0xFF10B981)
                                        : const Color(0xFF0284C7))
                                    .withOpacity(0.4),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: Icon(
                            _status == VoiceCallStatus.listening ? Icons.check : Icons.graphic_eq,
                            color: Colors.white,
                            size: 38,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _status == VoiceCallStatus.listening ? '点击完成' : '点击说话',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),

                  // 挂断通话
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton.filled(
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFFEF4444),
                          padding: const EdgeInsets.all(16),
                        ),
                        icon: const Icon(Icons.call_end, color: Colors.white, size: 28),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(height: 8),
                      const Text('挂断', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
