import 'package:flutter/material.dart';

/// 全局语义色。**所有"次要文字/次要图标"的颜色都必须从这里取。**
///
/// ## 为什么要有这个文件
///
/// 之前各处直接写 `Colors.grey` / `Colors.grey.shade600` —— 那些颜色是照**浅色背景**
/// 调的。切到深色模式后，`grey.shade600`(#757575) 压在 `#1E293B` 的卡片上对比度只有
/// 2:1 左右，副标题基本看不清；而 `Colors.grey`(#9E9E9E) 又和 Material 3 自己算出来的
/// 次级文字色不一致 —— 同一页里两种灰并存，看着就是"字体没统一"。
///
/// 这里统一映射到 `ColorScheme` 的语义槽位，浅色/深色由 Material 3 自己算：
///
/// | 用途 | 浅色下约等于 | 深色下约等于 |
/// | :--- | :--- | :--- |
/// | [secondary] 副标题、说明、次要图标 | `#44474E` | `#C4C7C5` |
/// | [faint] 更弱的提示、占位、分隔 | `#74777F` | `#8E9099` |
///
/// ⚠️ 新增界面时**不要再写** `Colors.grey` 系列；`Colors.black/white` 只允许出现在
/// **遮罩与阴影**里（那些本来就与明暗模式无关），不允许拿来做文字颜色。
class AppColors {
  AppColors._();

  /// 次要文字：卡片副标题、条目说明、次要图标（比如列表右侧的 `>` 箭头）。
  static Color secondary(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;

  /// 更弱的文字：占位提示、脚注、时间戳。
  static Color faint(BuildContext context) => Theme.of(context).colorScheme.outline;

  /// 输入框 / 容器的浅底色。
  static Color subtleFill(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerHighest;

  /// 分隔线。
  static Color divider(BuildContext context) => Theme.of(context).dividerColor;
}
