/// 把 `List<InlineNode>` 压平成 Flutter 的 InlineSpan 树。
///
/// 阶段 1 范围:Text / Em / Strong / LineBreak / Link / InlineCode / Emoji /
/// Mention / Image 九种 + 嵌套样式合并。后续阶段会加更多 inline 节点。
///
/// 设计:
/// - 输出 InlineSpan 树而不是 widget list — 让一个段落的所有文字共享一个
///   RichText,文本布局/选区/换行才能正常工作。
/// - Em/Strong 用 TextStyle 合并(`merge`)而不是嵌套 WidgetSpan,
///   性能 + 选区表现更好。
/// - LineBreak 渲染为 `\n` 文本字符。
/// - LinkRun 产出带 TapGestureRecognizer 的 TextSpan,recognizer 是
///   stateful 资源,通过 [FlattenResult.recognizers] 暴露给调用方,
///   由 widget dispose 时统一 dispose。
/// - InlineCodeRun 输出 `[NBSP][monospace code][NBSP]`(粘性内边距,见
///   [_buildInlineCodeSpan]);灰底由 InlineCodeBackgroundPainter 下层自绘。
/// - EmojiRun 走 WidgetSpan(图片不是文字),由 [EmojiImageBuilder] 注入,
///   尺寸跟随父字号(only-emoji 32dp)。
///
/// 不处理 whitespace 折叠 — 阶段 1.1 输入是 Discourse cooked HTML,
/// 已经是规整 markdown 输出,标签间空白由 paragraph 边界自然分隔。
/// 阶段 1.2(加 inline_code)再视情况引入 fwfh 的 whitespace 折叠。

library;

import 'dart:math' show Random;
import 'dart:ui' as ui show FragmentShader, PlaceholderAlignment;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../node/inline_node.dart';
import 'soft_break.dart';
import '../render/emoji_handler.dart';
import '../render/footnote_handler.dart';
import '../render/image_handler.dart';
import '../render/link_handler.dart';
import '../render/local_date_handler.dart';
import '../render/math_handler.dart';
import '../render/mention_handler.dart';
import '../render/spoiler_effect.dart';
import '../selection/projection.dart';
import '../selection/projection_builder.dart';

/// 挂载上下文宿主:flatten 产物与当前挂载点(State)之间的活 context 桥。
///
/// recognizer 的 onTap 闭包只捕获本对象(随 [FlattenResult] 走,可安全跨
/// State 复用/进全局缓存),点击时经 [context] 现取挂载方登记的活 context
/// —— 产物重挂载后不再持有已销毁 Element 的悬空引用(旧契约:闭包直接
/// 捕获 flatten 时的 context,State 级缓存下恰好同生共死,全局缓存下必悬空)。
///
/// 支持多重挂载(同一产物同时挂正文与预览 sheet):attach 压栈,
/// detach 只摘自己,[context] 取最近仍挂载的一个。
class SpanMountContext {
  final List<BuildContext> _contexts = [];

  /// 最近挂载且仍在树上的 context;全部卸载时返回 null。
  BuildContext? get context {
    for (var i = _contexts.length - 1; i >= 0; i--) {
      final c = _contexts[i];
      if (c.mounted) return c;
      _contexts.removeAt(i); // 顺手清死引用
    }
    return null;
  }

  /// 挂载方(承载 span 树的 widget)在 build 时登记自己的 context。
  void attach(BuildContext context) {
    _contexts.remove(context);
    _contexts.add(context);
  }

  /// 挂载方 dispose 时注销(只摘自己,不影响其他挂载点)。
  void detach(BuildContext context) {
    _contexts.remove(context);
  }
}

/// 直绘「岛」:占位尺寸**不依赖 widget 布局即可确定**的 WidgetSpan 原子。
/// 当前只有 emoji(普通 = 1em、only-emoji = 32dp,margin 常量),这是它
/// 能进直绘路径(CachedParagraphText)的根本前提 —— 图片/公式/chip 的
/// 占位尺寸都要先布局 widget 才知道,进不了。
class SpanIsland {
  const SpanIsland({
    required this.child,
    required this.width,
    required this.height,
    required this.alignment,
  });

  /// 与 RichText 路径同一实例(WidgetSpan.child:Padding + Builder +
  /// emojiBuilder),直绘岛直接挂它 —— 加载/动图/兜底行为零分歧。
  final Widget child;

  /// 占位尺寸(含 margin;= RichText 路径下该 child 的布局尺寸)。
  /// 注:emoji 加载失败的 `:name:` 胶囊可能宽于此值,RichText 会撑大
  /// 占位而直绘 tight 压缩 —— 异常兜底形态的可接受差异。
  final double width;
  final double height;

  final ui.PlaceholderAlignment alignment;
}

/// 压平结果 — InlineSpan 树 + 需要 dispose 的 recognizers + 选区映射表。
class FlattenResult {
  FlattenResult({
    required this.span,
    required this.recognizers,
    required this.projection,
    required this.mount,
    required this.islands,
  });

  final TextSpan span;

  /// 这次 flatten 创建的所有 GestureRecognizer,调用方必须在 widget
  /// dispose 时遍历 `recognizer.dispose()`。
  final List<GestureRecognizer> recognizers;

  /// 渲染偏移 ↔ 逻辑投影 映射表(自研选区复制/引用用)。
  /// 与 [span] 同源(同一份 inlines),渲染偏移坐标系一致。
  final RenderTextProjection projection;

