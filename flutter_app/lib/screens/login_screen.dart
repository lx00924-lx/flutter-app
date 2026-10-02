import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/app_config.dart';
import '../providers/settings_provider.dart';
import '../providers/chat_provider.dart';
import '../utils/app_colors.dart';
import '../utils/url_launcher_helper.dart';
import '../widgets/legal_documents.dart';
import 'chat_screen.dart';

/// App 登录页。
///
/// ⚠️ **本页刻意不再提供"注册"入口**（2026-10-02 移除「账号登录 / 新用户注册」
/// 分段卡与整套注册表单）。
///
/// 为什么要去掉：注册现在统一在**官网**进行，且必须过「邮箱验证码 + Cloudflare
/// 人机验证」，一个邮箱只能开一个账号。而 App 内原先那套「填账号名 + 密码」的表单
/// 对应的服务端 `/api/register` 已要求 `email` + `code` 两个必填字段 ——
/// 留着它只会**必然被 400 打回**，用户看到的是"注册失败"却查不出原因。
/// 人机验证、域名校验这类东西也本来就应该在浏览器里做。
///
/// 所以底部只留一个跳转：「还没有账号？点击前往官网注册」。
/// 顺带的好处：注册流程完全不碰「1 台手机 + 1 台电脑」的单点互斥逻辑
///（官网刻意没有登录态，不占任何槽位）。
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  /// 用户协议 / 隐私政策是否已勾选（未勾选不允许登录）。
  bool _agreedToTerms = false;

  // 登录表单
  final TextEditingController _loginAccountCtrl = TextEditingController();
  final TextEditingController _loginPasswordCtrl = TextEditingController();
  bool _obscureLoginPassword = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _loginAccountCtrl.dispose();
    _loginPasswordCtrl.dispose();
    super.dispose();
  }

  void _handleLogin() async {
    final account = _loginAccountCtrl.text.trim();
    final password = _loginPasswordCtrl.text;

    // 兜底：按钮虽已置灰，键盘回车仍可能走到这里
    if (!_agreedToTerms) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先阅读并同意《用户协议》和《隐私政策》')),
      );
      return;
    }
    if (account.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入登录账号')),
      );
      return;
    }
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入登录密码')),
      );
      return;
    }

    setState(() => _isLoading = true);
    final sp = context.read<SettingsProvider>();
    final result = await sp.loginWithServer(account, password);

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result['success'] == true) {
      context.read<ChatProvider>().reloadFromStorage();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('欢迎回来，${sp.settings.userName}！')),
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ChatScreen()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message']?.toString() ?? '账号或密码不正确，请重新输入'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  /// 用系统默认浏览器打开官网（注册入口在那里）。
  ///
  /// 地址取 `AppConfig.normalizedServerBaseUrl`（= 官网本身），**不写死域名** ——
  /// 自建部署时用 `--dart-define=SERVER_BASE_URL=...` 一改，这里跟着变。
  /// 打不开时明确告知失败并给出网址，不做"假装跳转了"。
  Future<void> _openOfficialSite() async {
    final site = AppConfig.normalizedServerBaseUrl;
    final opened = await UrlLauncherHelper.openUrl(site);
    if (!mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('没能自动打开浏览器，请手动访问官网注册：$site')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryColor = const Color(0xFF0284C7);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // App 标志与头部
                  Center(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF0284C7), Color(0xFF2563EB)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: primaryColor.withOpacity(0.3),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.smart_toy_outlined,
                        color: Colors.white,
                        size: 38,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Aether-X AI 智能助手',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '安全连接私有云端模型与本地自动化 Agent',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // 内容区域：只剩登录表单（注册已移到官网，见类注释）
                  _buildLoginForm(isDark, primaryColor),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoginForm(bool isDark, Color primaryColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _loginAccountCtrl,
          decoration: InputDecoration(
            labelText: '登录账号',
            hintText: '请输入注册账号',
            prefixIcon: const Icon(Icons.account_circle_outlined),
            filled: true,
            fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _loginPasswordCtrl,
          obscureText: _obscureLoginPassword,
          decoration: InputDecoration(
            labelText: '登录密码',
            hintText: '请输入密码',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(
                _obscureLoginPassword ? Icons.visibility_off : Icons.visibility,
                size: 20,
              ),
              onPressed: () => setState(() => _obscureLoginPassword = !_obscureLoginPassword),
            ),
            filled: true,
            fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
              ),
            ),
          ),
          onSubmitted: (_) => _handleLogin(),
        ),
        const SizedBox(height: 12),
        // 用户协议 / 隐私政策确认：不勾选不能登录。
        // 目的很直接——把"只能控制自己拥有或已获授权的设备"这条明确告知使用者，
        // 出事时这份"已告知并同意"的记录比事后辩解有用得多。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: Checkbox(
                value: _agreedToTerms,
                onChanged: (v) => setState(() => _agreedToTerms = v ?? false),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '我已阅读并同意',
                      style: TextStyle(fontSize: 12, color: AppColors.secondary(context)),
                    ),
                    InkWell(
                      onTap: () => showLegalDocument(context, LegalDocument.terms),
                      child: Text(
                        '《用户协议》',
                        style: TextStyle(fontSize: 12, color: primaryColor, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text('和', style: TextStyle(fontSize: 12, color: AppColors.secondary(context))),
                    InkWell(
                      onTap: () => showLegalDocument(context, LegalDocument.privacy),
                      child: Text(
                        '《隐私政策》',
                        style: TextStyle(fontSize: 12, color: primaryColor, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '，并确认只对自己拥有或已获授权的设备使用远程控制。',
                      style: TextStyle(fontSize: 12, color: AppColors.secondary(context)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 2,
          ),
          onPressed: (_isLoading || !_agreedToTerms) ? null : _handleLogin,
          child: _isLoading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text(
                  '立即登录',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
        ),
        const SizedBox(height: 16),
        // 注册入口：跳到官网（App 内不再注册，原因见文件顶部注释）
        TextButton.icon(
          onPressed: _openOfficialSite,
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text(
            '还没有账号？点击前往官网注册',
            style: TextStyle(color: primaryColor, fontSize: 13),
          ),
        ),
      ],
    );
  }
}
