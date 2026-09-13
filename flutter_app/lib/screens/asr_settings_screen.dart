import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../providers/settings_provider.dart';
import '../services/tts_service.dart';

class AsrSettingsScreen extends StatefulWidget {
  const AsrSettingsScreen({super.key});

  @override
  State<AsrSettingsScreen> createState() => _AsrSettingsScreenState();
}

class _AsrSettingsScreenState extends State<AsrSettingsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // --- ASR Controllers ---
  late TextEditingController _httpCtrl;
  late TextEditingController _wsCtrl;
  late TextEditingController _modelCtrl;
  late TextEditingController _keyCtrl;

  bool _isTestingHttp = false;
  bool _isTestingWs = false;

  // --- TTS Controllers ---
  late TextEditingController _ttsHttpCtrl;
  late TextEditingController _ttsModelCtrl;
  late TextEditingController _ttsVoiceCtrl;
  late TextEditingController _ttsKeyCtrl;

  bool _isTestingTts = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    final s = context.read<SettingsProvider>().settings;

    // ASR
    _httpCtrl = TextEditingController(text: s.asrHttpEndpoint);
    _wsCtrl = TextEditingController(text: s.asrWsEndpoint);
    _modelCtrl = TextEditingController(text: s.asrModel);
    _keyCtrl = TextEditingController(text: s.asrApiKey);

    // TTS
    _ttsHttpCtrl = TextEditingController(text: s.ttsHttpEndpoint);
    _ttsModelCtrl = TextEditingController(text: s.ttsModel);
    _ttsVoiceCtrl = TextEditingController(text: s.ttsVoice);
    _ttsKeyCtrl = TextEditingController(text: s.ttsApiKey);

    // 监听与持久化
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

    _ttsHttpCtrl.addListener(() {
      final sp = context.read<SettingsProvider>();
      sp.settings.ttsHttpEndpoint = _ttsHttpCtrl.text.trim();
      sp.updateSettings(sp.settings);
    });
    _ttsModelCtrl.addListener(() {
      final sp = context.read<SettingsProvider>();
      sp.settings.ttsModel = _ttsModelCtrl.text.trim();
      sp.updateSettings(sp.settings);
    });
    _ttsVoiceCtrl.addListener(() {
      final sp = context.read<SettingsProvider>();
      sp.settings.ttsVoice = _ttsVoiceCtrl.text.trim();
      sp.updateSettings(sp.settings);
    });
    _ttsKeyCtrl.addListener(() {
      final sp = context.read<SettingsProvider>();
      sp.settings.ttsApiKey = _ttsKeyCtrl.text.trim();
      sp.updateSettings(sp.settings);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _httpCtrl.dispose();
    _wsCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    _ttsHttpCtrl.dispose();
    _ttsModelCtrl.dispose();
    _ttsVoiceCtrl.dispose();
    _ttsKeyCtrl.dispose();
    super.dispose();
  }

  // --- ASR 预设 ---
  void _applyAsrPreset(String name) {
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
      SnackBar(content: Text('已应用 $name 语音识别预设配置')),
    );
  }

  // --- TTS 预设 ---
  void _applyTtsPreset(String name) {
    final sp = context.read<SettingsProvider>();
    if (name == 'system') {
      sp.settings.ttsEngine = 'system';
      _ttsHttpCtrl.text = '';
      _ttsModelCtrl.text = '';
      _ttsVoiceCtrl.text = '';
    } else if (name == 'siliconflow') {
      sp.settings.ttsEngine = 'cloud';
      _ttsHttpCtrl.text = 'https://api.siliconflow.cn/v1/audio/speech';
      _ttsModelCtrl.text = 'FunAudioLLM/CosyVoice2-0.5B';
      _ttsVoiceCtrl.text = 'FunAudioLLM/CosyVoice2-0.5B:alex';
    } else if (name == 'openai') {
      sp.settings.ttsEngine = 'cloud';
      _ttsHttpCtrl.text = 'https://api.openai.com/v1/audio/speech';
      _ttsModelCtrl.text = 'tts-1';
      _ttsVoiceCtrl.text = 'alloy';
    } else if (name == 'edge') {
      sp.settings.ttsEngine = 'cloud';
      _ttsHttpCtrl.text = 'https://api.openai.com/v1/audio/speech';
      _ttsModelCtrl.text = 'tts-1-hd';
      _ttsVoiceCtrl.text = 'zh-CN-XiaoxiaoNeural';
    }
    sp.updateSettings(sp.settings);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已应用 $name 语音合成预设配置')),
    );
  }

  void _saveAll() {
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    s.asrHttpEndpoint = _httpCtrl.text.trim();
    s.asrWsEndpoint = _wsCtrl.text.trim();
    s.asrModel = _modelCtrl.text.trim();
    s.asrApiKey = _keyCtrl.text.trim();

    s.ttsHttpEndpoint = _ttsHttpCtrl.text.trim();
    s.ttsModel = _ttsModelCtrl.text.trim();
    s.ttsVoice = _ttsVoiceCtrl.text.trim();
    s.ttsApiKey = _ttsKeyCtrl.text.trim();

    sp.updateSettings(s);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('语音转写与合成设置已保存')),
    );
  }

  Uint8List _createSilentWav() {
    const sampleRate = 16000;
    const numChannels = 1;
    const bitsPerSample = 16;
    const numSamples = 1600;
    const dataSize = numSamples * numChannels * (bitsPerSample ~/ 8);
    final totalSize = 36 + dataSize;

    final bytes = ByteData(44 + dataSize);
    bytes.setUint8(0, 0x52); bytes.setUint8(1, 0x49); bytes.setUint8(2, 0x46); bytes.setUint8(3, 0x46);
    bytes.setUint32(4, totalSize, Endian.little);
    bytes.setUint8(8, 0x57); bytes.setUint8(9, 0x41); bytes.setUint8(10, 0x56); bytes.setUint8(11, 0x45);
    bytes.setUint8(12, 0x66); bytes.setUint8(13, 0x6D); bytes.setUint8(14, 0x74); bytes.setUint8(15, 0x20);
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, numChannels, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * numChannels * (bitsPerSample ~/ 8), Endian.little);
    bytes.setUint16(32, numChannels * (bitsPerSample ~/ 8), Endian.little);
    bytes.setUint16(34, bitsPerSample, Endian.little);
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
            content: Text('连接成功：语音识别接口连通正常 (耗时 ${ms}ms)${previewText.isNotEmpty ? " [返回: $previewText]" : ""}'),
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

  // 测试 TTS 试听朗读
  Future<void> _testTtsSpeak() async {
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    setState(() => _isTestingTts = true);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('正在合成测试语音并朗读试听...'),
        duration: Duration(seconds: 2),
      ),
    );

    final success = await TtsService.instance.speak(
      '你好！我是你的 AI 助手，现在正在为你进行语音朗读试听测试。如果听到这段声音，说明语音播报引擎工作一切正常！',
      s,
    );

    if (mounted) {
      setState(() => _isTestingTts = false);
      if (!success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('语音播报失败，请检查设置或使用手机自带引擎'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sp = context.watch<SettingsProvider>();
    final s = sp.settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('语音转写与合成设置 (ASR/TTS)'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF0284C7),
          tabs: const [
            Tab(icon: Icon(Icons.mic), text: '语音转写 (ASR)'),
            Tab(icon: Icon(Icons.record_voice_over), text: '语音合成 (TTS)'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '保存全部',
            onPressed: _saveAll,
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // ----------------- TAB 1: 语音转写 (ASR) -----------------
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('语音识别 (ASR) 快捷商用预设', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ActionChip(
                            avatar: const Icon(Icons.bolt, size: 16, color: Colors.orange),
                            label: const Text('硅基流动 SenseVoice'),
                            onPressed: () => _applyAsrPreset('siliconflow'),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.rocket_launch, size: 16, color: Colors.purple),
                            label: const Text('Groq Whisper'),
                            onPressed: () => _applyAsrPreset('groq'),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.language, size: 16, color: Colors.green),
                            label: const Text('OpenAI Whisper'),
                            onPressed: () => _applyAsrPreset('openai'),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.cloud_outlined, size: 16, color: Colors.blue),
                            label: const Text('阿里百炼'),
                            onPressed: () => _applyAsrPreset('aliyun'),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.developer_board, size: 16, color: Colors.teal),
                            label: const Text('自建 FunASR'),
                            onPressed: () => _applyAsrPreset('funasr'),
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

          // ----------------- TAB 2: 语音合成 (TTS) -----------------
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 引擎选择卡片
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.tune, color: Color(0xFF0284C7)),
                          SizedBox(width: 8),
                          Text('语音合成播报引擎', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('手机系统自带引擎 (离线免费、零网络延迟、安全兜底)'),
                        subtitle: const Text('直接调用手机系统原生 Google / 小爱 / 华为 / Siri 语音'),
                        value: 'system',
                        groupValue: s.ttsEngine,
                        onChanged: (val) {
                          if (val != null) {
                            s.ttsEngine = val;
                            sp.updateSettings(s);
                            setState(() {});
                          }
                        },
                      ),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('云端大模型拟人音色 (CosyVoice / OpenAI / 微软)'),
                        subtitle: const Text('声音极其自然拟人，未配置或请求失败时自动无缝降级为手机自带语音'),
                        value: 'cloud',
                        groupValue: s.ttsEngine,
                        onChanged: (val) {
                          if (val != null) {
                            s.ttsEngine = val;
                            sp.updateSettings(s);
                            setState(() {});
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // 快捷预设
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('常用 TTS 音色快捷预设', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ActionChip(
                            avatar: const Icon(Icons.phone_android, size: 16, color: Colors.blue),
                            label: const Text('手机系统自带'),
                            onPressed: () => _applyTtsPreset('system'),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.bolt, size: 16, color: Colors.orange),
                            label: const Text('硅基流动 CosyVoice2'),
                            onPressed: () => _applyTtsPreset('siliconflow'),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.language, size: 16, color: Colors.green),
                            label: const Text('OpenAI TTS (Alloy)'),
                            onPressed: () => _applyTtsPreset('openai'),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.auto_awesome, size: 16, color: Colors.purple),
                            label: const Text('微软晓晓自然音'),
                            onPressed: () => _applyTtsPreset('edge'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // 语速与语调滑块
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('语速调节 (Speed)', style: TextStyle(fontWeight: FontWeight.bold)),
                          Text('${s.ttsSpeed.toStringAsFixed(1)}x', style: const TextStyle(color: Color(0xFF0284C7), fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Slider(
                        value: s.ttsSpeed,
                        min: 0.5,
                        max: 2.0,
                        divisions: 15,
                        label: '${s.ttsSpeed.toStringAsFixed(1)}x',
                        onChanged: (val) {
                          s.ttsSpeed = val;
                          sp.updateSettings(s);
                          setState(() {});
                        },
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('语调调节 (Pitch)', style: TextStyle(fontWeight: FontWeight.bold)),
                          Text('${s.ttsPitch.toStringAsFixed(1)}x', style: const TextStyle(color: Color(0xFF0284C7), fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Slider(
                        value: s.ttsPitch,
                        min: 0.5,
                        max: 1.5,
                        divisions: 10,
                        label: '${s.ttsPitch.toStringAsFixed(1)}x',
                        onChanged: (val) {
                          s.ttsPitch = val;
                          sp.updateSettings(s);
                          setState(() {});
                        },
                      ),
                      const Divider(height: 24),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('常规聊天中 AI 回复自动朗读'),
                        subtitle: const Text('开启后文字对话生成完毕自动朗读，亦可在顶部栏随时开关/打断'),
                        value: s.autoSpeakResponse,
                        onChanged: (val) {
                          s.autoSpeakResponse = val;
                          sp.updateSettings(s);
                          setState(() {});
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('实时语音通话中自动朗读回复'),
                        subtitle: const Text('AI 生成文字后自动通过选定 TTS 播报人声'),
                        value: s.ttsAutoPlayInCall,
                        onChanged: (val) {
                          s.ttsAutoPlayInCall = val;
                          sp.updateSettings(s);
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // 云端 TTS 专有配置卡片
              if (s.ttsEngine == 'cloud')
                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('云端 TTS 接口配置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _ttsHttpCtrl,
                          decoration: const InputDecoration(
                            labelText: 'TTS HTTP 接口地址',
                            hintText: 'https://api.siliconflow.cn/v1/audio/speech',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _ttsModelCtrl,
                          decoration: const InputDecoration(
                            labelText: 'TTS 模型',
                            hintText: '如 FunAudioLLM/CosyVoice2-0.5B 或 tts-1',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _ttsVoiceCtrl,
                          decoration: const InputDecoration(
                            labelText: '音色标识 (Voice)',
                            hintText: '如 FunAudioLLM/CosyVoice2-0.5B:alex 或 alloy',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _ttsKeyCtrl,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'TTS API Key (Token)',
                            hintText: 'sk-xxxxxxxx',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 20),

              // 试听朗读测试大按钮
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: _isTestingTts
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.volume_up, size: 20),
                label: Text(_isTestingTts ? '正在播报试听...' : '试听当前配置语音朗读效果'),
                onPressed: _isTestingTts ? null : _testTtsSpeak,
              ),
              const SizedBox(height: 30),
            ],
          ),
        ],
      ),
    );
  }
}
