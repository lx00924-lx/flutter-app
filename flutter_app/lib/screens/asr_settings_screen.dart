import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../providers/settings_provider.dart';

class AsrSettingsScreen extends StatefulWidget {
  const AsrSettingsScreen({super.key});

  @override
  State<AsrSettingsScreen> createState() => _AsrSettingsScreenState();
}

class _AsrSettingsScreenState extends State<AsrSettingsScreen> {
  late TextEditingController _httpCtrl;
  late TextEditingController _wsCtrl;
  late TextEditingController _modelCtrl;
  late TextEditingController _keyCtrl;

  bool _isTestingHttp = false;
  bool _isTestingWs = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<SettingsProvider>().settings;
    _httpCtrl = TextEditingController(text: s.asrHttpEndpoint);
    _wsCtrl = TextEditingController(text: s.asrWsEndpoint);
    _modelCtrl = TextEditingController(text: s.asrModel);
    _keyCtrl = TextEditingController(text: s.asrApiKey);

    _httpCtrl.addListener(() {
      final sp = context.read<SettingsProvider>();
      sp.settings.asrHttpEndpoint = _httpCtrl.text.trim();
      sp.updateSettings(sp.settings);
    });

    _wsCtrl.addListener(() {
      final sp = context.read<SettingsProvider>();
      sp.settings.asrWsEndpoint = _wsCtrl.text.trim();
      sp.updateSettings(sp.settings);
    });

    _modelCtrl.addListener(() {
      final sp = context.read<SettingsProvider>();
      sp.settings.asrModel = _modelCtrl.text.trim();
      sp.updateSettings(sp.settings);
    });