  /// 挂载上下文桥:recognizer 点击时经它取活 context(不捕获 flatten 时
  /// 的 context)。承载 span 的 widget 须在 build 时 [SpanMountContext.attach]、
  /// dispose 时 detach;未挂载时点击 no-op。
  final SpanMountContext mount;

  /// span 树全部 PlaceholderSpan 的**按序**清单(顺序 = builder
  /// placeholderCount 序 = getBoxesForPlaceholders 序):emoji 记
  /// [SpanIsland],其他 WidgetSpan(图/chip/公式/spoiler/上下标等)记
  /// null。构建时一次性收集,分路判据零遍历成本。
  final List<SpanIsland?> islands;

  /// span 树里是否含 PlaceholderSpan。
  bool get hasPlaceholders => islands.isNotEmpty;

  /// 全部占位都是岛(emoji)→ 段落可进直绘(占位岛模式)。
  bool get allPlaceholdersAreIslands =>
      islands.isNotEmpty && !islands.contains(null);
}

/// 单次 flatten 的参数包:handlers/尺寸/上下文 + recognizer 累计列表。
/// 一次 flatten 一个实例,替代原先逐方法透传的 13 个位置参数。
class _FlattenPass {
  _FlattenPass({
    required this.handler,
    required this.emojiBuilder,
    required this.mentionHandler,
    required this.imageBuilder,
    required this.footnoteHandler,
    required this.localDateBuilder,
    required this.mathInlineBuilder,
    required this.onDownloadAttachment,
    required this.emojiBaseSize,
    required this.totalImagesInPost,
    required this.context,
    required this.mount,
  });

  final LinkActionHandler handler;
  final EmojiImageBuilder emojiBuilder;
  final MentionTapHandler mentionHandler;
  final ImageContentBuilder imageBuilder;
  final FootnoteTapHandler footnoteHandler;
  final LocalDateBuilder? localDateBuilder;
  final MathInlineBuilder? mathInlineBuilder;
  final AttachmentDownloadHandler? onDownloadAttachment;
  final double emojiBaseSize;
  final int totalImagesInPost;

  /// flatten 期间同步读主题色 + 判定"是否创建 recognizer"用;
  /// **不进任何点击闭包**(那边走 [mount])。
  final BuildContext? context;

  /// 点击闭包经它现取挂载方活 context(见 [SpanMountContext])。
  final SpanMountContext mount;

  /// 本次 flatten 创建的 recognizer 累计表(随 FlattenResult 返回)。
  final List<GestureRecognizer> recognizers = [];

  /// WidgetSpan → 岛 登记表(_buildEmojiSpan 写入,_collectIslands 按
  /// 遍历序对齐输出;identity map,flatten 内一次性)。
  final Map<PlaceholderSpan, SpanIsland> islandBySpan = {};
}

class InlineFlattener {
  const InlineFlattener();

  /// 把 inline 节点列表压平,根 span 用 baseStyle 作 fallback。
  ///
  /// [linkHandler]:点击链接时执行的回调(主项目注入)。null 时用
  /// [defaultLinkHandler](仅 debugPrint)。
  /// [emojiImageBuilder]:emoji 图片渲染 builder(主项目注入)。null 时用
  /// [defaultEmojiImageBuilder](Image.network 兜底)。
  /// [mentionTapHandler]:点击 mention chip 跳用户卡的回调(主项目注入)。
  /// null 时用 [defaultMentionTapHandler](仅 debugPrint)。
  /// [imageContentBuilder]:内容图片(非 emoji)渲染 builder。null 时用
  /// [defaultImageContentBuilder](Image.network 兜底)。
  /// [totalImagesInPost]:当前 post 内 ImageRun 总数,透传给 imageBuilder
  /// 用作 gallery viewer 的 totalCount(主项目 Hero / 大图浏览用)。
  /// [context]:仅两个用途 —— ① flatten 期间同步读主题色(link 主色 /
  /// 行内代码字色 / mention 主色,共 3 处,产物带色所以调用方缓存 key 须含
  /// ColorScheme);② 作"交互开关":null 时不创建 recognizer(纯 unit test
  /// 场景)。**点击回调不捕获它**——tap 时经 [FlattenResult.mount] 现取
  /// 挂载方登记的活 context,产物可安全跨挂载复用。
  FlattenResult flatten(
    List<InlineNode> inlines,
    TextStyle baseStyle, {
    LinkActionHandler? linkHandler,
    EmojiImageBuilder? emojiImageBuilder,
    MentionTapHandler? mentionTapHandler,
    ImageContentBuilder? imageContentBuilder,
    FootnoteTapHandler? footnoteTapHandler,
    LocalDateBuilder? localDateBuilder,
    MathInlineBuilder? mathInlineBuilder,
    AttachmentDownloadHandler? onDownloadAttachment,
    int totalImagesInPost = 0,
    BuildContext? context,
  }) {
    final pass = _FlattenPass(
      handler: linkHandler ?? defaultLinkHandler,
      emojiBuilder: emojiImageBuilder ?? defaultEmojiImageBuilder,
      mentionHandler: mentionTapHandler ?? defaultMentionTapHandler,
      imageBuilder: imageContentBuilder ?? defaultImageContentBuilder,
      footnoteHandler: footnoteTapHandler ?? defaultFootnoteTapHandler,
      localDateBuilder: localDateBuilder,
      mathInlineBuilder: mathInlineBuilder,
      onDownloadAttachment: onDownloadAttachment,
      emojiBaseSize: baseStyle.fontSize ?? 14,
      totalImagesInPost: totalImagesInPost,
      context: context,
      mount: SpanMountContext(),
    );
    final children = <InlineSpan>[
      for (final node in inlines) _toSpan(node, pass),
    ];
    final rootSpan = TextSpan(style: baseStyle, children: children);
    return FlattenResult(
      span: rootSpan,
      recognizers: pass.recognizers,
      projection: buildInlineProjection(inlines),
      mount: pass.mount,
      // 按 span 树遍历序收集全部 PlaceholderSpan(顺序 = builder 的
      // placeholderCount 序):emoji 在 _buildEmojiSpan 已登记 SpanIsland,
      // 其余 WidgetSpan 登记 null(非岛,段落进不了直绘)。
      islands: _collectIslands(rootSpan, pass),
    );
  }

