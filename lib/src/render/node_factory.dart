/// 把 BlockNode 渲染成 Flutter Widget。
///
/// 阶段 1 范围:Paragraph + Heading,行内含 Text/Em/Strong/LineBreak/Link/
/// InlineCode/Emoji。
/// 设计上预留 sub-class 扩展点 — 主项目场景里(用户卡 bio / 通知 / AI 分享卡
/// 等)可以继承 NodeFactory 在 build* 方法里加 wrapper(如:简化版不让点
/// 链接、AI 分享卡内禁用图片)。
///
/// 后续阶段加新 BlockNode 时,新增对应 buildXxx 并在 build dispatch 里
/// 加 case;sealed class 编译期保证不漏。

library;

import 'dart:math' show Random;
import 'dart:ui' as ui show FragmentShader;

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../flatten/inline_flattener.dart';
import '../node/node.dart';
import '../selection/projection.dart';
import 'block_text_styles.dart';
import 'code_block_handler.dart';
import 'emoji_handler.dart';
import 'footnote_handler.dart';
import 'audio_handler.dart';
import 'iframe_handler.dart';
import 'image_grid_layout.dart';
import 'image_handler.dart';
import 'video_handler.dart';
import 'inline_span_text.dart';
import 'lazy_video_handler.dart';
import 'link_handler.dart';
import 'list_item_layout.dart';
import 'local_date_handler.dart';
import 'math_handler.dart';
import 'mention_handler.dart';
import 'onebox_handler.dart';
import 'policy_handler.dart';
import 'chat_transcript_handler.dart';
import 'poll_handler.dart';
import 'quote_avatar_handler.dart';
import 'selectable_text_box.dart';
import 'spoiler_effect.dart';
import 'svg_handler.dart';

class NodeFactory {
  NodeFactory({
    InlineFlattener? inlineFlattener,
    this.linkHandler,
    this.emojiImageBuilder,
    this.mentionTapHandler,
    this.imageContentBuilder,
    this.codeBlockHighlighter,
    this.codeBlockBuilder,
    this.quoteAvatarBuilder,
    this.oneboxBuilder,
    this.imageGridBuilder,
    this.footnoteTapHandler,
    this.lazyVideoBuilder,
    this.iframeBuilder,
    this.videoBuilder,
    this.audioBuilder,
    this.localDateBuilder,
    this.policyBuilder,
    this.pollBuilder,
    this.chatTranscriptBuilder,
    this.mathBlockBuilder,
    this.mathInlineBuilder,
    this.svgBuilder,
    this.onDownloadAttachment,
    this.baseTextStyle,
    this.totalImagesInPost = 0,
    this.compact = false,
    this.screenshotMode = false,
    this.chunkIndex = 0,
    Map<Object, int>? docOrders,
    Map<Object, int>? fallbackDocOrders,
  })  : _inlineFlattener = inlineFlattener ?? const InlineFlattener(),
        _docOrders = docOrders ?? const {},
        // identity:节点/ListItem 是值相等对象,重复内容不得共享兜底序号
        _fallbackDocOrders = fallbackDocOrders ?? Map<Object, int>.identity();

  final InlineFlattener _inlineFlattener;

  /// 正文基准文字样式。为 null 时回退 `Theme.textTheme.bodyMedium`。
  /// 主项目正文注入含 contentFontScale 的样式;非正文场景(用户卡 bio /
  /// AI 分享卡 等)各传自己的字号。影响段落 / 标题 / 列表 / 定义列表 /
  /// 脚注 / 空行 / 表格列宽等所有内容基样式(经 [_compactCopy] 传递到嵌套)。
  final TextStyle? baseTextStyle;

  /// 所属 chunk 的文档序号(长帖 sliver 分 chunk 时该 chunk 的位置;整帖渲染 0)。
  /// 与 [docOrderOf] 一起组成全局文档序 SelectableBlockId(chunkIndex, docOrder)。
  final int chunkIndex;

  /// parse 后算好的「节点/ListItem → 文档序」map(见 document_order.dart)。
  /// _compactCopy 共享同一份。直接构造 NodeFactory(用户卡等)不传时为空,
  /// 退化到 [_fallbackDocOrders] 按首见序兜底(同步内容仍正确)。
  final Map<Object, int> _docOrders;

  /// 兜底序号表(_docOrders 未命中时按首次访问递增分配,_compactCopy 共享)。
  final Map<Object, int> _fallbackDocOrders;

  /// 取某节点/ListItem 的文档序(优先 parse map,未命中走兜底首见序)。
  int docOrderOf(Object key) {
    final v = _docOrders[key];
    if (v != null) return v;
    return _fallbackDocOrders.putIfAbsent(key, () => _fallbackDocOrders.length);
  }

  /// 链接点击 callback,主项目注入。
  /// 不传时用 [defaultLinkHandler](仅 debugPrint)。
  final LinkActionHandler? linkHandler;

  /// Emoji 图片 builder,主项目注入。
  /// 不传时用 [defaultEmojiImageBuilder](Image.network 兜底,无缓存池)。
  final EmojiImageBuilder? emojiImageBuilder;

  /// Mention chip 点击跳用户卡 callback,主项目注入。
  /// 不传时用 [defaultMentionTapHandler](仅 debugPrint)。
  final MentionTapHandler? mentionTapHandler;

  /// 内容图片(非 emoji)builder,主项目注入。
  /// 不传时用 [defaultImageContentBuilder](Image.network + broken-image 占位)。
  final ImageContentBuilder? imageContentBuilder;

  /// 代码块高亮 builder,主项目注入(主项目用 HighlighterService + Mermaid)。
  /// 不传时用 [defaultCodeBlockHighlighter](纯 monospace 无高亮)。
  final CodeBlockHighlighter? codeBlockHighlighter;

  /// 代码块整块 override,主项目注入(mermaid 等语言整块换成图表容器)。
  /// 返回 null / 不传时走默认代码块外壳 + [codeBlockHighlighter]。
  final CodeBlockBuilder? codeBlockBuilder;

  /// 引用卡头像 builder,主项目注入(主项目用 SmartAvatar 走鉴权 +
  /// CDN 重写)。不传时用 [defaultQuoteAvatarBuilder](首字母 chip)。
  final QuoteAvatarBuilder? quoteAvatarBuilder;

  /// Onebox 卡片 builder,主项目注入(根据 OneboxKind dispatch 到 6 种
  /// 子 builder:github / video / social / tech / user / default)。
  /// 返回 null 时子包用内置通用卡片(标题 + 描述 + 缩略图)。
  final OneboxBuilder? oneboxBuilder;

  /// 图片网格 carousel builder,主项目注入(接 legacy buildImageCarousel:
  /// 分页 / 计数器 / 预加载 / 画廊左右切)。仅 [ImageGridNode] 的 carousel
  /// 形态会调用;返回 null 时子包 fallback 单列大图。grid 形态不走此 builder。
  final ImageGridBuilder? imageGridBuilder;

  /// 脚注点击 callback,主项目注入弹 popover 显示 contentHtml。
  /// 不传时用 [defaultFootnoteTapHandler](仅 debugPrint)。
  final FootnoteTapHandler? footnoteTapHandler;

  /// 懒加载视频 builder,主项目注入 webview iframe 嵌入。
  /// 返回 null 时子包用内置缩略图卡片(点击 → linkHandler 跳浏览器)。
  final LazyVideoBuilder? lazyVideoBuilder;

  /// 嵌入 iframe builder,主项目注入 webview 真实渲染。
  /// 返回 null 时子包用内置占位卡(图标 + 域名 + 打开按钮)。
  final IframeBuilder? iframeBuilder;

  /// 原生上传视频 builder,主项目注入 chewie 真播放器。
  /// 返回 null 时子包用内置占位卡(封面/图标 + 点击降级 linkHandler)。
  final VideoBuilder? videoBuilder;

  /// 原生上传音频 builder,主项目注入 just_audio 音频条。
  /// 返回 null 时子包用内置占位卡(音乐图标 + 文件名 + 点击降级 linkHandler)。
  final AudioBuilder? audioBuilder;

  /// 本地日期 chip builder,主项目注入完整虚线下划线 + 时区换算 + popover。
  /// 返回 null 时子包用内置 fallback(直接显示服务端预渲染文本 + 时钟图标)。
  final LocalDateBuilder? localDateBuilder;

  /// Discourse policy builder,主项目注入完整交互(接受/撤销 + API + 已接受
  /// 用户列表)。返回 null 时子包 fallback 渲染 body + 静态 footer 占位。
  final PolicyBuilder? policyBuilder;

  /// 投票块 builder,主项目接 legacy buildPoll(选项/票数/投票交互 + API)。
  /// 返回 null 时子包 fallback 占位卡(标题 + 接入提示)。
  final PollBuilder? pollBuilder;

  /// 聊天记录 builder,主项目接 legacy buildChatTranscript。
  /// 返回 null 时子包 fallback 卡(头像 + 用户名 + 时间 + 消息纯文本)。
  final ChatTranscriptBuilder? chatTranscriptBuilder;

  /// 块级数学公式 builder,主项目接入 flutter_math_fork。
  /// 返回 null 时子包用 monospace `$latex$` 原文。
  final MathBlockBuilder? mathBlockBuilder;

  /// 行内数学公式 builder,主项目接入 flutter_math_fork。
  /// 返回 null 时子包用 monospace `$latex$` 原文。
  final MathInlineBuilder? mathInlineBuilder;

  /// 内容型 SVG builder —— 主项目接入 jovial_svg(ScalableImage.fromSvgString)。
  /// 返回 null 时子包 fallback 画占位框。
  final SvgBuilder? svgBuilder;

  /// 附件(a.attachment)下载 callback,主项目注入。带 href+filename。
  /// 不传时附件 tap 降级到 [linkHandler](launchContentLink 内部仍识别 /uploads/)。
  final AttachmentDownloadHandler? onDownloadAttachment;

  /// 当前 post 内 ImageRun 总数,由 FluxdoRender 在 parse 完成后算出
  /// 并传入。透传到 ImageContentBuilder,主项目用于构造 gallery viewer。
  ///
  /// 调用方手动构造 NodeFactory(给 user card / AI 分享卡 等场景)时,
  /// 若不需要 image 路由,保持默认 0 即可。
  final int totalImagesInPost;

  /// **紧凑模式**:在容器内(blockquote / quote_card / spoiler 等)递归
  /// 渲染子节点时,paragraph 不再加 `1em 0` 上下 margin,避免与容器
  /// 自己的 padding 叠加产生过大间距。
  ///
  /// 对齐 legacy `DiscourseHtmlContent(compact: true)` 用法。
  final bool compact;

  /// 截图模式 —— 分享成图等离屏渲染场景。为 true 时关掉大表格行虚拟化
  /// (全渲染所有行,避免截断);mermaid 等主项目懒加载 builder 经
  /// [ScreenshotMode] InheritedWidget 感知,跳过 VisibilityDetector 立即加载。
  final bool screenshotMode;

  /// 派生一个"紧凑"版本(给 buildBlockquote / buildQuoteCard / 等
  /// 渲染子节点用)。所有 handlers / builders 完全相同,只是 [compact]
  /// 切到 true。
  NodeFactory _compactCopy() {
    if (compact) return this;
    return NodeFactory(
      inlineFlattener: _inlineFlattener,
      linkHandler: linkHandler,
      emojiImageBuilder: emojiImageBuilder,
      mentionTapHandler: mentionTapHandler,
      imageContentBuilder: imageContentBuilder,
      codeBlockHighlighter: codeBlockHighlighter,
      codeBlockBuilder: codeBlockBuilder,
      quoteAvatarBuilder: quoteAvatarBuilder,
      oneboxBuilder: oneboxBuilder,
      imageGridBuilder: imageGridBuilder,
      footnoteTapHandler: footnoteTapHandler,
      lazyVideoBuilder: lazyVideoBuilder,
      iframeBuilder: iframeBuilder,
      videoBuilder: videoBuilder,
      audioBuilder: audioBuilder,
      localDateBuilder: localDateBuilder,
      policyBuilder: policyBuilder,
      pollBuilder: pollBuilder,
      chatTranscriptBuilder: chatTranscriptBuilder,
      mathBlockBuilder: mathBlockBuilder,
      mathInlineBuilder: mathInlineBuilder,
      svgBuilder: svgBuilder,
      onDownloadAttachment: onDownloadAttachment,
      baseTextStyle: baseTextStyle,
      screenshotMode: screenshotMode,
      totalImagesInPost: totalImagesInPost,
      compact: true,
      chunkIndex: chunkIndex,
      docOrders: _docOrders,
      fallbackDocOrders: _fallbackDocOrders,
    );
  }

