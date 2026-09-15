import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' show Random;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// 单个 API 模型端点配置（卡片项）
class ApiModelEndpoint {
  final String id;
  String cardName; // 卡片展示名称，默认为模型名，可自定义
  String endpoint; // API 终端 URL，例如 https://api.deepseek.com
  String apiKey; // API Key
  String modelName; // 模型名称，例如 deepseek-chat 或 ep-xxx
  int contextLength; // 该 API 专属上下文长度，超出滑动截断
  double temperature;
  int maxTokens;
  bool isEnabled;

  ApiModelEndpoint({
    String? id,
    required this.cardName,
    required this.endpoint,
    required this.apiKey,
    required this.modelName,
    this.contextLength = 15000,
    this.temperature = 0.6,
    this.maxTokens = 4096,
    this.isEnabled = true,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'cardName': cardName,
      'endpoint': endpoint,
      'apiKey': apiKey,
      'modelName': modelName,
      'contextLength': contextLength,
      'temperature': temperature,
      'maxTokens': maxTokens,
      'isEnabled': isEnabled,
    };
  }

  factory ApiModelEndpoint.fromMap(Map<dynamic, dynamic> map) {
    return ApiModelEndpoint(
      id: map['id']?.toString(),
      cardName: map['cardName']?.toString() ?? '默认模型',
      endpoint: map['endpoint']?.toString() ?? 'https://api.deepseek.com',
      apiKey: map['apiKey']?.toString() ?? '',
      modelName: map['modelName']?.toString() ?? 'deepseek-chat',
      contextLength: (map['contextLength'] as num?)?.toInt() ?? 15000,
      temperature: (map['temperature'] as num?)?.toDouble() ?? 0.6,
      maxTokens: (map['maxTokens'] as num?)?.toInt() ?? 4096,
      isEnabled: map['isEnabled'] as bool? ?? true,
    );
  }
}

/// 完整应用设置
class AppSettings {
  // --- 系统与界面基础 ---
  bool isDarkMode;
  String activeEndpointId; // 当前选中的 ApiModelEndpoint id
  String activeModelDisplayName; // 当前主界面展示的模型名称

  // --- 1. 账户设置 ---
  bool isLoggedIn;
  String loginAccount;
  String userName;
  String userAvatar; // Base64 或本地图片路径
  String aiName;
  String aiAvatar; // Base64 或本地图片路径
  String accountPassword;
  String clientSessionId;

