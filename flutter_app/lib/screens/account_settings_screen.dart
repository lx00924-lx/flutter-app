import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/storage_service.dart';
import '../utils/image_picker_helper.dart';
import 'chat_search_screen.dart';
import 'login_screen.dart';
import 'session_management_screen.dart';

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  late TextEditingController _loginAccountCtrl;
  late TextEditingController _userNameCtrl;
  late TextEditingController _aiNameCtrl;
  late TextEditingController _oldPwdCtrl;
  late TextEditingController _newPwdCtrl;
  late TextEditingController _confirmPwdCtrl;

  final FocusNode _userNameFocus = FocusNode();
  final FocusNode _aiNameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    final s = context.read<SettingsProvider>().settings;
    _loginAccountCtrl = TextEditingController(text: s.loginAccount);
    _userNameCtrl = TextEditingController(text: s.userName);
    _aiNameCtrl = TextEditingController(text: s.aiName);
    _oldPwdCtrl = TextEditingController();
    _newPwdCtrl = TextEditingController();
    _confirmPwdCtrl = TextEditingController();

    // 失焦时自动保存，防止输入卡顿
    _userNameFocus.addListener(() {
      if (!_userNameFocus.hasFocus) {
        _saveAccountSilently();
      }
    });

    _aiNameFocus.addListener(() {
      if (!_aiNameFocus.hasFocus) {
        _saveAccountSilently();
      }
    });
  }

  void _saveAccountSilently() {
    if (!mounted) return;
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    final uName = _userNameCtrl.text.trim();
    final aName = _aiNameCtrl.text.trim();
    if (s.userName != uName || s.aiName != aName) {
      s.userName = uName;
      s.aiName = aName;
      sp.updateSettings(s);
    }
  }

  @override
  void dispose() {
    _saveAccountSilently();
    _userNameFocus.dispose();
    _aiNameFocus.dispose();
    _loginAccountCtrl.dispose();
    _userNameCtrl.dispose();
    _aiNameCtrl.dispose();
    _oldPwdCtrl.dispose();
    _newPwdCtrl.dispose();
    _confirmPwdCtrl.dispose();
    super.dispose();
  }

  void _saveAccount() {
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    s.userName = _userNameCtrl.text.trim();
    s.aiName = _aiNameCtrl.text.trim();
    sp.updateSettings(s);
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('账户设置已保存')),
    );
  }

  void _changePassword() {
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;

    if (s.accountPassword.isNotEmpty && _oldPwdCtrl.text.trim() != s.accountPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('原密码不正确')),
      );
      return;
    }

    if (_newPwdCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('新密码不能为空')),
      );
      return;
    }

    if (_newPwdCtrl.text.trim() != _confirmPwdCtrl.text.trim()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('两次输入的新密码不一致')),
      );
      return;
    }

    s.accountPassword = _newPwdCtrl.text.trim();
    sp.updateSettings(s);
    _oldPwdCtrl.clear();
    _newPwdCtrl.clear();
    _confirmPwdCtrl.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('密码修改成功')),
    );
  }

  void _exportChatData() {
    final data = StorageService.instance.exportAllData();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    Clipboard.setData(ClipboardData(text: jsonStr));

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出聊天记录备份'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('全部会话及消息数据已成功生成，并已复制到系统剪贴板！'),
            const SizedBox(height: 12),
            Text(
              '共导出 ${(data['sessions'] as List).length} 个会话，${(data['messages'] as List).length} 条消息记录。',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  void _importChatData() {
    final importCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入聊天记录备份'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('请将导出的 JSON 备份数据粘贴到下方文本框中：'),
              const SizedBox(height: 10),
              TextField(
                controller: importCtrl,
                maxLines: 8,
                decoration: const InputDecoration(
                  hintText: '{\n  "version": "1.0.0",\n  "sessions": [...],\n  "messages": [...]\n}',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              final raw = importCtrl.text.trim();
              if (raw.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('导入内容不能为空')),
                );
                return;
              }
              try {
                final parsed = json.decode(raw);
                if (parsed is! Map<String, dynamic>) {
                  throw Exception('格式错误');
                }
                final count = await StorageService.instance.importData(parsed);
                if (mounted) {
                  context.read<ChatProvider>().reloadFromStorage();
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('成功导入 $count 条消息记录！')),
                  );
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('导入失败，请检查 JSON 格式是否正确: $e')),
                );
              }
            },
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
  }

  void _handleLogout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？退出后需要重新输入账号密码登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              final sp = context.read<SettingsProvider>();
              sp.logout();
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
                (route) => false,
              );
            },
            child: const Text('确认退出'),
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
        title: const Text('账户设置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '保存',
            onPressed: _saveAccount,
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 基本资料
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('基本资料', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    // 登录账号（只读显示，注册后锁定）
                    TextField(
                      controller: _loginAccountCtrl,
                      readOnly: true,
                      decoration: InputDecoration(
                        labelText: '登录账号',
                        helperText: '系统注册账号 (唯一凭证，不可更改)',
                        prefixIcon: const Icon(Icons.lock_outline, size: 20),
                        filled: true,
                        fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    // 用户名（聊天界面展示，可自由修改）
                    TextField(
                      controller: _userNameCtrl,
                      focusNode: _userNameFocus,
                      decoration: const InputDecoration(
                        labelText: '聊天用户名',
                        helperText: '聊天界面气泡中展示的昵称，可随时更改',
                        prefixIcon: Icon(Icons.edit_outlined, size: 20),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 22,
                          backgroundColor: Colors.transparent,
                          backgroundImage: ImagePickerHelper.decodeBase64Image(s.userAvatar) != null
                              ? MemoryImage(ImagePickerHelper.decodeBase64Image(s.userAvatar)!)
                              : null,
                          child: ImagePickerHelper.decodeBase64Image(s.userAvatar) == null
                              ? Container(
                                  width: 44,
                                  height: 44,
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [Color(0xFF0284C7), Color(0xFF0EA5E9)],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.person, color: Colors.white, size: 24),
                                )
                              : null,
                        ),
                        const SizedBox(width: 12),
                        const Text('用户头像', style: TextStyle(fontSize: 14)),
                        const Spacer(),
                        if (s.userAvatar.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                            tooltip: '恢复默认',
                            onPressed: () {
                              s.userAvatar = '';
                              sp.updateSettings(s);
                            },
                          ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.image_outlined, size: 16),
                          label: const Text('选择图片'),
                          onPressed: () async {
                            final base64Image = await ImagePickerHelper.pickImageAsBase64();
                            if (base64Image != null && mounted) {
                              s.userAvatar = base64Image;
                              sp.updateSettings(s);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('用户头像已更新')),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    TextField(
                      controller: _aiNameCtrl,
                      focusNode: _aiNameFocus,
                      decoration: const InputDecoration(
                        labelText: 'AI 助手名称',
                        hintText: '如 Aether-X',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: const Color(0xFF0284C7).withOpacity(0.15),
                        backgroundImage: ImagePickerHelper.decodeBase64Image(s.aiAvatar) != null
                            ? MemoryImage(ImagePickerHelper.decodeBase64Image(s.aiAvatar)!)
                            : null,
                        child: ImagePickerHelper.decodeBase64Image(s.aiAvatar) == null
                            ? const Icon(Icons.smart_toy_outlined, color: Color(0xFF0284C7))
                            : null,
                      ),
                      const SizedBox(width: 12),
                      const Text('AI 头像', style: TextStyle(fontSize: 14)),
                      const Spacer(),
                      if (s.aiAvatar.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                          tooltip: '恢复默认',
                          onPressed: () {
                            s.aiAvatar = '';
                            sp.updateSettings(s);
                          },
                        ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.image_outlined, size: 16),
                        label: const Text('选择图片'),
                        onPressed: () async {
                          final base64Image = await ImagePickerHelper.pickImageAsBase64();
                          if (base64Image != null && mounted) {
                            s.aiAvatar = base64Image;
                            sp.updateSettings(s);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('AI 头像已更新')),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 会话与聊天记录管理
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('会话与数据管理', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0284C7).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.forum_outlined, color: Color(0xFF0284C7)),
                    ),
                    title: const Text('会话管理', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('卡片流管理、单选/多选批量删除、防误删及备份整合'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SessionManagementScreen()),
                      );
                    },
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0284C7).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.search, color: Color(0xFF0284C7)),
                    ),
                    title: const Text('聊天记录检索与定位'),
                    subtitle: const Text('支持模糊搜索、按日期和只看图片筛选、上下翻滚定位'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ChatSearchScreen()),
                      );
                    },
                  ),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.file_upload_outlined, size: 18),
                          label: const Text('导出聊天备份'),
                          onPressed: _exportChatData,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.file_download_outlined, size: 18),
                          label: const Text('导入合并数据'),
                          onPressed: _importChatData,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 修改密码
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('修改登录密码', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _oldPwdCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '原密码',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _newPwdCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '新密码',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirmPwdCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '确认新密码',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _changePassword,
                      child: const Text('确认修改'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // 退出登录按钮
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            label: const Text(
              '退出登录',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            onPressed: _handleLogout,
          ),
          const SizedBox(height: 32),
        ],
      ),
      ),
    );
  }
}