  /// 入口 dispatch — sealed class exhaustive switch。
  ///
  /// [trimTop]/[trimBottom]:把段落/标题的上/下外边距裁成 0。用于长帖分块时
  /// 「切断单段落」的接缝(chunk 首/尾块)—— 让两片拼接处与连续渲染一致(无缝),
  /// 同时不影响真正块边界的间距。仅对 Paragraph/Heading 生效(接缝块几乎都是)。
  Widget build(
    BuildContext context,
    BlockNode node, {
    bool trimTop = false,
    bool trimBottom = false,
  }) {
    return switch (node) {
      ParagraphNode() =>
        buildParagraph(context, node, trimTop: trimTop, trimBottom: trimBottom),
      HeadingNode() =>
        buildHeading(context, node, trimTop: trimTop, trimBottom: trimBottom),
      ListNode() => buildList(context, node),
      BlockquoteNode() => buildBlockquote(context, node),
      HorizontalRuleNode() => buildHorizontalRule(context, node),
      BlankLineNode() => buildBlankLine(context, node),
      CodeBlockNode() => buildCodeBlock(context, node),
      QuoteCardNode() => buildQuoteCard(context, node),
      SpoilerBlockNode() => buildSpoilerBlock(context, node),
      OneboxNode() => buildOnebox(context, node),
      DetailsNode() => buildDetails(context, node),
      CalloutNode() => buildCallout(context, node),
      ImageGridNode() => buildImageGrid(context, node),
      FootnotesSectionNode() => buildFootnotesSection(context, node),
      LazyVideoNode() => buildLazyVideo(context, node),
      IframeNode() => buildIframe(context, node),
      VideoNode() => buildVideo(context, node),
      AudioNode() => buildAudio(context, node),
      TableNode() => buildTable(context, node),
      PolicyNode() => buildPolicy(context, node),
      PollNode() => buildPoll(context, node),
      ChatTranscriptNode() => buildChatTranscript(context, node),
      MathBlockNode() => buildMathBlock(context, node),
      DefinitionListNode() => buildDefinitionList(context, node),
      SvgNode() => buildSvg(context, node),
    };
  }

  /// 段落渲染 — InlineSpanText 自动管 GestureRecognizer 生命周期。
  ///
  /// 子类可 override 实现段落级别的定制(如调字号、加 margin)。
  ///
  /// margin 对齐 legacy(fwfh `_tagP` `1em 0` + 浏览器 CSS margin-collapsing):
  /// 用 `em / 2` 做上下 padding,相邻两段累加正好 = `1em`(等同于 CSS
  /// margin-collapsing 取一份的结果)。直接用 `em` 会让相邻段距离 `2em`。
  /// **[compact] 模式下 margin 为 0**(嵌套在容器内,如 blockquote /
  /// quote_card,容器自己已加 padding,不再叠加)。
  Widget buildParagraph(
    BuildContext context,
    ParagraphNode node, {
    bool trimTop = false,
    bool trimBottom = false,
  }) {
    final theme = Theme.of(context);
    final baseStyle =
        baseTextStyle ?? theme.textTheme.bodyMedium ?? const TextStyle();
    final em = baseStyle.fontSize ?? 14;
    // image-only 段落(全是 ImageRun / LineBreakRun,无真文字)用更小的
    // vertical padding。否则文本 margin 叠加 image 自身上下 padding,
    // 与前后段距离过大,跟 fwfh margin-collapsing 行为差距明显。
    final isImageOnly = node.inlines.isNotEmpty &&
        node.inlines.every((n) => n is ImageRun || n is LineBreakRun);
    final vertical = compact
        ? 0.0
        : isImageOnly
            ? 4.0
            : em / 2;
    return Padding(
      padding: EdgeInsets.only(
        top: trimTop ? 0 : vertical,
        bottom: trimBottom ? 0 : vertical,
      ),
      child: InlineSpanText(
        inlines: node.inlines,
        baseStyle: baseStyle,
        documentOrder: docOrderOf(node),
        chunkIndex: chunkIndex,
        textAlign: node.textAlign,
        flattener: _inlineFlattener,
        linkHandler: linkHandler,
        onDownloadAttachment: onDownloadAttachment,
        emojiImageBuilder: emojiImageBuilder,
        mentionTapHandler: mentionTapHandler,
        imageContentBuilder: imageContentBuilder,
        footnoteTapHandler: footnoteTapHandler,
        localDateBuilder: localDateBuilder,

        mathInlineBuilder: mathInlineBuilder,
        totalImagesInPost: totalImagesInPost,
      ),
    );
  }

  /// 标题渲染 — 字号按 level 决定,默认值参考浏览器 UA stylesheet。
  ///
  /// h1=2em / h2=1.5em / h3=1.17em / h4=1em / h5=0.83em / h6=0.67em
  /// 字重统一 bold。垂直 padding 按 CSS heading margin(em 倍数)。
  Widget buildHeading(
    BuildContext context,
    HeadingNode node, {
    bool trimTop = false,
    bool trimBottom = false,
  }) {
    final theme = Theme.of(context);
    final baseStyle =
        baseTextStyle ?? theme.textTheme.bodyMedium ?? const TextStyle();
    final em = baseStyle.fontSize ?? 14;
    final headingStyle = headingStyleFor(baseStyle, node.level);
    final margin = em * kHeadingMargin[node.level - 1];
    return Padding(
      padding: EdgeInsets.only(
        top: trimTop ? 0 : margin,
        bottom: trimBottom ? 0 : margin,
      ),
      child: InlineSpanText(
        inlines: node.inlines,
        baseStyle: headingStyle,
        documentOrder: docOrderOf(node),
        chunkIndex: chunkIndex,
        textAlign: node.textAlign,
        flattener: _inlineFlattener,
        linkHandler: linkHandler,
        onDownloadAttachment: onDownloadAttachment,
        emojiImageBuilder: emojiImageBuilder,
        mentionTapHandler: mentionTapHandler,
        imageContentBuilder: imageContentBuilder,
        footnoteTapHandler: footnoteTapHandler,
        localDateBuilder: localDateBuilder,

        mathInlineBuilder: mathInlineBuilder,
        totalImagesInPost: totalImagesInPost,
      ),
    );
  }

  // heading 字号/间距常量移至 block_text_styles.dart(kHeadingScale/
  // kHeadingMargin)—— 编辑端 EditableTextBlock 同源取用。

  /// 列表渲染 — `<ul>` / `<ol>`,可递归嵌套子 list。
  ///
  /// 布局复刻浏览器 `list-style-position: outside`(经 [HtmlListItem],
  /// 移植自 fwfh):marker 悬挂在 content 左缘外、右缘对齐、基线对齐、
  /// 自然宽度永不换行 → `9.`/`10.`/`100.` 点号竖直对齐,位数多时向左延伸。
  ///
  /// 缩进对齐 Discourse `.cooked` CSS:
  ///   ul/ol: `margin: 1em 0 1em 1.25em; padding-inline-start: 1.25em`
  ///   → 每层内容左缘 = 2.5em 累进;marker 悬挂在 padding 区内。
  ///
  /// 无序 marker 形状(按嵌套 depth,对齐浏览器 CSS list-style 级联):
  /// depth0 实心圆 disc / depth1 空心圆 circle / depth≥2 实心方块 square。
  /// **绘制**而非字体字形([ListMarkerDot],自带文本基线)→ 清晰、跨字体
  /// 一致、垂直对齐稳定。key 供测试辨识层级。
  static Key _ulMarkerKey(int depth) => switch (depth) {
        0 => const ValueKey('ul_marker_disc'),
        1 => const ValueKey('ul_marker_circle'),
        _ => const ValueKey('ul_marker_square'),
      };

  /// 构建悬挂 marker:有序 = 等宽数字 Text(nowrap,自然宽);无序 = 自绘形状。
  static Widget _buildMarker(
    ListNode list,
    int index,
    TextStyle textStyle,
    Color color,
  ) {
    if (list.ordered) {
      return Text(
        '${list.start + index}.',
        style: textStyle,
        maxLines: 1,
        softWrap: false,
      );
    }
    return ListMarkerDot(
      key: _ulMarkerKey(list.depth),
      depth: list.depth,
      color: color,
      textStyle: textStyle,
    );
  }

