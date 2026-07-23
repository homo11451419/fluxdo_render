/// 可编辑段落视图。
///
/// 渲染链路与阅读端同源:EditableTextContent → toInlines() →
/// InlineFlattener → Text.rich —— 编辑态与帖子渲染视觉零差异
/// (行内代码 NBSP 灰底、样式精调全部复用)。
///
/// 外层用 [SelectableTextBox] 包装 → 注册进编辑器自己的 SelectionRegistry:
/// 命中(hit_tester)/选区高亮/逻辑块表(projection 坐标换算)全部走现有
/// 选区基建。
///
/// composing 下划线:foregroundPainter 按 [composing](**编辑文本坐标**)
/// 经 projection 转渲染坐标后,在 RenderParagraph 的 selection boxes 底边画线。
library;

import 'package:flutter/foundation.dart' show kDebugMode, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../flatten/inline_flattener.dart';
import '../../node/inline_node.dart' show ImageRun;
import '../../render/block_text_styles.dart';
import '../../render/emoji_handler.dart' show EmojiImageBuilder;
import '../../render/image_handler.dart' show ImageContentBuilder;
import '../../render/list_item_layout.dart';
import '../../render/selectable_text_box.dart';
import '../../selection/projection.dart';
import '../model/editable_text_content.dart' show MarkKind;
import '../model/editor_state.dart';

class EditableParagraph extends StatefulWidget {
  const EditableParagraph({
    super.key,
    required this.block,
    required this.documentOrder,
    required this.baseStyle,
    this.composing = TextRange.empty,
    this.listMarkerOrdinal = 1,
    this.imageContentBuilder,
    this.emojiImageBuilder,
    this.markerRanges = const [],
  });

  final TextBlock block;

  /// 本段当前显形的字面 markdown 标记区间(`**`/`> `)。渲染成淡色 ——
  /// 让用户一眼看出这是「标记」不是正文(展开态才非空)。
  final List<(int, int)> markerRanges;

  /// 在编辑器文档中的序号(= blocks index;SelectableBlockId.docOrder)。
  final int documentOrder;

  final TextStyle baseStyle;

  /// 行内图片原子(裸图)渲染 builder(FluxdoEditor 透传 NodeFactory 的
  /// imageContentBuilder,与岛内图同一管线);null 用子包默认。
  final ImageContentBuilder? imageContentBuilder;

  /// emoji 原子渲染 builder(宿主的 CDN 重写 + 缓存池;null 用子包默认
  /// —— 默认 builder 对相对 URL(`/images/emoji/…`,编辑已有帖的
  /// 客户端 cook 形态)加载失败,显示 `:name:` 占位胶囊)。
  final EmojiImageBuilder? emojiImageBuilder;

  /// 本段的 IME composing 区间(编辑文本坐标);非本段/无 composing 传 empty。
  final TextRange composing;

  /// 有序列表项显示序号(派生渲染态,FluxdoEditor 按连续 run 扫描计算)。
  final int listMarkerOrdinal;

  @override
  State<EditableParagraph> createState() => _EditableParagraphState();
}

class _EditableParagraphState extends State<EditableParagraph> {
  static const _flattener = InlineFlattener();

  final GlobalKey _textKey = GlobalKey();
  FlattenResult? _result;

  FlattenResult _ensureResult() {
    // block.content 不可变 → 引用相等即缓存有效(linkColor 变化走
    // didChangeDependencies 失效)。
    final cached = _result;
    if (cached != null) return cached;
    final sw = kDebugMode ? (Stopwatch()..start()) : null;
    final r = _result = _flattener.flatten(
      // forEditing:spoiler=淡底纹(内容可见)、link=主题色下划线纯文本
      // (真 SpoilerRun 的粒子 WidgetSpan / LinkRun 的 recognizer 都会
      // 破坏编辑手势与光标)。
      widget.block.content.toInlines(
        forEditing: true,
        editingLinkColor: _linkColor,
        markerRanges: widget.markerRanges,
        markerColor: _markerColor,
      ),
      _effectiveStyle,
      // 行内图片原子(裸图):走宿主图片管线(upload 解析/解码上限),
      // 但包 AbsorbPointer 冻结图自身交互(查看器 tap/Hero/右键菜单都
      // 会抢编辑手势 —— 岛同原则)。点图 = 编辑器落光标。
      imageContentBuilder: widget.imageContentBuilder == null
          ? null
          : (ctx, img, total) => AbsorbPointer(
                child: widget.imageContentBuilder!(ctx, img, total),
              ),
      // emoji 原子走宿主管线(CDN 重写 + 缓存池):此前编辑段落没接,
      // 子包默认 builder 对相对 URL(编辑已有帖的 :name: cook 形态)
      // 加载失败 → 满屏 :face_savoring_food: 占位胶囊。
      emojiImageBuilder: widget.emojiImageBuilder,
    );
    if (sw != null && sw.elapsedMilliseconds > 4) {
      debugPrint('[EditorPerf] flatten ${sw.elapsedMilliseconds}ms '
          '(${widget.block.content.length} chars)');
    }
    return r;
  }

