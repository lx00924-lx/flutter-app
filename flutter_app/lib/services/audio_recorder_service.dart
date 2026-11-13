import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 录音完成后的结果对象
class AudioRecordResult {
  final String path;
  final int durationSeconds;
  final String base64AudioData;

  AudioRecordResult({
    required this.path,
    required this.durationSeconds,
    required this.base64AudioData,
  });
}

/// 录音硬件控制与音频编码服务
class AudioRecorderService {
  static final AudioRecorderService instance = AudioRecorderService._internal();
  AudioRecorderService._internal();

  AudioRecorder? _audioRecorder;
  bool _isRecording = false;
  DateTime? _recordStartTime;
  String? _currentRecordingPath;

  bool get isRecording => _isRecording;

  /// 初始化录音器
  AudioRecorder _getRecorder() {
    _audioRecorder ??= AudioRecorder();
    return _audioRecorder!;
  }

  /// 检查并请求麦克风权限
  Future<bool> hasPermission() async {
    try {
      final recorder = _getRecorder();
      return await recorder.hasPermission();
    } catch (e) {
      debugPrint('hasPermission error: $e');
      return false;
    }
  }

  /// 开始录音
  Future<bool> startRecording() async {
    try {
      final recorder = _getRecorder();
      final hasPerm = await recorder.hasPermission();
      if (!hasPerm) {
        debugPrint('Microphone permission denied or not granted yet');
        return false;
      }

      // ⚠️ 录音文件**固定写 App 私有临时目录**，不走 StoragePathService（待办 #23）。
      //    那条路是给「原图持久化」用的，用户能把根目录改到公共目录（如 /sdcard/Music），
      //    一旦改了，录音文件就会出现在系统文件管理器 / 音乐库里。
      //    语音内容以 base64 存在消息体中，磁盘副本只是录制→上传的临时中转，
      //    删掉它不影响本机重复播放（走消息里那份），也不影响另一台试听。
      final tempDir = await getTemporaryDirectory();
      final now = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${tempDir.path}/audio_msg_$now.m4a';

      final targetFile = File(filePath);
      if (!targetFile.parent.existsSync()) {
        await targetFile.parent.create(recursive: true);
      }

      _currentRecordingPath = filePath;

      // 尝试标准 AAC 编码录制
      try {
        const config = RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 44100,
          bitRate: 64000,
          numChannels: 1,
        );
        await recorder.start(config, path: filePath);
      } catch (encodeErr) {
        debugPrint('AAC recording start failed, fallback to default config: $encodeErr');
        // 降级尝试默认编码器配置
        const fallbackConfig = RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 16000,
          numChannels: 1,
        );
        await recorder.start(fallbackConfig, path: filePath);
      }

      _isRecording = true;
      _recordStartTime = DateTime.now();
      return true;
    } catch (e) {
      debugPrint('startRecording failed: $e');
      _isRecording = false;
      return false;
    }
  }

  /// 停止录音并返回音频数据
  Future<AudioRecordResult?> stopRecording({bool cancelled = false}) async {
    if (!_isRecording) return null;
    try {
      final recorder = _getRecorder();
      final path = await recorder.stop();
      _isRecording = false;

      final durationSec = _recordStartTime != null
          ? DateTime.now().difference(_recordStartTime!).inSeconds
          : 0;

      if (cancelled) {
        if (path != null) {
          final file = File(path);
          if (await file.exists()) {
            await file.delete();
          }
        }
        return null;
      }

      final actualPath = path ?? _currentRecordingPath;
      if (actualPath == null) return null;

      final file = File(actualPath);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;

      // 读完立刻删掉磁盘副本（待办 #23「发完即删」）：语音内容已经在下面的 base64 里，
      // 播放和跨端同步都走消息体那一份 —— 本地文件留着只会在缓存目录里堆垃圾。
      // 注意 AudioRecordResult.path 目前没有任何调用方在用，所以删了不影响播放。
      try {
        await file.delete();
      } catch (_) {}

      final base64String = base64Encode(bytes);
      final finalDuration = durationSec < 1 ? 1 : durationSec;
      final dataUri = 'data:audio/m4a;duration=$finalDuration;base64,$base64String';

      return AudioRecordResult(
        path: actualPath,
        durationSeconds: finalDuration,
        base64AudioData: dataUri,
      );
    } catch (e) {
      debugPrint('stopRecording failed: $e');
      _isRecording = false;
      return null;
    }
  }

  /// 取消当前录音
  Future<void> cancelRecording() async {
    await stopRecording(cancelled: true);
  }

  /// 释放录音器资源
  Future<void> dispose() async {
    if (_audioRecorder != null) {
      try {
        await _audioRecorder!.dispose();
      } catch (_) {}
      _audioRecorder = null;
    }
  }
}