  /// 有序列表 marker 用 `FontFeature.tabularFigures`(等宽数字)
  /// 避免 "1." 比 "10." 窄导致对齐错位。
  ///
  /// 嵌套子列表用 `ListItem.children` 持有,渲染时递归 buildList。
  /// **嵌套层(depth > 0)跳过 outer vertical margin**:CSS 相邻 margin
  /// 折叠取大,Flutter Column padding 累加 —— 不跳过会出现嵌套上 + 父 li 下
  /// 的额外空白,视觉上像多了一行。
  Widget buildList(BuildContext context, ListNode node) {
    final theme = Theme.of(context);
    final baseStyle =
        baseTextStyle ?? theme.textTheme.bodyMedium ?? const TextStyle();
    final em = baseStyle.fontSize ?? 14;
    // Discourse .cooked CSS:
    //   ul/ol { margin: 1em 0 1em 1.25em; padding: 0 }
    //   .cooked ul/ol { padding-inline-start: 1.25em }
    // margin-left(1.25em) + padding-inline-start(1.25em) 合并到这一层
    // Padding → 每层内容左缘 2.5em 累进;marker 悬挂在其中(HtmlListItem
    // 负偏移绘制,落在 padding 区,不额外占位)。
    return Padding(
      padding: EdgeInsets.fromLTRB(
        em * 2.5,
        node.depth == 0 ? em : 0,
        0,
        node.depth == 0 ? em : 0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < node.items.length; i++)
            _buildListItem(context, node, i, baseStyle),
        ],
      ),
    );
  }

  Widget _buildListItem(
    BuildContext context,
    ListNode list,
    int index,
    TextStyle baseStyle,
  ) {
    final item = list.items[index];
    final markerStyle = baseStyle.copyWith(
      height: 1.5,
      fontFeatures: list.ordered
          ? const [FontFeature.tabularFigures()]
          : null,
    );
    final markerColor =
        markerStyle.color ?? Theme.of(context).colorScheme.onSurface;
    final textDirection = Directionality.of(context);

    // 块级形态(li 含 h4/p/pre/blockquote 等):marker + Column(块级子,走
    // compact factory 消除多余 margin)。如 FAQ 的 Q(h4)/A(p)分行。
    // marker 与首块首行基线对齐由 HtmlListItem 完成(defaultComputeDistance
    // ToFirstActualBaseline 沿 Column 首子取基线,heading 上 margin 自然计入)。
    final blocks = item.blocks;
    if (blocks != null) {
      final first = blocks.first;
      final isHead = first is HeadingNode;
      final blockMarkerStyle =
          markerStyle.copyWith(height: isHead ? 1.2 : 1.5);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: HtmlListItem(
          textDirection: textDirection,
          marker:
              _buildMarker(list, index, blockMarkerStyle, markerColor),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final b in blocks) _compactCopy().build(context, b),
            ],
          ),
        ),
      );
    }

    final hasChildren = item.children != null;

    // li 仅作嵌套列表包裹(无直接文本,如 <li><ol>…</ol><ul>…</ul></li>):
    // marker 悬挂于嵌套子列表整体左缘外,与其首行基线对齐(浏览器行为:
    // 外层 marker 与嵌套首项 marker/文本同一行)。
    if (item.inlines.isEmpty && hasChildren) {
      final children = item.children!;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: HtmlListItem(
          textDirection: textDirection,
          marker: _buildMarker(list, index, markerStyle, markerColor),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final sub in children) buildList(context, sub),
            ],
          ),
        ),
      );
    }

    return Padding(
      // 有嵌套子 list 时取消底部 padding,避免 inline 行和子 list 之间空一截
      padding: EdgeInsets.fromLTRB(0, 4, 0, hasChildren ? 0 : 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HtmlListItem(
            textDirection: textDirection,
            marker: _buildMarker(list, index, markerStyle, markerColor),
            child: InlineSpanText(
              inlines: item.inlines,
              baseStyle: baseStyle.copyWith(height: 1.5),
              documentOrder: docOrderOf(item),
              chunkIndex: chunkIndex,
              flattener: _inlineFlattener,
              linkHandler: linkHandler,
              onDownloadAttachment: onDownloadAttachment,
              emojiImageBuilder: emojiImageBuilder,
              mentionTapHandler: mentionTapHandler,
              imageContentBuilder: imageContentBuilder,
              footnoteTapHandler: footnoteTapHandler,
              localDateBuilder: localDateBuilder,
              mathInlineBuilder: mathInlineBuilder,
              totalImagesInPost: totalImagesInPost,
            ),
          ),
          // 嵌套子 list 递归渲染
          if (hasChildren)
            for (final sub in item.children!) buildList(context, sub),
        ],
      ),
    );
  }

  /// 定义列表渲染 — `<dl>`:dt(术语,常规字重)+ dd(释义,左缩进 1.25em)。
  ///
  /// 样式对齐 Discourse `.cooked` CSS(与 ul/ol 同一体系):
  ///   dl: 上下外边距(此处 8,与旧档一致)
  ///   dt: 块级、字重正常(**不加粗**,对齐浏览器默认 dt)
  ///   dd: 块级、`margin: 1em 0 1em 1.25em`(Discourse 覆盖了 UA 默认 40px;
  ///       dd 无 padding-inline-start,故缩进 = 1.25em,比 ul/ol 的 2.5em 浅)
  /// dd 内块级子节点走 _compactCopy()(消除嵌套 paragraph 的多余上下 margin,
  /// 与 li 块级形态 / blockquote 子节点一致)。
  Widget buildDefinitionList(BuildContext context, DefinitionListNode node) {
    final theme = Theme.of(context);
    final baseStyle =
        baseTextStyle ?? theme.textTheme.bodyMedium ?? const TextStyle();
    final em = baseStyle.fontSize ?? 14;
    final childFactory = _compactCopy();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in node.items) ...[
            // dt 术语行:常规字重(不加粗),行高 1.5,跟随正文色。
            if (item.term.isNotEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: em * 0.25),
                child: InlineSpanText(
                  inlines: item.term,
                  baseStyle: baseStyle.copyWith(height: 1.5),
                  documentOrder: docOrderOf(item),
                  chunkIndex: chunkIndex,
                  flattener: _inlineFlattener,
                  linkHandler: linkHandler,
                  onDownloadAttachment: onDownloadAttachment,
                  emojiImageBuilder: emojiImageBuilder,
                  mentionTapHandler: mentionTapHandler,
                  imageContentBuilder: imageContentBuilder,
                  footnoteTapHandler: footnoteTapHandler,
                  localDateBuilder: localDateBuilder,
                  mathInlineBuilder: mathInlineBuilder,
                  totalImagesInPost: totalImagesInPost,
                ),
              ),
            // dd 释义:左缩进 1.25em(Discourse dd margin-left),块级子节点走
            // compact factory。
            for (final dd in item.definitions)
              Padding(
                padding: EdgeInsets.only(left: em * 1.25),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final b in dd) childFactory.build(context, b),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 引用块渲染 — `<blockquote>`,内部 BlockNode 递归 build。
  ///
  /// 样式对齐 legacy(`blockquote_builder.dart` 普通引用分支):
  ///   margin 上下 8
  ///   padding L 12 / 上下 8 / R 12
  ///   背景 colorScheme.surfaceContainerHighest @ 0.3
  ///   左边 4px outline 竖条
  ///   右上 / 右下 圆角 4
  ///
  /// 子节点用 DefaultTextStyle 注入 onSurfaceVariant + height 1.5,
  /// 这样子 ParagraphNode 渲染时跟随这个色调(让引用块整体偏次要文本色)。
  ///
  /// **装饰下放**:大引用块被拆成多 sliver 片时,每片重套本装饰并按 [node.chunkPos]
  /// 出连续效果 —— 左条 + 背景每片都画(堆叠连续),仅首片留上外边距/上圆角、
  /// 尾片留下外边距/下圆角,中间片无外边距无圆角无缝拼接。whole = 完整引用块。
  Widget buildBlockquote(BuildContext context, BlockquoteNode node) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pos = node.chunkPos;
    final isFirst =
        pos == BlockquoteChunkPos.whole || pos == BlockquoteChunkPos.first;
    final isLast =
        pos == BlockquoteChunkPos.whole || pos == BlockquoteChunkPos.last;
    return Container(
      margin: EdgeInsets.only(top: isFirst ? 8 : 0, bottom: isLast ? 8 : 0),
      padding: EdgeInsets.fromLTRB(12, isFirst ? 8 : 0, 12, isLast ? 8 : 0),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border(
          left: BorderSide(
            color: scheme.outline,
            width: 4,
          ),
        ),
        borderRadius: BorderRadius.only(
          topRight: isFirst ? const Radius.circular(4) : Radius.zero,
          bottomRight: isLast ? const Radius.circular(4) : Radius.zero,
        ),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          height: 1.5,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 容器内子节点走 compact factory(消除嵌套 paragraph 多余 margin)
            for (final child in node.children)
              _compactCopy().build(context, child),
          ],
        ),
      ),
    );
  }

  /// 分割线 — `<hr>`。
  ///
  /// 样式对齐 legacy:vertical padding 12 + 1px 高线 +
  /// `colorScheme.outlineVariant @ 0.5`(派生)。
  Widget buildHorizontalRule(
    BuildContext context,
    HorizontalRuleNode node,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Container(
        height: 1,
        color: scheme.outlineVariant.withValues(alpha: 0.5),
      ),
    );
  }

  /// 底部脚注区渲染 — `<section class="footnotes">`。
  ///
  /// 设计取舍(legacy 此处 `SizedBox.shrink()`,见 FootnotesSectionNode 文档):
  ///   上分隔线 + 有序编号悬挂列表。与上标 [FootnoteRefRun] popover 并存:
  ///   popover 即时预览、底部列表完整可读(截图分享场景必需)。
  ///
  /// 样式(锚定 Discourse 网页 ol.footnotes-list 语义 + 子包既有 token):
  ///   分隔线:同 buildHorizontalRule(outlineVariant@0.5,上下各 12,但合并到本区顶部)
  ///   编号槽:宽 22(对齐 buildList ordered markerWidth),次要色 onSurfaceVariant
  ///   正文:InlineSpanText(bodyMedium，次要色，height 1.5,小一号 0.92em)
  ///   条目间距:上下各 4(对齐 buildList li)
  ///
  /// entries 为空 → SizedBox.shrink()(退化为隐藏,行为同 legacy)。
  Widget buildFootnotesSection(
    BuildContext context,
    FootnotesSectionNode node,
  ) {
    if (node.entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base =
        baseTextStyle ?? theme.textTheme.bodyMedium ?? const TextStyle();
    // 脚注正文比正文小一号(对齐网页 footnotes 字号习惯),次要色。
    final bodyStyle = base.copyWith(
      fontSize: (base.fontSize ?? 14) * 0.92,
      color: scheme.onSurfaceVariant,
      height: 1.5,
    );
    final numStyle = bodyStyle.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部分隔线(对齐 buildHorizontalRule 配色)
          Container(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 8),
          for (final entry in node.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 编号悬挂槽(右对齐 + 点号,对齐有序列表观感)
                  SizedBox(
                    width: 22,
                    child: Text(
                      '${entry.number}.',
                      textAlign: TextAlign.right,
                      style: numStyle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InlineSpanText(
                      inlines: entry.inlines,
                      baseStyle: bodyStyle,
                      documentOrder: docOrderOf(entry),
                      chunkIndex: chunkIndex,
                      flattener: _inlineFlattener,
                      linkHandler: linkHandler,
                      onDownloadAttachment: onDownloadAttachment,
                      emojiImageBuilder: emojiImageBuilder,
                      mentionTapHandler: mentionTapHandler,
                      imageContentBuilder: imageContentBuilder,
                      footnoteTapHandler: footnoteTapHandler,
                      localDateBuilder: localDateBuilder,
                      mathInlineBuilder: mathInlineBuilder,
                      totalImagesInPost: totalImagesInPost,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 空行渲染 — 作者留白空 `<p>`(`<p><em></em></p>` / `<p><br></p>`)的
  /// 垂直留白。
  ///
  /// 高度取一个 em(≈ 一个空 `<p>` 的 margin 贡献,实测对齐 fwfh:块间一个
  /// 空段落 ≈ +1em)。连续多个叠加成多行留白。纯 SizedBox,不参与选区。
  Widget buildBlankLine(BuildContext context, BlankLineNode node) {
    final baseStyle = baseTextStyle ??
        Theme.of(context).textTheme.bodyMedium ??
        const TextStyle();
    return SizedBox(height: baseStyle.fontSize ?? 14);
  }

  /// 代码块渲染 — `<pre><code>`。
  ///
  /// 视觉对齐 legacy `code_block_builder.dart`(简化版,无行号/全屏/分享):
  ///   外:Container 灰底 surfaceContainer + 圆角 8 + margin 上下 8
  ///   顶栏:Row(语言 chip(灰色文字 12px 左对齐)+ 复制按钮)
  ///   主体:横向 SingleChildScrollView + monospace 内容
  ///
  /// 高亮 / mermaid 由 [codeBlockHighlighter] callback 接管;不传时纯
  /// monospace 显示。
  Widget buildCodeBlock(BuildContext context, CodeBlockNode node) {
    // 整块 override:主项目按 node.language 决定是否整块接管(如 mermaid
    // 换成独立图表容器)。返回 null 走下面的默认代码块外壳。
    final custom = codeBlockBuilder?.call(context, node);
    if (custom != null) return custom;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final highlighter = codeBlockHighlighter ?? defaultCodeBlockHighlighter;
    final langLabel = (node.language ?? 'TEXT').toUpperCase();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶栏:语言 + 复制按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(
              children: [
                Text(
                  langLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                _CopyButton(code: node.code),
              ],
            ),
          ),
          // 分隔线
          Container(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.3),
          ),
          // 主体:横向滚动 + highlighter widget。
          // 限高 400px 避免长代码撑爆 ListView(legacy 同套路);
          // 含行号列(legacy 同套路),保持基线对齐 + 选择 disabled。
          _CodeBlockBody(
            code: node.code,
            language: node.language,
            highlighter: highlighter,
            documentOrder: docOrderOf(node),
            chunkIndex: chunkIndex,
          ),
        ],
      ),
    );
  }

  /// 引用卡渲染 — `<aside class="quote">`(Discourse 经典"@回复")。
  ///
  /// 样式对齐 legacy `quote_card_builder.dart`:
  ///   外容器:跟 buildBlockquote 同款(灰底 + 左 4px 竖条 + 右上右下圆角)
  ///   顶部:头像(radius 12)+ `username:` + 可选标题(主色,可点)
  ///   内容:子 BlockNode 递归 build,DefaultTextStyle 注入 onSurfaceVariant
  ///
  /// 标题 onTap 走 [linkHandler] + titleHref(主项目走 launchContentLink)。
  /// avatar 走 [quoteAvatarBuilder] callback,默认首字母 chip。
  Widget buildQuoteCard(BuildContext context, QuoteCardNode node) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final avatarBuilder = quoteAvatarBuilder ?? defaultQuoteAvatarBuilder;
    final usernameStyle = theme.textTheme.labelLarge?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );
    final titleStyle = theme.textTheme.labelMedium?.copyWith(
      height: 1.2,
      color: scheme.primary,
    );
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border(
          left: BorderSide(color: scheme.outline, width: 4),
        ),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(4),
          bottomRight: Radius.circular(4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部:头像 + username + 可选标题
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                avatarBuilder(context, node.username, node.avatarUrl, 24),
                const SizedBox(width: 8),
                // 话题引用(cooked 无 data-username)不显示 "用户名:";
                // 仅用户引用(有 username)才显示,对齐网页。
                if (node.username.isNotEmpty)
                  Text(
                    '${node.username}:',
                    style: usernameStyle,
                  ),
                if (node.titleInlines.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Expanded(
                    child: InlineSpanText(
                      inlines: node.titleInlines,
                      baseStyle: titleStyle ?? const TextStyle(),
                      documentOrder: docOrderOf(node),
                      chunkIndex: chunkIndex,
                      flattener: _inlineFlattener,
                      linkHandler: linkHandler,
                      onDownloadAttachment: onDownloadAttachment,
                      emojiImageBuilder: emojiImageBuilder,
                      mentionTapHandler: mentionTapHandler,
                      imageContentBuilder: imageContentBuilder,
                      footnoteTapHandler: footnoteTapHandler,
                      localDateBuilder: localDateBuilder,
                      mathInlineBuilder: mathInlineBuilder,
                      totalImagesInPost: totalImagesInPost,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ] else if (node.titleText != null) ...[
                  const SizedBox(width: 4),
                  Expanded(
                    child: _QuoteTitle(
                      text: node.titleText!,
                      href: node.titleHref,
                      style: titleStyle,
                      onTap: node.titleHref == null || linkHandler == null
                          ? null
                          : () => linkHandler!(context, node.titleHref!),
                    ),
                  ),
                ],
                if (node.categoryName != null) ...[
                  const SizedBox(width: 4),
                  _QuoteCategoryBadge(
                    name: node.categoryName!,
                    color: _hexColor(node.categoryColor),
                    onTap: node.categoryHref == null || linkHandler == null
                        ? null
                        : () => linkHandler!(context, node.categoryHref!),
                  ),
                ],
              ],
            ),
          ),
          // 内容
          if (node.children.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // quote_card 内子节点走 compact factory
                    for (final child in node.children)
                      _compactCopy().build(context, child),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 块级 spoiler 渲染 — `<div class="spoiler">`。
  ///
  /// 视觉(子包简化版,无粒子动画):
  ///   未揭示:灰底 + 中心 "点击显示剧透" + 锁图标
  ///   揭示后:子节点正常渲染,左边 4px primary 竖条提示"已揭示"
  ///
  /// 状态由 _SpoilerBlockWidget 内部管。
  Widget buildSpoilerBlock(BuildContext context, SpoilerBlockNode node) {
    return _SpoilerBlockWidget(
      // spoiler 内子节点走 compact factory(消除嵌套 paragraph 多余 margin)
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in node.children) _compactCopy().build(context, c),
        ],
      ),
    );
  }

  /// Onebox 卡片渲染。优先走主项目注入的 [oneboxBuilder](dispatch 到
  /// 6 种子 builder);返回 null 时 fallback 到子包内置通用卡片(对齐
  /// legacy `default_onebox_builder`:favicon + 来源 + 标题 + 描述 +
  /// 缩略图)。
  Widget buildOnebox(BuildContext context, OneboxNode node) {
    final custom = oneboxBuilder?.call(context, node);
    if (custom != null) return custom;
    return _DefaultOneboxCard(
      node: node,
      onTap: () {
        final url = node.url;
        if (url != null && url.isNotEmpty && linkHandler != null) {
          linkHandler!(context, url);
        }
      },
    );
  }

  /// 折叠块渲染 — `<details>`。
  ///
  /// 视觉对齐 legacy `details_builder.dart`:
  ///   外:margin 上下 8 + outline 边框 + 圆角 8
  ///   头:可点击灰底 + 旋转箭头(0 → 0.25 turns)+ summary 文本
  ///   体:折叠时不构建(懒);展开 heightFactor 0→1 动画 200ms easeInOut
  ///
  /// 简化:不做 legacy 的 HtmlChunker 渐进式分块(子包 parser 比 fwfh
  /// 快 10x,首屏不卡顿,无必要)。
  Widget buildDetails(BuildContext context, DetailsNode node) {
    // 子节点递归走 compact factory(消除嵌套 paragraph 多余 margin)
    final childFactory = _compactCopy();
    return _DetailsWidget(
      summary: node.summary,
      initiallyOpen: node.initiallyOpen,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in node.children) childFactory.build(context, c),
        ],
      ),
    );
  }

  /// Obsidian Callout 渲染 — `<blockquote>[!type]+title</blockquote>`。
  ///
  /// 视觉对齐 legacy `callout_builder.dart`:
  ///   margin 上下 8 + 主色 @ 10% 背景 + 左 4px 主色竖条 + 右上右下圆角 4
  ///   头:Row(icon 18 + 标题 titleSmall(主色)+ 可折叠箭头)
  ///   体:Padding(12, 8, 12, 12) + DefaultTextStyle(onSurfaceVariant + 1.5)
  ///   可折叠:头部 InkWell + heightFactor 200ms easeIn + 箭头 0→0.5 turns
  ///
  /// 简化:不支持 titleHtml(legacy 几乎都是纯文本标题);[CalloutKind.unknown]
  /// 时用 typeRaw 首字母大写作为默认标题(对齐 legacy 兜底分支)。
  Widget buildCallout(BuildContext context, CalloutNode node) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final config = _calloutConfigFor(node.kind, node.typeRaw, scheme);
    // 内容是否为空(空时不渲染 body,且头部不留 8px 底 padding)
    final hasBody = node.children.isNotEmpty;
    final foldable = node.foldable;

    final titleText = node.title?.isNotEmpty == true
        ? node.title!
        : config.defaultTitle;
    final titleStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w500,
      color: config.color,
    );

    // 标题 widget:有 inline(保留链接/格式)→ InlineSpanText(链接可点),复用
    // callout 自己那个**未被任何文本框占用**的 docOrder(容器本身不出文本框),
    // 避免选区 id 冲突;否则纯文本 Text(默认标题 / 无格式自定义标题)。
    final hasTitleInlines = node.titleInlines?.isNotEmpty == true;
    final Widget titleWidget = hasTitleInlines
        ? InlineSpanText(
            inlines: node.titleInlines!,
            baseStyle: titleStyle ?? const TextStyle(),
            documentOrder: docOrderOf(node),
            chunkIndex: chunkIndex,
            flattener: _inlineFlattener,
            linkHandler: linkHandler,
            onDownloadAttachment: onDownloadAttachment,
            emojiImageBuilder: emojiImageBuilder,
            mentionTapHandler: mentionTapHandler,
            imageContentBuilder: imageContentBuilder,
            footnoteTapHandler: footnoteTapHandler,
            localDateBuilder: localDateBuilder,
            mathInlineBuilder: mathInlineBuilder,
            totalImagesInPost: totalImagesInPost,
          )
        : Text(titleText, style: titleStyle);

    // 装饰下放(同 blockquote):大 callout 拆片时,左条+主色背景每片都画(连续),
    // 仅首片留上外边距/上圆角/标题头、尾片留下外边距/下圆角,中间片无缝拼接。
    // 可折叠 callout 不拆(折叠态本就懒构建),恒为 whole。
    final pos = node.chunkPos;
    final isFirst =
        pos == BlockquoteChunkPos.whole || pos == BlockquoteChunkPos.first;
    final isLast =
        pos == BlockquoteChunkPos.whole || pos == BlockquoteChunkPos.last;

    Widget bodyWidget = Padding(
      padding: EdgeInsets.fromLTRB(12, isFirst ? 8 : 0, 12, isLast ? 12 : 0),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          height: 1.5,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final c in node.children) _compactCopy().build(context, c),
          ],
        ),
      ),
    );

    if (foldable != null && hasBody) {
      return _FoldableCalloutWidget(
        config: config,
        titleWidget: titleWidget,
        body: bodyWidget,
        initiallyExpanded: foldable,
      );
    }

    // 不可折叠 / 无内容形态(支持装饰下放位置感知)
    return Container(
      margin: EdgeInsets.only(top: isFirst ? 8 : 0, bottom: isLast ? 8 : 0),
      decoration: BoxDecoration(
        color: config.color.withValues(alpha: 0.1),
        border: Border(
          left: BorderSide(color: config.color, width: 4),
        ),
        borderRadius: BorderRadius.only(
          topRight: isFirst ? const Radius.circular(4) : Radius.zero,
          bottomRight: isLast ? const Radius.circular(4) : Radius.zero,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题头只在首片(whole / first)出现。
          if (isFirst)
            Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, hasBody ? 0 : 8),
              child: _CalloutTitleRow(
                config: config,
                titleWidget: titleWidget,
                foldable: false,
              ),
            ),
          if (hasBody) bodyWidget,
        ],
      ),
    );
  }

  /// 图片网格渲染 — `<div class="d-image-grid">`(对齐 legacy
  /// `image_grid_builder.dart`)。
  ///
  /// 视觉:
  ///   外:Padding vertical 8
  ///   主体:LayoutBuilder + Wrap(spacing 6, runSpacing 6)
  ///     列宽 = (avail - (cols-1)*6) / cols
  ///     瓦片高 = 宽 * (h/w) clamp 80..300;无尺寸时 = 宽 * 0.75
  ///   瓦片:ClipRRect 圆角 4 + 走 imageContentBuilder(主项目同款渲染)
  ///
  /// **carousel 模式 fallback**:子包不实现真 carousel(legacy 含分页 /
  /// 计数器 / 预加载 / 手势 — 量大且依赖 visibility_detector)。降级为
  /// 单列大图垂直叠。主项目可通过自定义 NodeFactory 子类 override 实现。
  ///
  /// **lazy load**:子包不依赖 visibility_detector,瓦片不做 lazy load。
  /// 主项目 imageContentBuilder 内自管 LazyImage(主项目已实现)。
  Widget buildImageGrid(BuildContext context, ImageGridNode node) {
    if (node.images.isEmpty) return const SizedBox.shrink();
    final builder = imageContentBuilder ?? defaultImageContentBuilder;
    // carousel 形态:优先用主项目注入的真轮播(legacy buildImageCarousel —
    // 分页 / 计数器 / 预加载 / 画廊左右切);未注入或返回 null 时降级单列大图。
    if (node.mode == ImageGridMode.carousel) {
      final custom = imageGridBuilder?.call(context, node);
      if (custom != null) return custom;
      // fallback:单列 + 大图(子包不实现真 carousel,见类文档)。
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final img in node.images)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: builder(context, img, totalImagesInPost),
                ),
              ),
          ],
        ),
      );
    }
    // 瀑布流(官方 columns.js + d-image-grid.scss 逐条对齐):
    // - <2 张不启用网格(官方 minCount=2 → data-disabled,退化普通图流);
    // - 列数:2/4 张图 2 列,其余 3 列(官方 count());cooked 带
    //   data-columns ≥3 时(web 运行时已分列的形态)尊重之;
    // - 分配:逐图放入**当前累计高度最短**的列(高度按宽高比累计);
    // - **列强制等高**(官方 flex-grow:1 + object-fit:cover):高度差
    //   平分给列内瓦片、cover 裁切吸收 —— 底边平齐是官方观感的关键,
    //   列尾错落的"纯瀑布"不是官方形态;
    // - 瓦片间距 6px(官方 $grid-column-gap)。
    if (node.images.length < 2) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: builder(context, node.images.single, totalImagesInPost),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const spacing = 6.0;
          final cols = gridColumnCount(node.images.length, node.columns);
          final colWidth =
              (constraints.maxWidth - (cols - 1) * spacing) / cols;
          final columns = distributeGridImages(node.images, cols);
          final heights =
              gridEqualizedTileHeights(columns, colWidth, spacing);

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < cols; c++) ...[
                if (c > 0) const SizedBox(width: spacing),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var r = 0; r < columns[c].length; r++)
                        Padding(
                          padding: EdgeInsets.only(
                            bottom:
                                r == columns[c].length - 1 ? 0 : spacing,
                          ),
                          child: _GridTile(
                            image: columns[c][r].$2,
                            tileHeight: heights[c][r],
                            imageContentBuilder: builder,
                            totalImagesInPost: totalImagesInPost,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 懒加载视频渲染 — `<div class="lazy-video-container">`(对齐 legacy
  /// `lazy_video_builder.dart::_buildThumbnail`)。
  ///
  /// 视觉:
  ///   Padding vertical 8 + ClipRRect 圆角 8 + 黑底容器
  ///   主体:AspectRatio 16:9 缩略图 + 中央播放按钮(品牌色 60×42 圆角 8)
  ///   底部:标题栏(灰底 surfaceContainerHighest @ 0.5,可点跳 url)
  ///
  /// **优先调 [lazyVideoBuilder]**(主项目注入 webview iframe);
  /// 返回 null 时画内置缩略图卡片,点击通过 [linkHandler] 跳浏览器。
  Widget buildLazyVideo(BuildContext context, LazyVideoNode node) {
    final custom = lazyVideoBuilder?.call(context, node);
    // 平台 view(webview / video texture)在 macOS 桌面:鼠标 hover 经过时
    // Flutter MouseTracker 反复 hit-test + 重合成平台 view 导致闪烁
    // (flutter/flutter#53253 / #135999)。MouseRegion(opaque) 让 hover 在
    // Flutter 层被吸收、不反复穿透到平台 view;RepaintBoundary 隔离重绘。
    // 平台 view 的真实交互(播放控制 / webview)走 OS 层,不受影响。
    if (custom != null) {
      return RepaintBoundary(
        child: MouseRegion(opaque: true, child: custom),
      );
    }
    return _LazyVideoThumbnailCard(
      node: node,
      onTap: () {
        // 没注入 lazyVideoBuilder → 降级走 linkHandler 跳浏览器
        final url = node.url;
        if (url.isNotEmpty && linkHandler != null) {
          linkHandler!(context, url);
        }
      },
    );
  }

  /// iframe 渲染。优先调主项目 [iframeBuilder](注入真实 webview),
  /// 返回 null 时画内置占位卡(图标 + 域名 + "打开链接" 按钮,
  /// 点击通过 [linkHandler] 跳浏览器)。
  ///
  /// 子包不依赖 webview_flutter / flutter_inappwebview(平台插件量大)。
  Widget buildIframe(BuildContext context, IframeNode node) {
    final custom = iframeBuilder?.call(context, node);
    // 平台 view(webview / video texture)在 macOS 桌面:鼠标 hover 经过时
    // Flutter MouseTracker 反复 hit-test + 重合成平台 view 导致闪烁
    // (flutter/flutter#53253 / #135999)。MouseRegion(opaque) 让 hover 在
    // Flutter 层被吸收、不反复穿透到平台 view;RepaintBoundary 隔离重绘。
    // 平台 view 的真实交互(播放控制 / webview)走 OS 层,不受影响。
    if (custom != null) {
      return RepaintBoundary(
        child: MouseRegion(opaque: true, child: custom),
      );
    }
    return _IframePlaceholderCard(
      node: node,
      onTap: () {
        if (node.src.isNotEmpty && linkHandler != null) {
          linkHandler!(context, node.src);
        }
      },
    );
  }

  /// 原生上传视频渲染。优先调主项目 [videoBuilder]（注入 chewie 真播放器），
  /// 返回 null 时画内置占位卡（封面/图标 + "播放视频"，点击通过 [linkHandler]
  /// 跳浏览器）。
  ///
  /// 子包不依赖 chewie/video_player（平台插件量大）。
  Widget buildVideo(BuildContext context, VideoNode node) {
    final custom = videoBuilder?.call(context, node);
    // 平台 view(webview / video texture)在 macOS 桌面:鼠标 hover 经过时
    // Flutter MouseTracker 反复 hit-test + 重合成平台 view 导致闪烁
    // (flutter/flutter#53253 / #135999)。MouseRegion(opaque) 让 hover 在
    // Flutter 层被吸收、不反复穿透到平台 view;RepaintBoundary 隔离重绘。
    // 平台 view 的真实交互(播放控制 / webview)走 OS 层,不受影响。
    if (custom != null) {
      return RepaintBoundary(
        child: MouseRegion(opaque: true, child: custom),
      );
    }
    return _VideoPlaceholderCard(
      node: node,
      onTap: () {
        if (node.src.isNotEmpty && linkHandler != null) {
          linkHandler!(context, node.src);
        }
      },
    );
  }

  /// 原生上传音频渲染。优先调主项目 [audioBuilder]（注入 just_audio 音频条），
  /// 返回 null 时画内置占位卡（音乐图标 + 文件名,点击降级 [linkHandler]）。
  Widget buildAudio(BuildContext context, AudioNode node) {
    final custom = audioBuilder?.call(context, node);
    if (custom != null) return custom;
    return _AudioPlaceholderCard(
      node: node,
      onTap: () {
        if (node.src.isNotEmpty && linkHandler != null) {
          linkHandler!(context, node.src);
        }
      },
    );
  }

  /// 表格渲染 — `<table>`(对齐 legacy `table_builder.dart`)。
  ///
  /// 视觉:
  ///   外:margin v8 + Container outline 边框 + 圆角 8
  ///   水平 SingleChildScrollView(列宽超出屏幕宽时滚动)
  ///   表头:surfaceContainerHighest 灰底 + 加粗
  ///   每 cell:fixed 列宽(预算 60..200 clamp,前 10 行采样 TextPainter)
  ///   + 8px padding + 列右 1px 分隔线
  ///   每行:底部 1px 分隔线
  ///   行数 > [_kVirtualizeThreshold]:ListView.builder 行虚拟化 + 显示总行数
  ///
  /// cell 内子节点走 _compactCopy 渲染(消除嵌套 paragraph 多余 margin)。
  Widget buildTable(BuildContext context, TableNode node) {
    return _TableWidget(node: node, childFactory: _compactCopy());
  }

  /// Discourse policy 渲染 — `<div class="policy">`(对齐 legacy
  /// `policy_builder.dart::_PolicyWidget`)。
  ///
  /// **优先 [policyBuilder]** — 主项目注入完整交互(接受/撤销按钮 +
  /// API 调用 + 已接受用户列表);返回 null 时画 fallback 卡片:
  ///   外:边框容器 + 圆角 8 + margin v8
  ///   body:子节点走 _compactCopy
  ///   footer:横分隔线 + 静态 acceptLabel 按钮(占位,无作用)
  Widget buildPolicy(BuildContext context, PolicyNode node) {
    final custom = policyBuilder?.call(context, node);
    if (custom != null) return custom;
    return _PolicyFallbackCard(node: node, childFactory: _compactCopy());
  }

  /// 投票块渲染 — `<div class="poll">`。
  ///
  /// **优先 [pollBuilder]** — 主项目接 legacy buildPoll(选项/票数/投票
  /// 交互 + API);返回 null 时画 fallback 占位卡(标题 + 接入提示)。
  Widget buildPoll(BuildContext context, PollNode node) {
    final custom = pollBuilder?.call(context, node);
    if (custom != null) return custom;
    return _PollFallbackCard(node: node);
  }

  /// 聊天记录渲染 — `<div class="chat-transcript">`。
  ///
  /// **优先 [chatTranscriptBuilder]** — 主项目接 legacy buildChatTranscript
  /// (头像/反应/线程/消息递归);返回 null 时画 fallback 卡。
  Widget buildChatTranscript(BuildContext context, ChatTranscriptNode node) {
    final custom = chatTranscriptBuilder?.call(context, node);
    if (custom != null) return custom;
    return _ChatTranscriptFallbackCard(node: node);
  }

  /// 块级数学公式渲染 — `<div class="math">`(对齐 legacy
  /// `math_builder.dart::buildMathBlock`)。
  ///
  /// 优先调主项目 [mathBlockBuilder](注入 flutter_math_fork.Math.tex);
  /// 返回 null 时画 fallback:Padding v8 + Center + 水平 SingleChildScrollView
  /// + monospace `$latex$` 原文(对齐 legacy onErrorFallback)。
  Widget buildMathBlock(BuildContext context, MathBlockNode node) {
    if (node.latex.isEmpty) return const SizedBox.shrink();
    final custom = mathBlockBuilder?.call(context, node);
    if (custom != null) return custom;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            r'$' + node.latex + r'$',
            style: TextStyle(
              fontFamily: 'FiraCode',
              fontFamilyFallback: const ['monospace', 'Menlo', 'Courier'],
              fontSize: 16,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }

  /// 内容型 SVG 渲染 — `<svg viewBox>`(对齐 legacy `_buildInlineSvg`
  /// discourse_html_content_widget.dart:943)。
  ///
  /// 优先调主项目 [svgBuilder](注入 jovial_svg ScalableImage.fromSvgString +
  /// LayoutBuilder 等比铺满列宽);返回 null 时子包画 fallback 占位框
  /// (子包不绑 jovial_svg,无法真渲染矢量图)。
  Widget buildSvg(BuildContext context, SvgNode node) {
    if (node.svgSource.trim().isEmpty) return const SizedBox.shrink();
    final custom = svgBuilder?.call(context, node);
    if (custom != null) return custom;
    // 子包 fallback:不引 jovial_svg,只画占位(对齐 image/iframe fallback 风格)。
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        height: 96,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_outlined,
                size: 28, color: scheme.onSurfaceVariant),
            const SizedBox(height: 4),
            Text('SVG',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// 懒加载视频品牌色(对齐 legacy `_LazyVideoAttributes.brandColor`)。
Color _brandColorFor(LazyVideoProvider p) => switch (p) {
      LazyVideoProvider.youtube => const Color(0xFFFF0000),
      LazyVideoProvider.vimeo => const Color(0xFF1AB7EA),
      LazyVideoProvider.tiktok => const Color(0xFF010101),
      LazyVideoProvider.other => const Color(0xFF666666),
    };

/// 子包内置懒加载视频缩略图卡片(主项目不注入 lazyVideoBuilder 时的
/// fallback)。
class _LazyVideoThumbnailCard extends StatelessWidget {
  const _LazyVideoThumbnailCard({required this.node, required this.onTap});
  final LazyVideoNode node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brand = _brandColorFor(node.provider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: Colors.black,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 缩略图 + 中央播放按钮
              GestureDetector(
                onTap: onTap,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: node.thumbnailUrl.isNotEmpty
                          ? Image.network(
                              node.thumbnailUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const _VideoPlaceholder(),
                            )
                          : const _VideoPlaceholder(),
                    ),
                    Container(
                      width: 60,
                      height: 42,
                      decoration: BoxDecoration(
                        color: brand.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ],
                ),
              ),
              if (node.title.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  child: Text(
                    node.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: node.url.isNotEmpty ? scheme.primary : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: const Center(
        child: Icon(
          Icons.video_library_outlined,
          size: 48,
          color: Colors.white54,
        ),
      ),
    );
  }
}

/// 网格中的单张图片瓦片 — 按 columnWidth 算高 + ClipRRect 圆角 + 内部
/// 走 imageContentBuilder。
class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.image,
    required this.tileHeight,
    required this.imageContentBuilder,
    required this.totalImagesInPost,
  });

  final ImageRun image;

  /// 等高化后的瓦片高(gridEqualizedTileHeights 产出;与自然比例的差
  /// 由 cover 裁切吸收 —— 官方 flex-grow + object-fit:cover 同构)。
  final double tileHeight;

  final ImageContentBuilder imageContentBuilder;
  final int totalImagesInPost;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: tileHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        // FittedBox + cover:让 imageContentBuilder 产生的 widget(主项目
        // LazyImage 等)按 cover 填满瓦片,跟 legacy `BoxFit.cover` 一致。
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: imageContentBuilder(context, image, totalImagesInPost),
        ),
      ),
    );
  }
}

