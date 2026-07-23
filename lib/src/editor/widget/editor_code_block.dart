/// 代码块岛内原位编辑(对齐官方 ProseMirror composer:代码块直接在
/// 内容区编辑,不弹源码对话框)。
///
/// 结构照 EditorTableGrid 的成功先例:
/// - 主体在 [kEditorSelfManagedRegion] 自管区内 —— 编辑器 tap/pan 命中
///   即让路,内部 TextField 的焦点/IME/按键不被编辑器抢;
/// - 左上角块级选择柄在自管区**外**(hover/选中显)→ 编辑器整选本岛,
///   选中后退格删整块;
/// - 展示态视觉 = NodeFactory.buildCodeBlock 同款外壳(灰底圆角 + 语言
///   顶栏);单击代码区原位切换为 monospace 多行 TextField,失焦提交;
/// - 语言标签编辑态变成单行小输入框,改完随代码一起上抛。
///
/// 提交:[onChanged] 上抛新 code/language,宿主直接
/// `state.updateIslandNode(CodeBlockNode(...))` —— 结构化节点原位形变,
/// 不经 cook(比表格链路更短;序列化器 fence 冲突已处理:内容含 ```
/// 自动升 ````)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../../node/node.dart';
import 'editor_table_grid.dart' show kEditorSelfManagedRegion;

class EditorCodeBlock extends StatefulWidget {
  const EditorCodeBlock({
    super.key,
    required this.node,
    required this.onChanged,
    this.selected = false,
    this.autoEdit = false,
    this.onSelectRequest,
    this.highlightBuilder,
  });

  final CodeBlockNode node;

  /// 编辑提交(失焦/Esc):新 code + language。宿主 updateIslandNode。
  final void Function(String code, String? language) onChanged;

  /// 整选态(编辑器选区恰覆盖本块):primary 描边。
  final bool selected;

  /// 插入后自动进入编辑态并聚焦代码框(``` 回车新建时为 true)。
  final bool autoEdit;

  /// 左上角选择柄点击 → 编辑器整选本块(选中后退格/Delete 删除)。
  final VoidCallback? onSelectRequest;

  /// 展示态代码渲染(宿主注入语法高亮;null 用 monospace 纯文本)。
  final Widget Function(BuildContext context, String code, String? language)?
      highlightBuilder;

  @override
  State<EditorCodeBlock> createState() => _EditorCodeBlockState();
}

class _EditorCodeBlockState extends State<EditorCodeBlock> {
  bool _editing = false;
  bool _hover = false;

  late final TextEditingController _codeController =
      TextEditingController(text: widget.node.code);
  late final TextEditingController _langController =
      TextEditingController(text: widget.node.language ?? '');
  final FocusNode _codeFocus = FocusNode(debugLabel: 'codeblock-code');
  final FocusNode _langFocus = FocusNode(debugLabel: 'codeblock-lang');

