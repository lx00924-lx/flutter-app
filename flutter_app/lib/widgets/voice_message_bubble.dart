import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

/// 聊天语音气泡组件：支持播放、暂停、进度与时长展示
class VoiceMessageBubble extends StatefulWidget {
  final String audioDataUri;
  final bool isUser;
  final int? fallbackDuration;

  /// 裸模式：**不画自己的底色**，内容用蓝色系，供「纯语音消息」使用。
  ///
  /// 纯语音消息外层已经不套气泡了（见 `message_bubble.dart` 的 `hasVoiceOnly`），
  /// 这一层再画一个半透明底就变成"没有气泡、却有一块莫名其妙的色块"。
  /// 混合消息（语音 + 文字）仍然走正常模式 —— 那时底色是配给文字的。
  final bool bare;

  const VoiceMessageBubble({
    super.key,
    required this.audioDataUri,
    required this.isUser,
    this.fallbackDuration,
    this.bare = false,
  });

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  String? _tempFilePath;

  @override
  void initState() {
    super.initState();
    _parseDurationFromUri();
    _initPlayer();
  }

  void _parseDurationFromUri() {
    try {
      if (widget.audioDataUri.contains('duration=')) {
        final match = RegExp(r'duration=(\d+)').firstMatch(widget.audioDataUri);
        if (match != null) {
          final sec = int.tryParse(match.group(1) ?? '0') ?? 0;
          if (sec > 0) {
            _duration = Duration(seconds: sec);
          }
        }
      } else if (widget.fallbackDuration != null && widget.fallbackDuration! > 0) {
        _duration = Duration(seconds: widget.fallbackDuration!);
      }
    } catch (_) {}
  }

  Future<void> _initPlayer() async {
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _playerState = state);
      }
    });

    _audioPlayer.onDurationChanged.listen((d) {
      if (mounted && d.inSeconds > 0) {
        setState(() => _duration = d);
      }
    });

    _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) {
        setState(() => _position = p);
      }
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playerState = PlayerState.stopped;
          _position = Duration.zero;
        });
      }
    });
  }

  Future<String?> _prepareFile() async {
    if (_tempFilePath != null) return _tempFilePath;
    try {
      String cleanBase64 = widget.audioDataUri;
      if (cleanBase64.contains(',')) {
        cleanBase64 = cleanBase64.split(',').last;
      }
      cleanBase64 = cleanBase64.replaceAll('\n', '').replaceAll('\r', '').replaceAll(' ', '');
      final bytes = base64Decode(cleanBase64);

      final tempDir = await getTemporaryDirectory();
      final hash = bytes.lengthInBytes ^ widget.audioDataUri.hashCode;
      final file = File('${tempDir.path}/play_voice_$hash.m4a');
      if (!await file.exists()) {
        await file.writeAsBytes(bytes);
      }
      _tempFilePath = file.path;
      return _tempFilePath;
    } catch (e) {
      debugPrint('VoiceMessageBubble prepareFile failed: $e');
      return null;
    }
  }

  Future<void> _togglePlay() async {
    try {
      if (_playerState == PlayerState.playing) {
        await _audioPlayer.pause();
      } else {
        final path = await _prepareFile();
        if (path != null) {
          await _audioPlayer.play(DeviceFileSource(path));
        }
      }
    } catch (e) {
      debugPrint('togglePlay error: $e');
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = _playerState == PlayerState.playing;
    final totalSec = _duration.inSeconds > 0 ? _duration.inSeconds : (widget.fallbackDuration ?? 1);
    // ⚠️ 不能按屏幕宽度算长度：Windows 上 1920 × 0.7 = 1344px，一条几秒的语音能横跨半个窗口。
    //    改成按秒数线性增长、再夹进固定区间 —— 手机和桌面看起来差不多长。
    final bubbleWidth = (180.0 + totalSec * 6.0).clamp(220.0, 420.0);

    // 裸模式下没有底色了，白图标会消失在浅色背景上 —— 统一改用蓝色系。
    final primaryColor = widget.bare
        ? const Color(0xFF0284C7)
        : (widget.isUser ? Colors.white : const Color(0xFF0284C7));
    final secColor = widget.bare
        ? const Color(0xFF64748B)
        : (widget.isUser ? Colors.white.withOpacity(0.8) : const Color(0xFF64748B));

    return InkWell(
      onTap: _togglePlay,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: bubbleWidth,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        // ⚠️ 裸模式**也要底色**：用户 2026-11-16 明确「去掉的是气泡框，语音条自己的底要留着」。
        //    外层气泡没了，语音条就得自己有一块可见的底，否则图标和声波在浅色背景上像漂着。
        //    但不能沿用「半透明白」—— 那个是给蓝气泡配的，脱离蓝底会完全看不见，裸模式改用淡蓝。
        decoration: BoxDecoration(
          color: widget.bare
              ? const Color(0xFF0284C7).withOpacity(0.10)
              : (widget.isUser
                  ? Colors.white.withOpacity(0.18)
                  : const Color(0xFF0284C7).withOpacity(0.08)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
              color: primaryColor,
              size: 26,
            ),
            const SizedBox(width: 8),
            // 声波条动画 / 静态指示
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(12, (index) {
                  final h = ((index % 4) + 2) * 3.5;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 3,
                    height: isPlaying ? ((index % 3 + 1) * 5.0) : h,
                    decoration: BoxDecoration(
                      color: primaryColor.withOpacity(index < 6 ? 0.9 : 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$totalSec"',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: secColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