  /// 按遍历序对齐 placeholder ↔ 岛:_buildEmojiSpan 把 (WidgetSpan → 岛)
  /// 写进 pass.islandBySpan,这里 visitChildren(与 ParagraphBuilder 的
  /// build 同序)逐个查表输出;非 emoji 的 PlaceholderSpan 查不到 → null。
  static List<SpanIsland?> _collectIslands(TextSpan root, _FlattenPass pass) {
    final result = <SpanIsland?>[];
    root.visitChildren((s) {
      if (s is PlaceholderSpan) {
        result.add(pass.islandBySpan[s]);
      }
      return true;
    });
    return result;
  }

  List<InlineSpan> _build(
    List<InlineNode> nodes,
    _FlattenPass p, {
    GestureRecognizer? inheritedRecognizer,
  }) {
    return [
      for (final node in nodes)
        _toSpan(node, p, inheritedRecognizer: inheritedRecognizer),
    ];
  }

  InlineSpan _toSpan(
    InlineNode node,
    _FlattenPass p, {
    GestureRecognizer? inheritedRecognizer,
  }) {
    return switch (node) {
      TextRun(:final text) => TextSpan(
          text: insertSoftBreaks(text),
          recognizer: inheritedRecognizer,
        ),
      EmRun(:final children) => TextSpan(
          style: const TextStyle(fontStyle: FontStyle.italic),
          children:
              _build(children, p, inheritedRecognizer: inheritedRecognizer),
        ),
      StrongRun(:final children) => TextSpan(
          style: const TextStyle(fontWeight: FontWeight.bold),
          children:
              _build(children, p, inheritedRecognizer: inheritedRecognizer),
        ),
      StyledRun(:final kind, :final children) => _buildStyledSpan(
          kind,
          children,
          p,
          inheritedRecognizer: inheritedRecognizer,
        ),
      // 行内 CSS 着色:字色/背景色应用到 TextSpan(随文换行、可选区);color
      // 为 null 时不覆盖父级色(继承),background 为 null 时无底色。
      ColoredRun(:final color, :final background, :final children) => TextSpan(
          style: TextStyle(color: color, backgroundColor: background),
          children:
              _build(children, p, inheritedRecognizer: inheritedRecognizer),
        ),
      // 字号缩放(`[size=N]` → `font-size:N%`):用 fontSize 的**相对倍数**
      // 表达,对齐网页端 —— 0 倍即视觉隐藏,不夹上下限。
      SizedRun(:final scale, :final children) => TextSpan(
          // 基准取块的实际基础字号(emojiBaseSize 即 baseStyle.fontSize),
          // 比 DefaultTextStyle 准;嵌套 size 以块基准计算,属可接受边界。
          style: TextStyle(fontSize: emojiBaseSize * scale),
          children: _build(
            children,
            handler,
            emojiBuilder,
            mentionHandler,
            imageBuilder,
            footnoteHandler,
            localDateBuilder,
            mathInlineBuilder,
            onDownloadAttachment,
            emojiBaseSize,
            totalImagesInPost,
            context,
            recognizers,
            inheritedRecognizer: inheritedRecognizer,
          ),
        ),
      LineBreakRun() => TextSpan(
          text: '\n',
          recognizer: inheritedRecognizer,
        ),
      LinkRun(:final href, :final children, :final isAttachment, :final filename) =>
          _buildLinkSpan(
            href,
            children,
            p,
            isAttachment: isAttachment,
            filename: filename,
          ),
      InlineCodeRun(:final text) => _buildInlineCodeSpan(
          text,
          p.context,
          inheritedRecognizer: inheritedRecognizer,
        ),
      EmojiRun() => _buildEmojiSpan(node, p,
          inheritedRecognizer: inheritedRecognizer),
      MentionRun() => node.statusEmoji == null
          ? _buildMentionTextSpan(node, p)
          : _buildMentionSpan(node, p),
      ImageRun() => _buildImageSpan(
          node,
          p.imageBuilder,
          p.totalImagesInPost,
        ),
      SpoilerRun(:final children) => _buildSpoilerSpan(children, p),
      FootnoteRefRun() => _buildFootnoteRefSpan(
          node,
          p.footnoteHandler,
          p.context,
        ),
      LocalDateRun() => _buildLocalDateSpan(
          node,
          p.localDateBuilder,
        ),
      ClickCountRun() => _buildClickCountSpan(node),
      MathInlineRun() => _buildMathInlineSpan(node, p.mathInlineBuilder),
    };
  }