  @override
  void initState() {
    super.initState();
    if (widget.autoEdit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startEdit();
      });
    }
    // 失焦提交:code 与 lang 两个焦点都离开才算离开编辑态(在两个
    // 输入框之间切换不提交不退出)。
    _codeFocus.addListener(_onFocusChange);
    _langFocus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant EditorCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node != widget.node && !_editing) {
      _codeController.text = widget.node.code;
      _langController.text = widget.node.language ?? '';
    }
  }

  @override
  void dispose() {
    _codeFocus.removeListener(_onFocusChange);
    _langFocus.removeListener(_onFocusChange);
    _codeController.dispose();
    _langController.dispose();
    _codeFocus.dispose();
    _langFocus.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_editing) return;
    if (_codeFocus.hasFocus || _langFocus.hasFocus) return;
    // 帧后再判一次:两个框之间 tab 切换时会有一帧双 false
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_editing) return;
      if (_codeFocus.hasFocus || _langFocus.hasFocus) return;
      _commit();
    });
  }

  void _startEdit() {
    if (_editing) return;
    setState(() {
      _editing = true;
      _codeController.text = widget.node.code;
      _langController.text = widget.node.language ?? '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _codeFocus.requestFocus();
    });
  }

  void _commit() {
    if (!_editing) return;
    setState(() => _editing = false);
    final code = _codeController.text;
    final langRaw = _langController.text.trim().toLowerCase();
    final lang = langRaw.isEmpty ? null : langRaw;
    if (code != widget.node.code || lang != widget.node.language) {
      widget.onChanged(code, lang);
    }
  }

  /// Esc = 放弃本次修改退出编辑态。
  void _cancel() {
    if (!_editing) return;
    setState(() => _editing = false);
    _codeController.text = widget.node.code;
    _langController.text = widget.node.language ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final codeStyle = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
      fontSize: 13,
      height: 1.5,
      color: scheme.onSurface,
    );

    // ---- 顶栏:语言标签(编辑态=输入框)+ 编辑提示 ----
    final topBar = Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          if (_editing)
            SizedBox(
              width: 120,
              child: TextField(
                controller: _langController,
                focusNode: _langFocus,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                  color: scheme.onSurfaceVariant,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '语言(如 dart)',
                  hintStyle: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                onSubmitted: (_) => _commit(),
              ),
            )
          else
            Text(
              (widget.node.language ?? 'TEXT').toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: scheme.onSurfaceVariant,
                letterSpacing: 0.5,
              ),
            ),
          const Spacer(),
          if (_editing)
            Text(
              'Esc 取消 · 点击外部保存',
              style: TextStyle(
                fontSize: 10,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            )
          else if (_hover)
            Text(
              '点击编辑',
              style: TextStyle(
                fontSize: 10,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
        ],
      ),
    );

    // ---- 主体:展示态(高亮/纯文本)或编辑态(多行 TextField)----
    final Widget bodyContent;
    if (_editing) {
      bodyContent = Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Focus(
          // Esc 在 TextField 之前拦(TextField 不消费 Esc,会冒泡到
          // 编辑器 onKeyEvent 被当成普通按键)
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              _cancel();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: TextField(
            controller: _codeController,
            focusNode: _codeFocus,
            style: codeStyle,
            maxLines: null,
            minLines: 3,
            decoration: const InputDecoration(
              isDense: true,
              isCollapsed: true,
              border: InputBorder.none,
            ),
          ),
        ),
      );
    } else {
      final display = widget.highlightBuilder?.call(
            context,
            widget.node.code,
            widget.node.language,
          ) ??
          Text(widget.node.code, style: codeStyle);
      // 展示态限高 + 双向滚动交给内容自身(与阅读端一致的简化版:编辑
      // 场景代码通常不长,超长走编辑态滚动)。
      bodyContent = InkWell(
        onTap: _startEdit,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 400),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Align(
              alignment: Alignment.topLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: display,
              ),
            ),
          ),
        ),
      );
    }

    final body = MetaData(
      metaData: kEditorSelfManagedRegion,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: widget.selected
                ? scheme.primary
                : _editing
                    ? scheme.primary.withValues(alpha: 0.6)
                    : scheme.outlineVariant.withValues(alpha: 0.5),
            width: widget.selected || _editing ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            topBar,
            Container(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.3),
            ),
            bodyContent,
          ],
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(padding: const EdgeInsets.only(top: 4), child: body),
          // 左上角块级选择柄(表格同款;自管区外走编辑器整选)。
          // 触屏无 hover:编辑态常显(否则手机上无入口整选删块)
          if (widget.onSelectRequest != null &&
              (_hover ||
                  widget.selected ||
                  (!RendererBinding
                          .instance.mouseTracker.mouseIsConnected &&
                      _editing)))
            Positioned(
              left: -2,
              top: -6,
              child: Material(
                type: MaterialType.transparency,
                child: Tooltip(
                  message: '选中代码块(选中后退格删除)',
                  child: InkWell(
                    onTap: widget.onSelectRequest,
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: widget.selected
                            ? scheme.primary
                            : scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: widget.selected
                              ? scheme.primary
                              : scheme.outlineVariant,
                        ),
                      ),
                      child: Icon(
                        Icons.drag_indicator,
                        size: 12,
                        color: widget.selected
                            ? scheme.onPrimary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
