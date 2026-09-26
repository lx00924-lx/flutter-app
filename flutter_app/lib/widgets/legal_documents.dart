import 'package:flutter/material.dart';

/// 需要展示的法律文档。
enum LegalDocument {
  /// 用户协议 / 服务条款（仓库根目录 `TERMS.md`）。
  terms,

  /// 隐私政策（仓库根目录 `PRIVACY.md`）。
  privacy,
}

/// 文档正文（App 内精简版）。
///
/// 为什么内嵌一份而不是只放外链：这是一个"远程控制自己电脑"的工具，用户可能在
/// 没有网络、或还没登录的情况下就要看到关键约定；完整版始终以仓库里的
/// TERMS.md / PRIVACY.md 为准，这里只保留**必须让人看到**的那几条。
String legalDocumentTitle(LegalDocument doc) => switch (doc) {
      LegalDocument.terms => '用户协议 / 服务条款',
      LegalDocument.privacy => '隐私政策',
    };

/// 仓库里的完整版路径（相对仓库根目录）。
String legalDocumentPath(LegalDocument doc) => switch (doc) {
      LegalDocument.terms => 'TERMS.md',
      LegalDocument.privacy => 'PRIVACY.md',
    };

String legalDocumentBody(LegalDocument doc) => switch (doc) {
      LegalDocument.terms => '''
一、授权范围（最重要）

你只能对自己拥有所有权、或已获得设备所有者明确书面授权的设备使用本软件的
远程控制能力。未经授权控制他人设备的一切后果由你自行承担；作者不承担任何责任，
并有权停止向你提供服务。

二、按现状提供，无任何担保

本软件与服务按"现状"提供，不附带任何明示或默示担保，包括但不限于适销性、
特定用途适用性、不侵权、安全性、不中断、无错误、数据不丢失。作者不承诺任何
服务等级（SLA），服务可能因维护、升级、故障或第三方原因中断、延迟或丢数据。

三、责任限制

在适用法律允许的最大范围内，作者不对任何间接、附带、特殊、惩罚性或后果性
损害承担责任（含利润损失、数据丢失、业务中断）。就任何索赔，作者的累计赔偿
责任上限为你就本服务实际支付的费用；免费使用情形下该上限为 0 元。

提示：中华人民共和国法律下，故意或重大过失造成对方财产损失、以及造成人身
损害的免责条款无效；本协议不排除依法不能排除的责任。

四、你的责任

不得用于：未经授权控制他人设备、窃取数据、植入恶意程序、侵犯他人权益、
传播违法信息、攻击或绕过本服务鉴权、转售官方托管服务。你对自己账号下发生的
一切行为（含发起的任务与消息）负责。

五、账号与数据

请妥善保管账号、密码与配对 Token —— Token 泄露等同于他人可直接驱动你的电脑端
Agent，请立即重置。数据的收集与处理规则见《隐私政策》。

六、开源许可

本软件以 Apache License 2.0 发布：可自由使用、修改、分发（含闭源与商业用途），
须保留版权与许可声明；该许可不授予任何商标权。许可范围仅覆盖代码本身，
托管服务由本协议约束。

七、变更与终止

作者可随时更新本协议，公布即生效；你违反协议时作者可随时停止服务、封禁账号。
本协议适用中华人民共和国法律。
''',
      LegalDocument.privacy => '''
一、中继保存什么

• 账号：用户名 + 密码哈希（bcrypt，不可逆，不存明文密码）
• 设置：模型 API 端点、你填写的 API Key、Agent 配对 Token、界面偏好
  （API Key 与 Token 均以 AES-256-GCM 加密后落盘，主密钥存放在数据目录之外）
• 消息：你与 AI / Agent 的对话内容与执行记录、主动发送的图片/文件/语音
• 会话状态：单点登录心跳（设备类型、在线状态），用于 1 手机 + 1 电脑互斥登录
• 待办：挂起中的选择框 / 授权请求（24 小时后自动清理）
• 运行日志：连接、同步、错误记录（不含密码与密钥）

不收集：手机号、邮箱、通讯录、短信、精确位置、相册扫描，以及与软件无关的文件。

二、数据在哪里

中继实例所在服务器（自建 = 你自己的服务器）的 messages_data / messages_media
与日志文件；你的手机/电脑本机的会话缓存；电脑端 Bridge 仅保留可选的本地日志。

三、会发给谁

你发送的内容会转发到**你自己配置的**模型 API 端点（受对应服务商隐私政策约束）
以及你自己的电脑端 Agent。我们不向任何第三方出售、出租或共享你的数据，
法律法规另有强制要求的除外。

四、保存多久

• 聊天消息：默认保留 180 天，到期自动清理（部署者可用环境变量调整，0 = 永久）
• 图片 / 文件 / 语音：默认保留 90 天
• 选择框 / 授权请求：24 小时后自动清理
你也可以随时手动删除消息或申请删除账号数据，不必等保留期到期。

五、安全与风险

已做：密码 bcrypt 哈希；API Key 与 Token AES-256-GCM 加密落盘（主密钥在数据
目录之外，只拿到数据文件副本解不出明文）；账号级 Token 隔离；单点登录互斥；
本地服务默认只监听回环地址；默认保留期定期清理。

风险提示：若服务器被完整攻破（含主密钥文件）仍可能被解密——数据特别敏感时
建议自建中继，并让部署者设置 STORE_API_KEYS=0 使密钥完全不落盘；请使用权限
最小、可随时吊销的 API Key；请勿把本地 3080 端口直接暴露公网。

六、你的权利

可随时删除消息（同步删除服务端记录）；可申请删除账号、设置、消息与媒体文件；
可导出数据（自建实例直接导出 JSON）；撤回同意无需说明理由。

七、联系方式

通过仓库 issue 提交隐私相关问题或删除申请。
''',
    };

/// 弹出文档阅读框（登录页与设置页共用）。
Future<void> showLegalDocument(BuildContext context, LegalDocument doc) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(legalDocumentTitle(doc), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: SelectableText(
            legalDocumentBody(doc),
            style: const TextStyle(fontSize: 12.5, height: 1.55),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('我已阅读'),
        ),
      ],
    ),
  );
}
