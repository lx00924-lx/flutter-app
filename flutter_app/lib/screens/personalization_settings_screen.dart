import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../utils/image_picker_helper.dart';

class PersonalizationSettingsScreen extends StatefulWidget {
  const PersonalizationSettingsScreen({super.key});

  @override
  State<PersonalizationSettingsScreen> createState() => _PersonalizationSettingsScreenState();
}

class _PersonalizationSettingsScreenState extends State<PersonalizationSettingsScreen> {
  late TextEditingController _splashTitleCtrl;
  late TextEditingController _splashSubtitleCtrl;
  late TextEditingController _splashDurationCtrl;
  late TextEditingController _systemPromptCtrl;
  late TextEditingController _opacityCtrl;

  final FocusNode _splashTitleFocus = FocusNode();
  final FocusNode _splashSubtitleFocus = FocusNode();
  final FocusNode _splashDurationFocus = FocusNode();
  final FocusNode _systemPromptFocus = FocusNode();
  final FocusNode _opacityFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    final s = context.read<SettingsProvider>().settings;
    _splashTitleCtrl = TextEditingController(text: s.splashTitle);
    _splashSubtitleCtrl = TextEditingController(text: s.splashSubtitle);
    _splashDurationCtrl = TextEditingController(text: s.splashDurationMs.toString());
    _systemPromptCtrl = TextEditingController(text: s.systemPrompt);
    _opacityCtrl = TextEditingController(text: s.backgroundOpacity.toString());

