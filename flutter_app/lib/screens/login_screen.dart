import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../providers/chat_provider.dart';
import 'chat_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  int _tabIndex = 0; // 0: 登录, 1: 注册

  // 登录表单
  final TextEditingController _loginAccountCtrl = TextEditingController();
  final TextEditingController _loginPasswordCtrl = TextEditingController();
  bool _obscureLoginPassword = true;

  // 注册表单
  final TextEditingController _regAccountCtrl = TextEditingController();
  final TextEditingController _regUserNameCtrl = TextEditingController();
  final TextEditingController _regPasswordCtrl = TextEditingController();
  final TextEditingController _regConfirmPasswordCtrl = TextEditingController();
  bool _obscureRegPassword = true;
  bool _obscureRegConfirmPassword = true;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _loginAccountCtrl.dispose();
    _loginPasswordCtrl.dispose();
    _regAccountCtrl.dispose();
    _regUserNameCtrl.dispose();
    _regPasswordCtrl.dispose();
    _regConfirmPasswordCtrl.dispose();
    super.dispose();
  }

  void _handleLogin() async {
    final account = _loginAccountCtrl.text.trim();
    final password = _loginPasswordCtrl.text;

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

  void _handleRegister() async {
    final account = _regAccountCtrl.text.trim();
    final userName = _regUserNameCtrl.text.trim();
    final password = _regPasswordCtrl.text;
    final confirmPassword = _regConfirmPasswordCtrl.text;

    if (account.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入登录账号')),
      );
      return;
    }
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请设置登录密码')),
      );
      return;
    }
    if (password != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('两次输入的密码不一致'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    final sp = context.read<SettingsProvider>();
    final result = await sp.registerWithServer(
      account: account,
      userName: userName.isNotEmpty ? userName : account,
      password: password,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result['success'] == true) {
      context.read<ChatProvider>().reloadFromStorage();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('注册成功！欢迎您，$account')),
      );

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ChatScreen()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message']?.toString() ?? '注册失败，请稍后重试'),
          backgroundColor: Colors.redAccent,
        ),
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

                  // 登录 / 注册 分段选择卡
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () => setState(() => _tabIndex = 0),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _tabIndex == 0
                                    ? (isDark ? const Color(0xFF0F172A) : Colors.white)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: _tabIndex == 0
                                    ? [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.06),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Text(
                                '账号登录',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: _tabIndex == 0 ? FontWeight.bold : FontWeight.normal,
                                  color: _tabIndex == 0 ? primaryColor : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: InkWell(
                            onTap: () => setState(() => _tabIndex = 1),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _tabIndex == 1
                                    ? (isDark ? const Color(0xFF0F172A) : Colors.white)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: _tabIndex == 1
                                    ? [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.06),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Text(
                                '新用户注册',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: _tabIndex == 1 ? FontWeight.bold : FontWeight.normal,
                                  color: _tabIndex == 1 ? primaryColor : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 内容区域
                  if (_tabIndex == 0) _buildLoginForm(isDark, primaryColor)
                  else _buildRegisterForm(isDark, primaryColor),
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
        const SizedBox(height: 28),
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
          onPressed: _isLoading ? null : _handleLogin,
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
        TextButton(
          onPressed: () => setState(() => _tabIndex = 1),
          child: Text(
            '还没有账号？立即免费注册',
            style: TextStyle(color: primaryColor, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildRegisterForm(bool isDark, Color primaryColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _regAccountCtrl,
          decoration: InputDecoration(
            labelText: '登录账号 *',
            hintText: '作为唯一登录凭证，注册后不可修改',
            prefixIcon: const Icon(Icons.badge_outlined),
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
        const SizedBox(height: 14),
        TextField(
          controller: _regUserNameCtrl,
          decoration: InputDecoration(
            labelText: '聊天昵称 (选填)',
            hintText: '在聊天界面显示的名称，可随时在设置中修改',
            prefixIcon: const Icon(Icons.person_outline),
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
        const SizedBox(height: 14),
        TextField(
          controller: _regPasswordCtrl,
          obscureText: _obscureRegPassword,
          decoration: InputDecoration(
            labelText: '设置密码 *',
            hintText: '请输入登录密码',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(
                _obscureRegPassword ? Icons.visibility_off : Icons.visibility,
                size: 20,
              ),
              onPressed: () => setState(() => _obscureRegPassword = !_obscureRegPassword),
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
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _regConfirmPasswordCtrl,
          obscureText: _obscureRegConfirmPassword,
          decoration: InputDecoration(
            labelText: '确认密码 *',
            hintText: '请再次输入密码以验证',
            prefixIcon: const Icon(Icons.check_circle_outline),
            suffixIcon: IconButton(
              icon: Icon(
                _obscureRegConfirmPassword ? Icons.visibility_off : Icons.visibility,
                size: 20,
              ),
              onPressed: () => setState(() => _obscureRegConfirmPassword = !_obscureRegConfirmPassword),
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
          onSubmitted: (_) => _handleRegister(),
        ),
        const SizedBox(height: 24),
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
          onPressed: _isLoading ? null : _handleRegister,
          child: _isLoading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text(
                  '注册并开启体验',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
        ),
        const SizedBox(height: 14),
        TextButton(
          onPressed: () => setState(() => _tabIndex = 0),
          child: Text(
            '已有账号？点击返回登录',
            style: TextStyle(color: primaryColor, fontSize: 13),
          ),
        ),
      ],
    );
  }
}