    _keyCtrl.addListener(() {
      final sp = context.read<SettingsProvider>();
      sp.settings.asrApiKey = _keyCtrl.text.trim();
      sp.updateSettings(sp.settings);
    });
  }

  @override
  void dispose() {
    _httpCtrl.dispose();
    _wsCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  void _applyPreset(String name) {
    if (name == 'siliconflow') {
      _httpCtrl.text = 'https://api.siliconflow.cn/v1/audio/transcriptions';
      _modelCtrl.text = 'FunAudioLLM/SenseVoiceSmall';
    } else if (name == 'groq') {
      _httpCtrl.text = 'https://api.groq.com/openai/v1/audio/transcriptions';
      _modelCtrl.text = 'whisper-large-v3';
    } else if (name == 'openai') {
      _httpCtrl.text = 'https://api.openai.com/v1/audio/transcriptions';
      _modelCtrl.text = 'whisper-1';
    } else if (name == 'aliyun') {
      _httpCtrl.text = 'https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription';
      _modelCtrl.text = 'sensevoice-v1';
    } else if (name == 'funasr') {
      _httpCtrl.text = 'http://127.0.0.1:10095';
      _wsCtrl.text = 'ws://127.0.0.1:10095';
      _modelCtrl.text = 'damo/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-pytorch';
    }
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已应用 $name 快捷预设配置')),
    );
  }

  void _save() {
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    s.asrHttpEndpoint = _httpCtrl.text.trim();
    s.asrWsEndpoint = _wsCtrl.text.trim();
    s.asrModel = _modelCtrl.text.trim();
    s.asrApiKey = _keyCtrl.text.trim();
    sp.updateSettings(s);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('语音转写设置已保存')),
    );
  }

  Uint8List _createSilentWav() {
    // 构造合法的 16kHz 16位 单声道 0.1秒 静音 WAV
    const sampleRate = 16000;
    const numChannels = 1;
    const bitsPerSample = 16;
    const numSamples = 1600;
    const dataSize = numSamples * numChannels * (bitsPerSample ~/ 8);
    final totalSize = 36 + dataSize;

    final bytes = ByteData(44 + dataSize);
    // "RIFF"
    bytes.setUint8(0, 0x52); bytes.setUint8(1, 0x49); bytes.setUint8(2, 0x46); bytes.setUint8(3, 0x46);
    bytes.setUint32(4, totalSize, Endian.little);
    // "WAVE"
    bytes.setUint8(8, 0x57); bytes.setUint8(9, 0x41); bytes.setUint8(10, 0x56); bytes.setUint8(11, 0x45);
    // "fmt "
    bytes.setUint8(12, 0x66); bytes.setUint8(13, 0x6D); bytes.setUint8(14, 0x74); bytes.setUint8(15, 0x20);
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, numChannels, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * numChannels * (bitsPerSample ~/ 8), Endian.little);
    bytes.setUint16(32, numChannels * (bitsPerSample ~/ 8), Endian.little);
    bytes.setUint16(34, bitsPerSample, Endian.little);
    // "data"
    bytes.setUint8(36, 0x64); bytes.setUint8(37, 0x61); bytes.setUint8(38, 0x74); bytes.setUint8(39, 0x61);
    bytes.setUint32(40, dataSize, Endian.little);

    return bytes.buffer.asUint8List();
  }

  Future<void> _testHttp() async {
    final endpoint = _httpCtrl.text.trim();
    if (endpoint.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先输入转写 HTTP 接口地址')),
      );
      return;
    }

    setState(() => _isTestingHttp = true);
    final stopwatch = Stopwatch()..start();

    try {
      final wavBytes = _createSilentWav();
      final model = _modelCtrl.text.trim();
      final apiKey = _keyCtrl.text.trim();

      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(wavBytes, filename: 'test.wav'),
        'audio': MultipartFile.fromBytes(wavBytes, filename: 'test.wav'),
        'audio_in': MultipartFile.fromBytes(wavBytes, filename: 'test.wav'),
        if (model.isNotEmpty) 'model': model,
      });

      final headers = <String, dynamic>{};
      if (apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer $apiKey';
        headers['x-asr-api-key'] = apiKey;
      }

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 15),
        headers: headers,
      ));

      final res = await dio.post(endpoint, data: formData);
      final ms = stopwatch.elapsedMilliseconds;

      if (!mounted) return;

      if (res.statusCode == 200 || res.statusCode == 201) {
        final data = res.data;
        String previewText = '';
        if (data is Map) {
          previewText = (data['text'] ?? data['result'] ?? '').toString();
        } else if (data is String) {
          previewText = data.length > 50 ? data.substring(0, 50) : data;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('连接成功：语音转写接口连通正常 (耗时 ${ms}ms)${previewText.isNotEmpty ? " [返回: $previewText]" : ""}'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('服务返回异常状态码: ${res.statusCode}'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } on DioException catch (e) {
      if (!mounted) return;
      String errHint = '请求失败';
      if (e.response != null) {
        final code = e.response!.statusCode;
        if (code == 401 || code == 403) {
          errHint = '鉴权失败 (HTTP $code)：API Key 无效或未授权';
        } else if (code == 404) {
          errHint = '接口不存在 (HTTP 404)：请检查接口 URL 是否正确';
        } else {
          final resData = e.response?.data;
          errHint = '服务端返回错误 (HTTP $code): ${resData is Map ? (resData['error'] ?? resData['message'] ?? code) : code}';
        }
      } else if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.receiveTimeout) {
        errHint = '连接超时：请检查服务地址是否可达及网络通畅度';
      } else if (e.type == DioExceptionType.connectionError) {
        errHint = '连接失败：无法访问该 IP/端口 (Connection Refused 或网络不可达)';
      } else {
        errHint = '网络异常: ${e.message ?? e.toString()}';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errHint),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('测试异常: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _isTestingHttp = false);
    }
  }

  Future<void> _testWs() async {
    final wsUrl = _wsCtrl.text.trim();
    if (wsUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先输入实时流 WS 端点地址')),
      );
      return;
    }

    setState(() => _isTestingWs = true);
    final stopwatch = Stopwatch()..start();

    try {
      final uri = Uri.parse(wsUrl);
      final channel = WebSocketChannel.connect(uri);
      await channel.ready.timeout(const Duration(seconds: 6));
      final ms = stopwatch.elapsedMilliseconds;
      await channel.sink.close();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('连接成功：实时流 WebSocket 已建立双向握手 (耗时 ${ms}ms)'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      String errMsg = e.toString();
      if (errMsg.contains('TimeoutException')) {
        errMsg = 'WebSocket 握手超时 (6s)，请检查端口是否开放及地址';
      } else if (errMsg.contains('Connection refused') || errMsg.contains('Failed host lookup')) {
        errMsg = '无法连接到 WebSocket 服务器 (拒绝连接或域名无法解析)';
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('实时流连接失败：$errMsg'),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _isTestingWs = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('语音转写设置 (ASR)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '保存',
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('常用商用服务商快捷预设', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.bolt, size: 16, color: Colors.orange),
                        label: const Text('硅基流动 SenseVoice'),
                        onPressed: () => _applyPreset('siliconflow'),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.rocket_launch, size: 16, color: Colors.purple),
                        label: const Text('Groq Whisper'),
                        onPressed: () => _applyPreset('groq'),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.language, size: 16, color: Colors.green),
                        label: const Text('OpenAI Whisper'),
                        onPressed: () => _applyPreset('openai'),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.cloud_outlined, size: 16, color: Colors.blue),
                        label: const Text('阿里百炼'),
                        onPressed: () => _applyPreset('aliyun'),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.developer_board, size: 16, color: Colors.teal),
                        label: const Text('自建 FunASR'),
                        onPressed: () => _applyPreset('funasr'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('端点与密钥配置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _httpCtrl,
                          decoration: const InputDecoration(
                            labelText: '转写 HTTP 接口',
                            hintText: 'https://api.siliconflow.cn/...',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: _isTestingHttp
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh, size: 16),
                        label: Text(_isTestingHttp ? '测试中' : '测试'),
                        onPressed: _isTestingHttp ? null : _testHttp,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _modelCtrl,
                    decoration: const InputDecoration(
                      labelText: '转写模型',
                      hintText: '如 FunAudioLLM/SenseVoiceSmall',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _keyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '转写 Key (Token)',
                      hintText: 'sk-xxxxxxxx',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _wsCtrl,
                          decoration: const InputDecoration(
                            labelText: '实时流 WS 端点 (可选)',
                            hintText: 'ws://127.0.0.1:10095',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: _isTestingWs
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh, size: 16),
                        label: Text(_isTestingWs ? '测试中' : '测试'),
                        onPressed: _isTestingWs ? null : _testWs,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