    // 失焦时自动保存，消除每次按键的卡顿与重绘
    _splashTitleFocus.addListener(() {
      if (!_splashTitleFocus.hasFocus) _savePersonalization();
    });
    _splashSubtitleFocus.addListener(() {
      if (!_splashSubtitleFocus.hasFocus) _savePersonalization();
    });
    _splashDurationFocus.addListener(() {
      if (!_splashDurationFocus.hasFocus) _savePersonalization();
    });
    _systemPromptFocus.addListener(() {
      if (!_systemPromptFocus.hasFocus) _savePersonalization();
    });
    _opacityFocus.addListener(() {
      if (!_opacityFocus.hasFocus) _savePersonalization();
    });
  }

  void _savePersonalization() {
    if (!mounted) return;
    final sp = context.read<SettingsProvider>();
    final s = sp.settings;
    s.splashTitle = _splashTitleCtrl.text.trim();
    s.splashSubtitle = _splashSubtitleCtrl.text.trim();
    final dur = int.tryParse(_splashDurationCtrl.text.trim());
    if (dur != null) s.splashDurationMs = dur;
    s.systemPrompt = _systemPromptCtrl.text.trim();
    final op = int.tryParse(_opacityCtrl.text.trim());
    if (op != null && op >= 0 && op <= 100) s.backgroundOpacity = op;
    sp.updateSettings(s);
  }

  @override
  void dispose() {
    _savePersonalization();
    _splashTitleFocus.dispose();
    _splashSubtitleFocus.dispose();
    _splashDurationFocus.dispose();
    _systemPromptFocus.dispose();
    _opacityFocus.dispose();
    _splashTitleCtrl.dispose();
    _splashSubtitleCtrl.dispose();
    _splashDurationCtrl.dispose();
    _systemPromptCtrl.dispose();
    _opacityCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sp = context.watch<SettingsProvider>();
    final s = sp.settings;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('个性化设置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '保存',
            onPressed: () {
              FocusScope.of(context).unfocus();
              _savePersonalization();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('个性化设置已保存')),
              );
            },
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // 界面显示与壁纸
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('界面与显示', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('暗黑模式', style: TextStyle(fontSize: 14)),
                    value: s.isDarkMode,
                    onChanged: (val) => sp.toggleTheme(),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('暗黑模式下仍显示自定义壁纸', style: TextStyle(fontSize: 14)),
                    value: s.showBackgroundInDarkMode,
                    onChanged: (val) {
                      s.showBackgroundInDarkMode = val;
                      sp.updateSettings(s);
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.grey.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.withOpacity(0.3)),
                          image: ImagePickerHelper.decodeBase64Image(s.customBackground) != null
                              ? DecorationImage(
                                  image: MemoryImage(ImagePickerHelper.decodeBase64Image(s.customBackground)!),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: ImagePickerHelper.decodeBase64Image(s.customBackground) == null
                            ? const Icon(Icons.wallpaper, color: Color(0xFF0284C7))
                            : null,
                      ),
                      const SizedBox(width: 12),
                      const Text('自定义聊天背景', style: TextStyle(fontSize: 14)),
                      const Spacer(),
                      if (s.customBackground.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                          tooltip: '清除背景',
                          onPressed: () {
                            s.customBackground = '';
                            sp.updateSettings(s);
                          },
                        ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.image_outlined, size: 16),
                        label: const Text('选择图片'),
                        onPressed: () async {
                          final base64Image = await ImagePickerHelper.pickImageAsBase64();
                          if (base64Image != null && mounted) {
                            s.customBackground = base64Image;
                            sp.updateSettings(s);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('背景图片已实时更换并保存')),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('字体大小', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _buildFontSizeButton(13, '小号\n13px', s.chatFontSize == 13),
                      const SizedBox(width: 8),
                      _buildFontSizeButton(15, '标准\n15px', s.chatFontSize == 15),
                      const SizedBox(width: 8),
                      _buildFontSizeButton(16, '大号\n16px', s.chatFontSize == 16),
                      const SizedBox(width: 8),
                      _buildFontSizeButton(18, '特大\n18px', s.chatFontSize == 18),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '预览：这是一条示例聊天消息文本效果',
                      style: TextStyle(fontSize: s.chatFontSize.toDouble()),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _opacityCtrl,
                    focusNode: _opacityFocus,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '背景不透明度 (0-100%)',
                      hintText: '100',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 启动页设置
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('启动页设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用启动页', style: TextStyle(fontSize: 14)),
                    subtitle: Text(
                      s.enableSplash ? '已开启，冷启动展示指定时长' : '已关闭，冷启动直接秒进聊天界面',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                    value: s.enableSplash,
                    onChanged: (val) {
                      s.enableSplash = val;
                      sp.updateSettings(s);
                    },
                  ),
                  TextField(
                    controller: _splashTitleCtrl,
                    focusNode: _splashTitleFocus,
                    decoration: const InputDecoration(
                      labelText: '启动主标题',
                      hintText: 'Aether-X',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _splashSubtitleCtrl,
                    focusNode: _splashSubtitleFocus,
                    decoration: const InputDecoration(
                      labelText: '启动子文本',
                      hintText: 'Loading AI Experience',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _splashDurationCtrl,
                    focusNode: _splashDurationFocus,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '持续时间 (ms)',
                      hintText: '1000',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.grey.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.withOpacity(0.3)),
                          image: ImagePickerHelper.decodeBase64Image(s.splashImage) != null
                              ? DecorationImage(
                                  image: MemoryImage(ImagePickerHelper.decodeBase64Image(s.splashImage)!),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: ImagePickerHelper.decodeBase64Image(s.splashImage) == null
                            ? const Icon(Icons.rocket_launch_outlined, color: Color(0xFF0284C7))
                            : null,
                      ),
                      const SizedBox(width: 12),
                      const Text('启动图片', style: TextStyle(fontSize: 14)),
                      const Spacer(),
                      if (s.splashImage.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                          tooltip: '恢复默认',
                          onPressed: () {
                            s.splashImage = '';
                            sp.updateSettings(s);
                          },
                        ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.photo_outlined, size: 16),
                        label: const Text('选择图片'),
                        onPressed: () async {
                          final base64Image = await ImagePickerHelper.pickImageAsBase64();
                          if (base64Image != null && mounted) {
                            s.splashImage = base64Image;
                            sp.updateSettings(s);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('启动页图片已实时更新并保存')),
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

          // 系统回复逻辑 (System Prompt) - 自适应文字长度，弹性向下延展
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.psychology_outlined, color: Color(0xFF0284C7), size: 20),
                      SizedBox(width: 8),
                      Text('回复逻辑 (System Prompt)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '设置 AI 的角色设定与系统前置提示词，输入框会随文字长度自动撑开扩展。',
                    style: TextStyle(fontSize: 12, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _systemPromptCtrl,
                    focusNode: _systemPromptFocus,
                    minLines: 3,
                    maxLines: null, // 自适应文字长度，不再局限于固定狭小滑动区域
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(fontSize: 14, height: 1.5),
                    decoration: const InputDecoration(
                      labelText: '系统人设与回复逻辑',
                      hintText: '例如：你是一个专业的程序员，回答精简准确，优先给出高质量代码...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(14),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
      ),
    );
  }

  Widget _buildFontSizeButton(int size, String label, bool isSelected) {
    return Expanded(
      child: InkWell(
        onTap: () {
          final sp = context.read<SettingsProvider>();
          final s = sp.settings;
          s.chatFontSize = size;
          sp.updateSettings(s);
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF0284C7) : Colors.transparent,
            border: Border.all(
              color: isSelected ? const Color(0xFF0284C7) : Colors.grey.shade400,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? Colors.white : null,
            ),
          ),
        ),
      ),
    );
  }
}