  Color? _linkColor;
  Color? _markerColor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Theme.of(context).colorScheme.primary;
    final scheme = Theme.of(context).colorScheme;
    final nextMarker = scheme.onSurfaceVariant.withValues(alpha: 0.45);
    if (next != _linkColor || nextMarker != _markerColor) {
      _linkColor = next;
      _markerColor = nextMarker;
      _disposeResult();
    }
  }

  @override
  void didUpdateWidget(covariant EditableParagraph oldWidget) {
    super.didUpdateWidget(oldWidget);
    // kind/headingLevel 变了 → 有效样式变 → flatten 缓存失效
    if (oldWidget.block.content != widget.block.content ||
        oldWidget.block.kind != widget.block.kind ||
        oldWidget.block.headingLevel != widget.block.headingLevel ||
        oldWidget.baseStyle != widget.baseStyle ||
        !listEquals(oldWidget.markerRanges, widget.markerRanges)) {
      _disposeResult();
    }
  }

  void _disposeResult() {
    final r = _result;
    if (r != null) {
      r.mount.detach(context);
      for (final rec in r.recognizers) {
        rec.dispose();
      }
    }
    _result = null;
  }

  @override
  void dispose() {
    _disposeResult();
    super.dispose();
  }

  RenderParagraph? _findParagraph() {
    final ro = _textKey.currentContext?.findRenderObject();
    return ro == null ? null : _firstParagraph(ro);
  }

  static RenderParagraph? _firstParagraph(RenderObject node) {
    if (node is RenderParagraph) return node;
    RenderParagraph? found;
    node.visitChildren((child) {
      found ??= _firstParagraph(child);
    });
    return found;
  }

  /// 块有效字体样式(heading 缩放/加粗;FluxdoEditor 的 caret 行高与此
  /// 同源 —— 见其 _ensureCaretLineHeight 的 per-kind 缓存)。
  TextStyle get _effectiveStyle => widget.block.isHeading
      ? headingStyleFor(widget.baseStyle, widget.block.headingLevel)
      : widget.baseStyle;

  @override
  Widget build(BuildContext context) {
    final result = _ensureResult();
    // 挂载登记:flatten 契约的点击闭包经 mount 现取活 context。
    // (编辑态 link/mention 不产 recognizer,登记只为契约完整。)
    result.mount.attach(context);
    final block = widget.block;
    final style = _effectiveStyle;
    final em = widget.baseStyle.fontSize ?? 14;

    // forceStrutHeight 是**双向钳制**(探针实锤:153px WidgetSpan 的行
    // 被压到 26px,图片溢出绘制盖到邻块)—— 含图片原子的段落必须放开
    // (行高由图撑,输入文字不改行高,caret 走 editingCaretRectIn 的
    // 行盒校正);无图段落维持强制(M1 光标稳定性:空段=满段=恒定行高,
    // emoji/mention/date 原子都不超行高,不受影响)。
    final hasImageAtom =
        block.content.atoms.values.any((a) => a is ImageRun);

    Widget text = KeyedSubtree(
      key: _textKey,
      // forceStrutHeight 关键(探针实测):默认布局下空段落只有裸字体高度
      // (20px)、段末 caret 度量下坠(top 3.71 vs 行内 0.4)—— 输入前后
      // 光标/段高都在跳。强制 strut 后:空段=满段=26px,caret top/height
      // 处处一致,光标稳定性由布局构造保证(EditableText 同思路)。
      child: Text.rich(
        result.span,
        strutStyle: StrutStyle.fromTextStyle(
          style,
          forceStrutHeight: !hasImageAtom,
        ),
      ),
    );

    if (widget.composing.isValid && !widget.composing.isCollapsed) {
      text = CustomPaint(
        foregroundPainter: _ComposingUnderlinePainter(
          paragraphGetter: _findParagraph,
          projectionGetter: () => _result?.projection,
          composing: widget.composing,
          color: style.color ?? Theme.of(context).colorScheme.onSurface,
        ),
        child: text,
      );
    }

    // 行内剧透编辑态标识:底纹 + 虚线框(阅读端是粒子遮罩;编辑态要
    // "看得出是剧透"而非"遮住"——对齐官方 blurred decoration 意图)。
    final spoilerSpans = [
      for (final m in block.content.marks)
        if (m.kind == MarkKind.spoilerInline) TextRange(start: m.start, end: m.end),
    ];
    if (spoilerSpans.isNotEmpty) {
      final scheme = Theme.of(context).colorScheme;
      text = CustomPaint(
        painter: _SpoilerDecorPainter(
          paragraphGetter: _findParagraph,
          projectionGetter: () => _result?.projection,
          ranges: spoilerSpans,
          fillColor: scheme.onSurface.withValues(alpha: 0.08),
          borderColor: scheme.onSurfaceVariant.withValues(alpha: 0.55),
        ),
        child: text,
      );
    }

    Widget boxed = SelectableTextBox(
      projectionGetter: () => _ensureResult().projection,
      documentOrder: widget.documentOrder,
      debugLabel: 'edit:${block.id}',
      child: text,
    );

    // 列表项:marker 悬挂布局(阅读端 HtmlListItem 同款;marker 不在
    // RenderParagraph 内,投影/命中不受扰)。
    // 缩进必须是 (depth+1) 而非 depth:marker 画在 content **左侧负偏移**
    // 区,第 0 层不留 padding 的话 marker 悬挂到编辑器 Stack 外被
    // hardEdge 裁掉(症状:圆点消失)。阅读端 buildList 每层都有
    // padding-left,同理。
    if (block.isListItem) {
      final markerColor =
          style.color ?? Theme.of(context).colorScheme.onSurface;
      final markerStyle = style.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      boxed = Padding(
        padding: EdgeInsets.only(left: em * 1.5 * (block.depth + 1)),
        child: HtmlListItem(
          textDirection: Directionality.of(context),
          marker: block.ordered
              ? Text(
                  '${widget.listMarkerOrdinal}.',
                  style: markerStyle,
                  maxLines: 1,
                  softWrap: false,
                )
              : ListMarkerDot(
                  depth: block.depth,
                  color: markerColor,
                  textStyle: markerStyle,
                ),
          child: boxed,
        ),
      );
    }

    // heading 上下 margin(阅读端 buildHeading 同款)。
    if (block.isHeading) {
      final margin = em * kHeadingMargin[block.headingLevel - 1];
      boxed = Padding(
        padding: EdgeInsets.symmetric(vertical: margin / 2),
        child: boxed,
      );
    }

    // 容器装饰(quote 竖条/spoiler 底纹/details 框…)不在本 widget:
    // 由 FluxdoEditor 按相邻块容器栈分组统一画壳(M5-B),块本体只管
    // 文本渲染。

    return boxed;
  }
}

