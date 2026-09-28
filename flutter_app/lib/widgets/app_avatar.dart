import 'dart:typed_data';
import 'package:flutter/material.dart';

/// 零闪烁、无缝平滑头像组件 (Zero-Flicker Smooth Avatar)
/// 特性：
/// 1. 静态全局图片 Provider 缓存与 ResizeImage 显存优化，0 毫秒二次渲染开销；
/// 2. gaplessPlayback 持续绘制，杜绝首帧图标闪烁或跳变；
/// 3. 去除首帧回退图标劫持，确保有头像数据时首帧直接呈现图像层。
class AppAvatar extends StatelessWidget {
  final Uint8List? imageBytes;
  final double radius;
  final IconData fallbackIcon;
  final Color? fallbackBgColor;
  final Color? fallbackIconColor;
  final String? semanticLabel;

  /// 以 bytes 的【实例身份】为键。
  ///
  /// 原键是"长度 + 首字节 + 尾字节"，但 JPEG/PNG 的首尾字节是格式固定的
  /// （JPEG `FF…D9`、PNG `89…82`），键实际退化成"只有长度" —— 两张压缩后
  /// 等长的不同头像会互相命中，用户换完头像仍显示旧图。
  ///
  /// 改用实例身份是安全的：SettingsProvider 已保证"源串没变就复用同一个
  /// Uint8List"，而本缓存强引用着这些 bytes（不会被 GC，身份不会被复用）。
  static final Map<Uint8List, MemoryImage> _providerCache = {};

  static MemoryImage _getProvider(Uint8List bytes) {
    return _providerCache.putIfAbsent(bytes, () => MemoryImage(bytes));
  }

  const AppAvatar({
    super.key,
    required this.imageBytes,
    this.radius = 18,
    this.fallbackIcon = Icons.person,
    this.fallbackBgColor,
    this.fallbackIconColor,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final double size = radius * 2;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final defaultBg = fallbackBgColor ??
        (isDark ? const Color(0xFF1E293B) : const Color(0xFFE0F2FE));
    final defaultIconColor = fallbackIconColor ??
        (isDark ? const Color(0xFF94A3B8) : const Color(0xFF0284C7));

    if (imageBytes == null || imageBytes!.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          width: size,
          height: size,
          color: defaultBg,
          child: _buildFallback(size, defaultIconColor),
        ),
      );
    }

    final provider = _getProvider(imageBytes!);

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        color: defaultBg,
        child: Image(
          image: ResizeImage(
            provider,
            width: (size * (MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0)).round(),
            height: (size * (MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0)).round(),
          ),
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) => _buildFallback(size, defaultIconColor),
        ),
      ),
    );
  }

  Widget _buildFallback(double size, Color iconColor) {
    return Center(
      child: Icon(
        fallbackIcon,
        size: radius * 1.1,
        color: iconColor,
      ),
    );
  }
}