/// 子包内置 Onebox 通用卡片(主项目不注入 builder 时的 fallback)。
///
/// 视觉对齐 legacy `default_onebox_builder.dart`:
///   外:Container 灰底 surfaceContainerHighest @ 0.5 + 圆角 8 + outline border
///   顶:来源行(favicon + sourceName)
///   主体:标题(titleMedium 加粗) + 描述(bodySmall onSurfaceVariant)
///     + 右侧缩略图 80x80(若有 thumbnailUrl)
class _DefaultOneboxCard extends StatelessWidget {
  const _DefaultOneboxCard({required this.node, required this.onTap});
  final OneboxNode node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant, width: 1),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (node.sourceName != null || node.faviconUrl != null) ...[
                  _SourceRow(
                    faviconUrl: node.faviconUrl,
                    sourceName: node.sourceName,
                  ),
                  const SizedBox(height: 8),
                ],
                _Body(
                  title: node.title,
                  description: node.description,
                  thumbnailUrl: node.thumbnailUrl,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.faviconUrl, required this.sourceName});
  final String? faviconUrl;
  final String? sourceName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (faviconUrl != null && faviconUrl!.isNotEmpty) ...[
          // 子包不依赖任何 image provider,fallback 直接 Image.network
          // 主项目接入 oneboxBuilder 时会走 emojiImageProvider /
          // discourseImageProvider 体系,这里只是兜底
          SizedBox(
            width: 16,
            height: 16,
            child: Image.network(
              faviconUrl!,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Icon(
                Icons.public,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],
        if (sourceName != null && sourceName!.isNotEmpty)
          Flexible(
            child: Text(
              sourceName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.title,
    required this.description,
    required this.thumbnailUrl,
  });
  final String? title;
  final String? description;
  final String? thumbnailUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasThumb = thumbnailUrl != null && thumbnailUrl!.isNotEmpty;
    final textCol = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null && title!.isNotEmpty) ...[
          Text(
            title!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
        ],
        if (description != null && description!.isNotEmpty)
          Text(
            description!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
    if (!hasThumb) return textCol;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: textCol),
        const SizedBox(width: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 80,
            height: 80,
            child: Image.network(
              thumbnailUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: theme.colorScheme.surfaceContainerHigh,
                alignment: Alignment.center,
                child: Icon(
                  Icons.broken_image_outlined,
                  size: 24,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
///
/// 设计跟 legacy `_CodeBlockWidget.build` 对齐(简化版,无 mermaid /
/// 长按选择上下文):
/// - 行号列固定宽,与代码同步垂直滚动
/// - 代码区水平滚动,垂直 RawScrollbar
/// - 短代码自然撑开;超过 400px 高度后开始垂直滚
class _CodeBlockBody extends StatefulWidget {
  const _CodeBlockBody({
    required this.code,
    required this.language,
    required this.highlighter,
    required this.documentOrder,
    required this.chunkIndex,
  });

  final String code;
  final String? language;
  final CodeBlockHighlighter highlighter;
  final int documentOrder;
  final int chunkIndex;

  @override
  State<_CodeBlockBody> createState() => _CodeBlockBodyState();
}

class _CodeBlockBodyState extends State<_CodeBlockBody> {
  final _vController = ScrollController();
  final _hController = ScrollController();
  final _lineNumberVController = ScrollController();
  // 代码块可视外框(限高 SizedBox)的 key —— 给选区命中裁剪用(代码内容在
  // 内部滚动容器里,RenderParagraph 是完整内容尺寸,命中需裁到这个可视框)。
  final _viewportKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _vController.addListener(_syncLineNumberScroll);
  }

  @override
  void dispose() {
    _vController.removeListener(_syncLineNumberScroll);
    _vController.dispose();
    _hController.dispose();
    _lineNumberVController.dispose();
    super.dispose();
  }

  void _syncLineNumberScroll() {
    if (_lineNumberVController.hasClients) {
      _lineNumberVController.jumpTo(_vController.offset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final scheme = theme.colorScheme;

    final lines = widget.code.split('\n');
    final lineCount = lines.length;
    final padWidth = lineCount.toString().length;
    // 行号列宽 = 数字宽度(单字符 9px monospace 估算)+ 左右 padding 24
    final lineNumberWidth = padWidth * 9.0 + 24;

    // 估算高度:行高 13*1.5 = 19.5,+ 上下 padding 12*2
    const lineHeight = 13.0 * 1.5;
    const verticalPadding = 24.0;
    final contentHeight = lineCount * lineHeight + verticalPadding;
    final estimatedHeight = contentHeight.clamp(0.0, 400.0);

    final lineNumberStyle = TextStyle(
      fontFamily: 'FiraCode',
      fontFamilyFallback: const ['monospace', 'Menlo', 'Courier'],
      fontSize: 13,
      height: 1.5,
      color: isDark
          ? Colors.white.withValues(alpha: 0.35)
          : Colors.black.withValues(alpha: 0.35),
    );
    final borderColor = scheme.outlineVariant.withValues(alpha: 0.3);
    final thumbColor = (isDark ? Colors.white : Colors.black)
        .withValues(alpha: 0.15);

    return SizedBox(
      key: _viewportKey,
      height: estimatedHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 行号列(固定宽,跟随主体垂直滚)
          Container(
            width: lineNumberWidth,
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: borderColor)),
              color: isDark
                  ? Colors.white.withValues(alpha: 0.02)
                  : Colors.black.withValues(alpha: 0.02),
            ),
            child: SelectionContainer.disabled(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  scrollbars: false,
                ),
                child: SingleChildScrollView(
                  controller: _lineNumberVController,
                  physics: const NeverScrollableScrollPhysics(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 8,
                    ),
                    child: Text(
                      List.generate(
                        lineCount,
                        (i) => (i + 1).toString().padLeft(padWidth),
                      ).join('\n'),
                      style: lineNumberStyle,
                      textAlign: TextAlign.right,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 代码内容(双向滚动:垂直主体 + 水平内嵌)
          Expanded(
            child: RawScrollbar(
              controller: _vController,
              thumbVisibility: false,
              thickness: 4,
              radius: const Radius.circular(2),
              padding: const EdgeInsets.only(right: 2, top: 2, bottom: 2),
              thumbColor: thumbColor,
              child: SingleChildScrollView(
                controller: _vController,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  controller: _hController,
                  padding: const EdgeInsets.all(12),
                  // 代码块选区:整块作为一个可选文本块注册,projection 是纯文本
                  // (code 原文),复制时带 language(```lang)。highlighter 输出
                  // 的 RichText plainText 应等于 code 原文 → 渲染偏移对齐。
                  child: SelectableTextBox(
                    projectionGetter: () => RenderTextProjection([
                      ProjectionEntry(
                        renderStart: 0,
                        renderLen: widget.code.length,
                        logicalText: widget.code,
                        kind: ProjectionKind.text,
                      ),
                    ]),
                    documentOrder: widget.documentOrder,
                    chunkIndex: widget.chunkIndex,
                    codeLanguage: widget.language,
                    clipBoundsKey: _viewportKey,
                    debugLabel: 'codeBlock',
                    child: widget.highlighter(
                      context,
                      widget.code,
                      widget.language,
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

/// 块级 spoiler 揭示交互 widget。
class _SpoilerBlockWidget extends StatefulWidget {
  const _SpoilerBlockWidget({required this.child});
  final Widget child;

  @override
  State<_SpoilerBlockWidget> createState() => _SpoilerBlockWidgetState();
}

class _SpoilerBlockWidgetState extends State<_SpoilerBlockWidget>
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
    if (spoilerRevealed) {
      // 揭示态与未揭示态**同几何**(都只内容 + 上下 8 margin,无额外 padding/边框)
      // → 揭示前后不抖动。
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: GestureDetector(onTap: _hide, child: widget.child),
      );
    }
    // 未揭示:隐藏内容撑尺寸 + 上层遮罩(shader 粒子云 / reduce-motion 静态灰块),点击露出。
    final isDark = theme.brightness == Brightness.dark;
    final bg = theme.scaffoldBackgroundColor;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _reveal,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: widget.child,
              ),
              Positioned.fill(
                child: spoilerReduceMotion
                    // reduce-motion:静态灰块遮罩(可见、隐内容,无动画)。
                    ? DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
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
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 引用卡标题文本(只是一行 InkWell-y 可点 Text;主色 + 省略)。
class _QuoteTitle extends StatelessWidget {
  const _QuoteTitle({
    required this.text,
    required this.href,
    required this.style,
    required this.onTap,
  });

  final String text;
  final String? href;
  final TextStyle? style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textWidget = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (onTap == null) return textWidget;
    return GestureDetector(
      onTap: onTap,
      child: textWidget,
    );
  }
}

/// 把 CSS hex 颜色串(`#RGB`/`#RRGGBB`/`#RRGGBBAA`)解析成 [Color]。
/// 用于引用卡分类徽章的 `--category-badge-color` / `--category-badge-text-color`。
/// 解析失败返回 null(渲染回退主题色)。
Color? _hexColor(String? hex) {
  if (hex == null) return null;
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 3) {
    h = h.split('').map((c) => '$c$c').join(); // #RGB → RRGGBB
  }
  if (h.length == 6) h = 'ff$h'; // 补 alpha
  if (h.length != 8) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}

/// 引用卡标题旁的分类徽章(彩色圆角标签,对齐 legacy `.badge-category`)。
/// 底色/文字色来自 Discourse 的 `--category-badge-color` 变量;点击跳分类页。
/// (图标 svg 暂略,先对齐彩色 + 名称这两个主视觉。)
class _QuoteCategoryBadge extends StatelessWidget {
  const _QuoteCategoryBadge({
    required this.name,
    this.color,
    this.onTap,
  });

  final String name;

  /// 分类色(`--category-badge-color`)—— 用作圆点 + 名称的颜色。
  /// 对齐 Discourse `--style-icon`:彩色图标 + 彩色名称、**无背景块**。
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.onSurfaceVariant;
    // --style-icon:分类色「圆点(代图标)+ 名称」,无背景块(对齐网页 #4)。
    // 精确 category 图标是 svg(code/droplet 等),子包不渲染 svg,先用圆点近似。
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            height: 1.2,
            color: c,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
    if (onTap == null) return row;
    return GestureDetector(onTap: onTap, child: row);
  }
}

/// 代码块右上角的"复制"按钮,带 1.5s "已复制" 反馈。
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.code});
  final String code;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextButton.icon(
      onPressed: _copy,
      icon: Icon(
        _copied ? Icons.check_rounded : Icons.copy_rounded,
        size: 14,
      ),
      label: Text(
        _copied ? 'Copied' : 'Copy',
        style: const TextStyle(fontSize: 11),
      ),
      style: TextButton.styleFrom(
        foregroundColor: _copied ? scheme.primary : scheme.onSurfaceVariant,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 28),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 折叠块 stateful 交互 widget。
///
/// 折叠/展开:箭头旋转 0 → 0.25 turn + heightFactor 0 → 1,200ms easeInOut。
/// **懒构建**:折叠时不渲染 body widget(animation status = dismissed 时
/// 清掉 child),节省树深 + memory。
class _DetailsWidget extends StatefulWidget {
  const _DetailsWidget({
    required this.summary,
    required this.body,
    required this.initiallyOpen,
  });

  final String summary;
  final Widget body;
  final bool initiallyOpen;

  @override
  State<_DetailsWidget> createState() => _DetailsWidgetState();
}

class _DetailsWidgetState extends State<_DetailsWidget>
    with SingleTickerProviderStateMixin {
  late bool _isOpen;
  /// 是否构建 body widget(展开中或动画进行中为 true)
  late bool _buildBody;
  late AnimationController _controller;
  late Animation<double> _iconTurns;
  late Animation<double> _heightFactor;

  @override
  void initState() {
    super.initState();
    _isOpen = widget.initiallyOpen;
    _buildBody = _isOpen;
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _controller.addStatusListener(_handleAnimationStatus);
    _iconTurns = Tween<double>(begin: 0.0, end: 0.25).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _heightFactor = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
    if (_isOpen) _controller.value = 1.0;
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_handleAnimationStatus);
    _controller.dispose();
    super.dispose();
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) {
      setState(() => _buildBody = false);
    }
  }

  void _toggle() {
    setState(() {
      _isOpen = !_isOpen;
      if (_isOpen) {
        _buildBody = true;
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = isDark
        ? scheme.outlineVariant.withValues(alpha: 0.5)
        : scheme.outline.withValues(alpha: 0.3);
    final headerBgColor = isDark
        ? scheme.surfaceContainerHigh
        : scheme.surfaceContainerLow;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: borderColor, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头:可点击 + 旋转箭头 + summary
            Material(
              color: headerBgColor,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(7),
              ),
              child: InkWell(
                onTap: _toggle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      RotationTransition(
                        turns: _iconTurns,
                        child: Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          widget.summary.isEmpty ? 'Details' : widget.summary,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 体:折叠时不构建,展开动画
            if (_buildBody)
              ClipRect(
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) => Align(
                    alignment: Alignment.topLeft,
                    heightFactor: _heightFactor.value,
                    child: child,
                  ),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      border: Border(
                        top: BorderSide(color: borderColor, width: 1),
                      ),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: widget.body,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Callout 视觉配置 — 子包内置版本(13 大类 + unknown 兜底)。
///
/// 对齐 legacy `callout_config.dart::getCalloutConfig`,但:
/// - 不依赖 `app_icons`(子包零外部依赖原则),改用 Material `Icons.*`
/// - color 直接用 Material 命名色(与 legacy 同)
class _CalloutConfig {
  const _CalloutConfig({
    required this.color,
    required this.icon,
    required this.defaultTitle,
  });
  final Color color;
  final IconData icon;
  final String defaultTitle;
}

_CalloutConfig _calloutConfigFor(
  CalloutKind kind,
  String typeRaw,
  ColorScheme scheme,
) {
  switch (kind) {
    case CalloutKind.note:
      return const _CalloutConfig(
        color: Colors.blue,
        icon: Icons.edit_note_rounded,
        defaultTitle: 'Note',
      );
    case CalloutKind.summary:
      return const _CalloutConfig(
        color: Colors.cyan,
        icon: Icons.subject_rounded,
        defaultTitle: 'Summary',
      );
    case CalloutKind.info:
      return const _CalloutConfig(
        color: Colors.blue,
        icon: Icons.info_rounded,
        defaultTitle: 'Info',
      );
    case CalloutKind.todo:
      return const _CalloutConfig(
        color: Colors.blue,
        icon: Icons.check_circle_rounded,
        defaultTitle: 'Todo',
      );
    case CalloutKind.tip:
      return const _CalloutConfig(
        color: Colors.teal,
        icon: Icons.tips_and_updates_rounded,
        defaultTitle: 'Tip',
      );
    case CalloutKind.success:
      return const _CalloutConfig(
        color: Colors.green,
        icon: Icons.check_circle_rounded,
        defaultTitle: 'Success',
      );
    case CalloutKind.question:
      return const _CalloutConfig(
        color: Colors.orange,
        icon: Icons.help_rounded,
        defaultTitle: 'Question',
      );
    case CalloutKind.warning:
      return const _CalloutConfig(
        color: Colors.orange,
        icon: Icons.warning_amber_rounded,
        defaultTitle: 'Warning',
      );
    case CalloutKind.failure:
      return const _CalloutConfig(
        color: Colors.red,
        icon: Icons.close_rounded,
        defaultTitle: 'Failure',
      );
    case CalloutKind.danger:
      return const _CalloutConfig(
        color: Colors.red,
        icon: Icons.dangerous_rounded,
        defaultTitle: 'Danger',
      );
    case CalloutKind.bug:
      return const _CalloutConfig(
        color: Colors.red,
        icon: Icons.bug_report_rounded,
        defaultTitle: 'Bug',
      );
    case CalloutKind.example:
      return const _CalloutConfig(
        color: Colors.purple,
        icon: Icons.list_rounded,
        defaultTitle: 'Example',
      );
    case CalloutKind.quote:
      return const _CalloutConfig(
        color: Colors.grey,
        icon: Icons.format_quote_rounded,
        defaultTitle: 'Quote',
      );
    case CalloutKind.unknown:
      // 未知类型:typeRaw 首字母大写 + 灰色 + 引号图标
      final defaultTitle = typeRaw.isEmpty
          ? 'Note'
          : '${typeRaw[0].toUpperCase()}${typeRaw.substring(1)}';
      return _CalloutConfig(
        color: Colors.grey,
        icon: Icons.format_quote_rounded,
        defaultTitle: defaultTitle,
      );
  }
}

/// Callout 标题行:icon + 标题 + 可选展开箭头 placeholder。
///
/// `foldable=true` 时由父 _FoldableCalloutWidget 替换为带旋转动画的箭头;
/// 这里只画静态版给"不可折叠"形态用。
class _CalloutTitleRow extends StatelessWidget {
  const _CalloutTitleRow({
    required this.config,
    required this.titleWidget,
    required this.foldable,
  });

  final _CalloutConfig config;
  final Widget titleWidget;

  /// 是否需要画展开箭头占位(不可折叠时 false,这里就不画)。
  /// 注意:可折叠形态有自己的 _FoldableCalloutWidget,这里 foldable=false。
  final bool foldable;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(config.icon, size: 18, color: config.color),
        const SizedBox(width: 8),
        Expanded(
          child: titleWidget,
        ),
        if (foldable)
          Icon(
            Icons.expand_more_rounded,
            size: 18,
            color: config.color.withValues(alpha: 0.7),
          ),
      ],
    );
  }
}

/// 可折叠 Callout 交互 widget(对齐 legacy `FoldableCallout`)。
///
/// 头部 InkWell + 200ms easeIn:
/// - 箭头 RotationTransition 0 → 0.5 turns(对齐 legacy 行为)
/// - 内容 heightFactor 0 → 1(底部 padding 包含在 body 内)
///
/// 与 _DetailsWidget 不同点:
/// - 用 callout config 色块包外层(legacy 同)
/// - 内容用 ClipRect + Align 折叠,初始 _controller.value 按 initiallyExpanded
class _FoldableCalloutWidget extends StatefulWidget {
  const _FoldableCalloutWidget({
    required this.config,
    required this.titleWidget,
    required this.body,
    required this.initiallyExpanded,
  });

  final _CalloutConfig config;
  final Widget titleWidget;
  final Widget body;
  final bool initiallyExpanded;

  @override
  State<_FoldableCalloutWidget> createState() => _FoldableCalloutWidgetState();
}

class _FoldableCalloutWidgetState extends State<_FoldableCalloutWidget>
    with SingleTickerProviderStateMixin {
  late bool _expanded;
  late AnimationController _controller;
  late Animation<double> _iconTurns;
  late Animation<double> _heightFactor;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _iconTurns = Tween<double>(begin: 0.0, end: 0.5).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );
    _heightFactor = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeIn,
    );
    if (_expanded) _controller.value = 1.0;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (_expanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: config.color.withValues(alpha: 0.1),
        border: Border(
          left: BorderSide(color: config.color, width: 4),
        ),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(4),
          bottomRight: Radius.circular(4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Icon(config.icon, size: 18, color: config.color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: widget.titleWidget,
                  ),
                  RotationTransition(
                    turns: _iconTurns,
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 18,
                      color: config.color.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
          ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Align(
                alignment: Alignment.topLeft,
                heightFactor: _heightFactor.value,
                child: child,
              ),
              child: widget.body,
            ),
          ),
        ],
      ),
    );
  }
}

/// 子包内置 iframe 占位卡(主项目不注入 iframeBuilder 时的 fallback)。
///
/// 视觉:Container 灰底 + 圆角 8 + outline,内部:
///   左:Icon(open_in_new_rounded)
///   中:Text(域名 / "嵌入内容")标题 + src 灰色副标
///   右:箭头图标(暗示可点)
class _IframePlaceholderCard extends StatelessWidget {
  const _IframePlaceholderCard({required this.node, required this.onTap});
  final IframeNode node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final host = _extractHost(node.src);
    final title = node.title?.isNotEmpty == true ? node.title! : host;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant, width: 1),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.open_in_new_rounded,
                  size: 22,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title.isEmpty ? '嵌入内容' : title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (node.src.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          node.src,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 从 url 提 host(`https://www.example.com/path` → `example.com`),
  /// 失败兜底显示原 src。
  static String _extractHost(String src) {
    if (src.isEmpty) return '';
    final uri = Uri.tryParse(src);
    if (uri == null) return src;
    var host = uri.host;
    if (host.startsWith('www.')) host = host.substring(4);
    return host.isEmpty ? src : host;
  }
}

/// 原生上传视频占位卡（未注入 videoBuilder 时）。
///
/// 有封面 poster：画封面 + 中央播放按钮（对齐 lazy_video 卡片观感，AspectRatio
/// 16:9 黑底 + ClipRRect 圆角 8）；无封面：灰底卡 + 视频图标 + 文件名。
/// 整卡点击 → onTap（降级 linkHandler 跳浏览器）。
class _VideoPlaceholderCard extends StatelessWidget {
  const _VideoPlaceholderCard({required this.node, required this.onTap});
  final VideoNode node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasPoster = node.poster != null && node.poster!.isNotEmpty;
    final aspect = (node.width != null &&
            node.height != null &&
            node.width! > 0 &&
            node.height! > 0)
        ? node.width! / node.height!
        : 16 / 9;
    if (hasPoster) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              color: Colors.black,
              child: AspectRatio(
                aspectRatio: aspect,
                child: Stack(
                  alignment: Alignment.center,
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      node.poster!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: Colors.black,
                        child: const Center(
                          child: Icon(Icons.movie_rounded,
                              size: 48, color: Colors.white54),
                        ),
                      ),
                    ),
                    Container(
                      width: 60,
                      height: 42,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 32),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    // 无封面：横条卡（同 _IframePlaceholderCard 观感）
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant, width: 1),
            ),
            child: Row(
              children: [
                Icon(Icons.play_circle_outline_rounded,
                    size: 24, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    node.src.isEmpty ? '视频' : node.src,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 原生上传音频占位卡（未注入 audioBuilder 时）。
/// 横条卡：音乐图标 + 文件名（title 优先，否则 src），点击 → onTap。
class _AudioPlaceholderCard extends StatelessWidget {
  const _AudioPlaceholderCard({required this.node, required this.onTap});
  final AudioNode node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = (node.title != null && node.title!.isNotEmpty)
        ? node.title!
        : (node.src.isEmpty ? '音频' : node.src);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant, width: 1),
            ),
            child: Row(
              children: [
                Icon(Icons.audiotrack_rounded,
                    size: 22, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 表格渲染常量,对齐 legacy table_builder.dart。
const double _kTableMinColWidth = 60;
const double _kTableMaxColWidth = 200;
const EdgeInsets _kTableCellPadding = EdgeInsets.all(8);
const int _kTableVirtualizeThreshold = 30;

/// 表格 widget — 含列宽预算 + 水平滚动 + 表头特殊背景 + 大表格虚拟化。
///
/// childFactory 是 NodeFactory 的 compact 副本(消除 cell 内 paragraph
/// 多余 margin),build cell 时用它递归 build cell.children。
class _TableWidget extends StatelessWidget {
  const _TableWidget({required this.node, required this.childFactory});
  final TableNode node;
  final NodeFactory childFactory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final borderColor = scheme.outlineVariant;
    final columnWidths = _computeColumnWidths(theme);
    // 外框 width=1 会从 totalWidth 扣 2px 给子级,加回避免两列表格 Row 溢出 1px
    final totalWidth = columnWidths.fold<double>(0, (s, w) => s + w) + 2;

    // 分离 header / body
    final headerRow = node.hasHeader && node.rows.isNotEmpty ? node.rows.first : null;
    final bodyRows = node.hasHeader && node.rows.isNotEmpty
        ? node.rows.sublist(1)
        : node.rows;

    // 截图模式关掉行虚拟化 → 全渲染,避免离屏截图截断大表格。
    final showInfoBar = bodyRows.length > _kTableVirtualizeThreshold &&
        !childFactory.screenshotMode;

    Widget bodyWidget;
    if (showInfoBar) {
      // 大表格行虚拟化(viewport 外的行不构建)。
      // 不设 itemExtent —— cell 内容多行(bullet 列表 / 多段)时被固定
      // 高度强裁是 legacy 的 bug,这里让每行按 Text 自然撑高。
      // 缺点:大表初始化时每个可见行都要 measure,但 60..200px 列宽下
      // measure 成本可控(单 cell TextPainter 1ms 级)。
      final maxHeight = MediaQuery.of(context).size.height * 0.6;
      bodyWidget = SizedBox(
        height: maxHeight,
        child: ListView.builder(
          itemCount: bodyRows.length,
          itemBuilder: (ctx, i) => _buildRow(
            ctx, theme, bodyRows[i], columnWidths, borderColor,
            isHeader: false,
            // 虚拟化分支下方有 infoBar,行永远不当 last;infoBar 自有
            // top border 作为分隔
            isLastRow: false,
          ),
        ),
      );
    } else {
      bodyWidget = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < bodyRows.length; i++)
            _buildRow(
              context, theme, bodyRows[i], columnWidths, borderColor,
              isHeader: false,
              isLastRow: i == bodyRows.length - 1,
            ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Container(
          width: totalWidth,
          decoration: BoxDecoration(
            border: Border.all(color: borderColor, width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (headerRow != null)
                  _buildRow(context, theme, headerRow, columnWidths,
                      borderColor,
                      isHeader: true),
                bodyWidget,
                if (showInfoBar)
                  _buildInfoBar(context, theme, borderColor, node.rows.length),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 用 TextPainter 采样前 10 行 cell.textContent 算列宽(对齐 legacy)。
  /// TextPainter 比真 build 一次 widget 树快几个数量级,精度足够。
  ///
  /// 结果按 [node] 身份缓存(Expando,node 随 parse 缓存跨 rebuild 稳定):
  /// 大表格重 build(缓存失效的主题切换等)不再重复 rows×cols 次 layout。
  /// baseStyle 变化(字号/字体)时签名不匹配 → 重测。
  static final Expando<({TextStyle style, List<double> widths})>
      _columnWidthsCache = Expando('tableColumnWidths');

  List<double> _computeColumnWidths(ThemeData theme) {
    final baseStyle = childFactory.baseTextStyle ??
        theme.textTheme.bodyMedium ??
        const TextStyle(fontSize: 14);
    final cached = _columnWidthsCache[node];
    if (cached != null && cached.style == baseStyle) return cached.widths;

    final widths = List<double>.filled(node.columnCount, _kTableMinColWidth);
    final sampleCount = node.rows.length < 11 ? node.rows.length : 11;
    for (var i = 0; i < sampleCount; i++) {
      final row = node.rows[i];
      for (var col = 0; col < row.length && col < node.columnCount; col++) {
        final text = _cellText(row[col]);
        if (text.isEmpty) continue;
        final style = row[col].isHeader
            ? baseStyle.copyWith(fontWeight: FontWeight.w600)
            : baseStyle;
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        final measured = painter.width + _kTableCellPadding.horizontal;
        if (measured > widths[col]) widths[col] = measured;
        painter.dispose();
      }
    }
    // clamp
    for (var i = 0; i < node.columnCount; i++) {
      widths[i] = widths[i].clamp(_kTableMinColWidth, _kTableMaxColWidth);
    }
    _columnWidthsCache[node] = (style: baseStyle, widths: widths);
    return widths;
  }

  /// 从 cell.children 提纯文本(用于列宽测量,不参与实际渲染)
  String _cellText(TableCellData cell) {
    final buf = StringBuffer();
    void scanInlines(List<InlineNode> nodes) {
      for (final n in nodes) {
        switch (n) {
          case TextRun(:final text):
            buf.write(text);
          case EmRun(:final children):
          case StrongRun(:final children):
          case StyledRun(:final children):
          case ColoredRun(:final children):
          case SizedRun(:final children):
          case LinkRun(:final children):
          case SpoilerRun(:final children):
            scanInlines(children);
          case InlineCodeRun(:final text):
            buf.write(text);
          case MentionRun(:final username):
            buf.write('@$username');
          case EmojiRun(:final name):
            buf.write(':$name:');
          case LocalDateRun(:final fallbackText):
            buf.write(fallbackText);
          case ClickCountRun(:final count):
            buf.write(count);
          case MathInlineRun(:final latex):
            buf.write(r'$' + latex + r'$');
          case ImageRun() ||
                LineBreakRun() ||
                FootnoteRefRun():
            break;
        }
      }
    }

    void scanBlock(BlockNode b) {
      switch (b) {
        case ParagraphNode(:final inlines):
        case HeadingNode(:final inlines):
          scanInlines(inlines);
        case ListNode(:final items):
          for (final item in items) {
            scanInlines(item.inlines);
          }
        case BlockquoteNode(:final children):
        case QuoteCardNode(:final children):
        case SpoilerBlockNode(:final children):
        case DetailsNode(:final children):
        case CalloutNode(:final children):
          for (final c in children) {
            scanBlock(c);
          }
        case CodeBlockNode(:final code):
          buf.write(code);
        case _:
          break;
      }
    }

    for (final c in cell.children) {
      scanBlock(c);
    }
    return buf.toString().trim();
  }

  Widget _buildRow(
    BuildContext context,
    ThemeData theme,
    List<TableCellData> row,
    List<double> columnWidths,
    Color borderColor, {
    required bool isHeader,
    bool isLastRow = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isHeader
            ? theme.colorScheme.surfaceContainerHighest
            : null,
        // 最后一行不画 bottom — 外层 Container 的 Border.all 已经有底边,
        // 否则会出现双线毛刺。header 因为下方必有 body/infoBar,需要保留
        // bottom 作为分隔。
        border: isLastRow
            ? null
            : Border(
                bottom: BorderSide(color: borderColor, width: 1),
              ),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var col = 0; col < node.columnCount; col++)
              _buildCell(
                context,
                theme,
                col < row.length ? row[col] : null,
                columnWidths[col],
                borderColor,
                isLeftBorder: col > 0,
                isHeaderRow: isHeader,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCell(
    BuildContext context,
    ThemeData theme,
    TableCellData? cell,
    double width,
    Color borderColor, {
    required bool isLeftBorder,
    required bool isHeaderRow,
  }) {
    return Container(
      width: width,
      decoration: isLeftBorder
          ? BoxDecoration(
              border: Border(
                left: BorderSide(color: borderColor, width: 1),
              ),
            )
          : null,
      padding: _kTableCellPadding,
      child: cell == null
          ? const SizedBox.shrink()
          : DefaultTextStyle.merge(
              style: (isHeaderRow || cell.isHeader)
                  ? const TextStyle(fontWeight: FontWeight.w600)
                  : const TextStyle(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final b in cell.children) childFactory.build(context, b),
                ],
              ),
            ),
    );
  }

  Widget _buildInfoBar(
    BuildContext context,
    ThemeData theme,
    Color borderColor,
    int totalRows,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border(
          top: BorderSide(color: borderColor, width: 1),
        ),
      ),
      child: Text(
        'Table · $totalRows rows',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// Discourse policy 区块 fallback 卡(主项目不注入 policyBuilder 时)。
///
/// 视觉对齐 legacy `_PolicyWidget`:
///   外:Container outline 边框 + 圆角 8 + margin v8
///   body padding 12,子节点走 compactCopy
///   footer:横分隔线 + Padding 12 + 静态 acceptLabel 按钮(无交互)
///
/// 主项目接 policyBuilder 后会替换整个 widget。
class _PolicyFallbackCard extends StatelessWidget {
  const _PolicyFallbackCard({required this.node, required this.childFactory});
  final PolicyNode node;
  final NodeFactory childFactory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accept = node.acceptLabel?.isNotEmpty == true
        ? node.acceptLabel!
        : '接受';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // body
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in node.children) childFactory.build(context, c),
              ],
            ),
          ),
          // 分隔线
          Container(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          // footer:静态按钮(占位,主项目通过 policyBuilder 替换)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                // 模拟"按钮"形态(轻度强调,无交互)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    accept,
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Policy · 接入主项目后显示完整交互',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 投票块 fallback 占位卡(主项目不注入 pollBuilder 时)。
///
/// poll 数据在 API,子包拿不到,只能显示标题 + 接入提示。主项目接
/// pollBuilder 后会替换为带选项/票数/投票交互的真实 widget。
class _PollFallbackCard extends StatelessWidget {
  const _PollFallbackCard({required this.node});
  final PollNode node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.bar_chart_rounded, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (node.title != null && node.title!.isNotEmpty)
                  Text(
                    node.title!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                Text(
                  'Poll · 接入主项目后显示选项与投票',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 聊天记录 fallback 卡(主项目不注入 chatTranscriptBuilder 时)。
///
/// 对齐 legacy chat_transcript_builder 的基础视觉:非 chained 时左侧 4px
/// 竖条 + 圆角;头像首字母 + 用户名 + 消息纯文本(strip HTML)。
/// 主项目接 builder 后会替换为带头像图/反应/线程/消息递归的完整 widget。
class _ChatTranscriptFallbackCard extends StatelessWidget {
  const _ChatTranscriptFallbackCard({required this.node});
  final ChatTranscriptNode node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final messageText = _stripHtml(node.messagesHtml);
    return Container(
      margin: node.isChained
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: node.isChained
            ? null
            : Border(left: BorderSide(color: scheme.outline, width: 4)),
        borderRadius: node.isChained
            ? null
            : const BorderRadius.only(
                topRight: Radius.circular(4),
                bottomRight: Radius.circular(4),
              ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (node.channelName != null && !node.isChained)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.tag_rounded,
                      size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    node.channelName!,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              node.isChained ? 8 : (node.channelName != null ? 4 : 8),
              12,
              0,
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: scheme.surfaceContainerHighest,
                  child: Text(
                    node.username.isNotEmpty
                        ? node.username.characters.first.toUpperCase()
                        : '?',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${node.username}:',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (messageText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Text(
                messageText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 极简 strip HTML(fallback 显示纯文本用)。主项目 builder 走 htmlBuilder
  /// 递归渲染真 HTML,这里只是无 builder 时的兜底。
  static String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
