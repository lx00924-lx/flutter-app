import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'storage_path_service.dart';

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
        debugPrint('Microphone permission denied');
        return false;
      }

      // 准备录音输出路径（优先使用用户在资源管理器中自定义指定的目录）
      final filePath = await StoragePathService.instance.generateFilePath(
        prefix: 'audio_msg',
        extension: 'm4a',
      );
      _currentRecordingPath = filePath;

      const config = RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 44100,
        bitRate: 64000,
      );

      await recorder.start(config, path: filePath);
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