/// IME 预编辑下划线(2px,画在 composing 渲染区间每个 box 的底边)。
class _ComposingUnderlinePainter extends CustomPainter {
  _ComposingUnderlinePainter({
    required this.paragraphGetter,
    required this.projectionGetter,
    required this.composing,
    required this.color,
  });

  final RenderParagraph? Function() paragraphGetter;
  final RenderTextProjection? Function() projectionGetter;

  /// 编辑文本坐标(== 逻辑投影坐标)。
  final TextRange composing;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (!composing.isValid || composing.isCollapsed) return;
    final p = paragraphGetter();
    final proj = projectionGetter();
    if (p == null || proj == null || !p.attached || !p.hasSize) return;

    final rs = proj.renderOffsetForContent(composing.start);
    final re = proj.renderOffsetForContent(composing.end);
    if (rs >= re) return;

    final boxes = p.getBoxesForSelection(
      TextSelection(baseOffset: rs, extentOffset: re),
    );
    final paint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 2;
    for (final box in boxes) {
      final y = box.bottom - 1;
      canvas.drawLine(Offset(box.left, y), Offset(box.right, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ComposingUnderlinePainter oldDelegate) =>
      oldDelegate.composing != composing || oldDelegate.color != color;
}

/// 行内剧透编辑态装饰:每个 spoiler mark 区间画圆角底纹 + 虚线边框
/// (背景层 painter —— 画在文字下面)。
class _SpoilerDecorPainter extends CustomPainter {
  _SpoilerDecorPainter({
    required this.paragraphGetter,
    required this.projectionGetter,
    required this.ranges,
    required this.fillColor,
    required this.borderColor,
  });

  final RenderParagraph? Function() paragraphGetter;
  final RenderTextProjection? Function() projectionGetter;

  /// 编辑文本坐标区间集。
  final List<TextRange> ranges;

  final Color fillColor;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final p = paragraphGetter();
    final proj = projectionGetter();
    if (p == null || proj == null || !p.attached || !p.hasSize) return;

    final fill = Paint()..color = fillColor;
    final border = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (final r in ranges) {
      final rs = proj.renderOffsetForContent(r.start);
      final re = proj.renderOffsetForContent(r.end);
      if (rs >= re) continue;
      final boxes = p.getBoxesForSelection(
        TextSelection(baseOffset: rs, extentOffset: re),
      );
      for (final box in boxes) {
        final rect = RRect.fromLTRBR(
          box.left - 1,
          box.top,
          box.right + 1,
          box.bottom,
          const Radius.circular(3),
        );
        canvas.drawRRect(rect, fill);
        _drawDashedRRect(canvas, rect, border);
      }
    }
  }

  /// 简易虚线圆角框:上下边画 dash(左右短边省略 —— 视觉足够)。
  void _drawDashedRRect(Canvas canvas, RRect rect, Paint paint) {
    const dash = 4.0;
    const gap = 3.0;
    for (final y in [rect.top + 0.5, rect.bottom - 0.5]) {
      var x = rect.left + 2;
      while (x < rect.right - 2) {
        final end = (x + dash).clamp(0, rect.right - 2).toDouble();
        canvas.drawLine(Offset(x, y), Offset(end, y), paint);
        x += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SpoilerDecorPainter oldDelegate) =>
      !listEquals(oldDelegate.ranges, ranges) ||
      oldDelegate.fillColor != fillColor ||
      oldDelegate.borderColor != borderColor;
}
