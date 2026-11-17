import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import '../models/app_settings.dart';
import '../utils/http_client_helper.dart';

/// TTS 统一语音合成服务（支持手机系统原生离线 TTS 与云端大模型拟人 TTS 双轨降级）
class TtsService {
  static final TtsService instance = TtsService._internal();
  TtsService._internal();

  FlutterTts? _flutterTts;
  AudioPlayer? _audioPlayer;
  bool _isPlaying = false;
  bool _isInitialized = false;

  /// 当前云端 TTS 写入磁盘的临时 mp3（播放需要文件存在，stop() 时清掉）
  File? _currentTtsFile;

  bool get isPlaying => _isPlaying;

  /// 初始化系统 TTS 引擎
  Future<void> init() async {
    if (_isInitialized) return;
    try {
      _flutterTts = FlutterTts();
      _audioPlayer = AudioPlayer();

      // 设置系统 TTS 默认语系
      await _flutterTts?.setLanguage("zh-CN");
      await _flutterTts?.setSpeechRate(0.5); // flutter_tts 0.5 为标准语速
      await _flutterTts?.setVolume(1.0);
      await _flutterTts?.setPitch(1.0);

      _flutterTts?.setStartHandler(() {
        _isPlaying = true;
      });

      _flutterTts?.setCompletionHandler(() {
        _isPlaying = false;
      });

      _flutterTts?.setErrorHandler((msg) {
        debugPrint('FlutterTts error: $msg');
        _isPlaying = false;
      });

      _audioPlayer?.onPlayerComplete.listen((_) {
        _isPlaying = false;
      });

      _isInitialized = true;
    } catch (e) {
      debugPrint('TtsService init error: $e');
    }
  }

  /// 朗读文本（自动依据 settings 决定使用云端音色还是系统自带语音）
  Future<bool> speak(String text, AppSettings settings) async {
    final cleanText = _cleanMarkdownForSpeech(text);
    if (cleanText.isEmpty) return false;

    await init();
    await stop();

    // 1. 若配置了云端 TTS 且有有效接口 -> 尝试云端合成
    if (settings.ttsEngine == 'cloud' && settings.ttsHttpEndpoint.isNotEmpty) {
      final success = await _speakViaCloud(cleanText, settings);
      if (success) return true;
      debugPrint('Cloud TTS failed, falling back to System TTS...');
    }

    // 2. 兜底回退：使用手机系统自带语音引擎
    return await _speakViaSystem(cleanText, settings);
  }

  /// 使用手机自带系统引擎朗读
  Future<bool> _speakViaSystem(String text, AppSettings settings) async {
    try {
      if (_flutterTts == null) return false;

      // 语速映射：app 1.0 -> flutter_tts 0.5
      final rate = (settings.ttsSpeed * 0.5).clamp(0.1, 1.0);
      final pitch = settings.ttsPitch.clamp(0.5, 2.0);

      await _flutterTts?.setLanguage("zh-CN");
      await _flutterTts?.setSpeechRate(rate);
      await _flutterTts?.setPitch(pitch);
      await _flutterTts?.setVolume(1.0);

      _isPlaying = true;
      final result = await _flutterTts?.speak(text);
      return result == 1;
    } catch (e) {
      debugPrint('System TTS speak error: $e');
      _isPlaying = false;
      return false;
    }
  }

