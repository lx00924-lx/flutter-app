import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_settings.dart';
import '../providers/settings_provider.dart';
import '../services/api_service.dart';

class ApiSettingsScreen extends StatefulWidget {
  const ApiSettingsScreen({super.key});

  @override
  State<ApiSettingsScreen> createState() => _ApiSettingsScreenState();
}

class _ApiSettingsScreenState extends State<ApiSettingsScreen> {
  final ApiService _apiService = ApiService();

  void _showAddOrEditEndpointDialog({ApiModelEndpoint? existing}) {
    final isEditing = existing != null;
    final cardNameCtrl = TextEditingController(text: existing?.cardName ?? '');
    final endpointCtrl = TextEditingController(text: existing?.endpoint ?? 'https://api.deepseek.com');
    final apiKeyCtrl = TextEditingController(text: existing?.apiKey ?? '');
    final modelNameCtrl = TextEditingController(text: existing?.modelName ?? 'deepseek-chat');
    final contextLengthCtrl = TextEditingController(text: (existing?.contextLength ?? 15000).toString());

    bool isFetchingModels = false;
    List<String> fetchedModels = [];

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(
                    isEditing ? Icons.edit_note : Icons.add_circle_outline,
                    color: const Color(0xFF0284C7),
                  ),
                  const SizedBox(width: 8),
                  Text(isEditing ? '编辑 API 端点' : '添加 API 端点'),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: cardNameCtrl,
                      decoration: const InputDecoration(
                        labelText: '卡片显示名称',
                        hintText: '如 DeepSeek-V3 (主界面显示)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: endpointCtrl,
                      decoration: const InputDecoration(
                        labelText: 'API 终端地址',
                        hintText: 'https://api.deepseek.com',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: apiKeyCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'API Key',
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
                            controller: modelNameCtrl,
                            decoration: const InputDecoration(
                              labelText: '模型名称',
                              hintText: 'deepseek-chat 或 ep-xxxx',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (val) {
                              // 若未填卡片名称，自动同步为模型名
                              if (cardNameCtrl.text.trim().isEmpty) {
                                cardNameCtrl.text = val.trim();
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF0284C7),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                          ),
                          onPressed: isFetchingModels
                              ? null
                              : () async {
                                  if (endpointCtrl.text.trim().isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('请先输入 API 终端地址')),
                                    );
                                    return;
                                  }
                                  setDialogState(() => isFetchingModels = true);
                                  try {
                                    final models = await _apiService.fetchModelList(
                                      endpoint: endpointCtrl.text.trim(),
                                      apiKey: apiKeyCtrl.text.trim(),
                                    );
                                    setDialogState(() {
                                      fetchedModels = models;
                                      isFetchingModels = false;
                                    });
                                  } catch (e) {
                                    setDialogState(() => isFetchingModels = false);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('获取模型失败: $e')),
                                    );
                                  }
                                },
                          child: isFetchingModels
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Text('获取列表', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    if (fetchedModels.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xFF1E293B)
                              : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('点击快捷选择模型：', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: fetchedModels.take(8).map((m) {
                                return ActionChip(
                                  label: Text(m, style: const TextStyle(fontSize: 11)),
                                  onPressed: () {
                                    modelNameCtrl.text = m;
                                    if (cardNameCtrl.text.isEmpty || cardNameCtrl.text == '默认模型') {
                                      cardNameCtrl.text = m;
                                    }
                                    setDialogState(() {});
                                  },
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: contextLengthCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '专属上下文长度 (字符/Token)',
                        hintText: '如 32000，超过将滑动截断',
                        border: OutlineInputBorder(),
                        helperText: '超过此长度将从旧消息滑动截断，保持流畅',
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('取消'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    final cardName = cardNameCtrl.text.trim().isNotEmpty
                        ? cardNameCtrl.text.trim()
                        : (modelNameCtrl.text.trim().isNotEmpty ? modelNameCtrl.text.trim() : '未命名模型');
                    final endpoint = endpointCtrl.text.trim();
                    final apiKey = apiKeyCtrl.text.trim();
                    final modelName = modelNameCtrl.text.trim().isNotEmpty
                        ? modelNameCtrl.text.trim()
                        : 'deepseek-chat';
                    final contextLength = int.tryParse(contextLengthCtrl.text.trim()) ?? 15000;

                    final settingsProvider = context.read<SettingsProvider>();

                    if (isEditing) {
                      existing.cardName = cardName;
                      existing.endpoint = endpoint;
                      existing.apiKey = apiKey;
                      existing.modelName = modelName;
                      existing.contextLength = contextLength;
                      settingsProvider.updateApiEndpoint(existing);
                    } else {
                      final newEndpoint = ApiModelEndpoint(
                        cardName: cardName,
                        endpoint: endpoint,
                        apiKey: apiKey,
                        modelName: modelName,
                        contextLength: contextLength,
                      );
                      settingsProvider.addApiEndpoint(newEndpoint);
                    }

                    Navigator.pop(dialogCtx);
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settingsProvider = context.watch<SettingsProvider>();
    final endpoints = settingsProvider.settings.apiEndpoints;
    final activeId = settingsProvider.activeEndpointId;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('大模型 API 设置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, size: 26),
            tooltip: '添加 API 卡片',
            onPressed: () => _showAddOrEditEndpointDialog(),
          ),
        ],
      ),
      body: endpoints.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.api_outlined, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text('暂未配置任何 API 模型端点', style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: () => _showAddOrEditEndpointDialog(),
                    icon: const Icon(Icons.add),
                    label: const Text('立即添加 API'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: endpoints.length,
              itemBuilder: (ctx, index) {
                final ep = endpoints[index];
                final isActive = ep.id == activeId;

                return Card(
                  elevation: isActive ? 2 : 1,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: isActive
                          ? const Color(0xFF0284C7)
                          : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                      width: isActive ? 2 : 1,
                    ),
                  ),
                  margin: const EdgeInsets.only(bottom: 14),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: isActive
                                    ? const Color(0xFF0284C7).withOpacity(0.15)
                                    : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.hub_outlined,
                                color: isActive ? const Color(0xFF0284C7) : Colors.grey,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          ep.cardName,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (isActive) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF0284C7),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: const Text(
                                            '当前使用',
                                            style: TextStyle(color: Colors.white, fontSize: 10),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '模型: ${ep.modelName}',
                                    style: TextStyle(
                                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              tooltip: '编辑配置',
                              onPressed: () => _showAddOrEditEndpointDialog(existing: ep),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                              tooltip: '删除卡片',
                              onPressed: () {
                                settingsProvider.removeApiEndpoint(ep.id);
                              },
                            ),
                          ],
                        ),
                        const Divider(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '终端: ${ep.endpoint}',
                                style: const TextStyle(fontSize: 12, color: Colors.grey),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '截断上限: ${ep.contextLength} 字符/Token',
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                              ),
                            ),
                            const Spacer(),
                            if (!isActive)
                              TextButton(
                                onPressed: () {
                                  settingsProvider.selectEndpoint(ep);
                                },
                                child: const Text('设为当前对话模型'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
