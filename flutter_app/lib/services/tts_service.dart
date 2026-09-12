import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import '../models/app_settings.dart';
import 'storage_path_service.dart';

/// TTS 统一语音合成服务（支持手机系统原生离线 TTS 与云端大模型拟人 TTS 双轨降级）
class TtsService {
  static final TtsService instance = TtsService._internal();
  TtsService._internal();

  FlutterTts? _flutterTts;
  AudioPlayer? _audioPlayer;
  bool _isPlaying = false;
  bool _isInitialized = false;

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
          final tempFilePath = await StoragePathService.instance.generateFilePath(
            prefix: 'tts_output',
            extension: 'mp3',
          );
          final tempFile = File(tempFilePath);
          await tempFile.writeAsBytes(audioBytes);

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
  }

  /// 过滤 Markdown 标记与代码块，生成自然口语朗读文本
  String _cleanMarkdownForSpeech(String text) {
    String t = text;
    // 去除代码块 ```...```
    t = t.replaceAll(RegExp(r'```[\s\S]*?```'), ' [代码块省略] ');
    // 去除行内代码 `...`
    t = t.replaceAll(RegExp(r'`([^`]+)`'), r'$1');
    // 去除 Markdown 标题 #, ##, ###
    t = t.replaceAll(RegExp(r'#+\s*'), '');
    // 去除加粗/斜体 **text** or *text*
    t = t.replaceAll(RegExp(r'\*\*([^*]+)\*\*'), r'$1');
    t = t.replaceAll(RegExp(r'\*([^*]+)\*'), r'$1');
    // 去除链接 [text](url) -> text
    t = t.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1');
    // 去除多余空行
    t = t.replaceAll(RegExp(r'\n+'), '，');
    return t.trim();
  }
}