  /// 通过云端大模型接口合成并播放音频
  Future<bool> _speakViaCloud(String text, AppSettings settings) async {
    try {
      final endpoint = settings.ttsHttpEndpoint.trim();
      final model = settings.ttsModel.trim();
      final voice = settings.ttsVoice.trim();
      final apiKey = settings.ttsApiKey.trim();

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 20),
        responseType: ResponseType.bytes,
      ));
      HttpClientHelper.configureProxy(dio);

      final headers = <String, dynamic>{
        'Content-Type': 'application/json',
      };
      if (apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer $apiKey';
      }

      final body = {
        if (model.isNotEmpty) 'model': model,
        'input': text,
        'voice': voice.isNotEmpty ? voice : 'alloy',
        'speed': settings.ttsSpeed,
        'response_format': 'mp3',
      };

      final response = await dio.post(
        endpoint,
        data: body,
        options: Options(headers: headers),
      );

      if (response.statusCode == 200 && response.data != null) {
        final Uint8List audioBytes = response.data is Uint8List
            ? response.data as Uint8List
            : Uint8List.fromList(response.data as List<int>);

        if (audioBytes.isNotEmpty && _audioPlayer != null) {
          // 朗读输出固定写 App 私有临时目录，**不走 StoragePathService** ——
          // 那条路的根目录用户能改成公共目录（如 /sdcard/Music），
          // 文件就会出现在系统文件管理器/音乐库里（同待办 #23）。
          // 播放期间文件必须存在，所以这里不立即删，交给 stop()。
          final tempDir = await getTemporaryDirectory();
          final tempFilePath =
              '${tempDir.path}/tts_output_${DateTime.now().millisecondsSinceEpoch}.mp3';
          final tempFile = File(tempFilePath);
          await tempFile.writeAsBytes(audioBytes);
          _currentTtsFile = tempFile;

          _isPlaying = true;
          await _audioPlayer?.play(DeviceFileSource(tempFile.path));
          return true;
        }
      }
    } catch (e) {
      debugPrint('Cloud TTS request failed: $e');
    }
    return false;
  }

  /// 停止当前正在播放的朗读
  Future<void> stop() async {
    try {
      _isPlaying = false;
      await _flutterTts?.stop();
      await _audioPlayer?.stop();
    } catch (_) {}
    // 停了才删：云端 TTS 的 mp3 只是播放中转，留着会在缓存目录里堆垃圾。
    try {
      await _currentTtsFile?.delete();
    } catch (_) {}
    _currentTtsFile = null;
  }

  /// 过滤 Markdown 标记与代码块，生成自然口语朗读文本
  String _cleanMarkdownForSpeech(String text) {
    /**
     * ⚠️ 2026-11-18：整体兜底 try/catch。
     *
     * 教训：上一版在这里用了 `(?m)` 内联标志写正则，而 **Dart 的 RegExp 不支持它**
     * （只认 `multiLine: true` 命名参数）—— 于是每次朗读都抛
     * `FormatException: Invalid group`。这个异常从 `speak()` 一路冒到调用方，
     * 把 `await` 打断，UI 永久停在「正在播报试听」，两端都表现为「没声音、
     * 也不报错」，查了很久才落到这里。
     *
     * 清理失败本身不该让整条朗读失败 —— 原文直接拿去念，最坏是念出几个符号，
     * 也比彻底没声、界面卡死强。
     */
    try {
      return _doCleanMarkdownForSpeech(text);
    } catch (e) {
      debugPrint('[Tts] 清理 Markdown 失败，退回原文: $e');
      return text.trim();
    }
  }

  String _doCleanMarkdownForSpeech(String text) {
    String t = text;
    // 去除代码块 ```...```
    t = t.replaceAll(RegExp(r'```[\s\S]*?```'), ' [代码块省略] ');
    // 去除行内代码 `...`
    t = t.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m[1] ?? '');
    // 去除 Markdown 标题 #, ##, ###
    t = t.replaceAll(RegExp(r'#+\s*'), '');
    // 去除加粗/斜体 **text** or *text*
    t = t.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => m[1] ?? '');
    t = t.replaceAllMapped(RegExp(r'\*([^*]+)\*'), (m) => m[1] ?? '');
    // 去除链接 [text](url) -> text
    t = t.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1] ?? '');
    // 列表符号 / 引用符 / 分隔线 / 表格竖线 —— 这些也会被逐字朗读出来
    t = t.replaceAll(RegExp(r'^[ \t]{0,3}[-*+][ \t]+', multiLine: true), '');
    t = t.replaceAll(RegExp(r'^[ \t]{0,3}>[ \t]?', multiLine: true), '');
    // ⚠️ 2026-11-18：分隔线清理踩了两个坑，都记在这儿别再犯：
    //
    // ① 最初写成 `^\s*([-*_])\s*\1\s*\1[\s\-*_]*$` —— 三个 `\s*` 叠加，
    //    回溯爆炸。
    // ② 改成 `^\s*(?:-{3,}|...)\s*$` 之后仍然慢（3000 个连续空行耗时 **1085 ms**）。
    //    真凶是 **`\s` 匹配换行符** —— `^\s*` 会把后续所有空行一起吃掉、
    //    然后失败回溯，每个行首重试一遍，复杂度 O(n²)。
    //
    // 现在一律用 `[ \t]`（**不含换行**），只在本行内匹配。
    t = t.replaceAll(RegExp(r'^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$', multiLine: true), '');
    t = t.replaceAll('|', '，');
    // 去除多余空行
    t = t.replaceAll(RegExp(r'\n+'), '，');
    return t.trim();
  }
}