  /// 动态识别当前 Flutter 运行的设备分类：手机端 (mobile) / 电脑端 (desktop)
  static String get currentDeviceType {
    if (kIsWeb) return 'desktop';
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        return 'mobile';
      }
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        return 'desktop';
      }
    } catch (_) {}
    return 'desktop';
  }

  // --- 2. 个性化设置 ---
  String customBackground; // 背景图片路径或 Base64
  int backgroundOpacity; // 0 - 100
  bool showBackgroundInDarkMode;
  int chatFontSize; // 13 (小), 15 (标准), 16 (大), 18 (特大)
  
  // 启动页设置
  bool enableSplash;
  String splashTitle;
  String splashSubtitle;
  int splashDurationMs; // 毫秒
  String splashImage;
  
  // 回复逻辑 (System Prompt)
  String systemPrompt;
  bool sendOnEnter; // 桌面端回车发送消息（默认 true: 回车发送、Shift+回车换行；false: 回车换行、Shift+回车发送）

  // --- 3. 大模型 API 卡片列表 ---
  List<ApiModelEndpoint> apiEndpoints;

  // --- 4. 语音转写 (ASR) 与 语音合成 (TTS) 设置 ---
  String asrProvider; // 'siliconflow', 'groq', 'openai', 'aliyun', 'funasr'
  String asrHttpEndpoint;
  String asrWsEndpoint;
  String asrModel;
  String asrApiKey;
  int asrContextLength;

  // TTS 语音合成
  String ttsEngine; // 'system' (手机自带) | 'cloud' (云端接口)
  String ttsHttpEndpoint; // 云端 TTS 接口
  String ttsModel; // 如 CosyVoice-300M, tts-1, speech-01
  String ttsVoice; // 音色，如 alloy, echo, zh-CN-XiaoxiaoNeural, FunAudioLLM
  String ttsApiKey;
  double ttsSpeed; // 0.5 - 2.0 (语速)
  double ttsPitch; // 0.5 - 2.0 (音调)
  bool ttsAutoPlayInCall; // 语音通话中自动朗读
  bool autoSpeakResponse; // 开启时 AI 回复自动朗读，关闭时不启用

  // --- 5. DeepSeek Harness (本地电脑 Agent 桥接) ---
  bool defaultAgentMode;
  String harnessToken;
  String harnessServiceUrl; // 默认 http://127.0.0.1:3080
  String localBridgeWsUrl; // 默认 http://127.0.0.1:3080
  String localAgentToken;
  String targetWorkspace;
  String targetSessionId;
  bool isHarnessOnline;
  String agentReasoningEffort; // 'high' | 'medium' | 'low'
  String agentPermission; // 'workspace-write' | 'read-only' | 'full-access'
  String agentModel; // 'deepseek-v4-flash'

  // --- 打包固件常量 (随每次打包发布更新，不可被缓存篡改) ---
  static const String currentVersion = '1.0.1';
  static const int currentBuildNumber = 101;
  static const String officialGithubOwner = 'lx00924-lx';
  static const String officialGithubRepo = 'flutter-app';
  static const String officialGithubUrl = 'https://github.com/lx00924-lx/flutter-app';
  static const String officialGithubReleasesUrl = 'https://github.com/lx00924-lx/flutter-app/releases';

  // --- 直接展示项 ---
  String get githubOwner => officialGithubOwner;
  String get githubRepo => officialGithubRepo;
  set githubOwner(String _) {} // 忽略旧缓存写入
  set githubRepo(String _) {} // 忽略旧缓存写入
  String customDataPath;
  bool showDebugFab;

  AppSettings({
    this.isDarkMode = false,
    this.activeEndpointId = '',
    this.activeModelDisplayName = 'DeepSeek-V3',
    // 账户
    this.isLoggedIn = false,
    this.loginAccount = '',
    this.userName = '用户',
    this.userAvatar = '',
    this.aiName = 'Aether-X',
    this.aiAvatar = '',
    this.accountPassword = '',
    this.clientSessionId = '',
    // 个性化
    this.customBackground = '',
    this.backgroundOpacity = 100,
    this.showBackgroundInDarkMode = true,
    this.chatFontSize = 15,
    this.enableSplash = true,
    this.splashTitle = 'Aether-X',
    this.splashSubtitle = 'Loading AI Experience',
    this.splashDurationMs = 1000,
    this.splashImage = '',
    this.systemPrompt = '你是一个专业、诚实、乐于助人的 AI 助手。',
    this.sendOnEnter = true,
    // API 端点列表
    List<ApiModelEndpoint>? apiEndpoints,
    // ASR
    this.asrProvider = 'siliconflow',
    this.asrHttpEndpoint = 'https://api.siliconflow.cn/v1/audio/transcriptions',
    this.asrWsEndpoint = '',
    this.asrModel = 'FunAudioLLM/SenseVoiceSmall',
    this.asrApiKey = '',
    this.asrContextLength = 30000,
    // TTS
    this.ttsEngine = 'system',
    this.ttsHttpEndpoint = '',
    this.ttsModel = '',
    this.ttsVoice = '',
    this.ttsApiKey = '',
    this.ttsSpeed = 1.0,
    this.ttsPitch = 1.0,
    this.ttsAutoPlayInCall = true,
    this.autoSpeakResponse = false,
    // Harness
    this.defaultAgentMode = false,
    this.harnessToken = 'sk-agent030efheg0z78491abcdef0123456789abcdef0123456789',
    this.harnessServiceUrl = 'http://127.0.0.1:3080',
    this.localBridgeWsUrl = 'http://127.0.0.1:3080',
    this.localAgentToken = '',
    this.targetWorkspace = 'deepseek-agent',
    this.targetSessionId = '',
    this.isHarnessOnline = false,
    this.agentReasoningEffort = 'high',
    this.agentPermission = 'workspace-write',
    this.agentModel = 'deepseek-v4-flash',
    // 辅助
    String? githubOwner,
    String? githubRepo,
    this.customDataPath = '',
    this.showDebugFab = false,
  }) : apiEndpoints = apiEndpoints ?? [
          ApiModelEndpoint(
            id: 'default-deepseek-v3',
            cardName: 'DeepSeek-V3',
            endpoint: 'https://api.deepseek.com',
            apiKey: '',
            modelName: 'deepseek-chat',
            contextLength: 15000,
          ),
          ApiModelEndpoint(
            id: 'default-deepseek-r1',
            cardName: 'DeepSeek-R1',
            endpoint: 'https://api.deepseek.com',
            apiKey: '',
            modelName: 'deepseek-reasoner',
            contextLength: 15000,
          ),
        ];

  ApiModelEndpoint? get activeEndpoint {
    if (apiEndpoints.isEmpty) return null;
    final found = apiEndpoints.where((e) => e.id == activeEndpointId);
    if (found.isNotEmpty) return found.first;
    return apiEndpoints.first;
  }

  Map<String, dynamic> toMap() {
    return {
      'isDarkMode': isDarkMode,
      'activeEndpointId': activeEndpointId,
      'activeModelDisplayName': activeModelDisplayName,
      'isLoggedIn': isLoggedIn,
      'loginAccount': loginAccount,
      'userName': userName,
      'userAvatar': userAvatar,
      'aiName': aiName,
      'aiAvatar': aiAvatar,
      'accountPassword': accountPassword,
      'clientSessionId': clientSessionId,
      'customBackground': customBackground,
      'backgroundOpacity': backgroundOpacity,
      'showBackgroundInDarkMode': showBackgroundInDarkMode,
      'chatFontSize': chatFontSize,
      'enableSplash': enableSplash,
      'splashTitle': splashTitle,
      'splashSubtitle': splashSubtitle,
      'splashDurationMs': splashDurationMs,
      'splashImage': splashImage,
      'systemPrompt': systemPrompt,
      'sendOnEnter': sendOnEnter,
      'apiEndpoints': apiEndpoints.map((e) => e.toMap()).toList(),
      'asrProvider': asrProvider,
      'asrHttpEndpoint': asrHttpEndpoint,
      'asrWsEndpoint': asrWsEndpoint,
      'asrModel': asrModel,
      'asrApiKey': asrApiKey,
      'asrContextLength': asrContextLength,
      'ttsEngine': ttsEngine,
      'ttsHttpEndpoint': ttsHttpEndpoint,
      'ttsModel': ttsModel,
      'ttsVoice': ttsVoice,
      'ttsApiKey': ttsApiKey,
      'ttsSpeed': ttsSpeed,
      'ttsPitch': ttsPitch,
      'ttsAutoPlayInCall': ttsAutoPlayInCall,
      'autoSpeakResponse': autoSpeakResponse,
      'defaultAgentMode': defaultAgentMode,
      'harnessToken': harnessToken,
      'harnessServiceUrl': harnessServiceUrl,
      'localBridgeWsUrl': localBridgeWsUrl,
      'localAgentToken': localAgentToken,
      'targetWorkspace': targetWorkspace,
      'targetSessionId': targetSessionId,
      'isHarnessOnline': isHarnessOnline,
      'agentReasoningEffort': agentReasoningEffort,
      'agentPermission': agentPermission,
      'agentModel': agentModel,
      'githubOwner': githubOwner,
      'githubRepo': githubRepo,
      'customDataPath': customDataPath,
      'showDebugFab': showDebugFab,
    };
  }

  /// 转换为上传至云端的 Map 数据（严格脱敏：清除所有 apiKey、asrApiKey 和密码等敏感信息）
  Map<String, dynamic> toCloudMap() {
    final map = toMap();
    map['asrApiKey'] = '';
    map['ttsApiKey'] = '';
    map['accountPassword'] = '';
    if (map['apiEndpoints'] is List) {
      map['apiEndpoints'] = (map['apiEndpoints'] as List).map((item) {
        if (item is Map) {
          final copy = Map<String, dynamic>.from(item);
          copy['apiKey'] = '';
          return copy;
        }
        return item;
      }).toList();
    }
    return map;
  }

  /// 随机生成 OpenAI 风格的高安全强度长字符密钥 (sk- + 48位随机大小写字母与数字)
  static String generateOpenAiStyleKey() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rand = Random.secure();
    final randomPart = List.generate(48, (_) => chars[rand.nextInt(chars.length)]).join();
    return 'sk-$randomPart';
  }

  factory AppSettings.fromMap(Map<dynamic, dynamic> map) {
    List<ApiModelEndpoint> endpoints = [];
    if (map['apiEndpoints'] is List) {
      endpoints = (map['apiEndpoints'] as List)
          .map((item) => ApiModelEndpoint.fromMap(item as Map))
          .toList();
    }
    if (endpoints.isEmpty) {
      endpoints = [
        ApiModelEndpoint(
          id: 'default-deepseek-v3',
          cardName: 'DeepSeek-V3',
          endpoint: 'https://api.deepseek.com',
          apiKey: '',
          modelName: 'deepseek-chat',
          contextLength: 15000,
        ),
        ApiModelEndpoint(
          id: 'default-deepseek-r1',
          cardName: 'DeepSeek-R1',
          endpoint: 'https://api.deepseek.com',
          apiKey: '',
          modelName: 'deepseek-reasoner',
          contextLength: 15000,
        ),
      ];
    }

    final activeId = map['activeEndpointId']?.toString() ?? endpoints.first.id;
    final activeEp = endpoints.firstWhere((e) => e.id == activeId, orElse: () => endpoints.first);

    return AppSettings(
      isDarkMode: map['isDarkMode'] as bool? ?? false,
      activeEndpointId: activeId,
      activeModelDisplayName: map['activeModelDisplayName']?.toString() ?? activeEp.cardName,
      isLoggedIn: map['isLoggedIn'] as bool? ?? false,
      loginAccount: map['loginAccount']?.toString() ?? '',
      userName: map['userName']?.toString() ?? '用户',
      userAvatar: map['userAvatar']?.toString() ?? '',
      aiName: map['aiName']?.toString() ?? 'Aether-X',
      aiAvatar: map['aiAvatar']?.toString() ?? '',
      accountPassword: map['accountPassword']?.toString() ?? '',
      clientSessionId: map['clientSessionId']?.toString() ?? '',
      customBackground: map['customBackground']?.toString() ?? '',
      backgroundOpacity: (map['backgroundOpacity'] as num?)?.toInt() ?? 100,
      showBackgroundInDarkMode: map['showBackgroundInDarkMode'] as bool? ?? true,
      chatFontSize: (map['chatFontSize'] as num?)?.toInt() ?? 15,
      enableSplash: map['enableSplash'] as bool? ?? true,
      splashTitle: map['splashTitle']?.toString() ?? 'Aether-X',
      splashSubtitle: map['splashSubtitle']?.toString() ?? 'Loading AI Experience',
      splashDurationMs: (map['splashDurationMs'] as num?)?.toInt() ?? 1000,
      splashImage: map['splashImage']?.toString() ?? '',
      systemPrompt: map['systemPrompt']?.toString() ?? '你是一个专业、诚实、乐于助人的 AI 助手。',
      sendOnEnter: map['sendOnEnter'] as bool? ?? true,
      apiEndpoints: endpoints,
      asrProvider: map['asrProvider']?.toString() ?? 'siliconflow',
      asrHttpEndpoint: map['asrHttpEndpoint']?.toString() ?? 'https://api.siliconflow.cn/v1/audio/transcriptions',
      asrWsEndpoint: map['asrWsEndpoint']?.toString() ?? '',
      asrModel: map['asrModel']?.toString() ?? 'FunAudioLLM/SenseVoiceSmall',
      asrApiKey: map['asrApiKey']?.toString() ?? '',
      asrContextLength: (map['asrContextLength'] as num?)?.toInt() ?? 30000,
      ttsEngine: map['ttsEngine']?.toString() ?? 'system',
      ttsHttpEndpoint: map['ttsHttpEndpoint']?.toString() ?? '',
      ttsModel: map['ttsModel']?.toString() ?? '',
      ttsVoice: map['ttsVoice']?.toString() ?? '',
      ttsApiKey: map['ttsApiKey']?.toString() ?? '',
      ttsSpeed: (map['ttsSpeed'] as num?)?.toDouble() ?? 1.0,
      ttsPitch: (map['ttsPitch'] as num?)?.toDouble() ?? 1.0,
      ttsAutoPlayInCall: map['ttsAutoPlayInCall'] as bool? ?? true,
      autoSpeakResponse: map['autoSpeakResponse'] as bool? ?? false,
      defaultAgentMode: map['defaultAgentMode'] as bool? ?? false,
      harnessToken: map['harnessToken']?.toString() ?? 'sk-agent030efheg0z78491abcdef0123456789abcdef0123456789',
      harnessServiceUrl: map['harnessServiceUrl']?.toString() ?? 'http://127.0.0.1:3080',
      localBridgeWsUrl: map['localBridgeWsUrl']?.toString() ?? 'http://127.0.0.1:3080',
      localAgentToken: map['localAgentToken']?.toString() ?? '',
      targetWorkspace: map['targetWorkspace']?.toString() ?? 'deepseek-agent',
      targetSessionId: map['targetSessionId']?.toString() ?? '',
      isHarnessOnline: map['isHarnessOnline'] as bool? ?? false,
      agentReasoningEffort: map['agentReasoningEffort']?.toString() ?? 'high',
      agentPermission: map['agentPermission']?.toString() ?? 'workspace-write',
      agentModel: map['agentModel']?.toString() ?? 'deepseek-v4-flash',
      githubOwner: map['githubOwner']?.toString() ?? 'lx00924-lx',
      githubRepo: map['githubRepo']?.toString() ?? 'flutter-app',
      customDataPath: map['customDataPath']?.toString() ?? '',
      showDebugFab: map['showDebugFab'] as bool? ?? false,
    );
  }
}
