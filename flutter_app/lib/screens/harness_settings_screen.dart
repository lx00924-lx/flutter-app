import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../models/app_settings.dart';
import '../utils/bridge_script_helper.dart';

class HarnessSettingsScreen extends StatefulWidget {
  const HarnessSettingsScreen({super.key});

  @override
  State<HarnessSettingsScreen> createState() => _HarnessSettingsScreenState();
}

class _HarnessSettingsScreenState extends State<HarnessSettingsScreen> {
  late TextEditingController _tokenCtrl;
  late TextEditingController _harnessUrlCtrl;
  late TextEditingController _workspaceCtrl;
  late TextEditingController _localWsUrlCtrl;
  late TextEditingController _localAgentTokenCtrl;

  final FocusNode _tokenFocus = FocusNode();
  final FocusNode _harnessUrlFocus = FocusNode();
  final FocusNode _workspaceFocus = FocusNode();
  final FocusNode _localWsUrlFocus = FocusNode();
  final FocusNode _localAgentTokenFocus = FocusNode();

  bool _isRefreshing = false;
  List<String> _workspaces = ['deepseek-agent', 'workspace-main', 'dev-sandbox'];
  List<Map<String, dynamic>> _rawSessions = [];
  List<String> _filteredSessions = ['智能选择 / 自动新建会话 (推荐)'];
  String _selectedSession = '智能选择 / 自动新建会话 (推荐)';

  @override
  void initState() {
    super.initState();
    final s = context.read<SettingsProvider>().settings;
    _tokenCtrl = TextEditingController(text: s.harnessToken);
    var urlText = s.harnessServiceUrl.trim();
    if (urlText.startsWith('http://')) {
      urlText = urlText.substring(7);
    } else if (urlText.startsWith('https://')) {
      urlText = urlText.substring(8);
    }
    if (urlText.isEmpty) {
      urlText = '127.0.0.1:3080';
    }
    _harnessUrlCtrl = TextEditingController(text: urlText);
    _workspaceCtrl = TextEditingController(text: s.targetWorkspace);
    _localWsUrlCtrl = TextEditingController(
      text: s.localBridgeWsUrl.isNotEmpty ? s.localBridgeWsUrl : 'http://127.0.0.1:3080',
    );
    _localAgentTokenCtrl = TextEditingController(text: s.localAgentToken);

    if (!_workspaces.contains(s.targetWorkspace)) {
      _workspaces.insert(0, s.targetWorkspace);
    }

    // 绑定失焦自动保存监听，解决每次击键卡顿问题
    _tokenFocus.addListener(_handleFocusChange);
    _harnessUrlFocus.addListener(_handleFocusChange);
    _workspaceFocus.addListener(() {
      _handleFocusChange();
      if (!_workspaceFocus.hasFocus) {
        _updateFilteredSessions();
      }
    });
    _localWsUrlFocus.addListener(_handleFocusChange);
    _localAgentTokenFocus.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (!_tokenFocus.hasFocus &&
        !_harnessUrlFocus.hasFocus &&
        !_workspaceFocus.hasFocus &&
        !_localWsUrlFocus.hasFocus &&
        !_localAgentTokenFocus.hasFocus) {
      _saveSilently();
    }
  }

  void _updateFilteredSessions() {
    final currentWs = _workspaceCtrl.text.trim();
    final list = <String>['智能选择 / 自动新建会话 (推荐)'];
    for (final sess in _rawSessions) {
      final sessWs = sess['workspace']?.toString() ?? '';
      if (sessWs.isEmpty || sessWs == currentWs) {
        final title = sess['title']?.toString() ?? sess['id']?.toString() ?? '未命名会话';
        list.add(title);
      }
    }
    setState(() {
      _filteredSessions = list;
      if (!_filteredSessions.contains(_selectedSession)) {
        _selectedSession = _filteredSessions.first;
      }
    });
  }

  void _saveSilently() {
    if (!mounted) return;
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    s.harnessToken = _tokenCtrl.text.trim();
    var rawUrl = _harnessUrlCtrl.text.trim();
    if (rawUrl.isEmpty) rawUrl = '127.0.0.1:3080';
    if (!rawUrl.startsWith('http://') && !rawUrl.startsWith('https://')) {
      s.harnessServiceUrl = 'http://$rawUrl';
    } else {
      s.harnessServiceUrl = rawUrl;
    }
    s.targetWorkspace = _workspaceCtrl.text.trim();
    s.localBridgeWsUrl = _localWsUrlCtrl.text.trim().isNotEmpty
        ? _localWsUrlCtrl.text.trim()
        : 'http://127.0.0.1:3080';
    s.localAgentToken = _localAgentTokenCtrl.text.trim();
    sp.updateSettings(s);
  }

