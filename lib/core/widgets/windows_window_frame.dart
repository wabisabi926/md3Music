import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:md3music/core/layout/bottom_chrome_sink.dart';

/// 仅 Windows：20% 主题底色叠在全局背景上，正文不透明度不变。
class WindowsWindowFrame extends StatefulWidget {
  const WindowsWindowFrame({super.key, required this.child});

  final Widget child;

  @override
  State<WindowsWindowFrame> createState() => _WindowsWindowFrameState();
}

class _WindowsWindowFrameState extends State<WindowsWindowFrame>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('md3music/window_tray');
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      WidgetsBinding.instance.addObserver(this);
      _invoke('isMaximized');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => _invoke('isMaximized');

  Future<void> _invoke(String method) async {
    try {
      final value = await _channel.invokeMethod<bool>(method);
      if (mounted &&
          value != null &&
          (method == 'isMaximized' || method == 'toggleMaximize')) {
        setState(() => _maximized = value);
      }
    } on MissingPluginException {
      // Widget 测试没有原生 runner；实际运行须使用同一构建中的 Dart 与 runner。
    } on PlatformException catch (error) {
      debugPrint('Windows window control $method failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return widget.child;
    final colors = Theme.of(context).colorScheme;
    // 本组件位于 MaterialApp.builder，Navigator 的 Overlay 是后代而非祖先。
    // 三键的 Tooltip 悬停需要独立宿主，否则 release 会被错误占位替换成白块。
    return Overlay.wrap(
      child: ValueListenableBuilder<double>(
        valueListenable: PlayerPanelSignal.expansion,
        builder: (context, expansion, child) => Column(
          children: [
            // 完整播放页（含展开/收起过程）占满客户区，不留下标题栏空白。
            Visibility(
              visible: expansion <= 0,
              child: SizedBox(
                height: 32,
                child: ColoredBox(
                  key: const ValueKey('windows_title_bar'),
                  color: colors.surface.withValues(alpha: 0.2),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            key: const ValueKey('windows_title_drag'),
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (_) => _invoke('startDrag'),
                            onDoubleTap: () => _invoke('toggleMaximize'),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.music_note,
                                    size: 16,
                                    color: colors.onSurface,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'md3Music',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.onSurface,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        _button('minimize', '最小化', 0, colors),
                        _button(
                          'toggleMaximize',
                          _maximized ? '还原' : '最大化',
                          _maximized ? 2 : 1,
                          colors,
                        ),
                        _button('closeWindow', '关闭', 3, colors),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: child!),
          ],
        ),
        child: widget.child,
      ),
    );
  }

  Widget _button(String method, String label, int glyph, ColorScheme colors) {
    // 窗口系统按钮使用 Windows 平直命中区域，不用圆角 M3E 按钮。
    return _CaptionButton(
      key: ValueKey('windows_$method'),
      label: label,
      glyph: glyph,
      colors: colors,
      onPressed: () => _invoke(method),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    super.key,
    required this.label,
    required this.glyph,
    required this.colors,
    required this.onPressed,
  });
  final String label;
  final int glyph;
  final ColorScheme colors;
  final VoidCallback onPressed;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _focused || _pressed;
    final tone = widget.glyph == 3
        ? widget.colors.error
        : widget.colors.onSurface;
    return Tooltip(
      message: widget.label,
      excludeFromSemantics: true,
      child: SizedBox(
        width: 46,
        height: 32,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: FocusableActionDetector(
            mouseCursor: SystemMouseCursors.basic,
            onShowFocusHighlight: (value) => setState(() => _focused = value),
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onPressed();
                  return null;
                },
              ),
            },
            child: Semantics(
              button: true,
              label: widget.label,
              onTap: widget.onPressed,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: widget.onPressed,
                onTapDown: (_) => setState(() => _pressed = true),
                onTapUp: (_) => setState(() => _pressed = false),
                onTapCancel: () => setState(() => _pressed = false),
                // 不把反馈绘制到共用 Material 墨水层，避免透明/缩放下越界。
                child: RepaintBoundary(
                  child: ClipRect(
                    child: ColoredBox(
                      color: tone.withValues(
                        alpha: active ? (_pressed ? .18 : .12) : 0,
                      ),
                      child: Center(
                        child: CustomPaint(
                          size: const Size(12, 12),
                          painter: _CaptionGlyph(
                            widget.glyph,
                            widget.colors.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CaptionGlyph extends CustomPainter {
  const _CaptionGlyph(this.glyph, this.color);
  final int glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    if (glyph == 0) {
      canvas.drawLine(const Offset(1, 6), const Offset(11, 6), pen);
    } else if (glyph == 1) {
      canvas.drawRect(const Rect.fromLTWH(1, 1, 10, 10), pen);
    } else if (glyph == 2) {
      canvas.drawPath(
        Path()
          ..moveTo(3, 3)
          ..lineTo(3, 1)
          ..lineTo(11, 1)
          ..lineTo(11, 9)
          ..lineTo(9, 9),
        pen,
      );
      canvas.drawRect(const Rect.fromLTWH(1, 3, 8, 8), pen);
    } else {
      canvas.drawLine(const Offset(1, 1), const Offset(11, 11), pen);
      canvas.drawLine(const Offset(11, 1), const Offset(1, 11), pen);
    }
  }

  @override
  bool shouldRepaint(covariant _CaptionGlyph oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
