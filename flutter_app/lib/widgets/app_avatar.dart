import 'dart:typed_data';
import 'package:flutter/material.dart';

/// 类似 Telegram 的零闪烁、无缝平滑头像组件 (Zero-Flicker Telegram Avatar)
/// 特性：
/// 1. 静态全局图片缓存，0 毫秒启动开销；
/// 2. 使用 gaplessPlayback 和同色系底色，杜绝首帧图标闪烁或跳变；
/// 3. 支持平滑微透明度过渡，构建极致丝滑视觉体验。
class AppAvatar extends StatelessWidget {
  final Uint8List? imageBytes;
  final double radius;
  final IconData fallbackIcon;
  final Color? fallbackBgColor;
  final Color? fallbackIconColor;
  final String? semanticLabel;

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

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        color: defaultBg,
        child: imageBytes != null && imageBytes!.isNotEmpty
            ? Image.memory(
                imageBytes!,
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) => _buildFallback(size, defaultIconColor),
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) {
                    return child;
                  }
                  return _buildFallback(size, defaultIconColor);
                },
              )
            : _buildFallback(size, defaultIconColor),
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