  @override
  void dispose() {
    _saveSilently();
    _tokenFocus.dispose();
    _harnessUrlFocus.dispose();
    _workspaceFocus.dispose();
    _localWsUrlFocus.dispose();
    _localAgentTokenFocus.dispose();
    _tokenCtrl.dispose();
    _harnessUrlCtrl.dispose();
    _workspaceCtrl.dispose();
    _localWsUrlCtrl.dispose();
    _localAgentTokenCtrl.dispose();
    super.dispose();
  }

  void _save() {
    FocusScope.of(context).unfocus();
    _saveSilently();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Harness 桥接设置已保存')),
    );
  }

  Future<void> _refreshWorkspacesAndSessions() async {
    setState(() => _isRefreshing = true);
    final sp = context.read<SettingsProvider>();
    try {
      final res = await sp.fetchAgentWorkspacesAndSessions();
      final isOnline = res['online'] == true;
      final wsList = (res['workspaces'] as List<dynamic>?)?.map((e) => e.toString()).toList();
      final sessList = (res['sessions'] as List<dynamic>?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList();

      if (mounted) {
        setState(() {
          _isRefreshing = false;
          if (wsList != null && wsList.isNotEmpty) {
            _workspaces = wsList;
            if (!_workspaces.contains(_workspaceCtrl.text.trim())) {
              _workspaceCtrl.text = _workspaces.first;
            }
          }
          if (sessList != null) {
            _rawSessions = sessList;
            _updateFilteredSessions();
          }
        });

        if (isOnline) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('✅ 成功同步本地 Agent 工作区（共 ${_workspaces.length} 个工作区）')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ 电脑端桥接脚本当前未在线，已载入本地预设工作区'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isRefreshing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('刷新异常: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  void _showQrScanPairingDialog() {
    final token = _tokenCtrl.text.trim();
    final url = _harnessUrlCtrl.text.trim();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.qr_code_scanner, color: Color(0xFF0284C7)),
            SizedBox(width: 8),
            Text('Agent 扫码与快速配对'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '手机端可直接与电脑端通过配对口令或局域网配置互通：',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(ctx).brightness == Brightness.dark
                    ? const Color(0xFF1E293B)
                    : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前配对 Token: $token', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text('Harness 地址: http://$url', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 4),
                  const Text('状态: 即时双向安全长连接', style: TextStyle(fontSize: 12, color: Colors.green)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text('💡 提示：电脑端运行 deepseek_bridge.py 即可自动握手接入，无需在同 WiFi 下暴露任何端口。', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7), foregroundColor: Colors.white),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: 'TOKEN=$token;URL=http://$url'));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('配对配置参数已复制到剪贴板')),
              );
            },
            child: const Text('复制配对参数'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sp = context.watch<SettingsProvider>();
    final s = sp.settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('DeepSeek Harness 设置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: '扫码配对',
            onPressed: _showQrScanPairingDialog,
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '保存',
            onPressed: _save,
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 桥接状态与模式
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.computer, color: Color(0xFF0284C7)),
                        const SizedBox(width: 8),
                        const Text(
                          '本地 Agent 桥接设置 (DeepSeek Harness)',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: s.isHarnessOnline
                                ? Colors.green.withOpacity(0.2)
                                : Colors.grey.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.circle,
                                size: 10,
                                color: s.isHarnessOnline ? Colors.green : Colors.grey,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                s.isHarnessOnline ? '桥接在线' : '桥接离线',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: s.isHarnessOnline ? Colors.green : Colors.grey,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('默认 Agent 模式', style: TextStyle(fontSize: 14)),
                      subtitle: Text(
                        s.defaultAgentMode ? '已开启（优先执行电脑本地 Agent 操作）' : '已关闭（直接与 App 模型对话）',
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: s.defaultAgentMode,
                      onChanged: (val) {
                        s.defaultAgentMode = val;
                        sp.updateSettings(s);
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _tokenCtrl,
                            focusNode: _tokenFocus,
                            decoration: const InputDecoration(
                              labelText: '配对 Token',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          tooltip: '重置注销',
                          onPressed: () {
                            final newToken = AppSettings.generateOpenAiStyleKey();
                            _tokenCtrl.text = newToken;
                            s.harnessToken = newToken;
                            sp.updateSettings(s);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已重新生成配对 Token')),
                            );
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy),
                          tooltip: '复制',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _tokenCtrl.text.trim()));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Token 已复制到剪贴板')),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.amber.withOpacity(0.3)),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('🛡️ 安全防护与白名单：', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.amber)),
                          SizedBox(height: 2),
                          Text(
                            '桥接脚本内置严格接口白名单（仅允许标准对话转发），禁止篡改系统与插件；纯内存运行，不持久化任何对话与日志。',
                            style: TextStyle(fontSize: 11, color: Colors.amber),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _harnessUrlCtrl,
                      focusNode: _harnessUrlFocus,
                      decoration: const InputDecoration(
                        labelText: 'Harness 服务地址',
                        prefixText: 'http://',
                        hintText: '127.0.0.1:3080',
                        border: OutlineInputBorder(),
                        helperText: '固定协议头 http://，默认预填 127.0.0.1:3080',
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // DSH 智能体执行选项配置（用户需求定制）
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.tune, size: 20, color: Color(0xFF0284C7)),
                        SizedBox(width: 8),
                        Text(
                          'DSH 智能体执行选项',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // 1. 底层模型
                    DropdownButtonFormField<String>(
                      value: s.agentModel,
                      decoration: const InputDecoration(
                        labelText: '智能体调度模型',
                        border: OutlineInputBorder(),
                        isDense: true,
                        helperText: '驱动 Agent 推演拆解与调度的语言模型',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'deepseek-reasoner',
                          child: Text('DeepSeek-R1 (深度思考推演模式)'),
                        ),
                        DropdownMenuItem(
                          value: 'deepseek-chat',
                          child: Text('DeepSeek-V3 (高速通用模型)'),
                        ),
                        DropdownMenuItem(
                          value: 'local-harness-default',
                          child: Text('本地工作区默认模型 (Harness Default)'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          s.agentModel = val;
                          sp.updateSettings(s);
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    // 2. 思考链强度
                    DropdownButtonFormField<String>(
                      value: s.agentReasoningEffort,
                      decoration: const InputDecoration(
                        labelText: '思考链预算 / 强度 (Reasoning Effort)',
                        border: OutlineInputBorder(),
                        isDense: true,
                        helperText: '控制 Agent 在执行工具前的拆解深度',
                      ),
                      items: const [
                        DropdownMenuItem(value: 'low', child: Text('Low - 快速分析 (少量思考)')),
                        DropdownMenuItem(value: 'medium', child: Text('Medium - 标准平衡 (推荐)')),
                        DropdownMenuItem(value: 'high', child: Text('High - 深度推演 (全量多步分析)')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          s.agentReasoningEffort = val;
                          sp.updateSettings(s);
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    // 3. 执行权限管控
                    DropdownButtonFormField<String>(
                      value: s.agentPermission,
                      decoration: const InputDecoration(
                        labelText: '工具执行安全权限',
                        border: OutlineInputBorder(),
                        isDense: true,
                        helperText: '本地执行高危命令或文件修改时的防护策略',
                      ),
                      items: const [
                        DropdownMenuItem(value: 'ask', child: Text('安全拦截 - 敏感操作每次弹窗确认 (推荐)')),
                        DropdownMenuItem(value: 'auto_allow', child: Text('自治执行 - 自动放行白名单内操作')),
                        DropdownMenuItem(value: 'read_only', child: Text('只读审查 - 仅允许读取，禁止修改/写入')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          s.agentPermission = val;
                          sp.updateSettings(s);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 本地工作区与会话列表（下拉选择 + 联动筛选）
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '本地工作区与会话选择',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        OutlinedButton.icon(
                          icon: _isRefreshing
                              ? const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.refresh, size: 14),
                          label: const Text('刷新列表', style: TextStyle(fontSize: 12)),
                          onPressed: _isRefreshing ? null : _refreshWorkspacesAndSessions,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // 目标工作区下拉选择与自定义输入
                    DropdownButtonFormField<String>(
                      value: _workspaces.contains(_workspaceCtrl.text.trim()) ? _workspaceCtrl.text.trim() : null,
                      decoration: const InputDecoration(
                        labelText: '目标工作区 (下拉选择)',
                        border: OutlineInputBorder(),
                        isDense: true,
                        helperText: '选择电脑上已配置的代码仓或专属目录',
                      ),
                      items: _workspaces.map((ws) {
                        return DropdownMenuItem(value: ws, child: Text(ws, style: const TextStyle(fontSize: 13)));
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          _workspaceCtrl.text = val;
                          s.targetWorkspace = val;
                          sp.updateSettings(s);
                          _updateFilteredSessions();
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _workspaceCtrl,
                      focusNode: _workspaceFocus,
                      decoration: const InputDecoration(
                        labelText: '自定义工作区路径/名称',
                        hintText: 'deepseek-agent 或 C:\\workspace',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    // 目标会话下拉（联动当前工作区）
                    DropdownButtonFormField<String>(
                      value: _filteredSessions.contains(_selectedSession) ? _selectedSession : _filteredSessions.first,
                      decoration: const InputDecoration(
                        labelText: '目标会话 (已联动当前工作区)',
                        border: OutlineInputBorder(),
                        isDense: true,
                        helperText: '选择已存在的上下文会话或自动开启新会话',
                      ),
                      items: _filteredSessions.map((sess) {
                        return DropdownMenuItem(value: sess, child: Text(sess, style: const TextStyle(fontSize: 13)));
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _selectedSession = val);
                          s.targetSessionId = val == '智能选择 / 自动新建会话 (推荐)' ? '' : val;
                          sp.updateSettings(s);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 局域网 / 本地直连设置 (Local Agent)
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.lan_outlined, size: 20, color: Colors.blueAccent),
                        SizedBox(width: 8),
                        Text(
                          '局域网 / 本地直连设置 (可选)',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '同 WiFi 局域网或桌面版直接连接本地电脑 Agent，无需公网中继。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _localWsUrlCtrl,
                      focusNode: _localWsUrlFocus,
                      decoration: const InputDecoration(
                        labelText: '本地直连地址 (WS / HTTP)',
                        hintText: 'http://127.0.0.1:3080',
                        border: OutlineInputBorder(),
                        helperText: '局域网或本机直连地址，默认 http://127.0.0.1:3080',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _localAgentTokenCtrl,
                      focusNode: _localAgentTokenFocus,
                      decoration: const InputDecoration(
                        labelText: '直连安全 Token (可选)',
                        hintText: '留空或输入本地安全口令',
                        border: OutlineInputBorder(),
                        helperText: '局域网握手鉴权 Token，未配置可留空',
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 本地启动程序与脚本导出
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('电脑端启动命令 (免公网 IP，安全长连接)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.withOpacity(0.3)),
                      ),
                      child: Text(
                        'python deepseek_bridge.py --token "${_tokenCtrl.text.trim()}" --harness-url "${_harnessUrlCtrl.text.trim()}"',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 一键工具组：下载 py 脚本、下载 bat 脚本、复制命令
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.code, size: 16, color: Color(0xFF0284C7)),
                          label: const Text('下载 py 脚本', style: TextStyle(fontSize: 13)),
                          onPressed: () async {
                            final pyContent = BridgeScriptHelper.generatePyContent();
                            final path = await BridgeScriptHelper.saveFileToDevice(
                              fileName: 'deepseek_bridge.py',
                              content: pyContent,
                            );
                            if (mounted) {
                              if (path != null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('已成功保存 deepseek_bridge.py 到：$path')),
                                );
                              } else {
                                Clipboard.setData(ClipboardData(text: pyContent));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('已将 deepseek_bridge.py 完整代码复制到剪贴板')),
                                );
                              }
                            }
                          },
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.terminal, size: 16, color: Color(0xFF0284C7)),
                          label: const Text('下载 bat 脚本', style: TextStyle(fontSize: 13)),
                          onPressed: () async {
                            final batContent = BridgeScriptHelper.generateBatContent(
                              token: _tokenCtrl.text.trim(),
                              serverUrl: 'https://www.lx00924ai.top',
                              harnessUrl: 'http://${_harnessUrlCtrl.text.trim()}',
                            );
                            final path = await BridgeScriptHelper.saveFileToDevice(
                              fileName: 'run_bridge.bat',
                              content: batContent,
                            );
                            if (mounted) {
                              if (path != null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('已成功保存 run_bridge.bat 到：$path')),
                                );
                              } else {
                                Clipboard.setData(ClipboardData(text: batContent));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('已将 run_bridge.bat 完整脚本复制到剪贴板')),
                                );
                              }
                            }
                          },
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0284C7),
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('复制命令', style: TextStyle(fontSize: 13)),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(
                              text: 'python deepseek_bridge.py --token "${_tokenCtrl.text.trim()}" --harness-url "${_harnessUrlCtrl.text.trim()}"',
                            ));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('启动命令已复制')),
                            );
                          },
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
    );
  }
}
