import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/font_manager.dart';
import 'typography_config.dart';

class TypographySettingsModal extends StatefulWidget {
  final TypographyConfig config;
  final ValueChanged<TypographyConfig> onConfigChanged;
  /// EPUB 走 WebView 渲染，无法应用 Flutter 注册的字体，需关闭字体选择
  final bool showFontSection;

  const TypographySettingsModal({
    super.key,
    required this.config,
    required this.onConfigChanged,
    this.showFontSection = true,
  });

  static Future<void> show(
    BuildContext context, {
    required TypographyConfig config,
    required ValueChanged<TypographyConfig> onConfigChanged,
    bool showFontSection = true,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF222222),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => TypographySettingsModal(
        config: config,
        onConfigChanged: onConfigChanged,
        showFontSection: showFontSection,
      ),
    );
  }

  @override
  State<TypographySettingsModal> createState() => _TypographySettingsModalState();
}

class _TypographySettingsModalState extends State<TypographySettingsModal> {
  late TypographyConfig _config;

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    if (widget.showFontSection) {
      FontManager.instance.loadSavedFonts().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _update(TypographyConfig newConfig) {
    setState(() => _config = newConfig);
    widget.onConfigChanged(newConfig);
  }

  Future<void> _pickAndImportFont() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ttf', 'otf'],
    );

    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      final imported = await FontManager.instance.importFont(file);
      if (imported != null) {
        _update(_config.copyWith(customFontFamily: imported.fontFamily));
      }
    }
  }

  Future<void> _confirmDeleteFont(CustomFontItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除字体'),
        content: Text('确定删除已导入的字体「${item.name}」吗？重启应用后彻底生效。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final ok = await FontManager.instance.deleteFont(item);
    if (!mounted) return;
    if (ok && _config.customFontFamily == item.fontFamily) {
      _update(_config.copyWith(clearFont: true));
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(
              child: Text(
                '排版与字体设置',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 16),

            // 1. 字体选择与导入
            if (widget.showFontSection) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('字体选择（长按可删除）', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  TextButton.icon(
                    onPressed: _pickAndImportFont,
                    icon: const Icon(Icons.add, size: 16, color: Colors.blueAccent),
                    label: const Text('导入字体 (.ttf/.otf)', style: TextStyle(color: Colors.blueAccent, fontSize: 12)),
                  ),
                ],
              ),
              SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    ChoiceChip(
                      label: const Text('系统默认'),
                      selected: _config.customFontFamily == null,
                      selectedColor: const Color(0xFF382E25),
                      labelStyle: TextStyle(
                        color: _config.customFontFamily == null ? Colors.white : Colors.white70,
                        fontSize: 12,
                      ),
                      onSelected: (_) => _update(_config.copyWith(clearFont: true)),
                    ),
                    const SizedBox(width: 8),
                    ...FontManager.instance.fonts.map((f) {
                      final isSelected = _config.customFontFamily == f.fontFamily;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onLongPress: () => _confirmDeleteFont(f),
                          child: InputChip(
                            label: Text(f.name),
                            selected: isSelected,
                            selectedColor: const Color(0xFF382E25),
                            labelStyle: TextStyle(
                              color: isSelected ? Colors.white : Colors.black87,
                              fontSize: 12,
                              fontFamily: f.fontFamily,
                            ),
                            onSelected: (_) => _update(_config.copyWith(customFontFamily: f.fontFamily)),
                            onDeleted: () => _confirmDeleteFont(f),
                            deleteIcon: Icon(
                              Icons.close,
                              size: 14,
                              color: isSelected ? Colors.white70 : Colors.black54,
                            ),
                            deleteButtonTooltipMessage: '删除字体',
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const Divider(color: Colors.white24, height: 24),
            ],

            // 2. 行高与字间距滑块
            Row(
              children: [
                const SizedBox(width: 60, child: Text('行间距', style: TextStyle(color: Colors.white70, fontSize: 13))),
                Expanded(
                  child: Slider(
                    value: _config.lineHeight,
                    min: 1.2,
                    max: 2.4,
                    divisions: 12,
                    label: _config.lineHeight.toStringAsFixed(1),
                    onChanged: (v) => _update(_config.copyWith(lineHeight: v)),
                  ),
                ),
                Text('${_config.lineHeight.toStringAsFixed(1)}x', style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 60, child: Text('字间距', style: TextStyle(color: Colors.white70, fontSize: 13))),
                Expanded(
                  child: Slider(
                    value: _config.letterSpacing,
                    min: 0.0,
                    max: 4.0,
                    divisions: 16,
                    label: _config.letterSpacing.toStringAsFixed(1),
                    onChanged: (v) => _update(_config.copyWith(letterSpacing: v)),
                  ),
                ),
                Text('${_config.letterSpacing.toStringAsFixed(1)}px', style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
            const Divider(color: Colors.white24, height: 16),

            // 3. 段首缩进开关
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('段首缩进 (2 字符)', style: TextStyle(color: Colors.white70, fontSize: 13)),
              value: _config.indentFirstLine,
              activeThumbColor: Colors.brown.shade300,
              onChanged: (v) => _update(_config.copyWith(indentFirstLine: v)),
            ),
          ],
        ),
      ),
    );
  }
}