  TextSpan _buildLinkSpan(
    String href,
    List<InlineNode> children,
    _FlattenPass p, {
    bool isAttachment = false,
    String filename = '',
  }) {
    final ctx = p.context;
    final mount = p.mount;
    final handler = p.handler;
    final onDownloadAttachment = p.onDownloadAttachment;
    // 附件:优先走主项目注入的附件下载回调(带 filename);未注入则降级到
    // 普通 link handler(主项目 launchContentLink 内部按 /uploads/ 路径仍能
    // 识别附件并下载/外开)。普通链接:走 link handler。
    //
    // onTap 闭包只捕获 mount(不捕获 flatten 时的 ctx):点击时现取挂载方
    // 登记的活 context,产物跨挂载复用不悬空;未挂载时 no-op。
    final recognizer = ctx == null
        ? null
        : (TapGestureRecognizer()
          ..onTap = () {
            final live = mount.context;
            if (live == null) return;
            if (isAttachment && onDownloadAttachment != null) {
              onDownloadAttachment(live, href, filename);
            } else {
              handler(live, href);
            }
          });
    if (recognizer != null) p.recognizers.add(recognizer);

    // 样式对齐 legacy(DiscourseHtmlContentWidget customStylesBuilder):
    //   `{color: theme.colorScheme.primary, text-decoration: none}`
    // 没有下划线,只用主题主色区分。
    final linkColor = ctx == null ? null : Theme.of(ctx).colorScheme.primary;

    // Flutter `TextSpan.recognizer` 不会从父 span 传播到 child:
    // hit test 只对 span 本身的 `text` 字段生效。所以 link 子树里的
    // 所有叶子 span(TextRun / InlineCodeRun / LineBreakRun)都得把
    // 同一个 recognizer 挂上,才能在任意位置 tap 都触发 onTap。
    final linkChildren = _build(children, p, inheritedRecognizer: recognizer);

    // 附件:在文件名前加一个下载图标(WidgetSpan)。图标本体用
    // GestureDetector 兜底点击(WidgetSpan 不吃 TextSpan.recognizer):
    // 优先 onDownloadAttachment,否则降级 handler。图标用自己的活
    // iconCtx(Theme/onTap 都不依赖 flatten context)。
    if (isAttachment) {
      final interactive = ctx != null;
      final iconSpan = WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Builder(
          builder: (iconCtx) {
            final color = Theme.of(iconCtx).colorScheme.primary;
            final size = (DefaultTextStyle.of(iconCtx).style.fontSize ??
                    p.emojiBaseSize) *
                0.95;
            final icon = Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Icon(Icons.download_rounded, size: size, color: color),
            );
            if (!interactive) return icon;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (onDownloadAttachment != null) {
                  onDownloadAttachment(iconCtx, href, filename);
                } else {
                  handler(iconCtx, href);
                }
              },
              child: icon,
            );
          },
        ),
      );
      return TextSpan(
        style: TextStyle(color: linkColor),
        children: [iconSpan, ...linkChildren],
      );
    }

    return TextSpan(
      style: TextStyle(color: linkColor),
      // 父 span 没有 text,recognizer 设了也不响应;但 children 里的
      // 叶子会带同一个 recognizer
      children: linkChildren,
    );
  }

  /// 行内样式标签渲染(对齐 fwfh core_widget_factory 默认值)。
  /// - TextSpan 类(underline/lineThrough/small/big/mark/monospace):随文换行、
  ///   可选区,用 `TextStyle` 合并。
  /// - WidgetSpan 类(superscript/subscript):小字号 + `Transform` 垂直偏移,
  ///   占 1 ￼(projection 原子,见 projection_builder)。
  ///
  /// 字号倍率基于段落基准字号 [emojiBaseSize](= baseStyle.fontSize)取绝对值,
  /// 同 inline code 的处理(嵌套多层 small 罕见,够用)。
  InlineSpan _buildStyledSpan(
    InlineStyleKind kind,
    List<InlineNode> children,
    _FlattenPass p, {
    GestureRecognizer? inheritedRecognizer,
  }) {
    final emojiBaseSize = p.emojiBaseSize;
    List<InlineSpan> buildChildren() =>
        _build(children, p, inheritedRecognizer: inheritedRecognizer);

    // 上/下标:小字号 + 垂直偏移(WidgetSpan)。对齐 fwfh:0.833x + super/sub。
    if (kind == InlineStyleKind.superscript ||
        kind == InlineStyleKind.subscript) {
      final isSup = kind == InlineStyleKind.superscript;
      final dy = isSup ? -emojiBaseSize * 0.33 : emojiBaseSize * 0.16;
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Transform.translate(
          offset: Offset(0, dy),
          child: Text.rich(TextSpan(
            style: TextStyle(fontSize: emojiBaseSize * 0.833),
            children: buildChildren(),
          )),
        ),
      );
    }

    // TextSpan 类:按 kind 出样式。
    final style = switch (kind) {
      InlineStyleKind.underline =>
        const TextStyle(decoration: TextDecoration.underline),
      InlineStyleKind.lineThrough =>
        const TextStyle(decoration: TextDecoration.lineThrough),
      InlineStyleKind.small => TextStyle(fontSize: emojiBaseSize * 0.833),
      InlineStyleKind.big => TextStyle(fontSize: emojiBaseSize * 1.2),
      // mark:对齐 fwfh 默认 #ff0 底 / #000 字。
      InlineStyleKind.mark => TextStyle(
          color: const Color(0xFF000000),
          background: Paint()..color = const Color(0xFFFFFF00),
        ),
      // kbd/samp/tt:fwfh 默认仅等宽字体(无边框/底色)。
      InlineStyleKind.monospace => const TextStyle(
          fontFamily: 'FiraCode',
          fontFamilyFallback: ['monospace', 'Menlo', 'Courier'],
        ),
      // sup/sub 已在上面处理,这里不会到。
      InlineStyleKind.superscript ||
      InlineStyleKind.subscript =>
        const TextStyle(),
    };
    return TextSpan(style: style, children: buildChildren());
  }


  /// 行内代码渲染:NBSP 粘性内边距 + monospace 小字 TextSpan。
  ///
  /// 结构 = `[NBSP][code 文本][NBSP]`(对齐 legacy 预处理
  /// ` <code>…</code> `):NBSP 用**父级普通字体**渲染(宽度可控)、
  /// 不可换行(和 code 粘死不孤行),给 [InlineCodeBackgroundPainter] 的水平
  /// padding(3.5px)留出空白 —— 没有它,code 紧贴相邻文字时灰底会画到文字
  /// 底下(真机溢出问题的根因)。painter 的灰底区间只含 code 文本本身
  /// (projection 里 NBSP 是独立 codePad 条目,不进 inlineCode 区间)。
  ///
  /// **一致性**:projection_builder 对 InlineCodeRun 同步产出
  /// codePad(1) + inlineCode(n) + codePad(1),两侧偏移模型必须一致;
  /// codePad 逻辑投影为空串,复制/引用文本不含 NBSP。
  ///
  /// 颜色策略:**派生自 ColorScheme**,跟主题统一(legacy 用了固定 hex,
  /// 我们在子包内主动升级 — 任何品牌色 / 自定义 seed 都自动适配):
  /// - 字色 ← `colorScheme.onSurfaceVariant`(中性次要文本)
  /// - 底色 ← `colorScheme.surfaceContainerHighest`(M3 灰底容器),由
  ///   [InlineCodeBackgroundPainter] 在文字**下层**自绘:圆角 + 跨行 RRect 合并 +
  ///   行内 padding(对齐 legacy InlineCodePainter)。这里只出字色/字号,**不**用
  ///   `TextStyle.background`(那只能画直角、跨行裂块、无圆角)。
  ///
  /// 字体/字号沿用 legacy:`FiraCode, monospace` + 0.85em。
  TextSpan _buildInlineCodeSpan(
    String text,
    BuildContext? context, {
    GestureRecognizer? inheritedRecognizer,
  }) {
    // 无 context 时退化到固定 fallback(便于纯 unit test 跳过 widget tree)
    final scheme = context == null ? null : Theme.of(context).colorScheme;
    final fgColor = scheme?.onSurfaceVariant;
    return TextSpan(
      // recognizer 不从父 span 传播,pad 与 code 叶子都得挂(link 内可点)。
      children: [
        TextSpan(text: kInlineCodePadChar, recognizer: inheritedRecognizer),
        TextSpan(
          text: insertSoftBreaks(text),
          recognizer: inheritedRecognizer,
          style: TextStyle(
            fontFamily: 'FiraCode',
            fontFamilyFallback: const ['monospace', 'Menlo', 'Courier'],
            fontSize: _inlineCodeFontSize, // baseStyle 14 → 11.9
            color: fgColor,
          ),
        ),
        TextSpan(text: kInlineCodePadChar, recognizer: inheritedRecognizer),
      ],
    );
  }

  // 0.85em:相对于父 baseStyle.fontSize。当前实现是绝对值预设,正确做法
  // 是 inherit 父 fontSize 再 * 0.85,留待阶段 5 调整(届时 baseStyle 体系
  // 整理)。14 * 0.85 = 11.9。
  static const _inlineCodeFontSize = 11.9;

  /// Emoji 渲染:WidgetSpan 嵌入图片,尺寸跟随父字号(only-emoji 32dp)。
  ///
  /// 对齐 Discourse CSS:
  /// - `img.emoji`:`width: 1em; height: 1em; vertical-align: middle`
  /// - `img.emoji.only-emoji`:`width: 32px; height: 32px`
  ///
  /// 子包不加载图片,实际渲染由 [EmojiImageBuilder] 注入;**约定 builder
  /// 自行用 size 约束尺寸**,这里不外包 SizedBox(否则 fallback 文本
  /// 会被裁剪)。
  ///
  /// **垂直对齐**:用 [PlaceholderAlignment.middle] 让 widget 中点对齐
  /// 字号高度的中线 + 减半行 leading 微调。
  ///
  /// 之前用 baseline + alphabetic 在含中文行里会偏低(中文 visual baseline
  /// 比 alphabetic 高);middle 在纯拉丁行里会偏高(拉丁 x-height 在
  /// 行中线下方)。两者都不完美,中文场景 middle 视觉接受度更高
  /// (Discourse 也是 vertical-align: middle)。
  ///
  /// 选区注意:WidgetSpan 默认不参与选区文本,实际选区文本由 SelectionArea
  /// 自处理(阶段 5 自研选区时通过 EmojiRun.name 提供 ":heart:" 作选区文本)。
  ///
  /// recognizer 透传:emoji 嵌套在 LinkRun 子树时,WidgetSpan 没有
  /// `recognizer` 字段,tap 通过 WidgetSpan 内部的 GestureDetector 处理。
  /// 当前实现:link 内 emoji **直接显示但不可点**。阶段 2 加 mention 节点
  /// 时统一处理(mention 内的状态 emoji 也是同样问题)。
  WidgetSpan _buildEmojiSpan(
    EmojiRun emoji,
    _FlattenPass p, {
    GestureRecognizer? inheritedRecognizer,
  }) {
    final emojiBaseSize = p.emojiBaseSize;
    final size = emoji.isOnlyEmoji ? 32.0 : emojiBaseSize;
    // legacy 对齐:普通 emoji 左右各 2px;only-emoji 左右 1px + 上下 0.5em
    final margin = emoji.isOnlyEmoji
        ? EdgeInsets.symmetric(horizontal: 1.0, vertical: emojiBaseSize * 0.5)
        : const EdgeInsets.symmetric(horizontal: 2.0);
    // 选区文本由自研选区的映射表(buildInlineProjection)统一投影成 `:name:`,
    // 不在此处用 SelectableAdapter(那是已废弃的 SelectionArea 方案)。
    // builder 用挂载处的活 Builder ctx(编辑器路径一直如此),产物可跨挂载复用。
    final child = Padding(
      padding: margin,
      child: Builder(
        builder: (ctx) {
          return p.emojiBuilder(ctx, emoji, size);
        },
      ),
    );
    final span = WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: child,
    );
    // 岛登记:emoji 的占位尺寸不依赖 widget 布局(size + margin 均为
    // 确定值)—— 直绘路径据此 addPlaceholder,与 RichText 布局同构
    // (emojiBuilder 契约:自行用 size 约束尺寸)。
    p.islandBySpan[span] = SpanIsland(
      child: child,
      width: size + margin.horizontal,
      height: size + margin.vertical,
      alignment: ui.PlaceholderAlignment.middle,
    );
    return span;
  }

  /// Mention 渲染:chip 样式(灰底圆角 + primary 字 + 0.82em),
  /// 可选状态 emoji 跟在用户名右侧。点击跳用户卡(MentionTapHandler 注入)。
  ///
  /// 样式对齐 legacy `mention_builder.dart::buildMention`:
  ///   font-size: baseStyle.fontSize * 0.82
  ///   padding: horizontal 6, vertical 1
  ///   border-radius: 10
  ///   color: theme.colorScheme.primary
  ///   background: ColorScheme.surfaceContainerHigh(派生升级,legacy 是 hex)
  ///   status emoji: 字号 * 1.2 跟在用户名右
  ///
  /// 用 WidgetSpan 而非 TextSpan 因为是个有内部 padding/border 的整体
  /// chip,不参与文字 baseline 对齐(legacy 同样走 InlineCustomWidget)。
  /// 无状态 emoji 的 mention:纯 TextSpan 路径(行内代码三件套同款)。
  ///
  /// WidgetSpan 版([_buildMentionSpan])每个 mention 是 5 层子树
  /// (Builder→GestureDetector→Container→Row→Text)+ RenderParagraph
  /// 占位布局,@密集帖一帖几十上百节点只为 mention。本路径降为
  /// NBSP 粘性内边距 + `@username` 文本 span:药丸底色由
  /// InlineCodeBackgroundPainter 按 mentionText 投影区间自绘,点击走
  /// recognizer(链接同款,经 [FlattenResult.recognizers] 释放)。
  /// 带状态 emoji 的 mention 需嵌图,保留 WidgetSpan 路径。
  TextSpan _buildMentionTextSpan(MentionRun mention, _FlattenPass p) {
    final ctx = p.context;
    final mount = p.mount;
    final mentionHandler = p.mentionHandler;
    final scheme = ctx == null ? null : Theme.of(ctx).colorScheme;
    // onTap 只捕获 mount,点击时现取活 context(链接同款,不悬空)。
    final recognizer = ctx == null
        ? null
        : (TapGestureRecognizer()
          ..onTap = () {
            final live = mount.context;
            if (live == null) return;
            mentionHandler(live, mention.username, mention.href);
          });
    if (recognizer != null) p.recognizers.add(recognizer);
    return TextSpan(
      // recognizer 不从父 span 传播,pad 与文本叶子都得挂(整个药丸可点)
      children: [
        TextSpan(text: kInlineCodePadChar, recognizer: recognizer),
        TextSpan(
          text: '@${mention.username}',
          recognizer: recognizer,
          style: TextStyle(
            color: scheme?.primary,
            // 与 WidgetSpan 版一致:小一号(0.82em)
            fontSize: p.emojiBaseSize * 0.82,
          ),
        ),
        TextSpan(text: kInlineCodePadChar, recognizer: recognizer),
      ],
    );
  }

  WidgetSpan _buildMentionSpan(MentionRun mention, _FlattenPass p) {
    final emojiBuilder = p.emojiBuilder;
    final mentionHandler = p.mentionHandler;
    final emojiBaseSize = p.emojiBaseSize;
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Builder(
        builder: (ctx) {
          // 全部用挂载处活 ctx:Theme 随挂载点、onTap 不悬空,产物可跨挂载复用。
          final scheme = Theme.of(ctx).colorScheme;
          final fontSize = emojiBaseSize * 0.82;
          final statusEmojiSize = fontSize * 1.2;
          // chip 高度锁定 = 正文行高(主项目正文统一 height:1.5),让 chip
          // 填满整行、不矮浮也不撑高;小一号文字在内部垂直居中。
          final lineHeight = emojiBaseSize * 1.5;
          return GestureDetector(
            onTap: () => mentionHandler(
              ctx,
              mention.username,
              mention.href,
            ),
            child: Container(
              height: lineHeight,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '@${mention.username}',
                    style: TextStyle(
                      color: scheme.primary,
                      fontSize: fontSize,
                      height: 1.0,
                    ),
                  ),
                  if (mention.statusEmoji != null) ...[
                    const SizedBox(width: 2),
                    emojiBuilder(
                      ctx,
                      mention.statusEmoji!,
                      statusEmojiSize,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 内容图片渲染:WidgetSpan 嵌入图片,大小完全由 builder 决定。
  ///
  /// 跟 EmojiRun 不同:emoji 是 1em / 32dp 固定尺寸,这里不限制 ——
  /// `<img width=600 height=400>` 应该撑满 600x400,但段宽不够时
  /// builder 自己处理(主项目通常用 BoxFit.contain + 外层 Stack 截宽)。
  ///
  /// 对齐 [PlaceholderAlignment.middle](跟 emoji 一致,避免基线偏移)。
  ///
  /// [totalImagesInPost] 透传给 builder,主项目用它构造 gallery viewer 的
  /// totalCount(配合 [ImageRun.indexInPost] 算 Hero tag + currentIndex)。
  WidgetSpan _buildImageSpan(
    ImageRun image,
    ImageContentBuilder imageBuilder,
    int totalImagesInPost,
  ) {
    // lightbox 图(典型形态:Discourse cooked 上传图)单独成行,
    // 加上下小 margin 区隔相邻图片 / 文字。普通 inline <img> 不加。
    // builder 用挂载处活 ctx(编辑器路径一直如此),产物可跨挂载复用。
    final isLightbox = image.lightboxUrl != null;
    final child = Builder(
      builder: (ctx) => imageBuilder(ctx, image, totalImagesInPost),
    );
    return WidgetSpan(
      // bottom(≈ CSS img 默认 vertical-align:baseline):图底边贴文字
      // 底部。middle 会让大图行的文字挂在图片垂直中点(浏览器/官方
      // composer 里文字都在图底部)—— 行内大图进编辑器后这个偏差被
      // 放大成明显 bug;小图两种对齐只差几 px。
      alignment: PlaceholderAlignment.bottom,
      child: isLightbox
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: child,
            )
          : child,
    );
  }

  /// 行内 spoiler 渲染:WidgetSpan + _SpoilerInlineWidget。
  ///
  /// 未揭示时显示同色色块(看起来一片黑/灰),点击展开后内部子节点
  /// 走 InlineFlattener 重新 flatten 渲染。
  ///
  /// 注意:flatten 期间无法用 const InlineFlattener() 套子节点(因为
  /// 需要透传 handlers),所以 spoiler 子树用 Text.rich + _build 再展平,
  /// recognizer 仍累计到外层 recognizers 列表里(由 InlineSpanText 统一
  /// dispose)。
  WidgetSpan _buildSpoilerSpan(List<InlineNode> children, _FlattenPass p) {
    // 子节点提前 flatten 成 InlineSpan list,避免 _SpoilerInlineWidget
    // 内部还要依赖 InlineFlattener
    final spans = _build(children, p);
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _SpoilerInlineWidget(spans: spans),
    );
  }

  /// 脚注引用渲染:`[N]` 蓝色上标 + 点击调主项目 [footnoteTapHandler]
  /// 弹 popover(子包不依赖 popover 包)。
  ///
  /// 视觉对齐 legacy `_FootnoteRefWidget`:
  ///   Padding(horizontal 2, vertical 6) + Transform.translate(0, -3)
  ///   蓝色 / fontSize 11 / w600 / height 1
  WidgetSpan _buildFootnoteRefSpan(
    FootnoteRefRun node,
    FootnoteTapHandler footnoteHandler,
    BuildContext? context,
  ) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _FootnoteRefWidget(
        node: node,
        handler: footnoteHandler,
      ),
    );
  }
}

/// 行内脚注引用 widget。
class _FootnoteRefWidget extends StatelessWidget {
  const _FootnoteRefWidget({required this.node, required this.handler});
  final FootnoteRefRun node;
  final FootnoteTapHandler handler;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => handler(context, node.fnId, node.contentHtml),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        child: Transform.translate(
          offset: const Offset(0, -3),
          child: Text(
            '[${node.number}]',
            style: TextStyle(
              color: scheme.primary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// 行内 spoiler 揭示交互 widget。
class _SpoilerInlineWidget extends StatefulWidget {
  const _SpoilerInlineWidget({required this.spans});
  final List<InlineSpan> spans;

  @override
  State<_SpoilerInlineWidget> createState() => _SpoilerInlineWidgetState();
}

class _SpoilerInlineWidgetState extends State<_SpoilerInlineWidget>
    with SingleTickerProviderStateMixin, SpoilerTickerGate {
  final double _seed = Random().nextDouble() * 100;
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    initSpoilerTicker();
    _initShader();
  }

  void _initShader() {
    if (SpoilerShader.program != null) {
      _shader = SpoilerShader.program!.fragmentShader();
      return;
    }
    SpoilerShader.ensureLoaded().then((_) {
      if (!mounted || SpoilerShader.program == null) return;
      setState(() => _shader = SpoilerShader.program!.fragmentShader());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncSpoilerDeps();
  }

  void _reveal() {
    if (spoilerRevealed) return;
    setState(() => spoilerRevealed = true);
    syncSpoilerTicker();
  }

  void _hide() {
    if (!spoilerRevealed) return;
    setState(() => spoilerRevealed = false);
    syncSpoilerTicker();
  }

  @override
  void dispose() {
    disposeSpoilerTicker();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final richText = Text.rich(TextSpan(children: widget.spans));
    if (spoilerRevealed) {
      // 揭示态与未揭示态**同尺寸**(都只内容,无额外 padding/decoration)→ 不抖动。
      return GestureDetector(onTap: _hide, child: richText);
    }
    // 遮蔽态:文字占布局(Opacity 0)+ 上层遮罩(shader 粒子云 / reduce-motion 静态块),点击散开。
    final isDark = theme.brightness == Brightness.dark;
    final bg = theme.scaffoldBackgroundColor;
    return GestureDetector(
      onTap: _reveal,
      child: Stack(
        children: [
          Opacity(opacity: 0.0, child: richText),
          Positioned.fill(
            child: spoilerReduceMotion
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  )
                : RepaintBoundary(
                    child: CustomPaint(
                      painter: SpoilerEffectPainter(
                        time: spoilerTime,
                        seed: _seed,
                        shader: _shader,
                        isDark: isDark,
                        backgroundColor: bg,
                        borderRadius: 3,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

extension on InlineFlattener {
  /// 本地日期渲染:优先调主项目注入的 [localDateBuilder](带时区换算 +
  /// popover);fallback 显示 fallbackText(服务端预渲染)+ 时钟图标。
  ///
  /// 子包不绑 `timezone` / `flutter_timezone` / `popover` 等重依赖。
  WidgetSpan _buildLocalDateSpan(
    LocalDateRun node,
    LocalDateBuilder? localDateBuilder,
  ) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Builder(
        builder: (context) {
          final custom = localDateBuilder?.call(context, node);
          if (custom != null) return custom;
          return _LocalDateFallbackWidget(node: node);
        },
      ),
    );
  }
}

/// 子包内置本地日期 fallback widget — 直接显示服务端预渲染文本 +
/// 时钟图标(无时区换算 / 无 popover)。主项目接入 LocalDateBuilder 后
/// 会被替换。
class _LocalDateFallbackWidget extends StatelessWidget {
  const _LocalDateFallbackWidget({required this.node});
  final LocalDateRun node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fontSize = theme.textTheme.bodyMedium?.fontSize ?? 14;
    final text = node.fallbackText.isNotEmpty
        ? node.fallbackText
        : (node.time == null ? node.date : '${node.date} ${node.time}');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            node.countdown ? Icons.schedule_rounded : Icons.public_rounded,
            size: fontSize * 0.95,
            color: scheme.primary,
          ),
          const SizedBox(width: 3),
          Text(
            text,
            style: TextStyle(color: scheme.primary, fontSize: fontSize),
          ),
        ],
      ),
    );
  }
}

extension on InlineFlattener {
  /// 链接点击数 chip 渲染(对齐 legacy `buildClickCountWidget`)。
  /// 小灰底圆角(radius 10),h5/v1 padding,10px 字号。
  WidgetSpan _buildClickCountSpan(ClickCountRun node) {
    // click-count 是主项目 preprocess 注入的,原始 post.cooked 没有这段文本。
    // 自研选区的映射表(buildInlineProjection)已把 ClickCountRun 投影成空串
    // 排除出选区,这里无需任何选区特殊处理。
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _ClickCountWidget(count: node.count),
    );
  }
}

/// 链接点击数 chip widget(纯展示,无 callback)。
class _ClickCountWidget extends StatelessWidget {
  const _ClickCountWidget({required this.count});
  final String count;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor =
        isDark ? const Color(0xFF3A3D47) : const Color(0xFFE8EBEF);
    final textColor =
        isDark ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        count,
        style: TextStyle(color: textColor, fontSize: 10),
      ),
    );
  }
}

extension on InlineFlattener {
  /// 行内数学公式渲染 — 优先调主项目 [mathInlineBuilder](接 flutter_math_fork);
  /// fallback 用 monospace `$latex$` 原文(对齐 legacy onErrorFallback)。
  WidgetSpan _buildMathInlineSpan(
    MathInlineRun node,
    MathInlineBuilder? mathInlineBuilder,
  ) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Builder(
        builder: (context) {
          final custom = mathInlineBuilder?.call(context, node);
          if (custom != null) return custom;
          return _MathInlineFallbackWidget(node: node);
        },
      ),
    );
  }
}

/// 行内数学公式 fallback widget — monospace `$latex$` 原文(主项目接
/// mathInlineBuilder 后替换)。
class _MathInlineFallbackWidget extends StatelessWidget {
  const _MathInlineFallbackWidget({required this.node});
  final MathInlineRun node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fontSize = theme.textTheme.bodyMedium?.fontSize ?? 14;
    return Text(
      r'$' + node.latex + r'$',
      style: TextStyle(
        fontFamily: 'FiraCode',
        fontFamilyFallback: const ['monospace', 'Menlo', 'Courier'],
        fontSize: fontSize,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
      ),
    );
  }
}
