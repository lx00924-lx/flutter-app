import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../services/sync_service.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> with SingleTickerProviderStateMixin {
  late final MobileScannerController _controller;
  late final AnimationController _animController;
  late final Animation<double> _animLine;

  bool _isProcessing = false;
  bool _torchEnabled = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      torchEnabled: false,
    );

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _animLine = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleBarcode(BarcodeCapture capture) async {
    if (_isProcessing) return;
    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final rawValue = barcodes.first.rawValue;
    if (rawValue == null || rawValue.trim().isEmpty) return;

    await _processAuthCode(rawValue.trim());
  }

  Future<void> _processAuthCode(String code) async {
    setState(() => _isProcessing = true);
    _controller.stop();

    String authCode = code;
    // 解析支持三种格式：
    //   1) 电脑端 bridge 生成的二维码：URL 形如 https://host?authSession=AUTH_XXXXXX
    //   2) 自定义协议前缀：lx_auth:AUTH_XXXXXX
    //   3) JSON：{"authCode": "..."} / {"code": "..."} / {"sessionCode": "..."}
    if (code.startsWith('lx_auth:')) {
      authCode = code.substring('lx_auth:'.length).trim();
    } else if (code.startsWith('{') && code.endsWith('}')) {
      try {
        final json = jsonDecode(code);
        authCode = (json['sessionCode'] ?? json['authCode'] ?? json['code'] ?? authCode)
            .toString()
            .trim();
      } catch (_) {}
    } else if (code.contains('authSession=') || code.contains('authCode=')) {
      // 关键修复：bridge 的二维码内容是 URL，此前未解析参数，
      // 导致把整条 URL 当成配对码提交，服务端必然查不到该会话。
      try {
        final uri = Uri.parse(code);
        authCode = (uri.queryParameters['authSession'] ??
                uri.queryParameters['authCode'] ??
                uri.queryParameters['sessionCode'] ??
                authCode)
            .trim();
      } catch (_) {}
    }

    // 扫码者身份：服务端据此校验账号真实性并把 token 绑定到该账号
    final userId = context.read<SettingsProvider>().syncUserId;
    if (userId.isEmpty || userId == 'guest' || userId == 'default_user') {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showErrorAndResume('请先登录账号后再进行扫码配对');
      }
      return;
    }

    try {
      final serverUrl = SyncService.instance.serverBaseUrl;

      final uri = Uri.parse('$serverUrl/api/bridge/auth-confirm');
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          // 服务端字段名为 sessionCode（旧字段 authCode 服务端也兼容）
          'sessionCode': authCode,
          // 扫码者身份：服务端校验通过后把 token 绑定到该账号
          'userId': userId,
          'device': 'mobile',
        }),
      ).timeout(const Duration(seconds: 8));

      if (!mounted) return;

      if (res.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🎉 电脑 Agent 配对成功！已建立长连接'),
            backgroundColor: Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.of(context).pop(true);
      } else {
        final data = jsonDecode(res.body);
        final err = data['error'] ?? '授权失败或已过期';
        _showErrorAndResume(err);
      }
    } catch (e) {
      if (!mounted) return;
      _showErrorAndResume('网络连接异常: $e');
    }
  }

  void _showErrorAndResume(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFEF4444),
        behavior: SnackBarBehavior.floating,
      ),
    );
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _isProcessing = false);
        _controller.start();
      }
    });
  }

  void _showManualInputDialog() {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.keyboard_alt_outlined, color: Color(0xFF0284C7)),
            SizedBox(width: 8),
            Text('手动输入配对码', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '请输入电脑终端上显示的 6 位配对授权码：',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              autofocus: true,
              maxLength: 12,
              decoration: InputDecoration(
                hintText: '如: 894215',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final val = textController.text.trim();
              Navigator.pop(ctx);
              if (val.isNotEmpty) {
                _processAuthCode(val);
              }
            },
            child: const Text('立即配对'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const scanBoxSize = 250.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. 真实相机取景
          MobileScanner(
            controller: _controller,
            onDetect: _handleBarcode,
          ),

          // 2. 半透明遮罩与中央扫描框
          LayoutBuilder(
            builder: (ctx, constraints) {
              final double left = (constraints.maxWidth - scanBoxSize) / 2;
              final double top = (constraints.maxHeight - scanBoxSize) / 2 - 40;

              return Stack(
                children: [
                  // 100% 透明全景取景，无任何遮罩黑块

                  // 扫描框边角修饰与对准线
                  Positioned(
                    left: left,
                    top: top,
                    width: scanBoxSize,
                    height: scanBoxSize,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF0284C7), width: 2.5),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF0284C7).withOpacity(0.25),
                            blurRadius: 12,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: AnimatedBuilder(
                        animation: _animLine,
                        builder: (ctx, child) {
                          return Align(
                            alignment: Alignment(0, _animLine.value * 2 - 1),
                            child: Container(
                              height: 3,
                              margin: const EdgeInsets.symmetric(horizontal: 16),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(2),
                                gradient: const LinearGradient(
                                  colors: [
                                    Colors.transparent,
                                    Color(0xFF38BDF8),
                                    Color(0xFF0284C7),
                                    Color(0xFF38BDF8),
                                    Colors.transparent,
                                  ],
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0xFF0284C7),
                                    blurRadius: 8,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),

                  // 扫描提示词
                  Positioned(
                    left: 20,
                    right: 20,
                    top: top + scanBoxSize + 24,
                    child: const Text(
                      '将电脑终端运行生成的配对二维码置于框内\n即可自动识别并绑定',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),

          // 3. 顶部导航与操作栏
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Text(
                    '扫码连接电脑 Agent',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _torchEnabled ? Icons.flash_on : Icons.flash_off,
                      color: _torchEnabled ? const Color(0xFFFACC15) : Colors.white,
                    ),
                    onPressed: () {
                      _controller.toggleTorch();
                      setState(() => _torchEnabled = !_torchEnabled);
                    },
                  ),
                ],
              ),
            ),
          ),

          // 4. 底部备用手动输入按钮
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: OutlinedButton.icon(
                onPressed: _showManualInputDialog,
                icon: const Icon(Icons.edit, size: 16, color: Colors.white),
                label: const Text(
                  '无法扫码？手动输入配对码',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white54),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
              ),
            ),
          ),

          // 5. 正在处理中的遮罩
          if (_isProcessing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF0284C7)),
                    SizedBox(height: 16),
                    Text(
                      '正在验证并握手连接...',
                      style: TextStyle(color: Colors.white, fontSize: 15),
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
