import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import '../screens/log_console_screen.dart';

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
  State<VoiceMessageBubble> createState() => VoiceMessageBubbleState();
}

class VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  Duration _duration = Duration.zero;
  /// 播放进度。⚠️ 这个字段之前就存在，但**从来没被读过** —— 声波一直是 12 根静态柱子，
  /// 播放到哪完全看不出来（analyze 那条 unused_field 报的就是这个「设计上有、实际没用」）。
  /// 用户 2026-11-16 明确要「把进度条加回来」，现在按 _position / _duration 给柱子上色。
  Duration _position = Duration.zero;
  /// ⚠️ 播放不再落盘（见 `_decodeBytes`），所以这个"临时文件路径"字段已经没用了。
  ///    保留一行注释是为了说明它为什么消失，避免以后有人又加回来。

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

    // 播放进度：驱动声波柱子的明暗，这就是「进度条」。
    // 只在播放中重建（暂停/停止时位置不会变，没必要刷）。
    _audioPlayer.onPositionChanged.listen((p) {
      if (mounted && _playerState == PlayerState.playing) {
        setState(() => _position = p);
      }
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playerState = PlayerState.stopped;
          // 播完把进度停在末尾（柱子保持全亮），下次点播放时才归零 ——
          // 否则刚播完就整条暗回去，看起来像"没播成功"。
          _position = _duration;
        });
      }
    });
  }

  /// 解出音频字节，**不落盘**。
  ///
  /// 为什么不再写临时文件（用户 2026-11-16 要求「把缓存搬回来」）：
  /// 桌面端的缓存根是 `...\LxAI Team\LxAI\cache`，**路径里带空格**，而 audioplayers
  /// 的 Windows 后端走 Media Foundation，处理不了含空格的路径 —— 实测同一个 m4a
  /// 放 %TEMP% 能播、放缓存目录就彻底无声（而且失败被 catch 吞掉，点了没反应）。
  ///
  /// 上一版的办法是把播放副本挪到 `%TEMP%\lxai_voice\` 绕开空格，能播了，但那是
  /// **排查用的临时手段**：它跑到了用户的缓存目录之外、没人清理、统计也统计不到。
  /// 现在改成把字节直接喂给播放器（BytesSource），压根不产生文件 ——
  /// 空格问题不存在了，也不用再选"放哪儿"。
  Uint8List? _decodeBytes() {
    try {
      var b64 = widget.audioDataUri;
      if (b64.contains(',')) {
        b64 = b64.split(',').last;
      }
      // base64 里可能混进换行/空格（过长时会被折行），先剔干净
      b64 = b64.replaceAll(RegExp(r'\s'), '');
      return base64Decode(b64);
    } catch (e) {
      // 解不开就是数据坏了，必须说出来，不能静默
      debugPrint('VoiceMessageBubble decode failed: $e');
      AppLogger.instance.log('ERROR', 'Voice', '语音解码失败: $e');
      return null;
    }
  }

  Future<void> _togglePlay() async {
    try {
      if (_playerState == PlayerState.playing) {
        await _audioPlayer.pause();
      } else {
        final bytes = _decodeBytes();
        if (bytes == null) {
          if (mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(
                content: Text('这条语音的数据坏了，播不了'),
                duration: Duration(seconds: 4),
              ),
            );
          }
          return;
        }
        // 从「停止」状态开播时进度归零；从「暂停」恢复则保持原位置 ——
        // 否则暂停一下再继续，进度条会跳回开头。
        if (_playerState != PlayerState.paused) {
          setState(() => _position = Duration.zero);
        }
        await _audioPlayer.play(BytesSource(bytes));
      }
    } catch (e) {
      // ⚠️ 这里以前只有一句 debugPrint —— 播放失败时界面**毫无反应**，
      //    用户点一下、没声音、也没提示，只能以为「点了没用」。
      //    按「坏的链路不许假装自己是好的」：失败必须写进日志页 + 当场告诉用户。
      debugPrint('togglePlay error: $e');
      AppLogger.instance.log('ERROR', 'Voice', '语音播放失败: $e');
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('语音播放失败：$e'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  /// 从头重播 —— 给长按菜单的「重新播放」用（用户 2026-11-16 要的）。
  ///
  /// 为此把 State 类从 `_VoiceMessageBubbleState` 改成了公开的 `VoiceMessageBubbleState`：
  /// 长按菜单在 `message_bubble.dart` 里，只能通过 `GlobalKey<VoiceMessageBubbleState>`
  /// 拿到它、调这个公开方法。私有类名外部根本引用不了。
  Future<void> replay() async {
    try {
      await _audioPlayer.stop();
      if (mounted) {
        setState(() {
          _position = Duration.zero;
          _playerState = PlayerState.stopped;
        });
      }
      // 字节每次现解，不落盘也就没有缓存文件要复用
      final bytes = _decodeBytes();
      if (bytes != null) {
        await _audioPlayer.play(BytesSource(bytes));
      }
    } catch (e) {
      debugPrint('replay error: $e');
      AppLogger.instance.log('ERROR', 'Voice', '语音重新播放失败: $e');
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('语音重新播放失败：$e'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
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
    // 播放进度 0~1，驱动声波柱子的明暗 —— 这就是用户要的「进度条」。
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    // ⚠️ 宽度**固定 200**，不再随秒数变（用户 2026-11-16 定：长度固定就好）。
    //    之前是 `屏幕宽 × 百分比`，Windows 上能到 1344px；后来改成按秒数增长，还是「每条不一样长」。
    //    固定之后 2 秒和 40 秒长得一样，列表看起来才是整齐的一列而不是参差。
    const bubbleWidth = 200.0;

    // 裸模式（纯语音消息）：底色用「用户文字气泡」那个蓝 #0284C7，图标/声波/秒数全部走白。
    // 这是用户 2026-11-16 亲自从八套里挑的（F），理由是「蓝底白字最醒目」。
    // 混合消息（语音+转写文字）仍然留在气泡里、走原来的淡色小条 ——
    // 那种情况外层已经有气泡底了，里面再来一块实蓝就成双层蓝。
    final primaryColor = widget.bare
        ? Colors.white
        : (widget.isUser ? Colors.white : const Color(0xFF0284C7));
    final secColor = widget.bare
        ? Colors.white.withOpacity(0.85)
        : (widget.isUser ? Colors.white.withOpacity(0.8) : const Color(0xFF64748B));

    return InkWell(
      onTap: _togglePlay,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: bubbleWidth,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        // 裸模式 = 用户文字气泡同款实蓝（#0284C7），白图标白声波（用户 2026-11-16 选的 F）。
        // 深色主题下不另调：这个蓝在深底上更亮，反而更清楚，不需要两套。
        decoration: BoxDecoration(
          color: widget.bare
              ? const Color(0xFF0284C7)
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
            // 声波条 + **跟随进度的竖线**（用户 2026-11-16 要的，之前确实有过这么一条）。
            //
            // ⚠️ 竖线的移动**必须走 Transform.translate**，不能改 Positioned.left / Container.width：
            //    改 left/width 每次都要重新 layout 整条声波（这正是 2026-10-18 那次
            //    「进度条一直闪、掉帧」的根因，当时换成 clip-path 才压到 60fps）。
            //    Transform 只更新变换矩阵，走合成层，不重排、不重绘子树。
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final waveW = constraints.maxWidth;
                  return Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: List.generate(20, (index) {
                          // 20 根（原来是 12）—— 用户 2026-11-16：柱子多一点才跟竖线配得上。
                          // 宽度 3→2px，20 根塞进约 114px 的声波区仍然有余量。
                          final h = ((index % 5) + 2) * 2.8;
                          // 这根柱子有没有被竖线走过：看它中心点在不在进度左侧
                          final playedHere =
                              progress > 0 && (index + 0.5) / 20 <= progress;
                          final opacity = progress <= 0
                              ? 0.55                          // 还没播：整条压暗
                              : (playedHere ? 1.0 : 0.28);    // 已播亮、未播暗
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 110),
                            width: 2,
                            height: isPlaying ? ((index % 4 + 1) * 4.0) : h,
                            decoration: BoxDecoration(
                              color: primaryColor.withOpacity(opacity),
                              borderRadius: BorderRadius.circular(1),
                            ),
                          );
                        }),
                      ),
                      // 播放位置竖线：没开始播时钉在最左边
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Transform.translate(
                          offset: Offset((waveW * progress).clamp(0.0, waveW) - 1, 0),
                          child: Container(
                            width: 2,
                            height: 20,
                            decoration: BoxDecoration(
                              color: primaryColor,
                              borderRadius: BorderRadius.circular(1),
                              boxShadow: [
                                BoxShadow(
                                  color: primaryColor.withOpacity(0.45),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
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
