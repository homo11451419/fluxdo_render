/// HTML cooked → `List<BlockNode>` 解析器(阶段 1 范围)。
///
/// 当前作用域:
/// - 块级:`<p>` / `<h1>` - `<h6>` / `<ul>` / `<ol>` / `<blockquote>` /
///   `<hr>` / `<pre>`(其他块级标签 fallback 成 ParagraphNode + textContent)
/// - 行内:文本 / `<em>` / `<i>` / `<strong>` / `<b>` / `<br>` /
///   `<a href>` / `<code>` / `<img>`
///
/// 后续阶段会扩展 quote_card / spoiler / 等。

library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'dart:ui' show TextAlign, Color;

import '../node/node.dart';
import 'arrow_ligature.dart';

class ParagraphParser {
  ParagraphParser();

  /// 本次 parse 调用中收集的 fnId → contentHtml 映射。
  /// `parse` 入口扫一次 fragment 填,sup.footnote-ref 解析时直接 lookup。
  /// **注意:不是线程安全 — ParagraphParser 不应被多线程同时调用同一实例。**
  /// 实践上每次 parse 都会重置,无需调用方关心。
  Map<String, String> _footnotes = const {};

  /// 诊断:本次 parse 中**落到纯文本兜底**(既非专用节点、非 skip-element)的
  /// 元素 tag 集合。非 null 时(由 [parseWithDiagnostics] 开启)才收集。
  /// 用于「fwfh 对齐」守护:喂真实 cooked → dump 出新引擎尚未覆盖的标签,
  /// 把"渲染缺口"从真机踩雷变成可枚举。见 fwfh_coverage_test。
  Set<String>? _unhandledTags;

  void _recordUnhandled(String tag) => _unhandledTags?.add(tag);

  /// 带诊断的 parse:返回节点 + 「未覆盖标签」集合(落到纯文本兜底的 tag)。
  /// 仅供 dev / 测试用,正常渲染走 [parse]。
  ({List<BlockNode> nodes, Set<String> unhandledTags}) parseWithDiagnostics(
    String html, {
    int imageIndexStart = 0,
    String? footnotesHtml,
  }) {
    final sink = <String>{};
    _unhandledTags = sink;
    try {
      final nodes = parse(
        html,
        imageIndexStart: imageIndexStart,
        footnotesHtml: footnotesHtml,
      );
      return (nodes: nodes, unhandledTags: sink);
    } finally {
      _unhandledTags = null;
    }
  }

  /// 把 cooked HTML 解析成 BlockNode 序列。
  ///
  /// - 顶层 `<p>` → `ParagraphNode`
  /// - 顶层裸文本(罕见,如 fragment 直接挂文本节点) → `ParagraphNode([TextRun(...)])`
  /// - 顶层未识别块级(如 `<h1>` 在阶段 1.1 未实现)→ 当作 paragraph,只取
  ///   textContent
  /// - 顶层 inline-only(没用 `<p>` 包,某些 cooked 形态)→ 把这一组合并
  ///   成单个 ParagraphNode
  ///
  /// 每个产出的 BlockNode 分配稳定 id("b_0", "b_1", ...),id 仅在
  /// 这一次 parse 调用内有意义,不跨调用稳定(同一 html parse 两次 id
  /// 相同是因为顺序确定,不需要额外保证)。
  /// [imageIndexStart]:本次 parse 的图片 indexInPost 起始值。长帖分 chunk 时,
  /// 每个 chunk 单独 parse,传该 chunk 之前所有 chunk 的图片总数,使 indexInPost
  /// 对齐**整帖**序(主项目画廊 viewer / heroTag 按整帖索引)。
  ///
  /// [footnotesHtml]:整帖脚注区源 html(`section.footnotes` 等)。长帖分 chunk
  /// 时正文 chunk 不含帖尾脚注区,需额外传整帖脚注区,否则脚注点击取不到内容。
  List<BlockNode> parse(
    String html, {
    int imageIndexStart = 0,
    String? footnotesHtml,
  }) {
    if (html.isEmpty) return const [];

    final fragment = html_parser.parseFragment(html);

    // 全局 id counter — 嵌套块级(list / blockquote 等)也用这个分配,
    // 保证一次 parse 内的 BlockNode id 全局唯一。
    var idCounter = 0;
    String nextId() => 'b_${idCounter++}';

    // 全局 image index counter,按 image 出现顺序自增分配 indexInPost。
    // 给主项目算 Hero tag / gallery viewer 索引用。分 chunk 时从整帖偏移起算。
    var imageIndexCounter = imageIndexStart;
    int nextImageIndex() => imageIndexCounter++;

    // 一次性扫整个 fragment 建立 fnId → contentHtml 映射,
    // 后续 sup.footnote-ref 解析时直接 lookup(避免 inline 节点再回查)。
    _footnotes = _collectFootnoteContents(fragment);
    // 分 chunk 时正文与脚注区不在同一 html,额外扫整帖脚注区补全映射。
    if (footnotesHtml != null && footnotesHtml.isNotEmpty) {
      final extra =
          _collectFootnoteContents(html_parser.parseFragment(footnotesHtml));
      for (final e in extra.entries) {
        _footnotes.putIfAbsent(e.key, () => e.value);
      }
    }

    return _parseBlocks(fragment.nodes, nextId, nextImageIndex);
  }

  /// 扫整个 fragment 收集 `section.footnotes` / `ol.footnotes-list` 下的
  /// 所有 `<li id="fnId">` → contentHtml 映射。
  ///
  /// contentHtml 处理:
  /// - 移除 backref(`<a class="footnote-backref">↩︎</a>`)
  /// - 若整体被 `<p>...</p>` 单层包裹,剥掉外层 p(legacy 同处理)
  /// - trim
  ///
  /// 找不到任何 footnotes section 时返回空 map。
  Map<String, String> _collectFootnoteContents(dom.DocumentFragment fragment) {
    final out = <String, String>{};
    // 收 section.footnotes 或 ol.footnotes-list 内所有 li
    final candidates = <dom.Element>[
      ...fragment.querySelectorAll('section.footnotes li'),
      ...fragment.querySelectorAll('ol.footnotes-list li'),
    ];
    for (final li in candidates) {
      final id = li.attributes['id']?.trim();
      if (id == null || id.isEmpty) continue;
      if (out.containsKey(id)) continue;
      var html = li.innerHtml;
      // 去掉 backref(可能在末尾,可能含 emoji ↩)
      html = html.replaceAll(
        RegExp(
          r'<a[^>]*class="[^"]*footnote-backref[^"]*"[^>]*>[\s\S]*?</a>',
          caseSensitive: false,
        ),
        '',
      );
      // 剥掉单层 <p>...</p>
      html = html
          .replaceAll(RegExp(r'^\s*<p>\s*'), '')
          .replaceAll(RegExp(r'\s*</p>\s*$'), '')
          .trim();
      if (html.isNotEmpty) out[id] = html;
    }
    return out;
  }

  /// 解析 `<section class="footnotes">` 内的 `<ol class="footnotes-list"><li id="fn:x">`
  /// 列表为有序 [FootnoteEntry]。
  ///
  /// 每个 li:
  /// - id 取 `id` 属性(`fn:abc`);缺失则跳过(无法对应上标)。
  /// - number 取 li 在列表中的 1-based 序号(Discourse 渲染保证 li 顺序 = 编号序)。
  /// - inlines:strip 末尾 backref(`<a class="footnote-backref">↩︎</a>`)后,
  ///   对 li 全部子节点跑 _collectInlineFromAnyNode(保留链接/样式/emoji)。
  ///   li 内常见 `<p>正文</p>` 单层包裹,_collectInlineFromAnyNode 会透传 p 内 inline
  ///   (p 是块级,但脚注 li 里通常仅单段;多段时退化为顺序拼接,可接受)。
  List<FootnoteEntry> _parseFootnoteEntries(
    dom.Element section,
    int Function() nextImageIndex,
  ) {
    final lis = section.querySelectorAll('li');
    if (lis.isEmpty) return const [];
    final out = <FootnoteEntry>[];
    var number = 0;
    for (final li in lis) {
      number++;
      final id = li.attributes['id']?.trim();
      if (id == null || id.isEmpty) continue;
      // 移除 backref(放进 inline 前先从 DOM 摘掉,避免解析出 ↩︎ 文本/链接)。
      for (final back in li.querySelectorAll('a.footnote-backref').toList()) {
        back.remove();
      }
      final inlines = <InlineNode>[];
      for (final child in li.nodes) {
        // li 内常见 <p>正文</p> 单层包裹:unwrap p 取其 inline 子,避免 p 走
        // _collectInline 的 default 触发 _recordUnhandled('p')。多段 p 顺序拼接。
        if (child is dom.Element && child.localName?.toLowerCase() == 'p') {
          for (final pc in child.nodes) {
            _collectInlineFromAnyNode(pc, inlines, nextImageIndex);
          }
        } else {
          _collectInlineFromAnyNode(child, inlines, nextImageIndex);
        }
      }
      _normalizeWhitespace(inlines);
      if (inlines.isEmpty) continue;
      out.add(FootnoteEntry(
        id: id,
        number: number.toString(),
        inlines: List.unmodifiable(inlines),
      ));
    }
    return out;
  }


  /// 顶层 parse 调它处理 fragment.nodes;blockquote 递归调它处理 inner。
  ///
  /// 处理流程:
  /// - 块级 element → 直接产 BlockNode
  /// - inline element / 裸 text → 累积到 pendingInlines,遇到下一个块级
  ///   或结束时 flush 成 ParagraphNode
  List<BlockNode> _parseBlocks(
    Iterable<dom.Node> nodes,
    String Function() nextId,
    int Function() nextImageIndex, {
    bool keepBlankEdges = false,
    int depth = 0,
  }) {
    final out = <BlockNode>[];
    final pendingInlines = <InlineNode>[];

    void flushInlines() {
      if (pendingInlines.isEmpty) return;
      _normalizeWhitespace(pendingInlines);
      if (pendingInlines.isEmpty) return;
      out.add(ParagraphNode(
        id: nextId(),
        inlines: List.unmodifiable(pendingInlines),
      ));
      pendingInlines.clear();
    }

    for (final node in nodes) {
      switch (node) {
        case dom.Element():
          final tag = node.localName?.toLowerCase() ?? '';
          // 顶层裸 <br>:Discourse cooked 经常在 block 之间塞 <br> 作为
          // markdown 段间格式残留(浏览器里因为 block 之间已有 margin 而
          // 几乎不可见),不能让它单起一行 ParagraphNode 占额外高度。
          if (tag == 'br' && pendingInlines.isEmpty) continue;
          // div.d-wrap[data-wrap=voice]:语音消息容器(本 app 约定,
          // `[wrap=voice]` BBCode 产物)。内部 audio 升格语音条;容器内
          // 其余内容照常递归(约定形态只有 audio,防御性保留)。
          if (tag == 'div' &&
              node.classes.contains('d-wrap') &&
              node.attributes['data-wrap'] == 'voice') {
            flushInlines();
            var hasAudio = false;
            for (final a in node.querySelectorAll('audio')) {
              out.add(_parseAudio(a, nextId, voice: true));
              hasAudio = true;
            }
            if (hasAudio) continue;
            // 无 audio 的 wrap=voice:当普通容器落到下方通用 div 逻辑
          }
          // div.lazy-video-container:懒加载视频卡片(youtube / vimeo / tiktok)
          if (tag == 'div' && node.classes.contains('lazy-video-container')) {
            flushInlines();
            out.add(_parseLazyVideo(node, nextId));
            continue;
          }
          // div.policy:Discourse policy 插件区块
          if (tag == 'div' && node.classes.contains('policy')) {
            flushInlines();
            out.add(_parsePolicy(node, nextId, nextImageIndex));
            continue;
          }
          // div.math:块级数学公式(markdown-it-math)。
          // 优先于 d-image-grid 是因为两者都是 div 块级,但 math 只取 text。
          if (tag == 'div' && node.classes.contains('math')) {
            flushInlines();
            final latex = node.text.trim();
            if (latex.isNotEmpty) {
              out.add(MathBlockNode(id: nextId(), latex: latex));
            }
            continue;
          }
          // div.poll:Discourse 投票块(数据在 API,这里只提 name + 标题)
          if (tag == 'div' && node.classes.contains('poll')) {
            flushInlines();
            out.add(_parsePoll(node, nextId));
            continue;
          }
          // div.chat-transcript:Discourse chat 转帖(纯 DOM,主项目接 legacy)
          if (tag == 'div' && node.classes.contains('chat-transcript')) {
            flushInlines();
            out.add(_parseChatTranscript(node, nextId));
            continue;
          }
          // div.d-image-grid:多图网格(Discourse 原生 image-grid 组件)。
          // 优先于 lightbox-wrapper 检测,因为 grid 内可能含多个 lightbox-wrapper。
          if (tag == 'div' && node.classes.contains('d-image-grid')) {
            flushInlines();
            out.add(_parseImageGrid(node, nextId, nextImageIndex));
            continue;
          }
          // div.video-placeholder-container(linux.do 上传视频主形态:cooked 里
          // 只有空 div + data-video-src/data-thumbnail-src,<video> 是 web 端
          // 运行时注入)。也兼容 web 端已加 video-container class 的形态。
          // div.onebox.video-onebox(旧式/直链视频):内含真 <video>。
          if (tag == 'div' &&
              (node.classes.contains('video-placeholder-container') ||
                  node.classes.contains('video-container') ||
                  node.classes.contains('video-onebox'))) {
            flushInlines();
            out.add(_parseVideo(node, nextId));
            continue;
          }
          // div.lightbox-wrapper 当 inline 流:cooked 里多张图常常是连续
          // 的 `<div class="lightbox-wrapper">` 块,如果各产独立 ParagraphNode,
          // 段间累加 1em+1em margin,两张图之间空一大截。改让它进 pending,
          // 跟相邻 image 合并到同一 ParagraphNode。
          if (tag == 'div' && node.classes.contains('lightbox-wrapper')) {
            final imgRun = _imageRunFromLightboxWrapper(node, nextImageIndex);
            if (imgRun != null) pendingInlines.add(imgRun);
            continue;
          }
          // <center> / 带 align 的 <div>(仅含 inline 内容)→ 对齐段落容器。
          // 含块级子 / skip 元素 / 无对齐 → 不在此处理,走下面原有逻辑。
          final alignedInlines = _alignedInlineParagraph(tag, node);
          if (alignedInlines != null) {
            flushInlines();
            final inlines = <InlineNode>[];
            for (final child in node.nodes) {
              _collectInlineFromAnyNode(child, inlines, nextImageIndex);
            }
            _normalizeWhitespace(inlines);
            if (inlines.isNotEmpty) {
              out.add(ParagraphNode(
                id: nextId(),
                inlines: List.unmodifiable(inlines),
                textAlign: alignedInlines,
              ));
            }
            continue;
          }
          if (_isInlineTag(tag)) {
            // inline 元素 → 累积到 pending
            _collectInline(node, pendingInlines, nextImageIndex);
          } else {
            flushInlines();
            // 块级
            switch (tag) {
              case 'p':
                // 空段落 → BlankLineNode 候选。是否真渲染成空行由
                // _applyBlankLinePolicy 按容器决定(对齐 CSS margin 折叠:
                // 只有 padding 盒子容器首尾的空 p 会显示)。
                if (_isBlankParagraph(node)) {
                  out.add(BlankLineNode(id: nextId()));
                  break;
                }
                // <p> 内可能包裹「块级媒体」(video / audio / video-placeholder
                // 容器):Discourse cooked 把上传视频/音频塞进 <p>,但语义是块级。
                // 扫直属子节点:遇媒体块先 flush 已累积 inline 成 ParagraphNode,
                // 再单独产 VideoNode/AudioNode(保留文档顺序);其余按 inline 收。
                final pInlines = <InlineNode>[];
                void flushPInlines() {
                  _normalizeWhitespace(pInlines);
                  if (pInlines.isNotEmpty) {
                    out.add(ParagraphNode(
                      id: nextId(),
                      inlines: List.unmodifiable(pInlines),
                      textAlign: _readTextAlign(node),
                    ));
                  }
                  pInlines.clear();
                }

                for (final child in node.nodes) {
                  if (child is dom.Element) {
                    final media = _mediaBlockFromElement(child, nextId);
                    if (media != null) {
                      flushPInlines();
                      out.add(media);
                      continue;
                    }
                  }
                  _collectInlineFromAnyNode(child, pInlines, nextImageIndex);
                }
                flushPInlines();
              case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
                final level = int.parse(tag.substring(1));
                final inlines = <InlineNode>[];
                for (final child in node.nodes) {
                  _collectInlineFromAnyNode(child, inlines, nextImageIndex);
                }
                _normalizeWhitespace(inlines);
                out.add(HeadingNode(
                  id: nextId(),
                  level: level,
                  inlines: List.unmodifiable(inlines),
                  textAlign: _readTextAlign(node),
                ));
              case 'ol' when node.classes.contains('footnotes-list'):
                // 客户端 cook 的脚注区形态:裸 <ol class="footnotes-list">
                // (服务端才包 <section class="footnotes">)。必须先于
                // 通用 ul/ol case,否则走普通列表 → 序列化吐
                // `1. 正文 [↩︎](#fnref1)` 垃圾。
                out.add(FootnotesSectionNode(
                  id: nextId(),
                  entries: _parseFootnoteEntries(node, nextImageIndex),
                ));
              case 'ul' || 'ol':
                out.add(_parseList(
                  node,
                  ordered: tag == 'ol',
                  depth: depth,
                  nextId: nextId,
                  nextImageIndex: nextImageIndex,
                ));
              case 'dl':
                // 定义列表 <dl>:dt(术语)+ 其后紧邻的若干 dd(释义)。
                // legacy 走 fwfh 默认(浏览器 dl 样式);新引擎产 DefinitionListNode
                // 保留结构(dt 常规字重 + dd 左缩进 40)。
                final dl = _parseDefinitionList(node, nextId, nextImageIndex);
                if (dl != null) out.add(dl);
              case 'blockquote':
                // 装饰下放:带 data-fxd-callout 属性 = 大 callout 拆出的中/尾片
                // (无 [!type] 文本),按属性识别 callout;否则先试文本识别 callout,
                // 再退普通 BlockquoteNode。
                final calloutAttr = node.attributes['data-fxd-callout'];
                if (calloutAttr != null) {
                  out.add(_calloutFromAttrs(
                      node, calloutAttr, nextId, nextImageIndex));
                } else {
                  final callout =
                      _tryParseCallout(node, nextId, nextImageIndex);
                  if (callout != null) {
                    out.add(callout);
                  } else {
                    out.add(BlockquoteNode(
                      id: nextId(),
                      children: _parseBlocks(
                          node.nodes, nextId, nextImageIndex,
                          keepBlankEdges: true),
                      chunkPos: _blockquoteChunkPos(node),
                    ));
                  }
                }
              case 'hr':
                // hr.footnotes-sep:legacy 隐藏(脚注体系的分隔)。
                // 其他 hr 才走 HorizontalRuleNode。
                if (node.classes.contains('footnotes-sep')) break;
                out.add(HorizontalRuleNode(id: nextId()));
              case 'pre':
                // `<pre><code class="lang-xxx">...</code></pre>` —— 代码块。
                // 取 textContent(已解码 HTML 实体),从 class 提语言。
                final codeEl = node.children.firstWhere(
                  (c) => c.localName?.toLowerCase() == 'code',
                  orElse: () => node,
                );
                final rawText = codeEl.text;
                // 去掉末尾换行避免多空行(legacy 同样处理)
                final code = rawText.endsWith('\n')
                    ? rawText.substring(0, rawText.length - 1)
                    : rawText;
                String? language;
                final className = codeEl.className;
                if (className.isNotEmpty) {
                  final m = RegExp(r'lang-(\w+)').firstMatch(className);
                  if (m != null) language = m.group(1)?.toLowerCase();
                }
                out.add(CodeBlockNode(
                  id: nextId(),
                  code: code,
                  language: language,
                ));
              case 'aside':
                // class="quote" → QuoteCardNode
                // class="onebox" / 含 *-onebox 子类 → OneboxNode
                if (node.classes.contains('quote')) {
                  out.add(_parseQuoteCard(node, nextId, nextImageIndex));
                } else if (node.classes.contains('onebox') ||
                    node.classes.any((c) => c.endsWith('-onebox'))) {
                  out.add(_parseOnebox(node, nextId));
                } else {
                  // 其他 aside:走 fallback textContent
                  final text = node.text;
                  if (text.trim().isNotEmpty) {
                    out.add(ParagraphNode(
                      id: nextId(),
                      inlines: List.unmodifiable([_proseText(text)]),
                    ));
                  }
                }
              case 'div' when node.classes.contains('spoiler') ||
                    node.classes.contains('spoiled'):
                // 块级 spoiler:div.spoiler / div.spoiled
                out.add(SpoilerBlockNode(
                  id: nextId(),
                  children: _parseBlocks(node.nodes, nextId, nextImageIndex,
                      keepBlankEdges: true),
                ));
              case 'details':
                // 折叠块:<details><summary>标题</summary>内容</details>
                out.add(_parseDetails(node, nextId, nextImageIndex));
              case 'section' when node.classes.contains('footnotes'):
                // 脚注列表区:解析成 FootnotesSectionNode(带 entries),
                // node_factory 渲染底部「分隔线 + 编号列表」。
                // 上标 popover 仍由 FootnoteRefRun.contentHtml 提供(并存)。
                out.add(FootnotesSectionNode(
                  id: nextId(),
                  entries: _parseFootnoteEntries(node, nextImageIndex),
                ));
              case 'iframe':
                // 嵌入 iframe — 子包不渲染 webview,只产 IframeNode 让主项目
                // 通过 iframeBuilder 注入真实 widget,fallback 显示占位卡。
                out.add(_parseIframe(node, nextId));
              case 'video':
                // 裸 <video>(直链/onebox 内已被上面 div 截获,这里是顶层裸 video)
                out.add(_parseVideo(node, nextId));
              case 'audio':
                // <audio preload controls><source ...>:上传音频终态
                out.add(_parseAudio(node, nextId));
              case 'div' when node.classes.contains('md-table'):
                // Discourse markdown 表格包裹层 <div class="md-table"><table>。
                // 透明拆壳:递归内部节点(里头就是 <table>),命中 table case。
                out.addAll(_parseBlocks(node.nodes, nextId, nextImageIndex));
              case 'table':
                // 表格 — thead/tbody/tr/th/td 递归;cell 内 children
                // 走 _parseBlocks(保留 inline 样式 + 嵌套块级)
                final t = _parseTable(node, nextId, nextImageIndex);
                if (t != null) out.add(t);
              case 'figure':
                // <figure> 图片容器(常带 <figcaption> 说明)。legacy 走 fwfh
                // 默认渲染(figure=block + 内部 img + figcaption block);新引擎
                // 块级 switch 此前无 case → default 文本兜底丢图。拆壳:取内部
                // 全部内容图 → image-only ParagraphNode;figcaption 文本 → 居中
                // 小字 ParagraphNode。无内部 img(figure 包 table/video 等)时
                // 退回 _parseBlocks 递归内部块级,避免丢内容。
                out.addAll(_parseFigure(node, nextId, nextImageIndex));
              case 'picture':
                // 块级 <picture>(响应式图片)。fwfh 不认 picture,只渲染内部
                // <img> fallback、忽略 <source srcset>。拆壳同此:优先内部 img,
                // 无 img 时取首个 <source srcset> 的首个 URL → 单图 ParagraphNode。
                out.addAll(_parsePictureBlock(node, nextId, nextImageIndex));
              case 'svg':
                // 内容型 svg(有 viewBox 或显式宽高,且非 d-icon)→ SvgNode;
                // UI 图标 svg(d-icon / 无 viewBox 无尺寸)→ 跳过(对齐 legacy
                // _buildInlineSvg:无 viewBox 且无宽高视为图标 SizedBox.shrink)。
                if (_isContentSvg(node)) {
                  out.add(SvgNode(
                    id: nextId(),
                    svgSource: node.outerHtml,
                    width: double.tryParse(node.attributes['width'] ?? ''),
                    height: double.tryParse(node.attributes['height'] ?? ''),
                  ));
                }
                // 非内容 svg(图标):不产节点(等价 legacy shrink)。
              // 注意:div.lightbox-wrapper 在块级 switch 之前已被截获
              // 走 pendingInlines 流(不会到达这里),目的是让连续多张
              // lightbox 图合并到同一 ParagraphNode,消除 1em+1em 段间距。
              case 'div' || 'center':
                // 纯展示 skip 元素(div.meta / div.lb-spacer):UI 占位,
                // 既不拆壳也不兜底,直接丢弃(与 default 的 skip 行为一致)。
                if (_isSkipElement(tag, node)) break;
                // 通用容器 div / <center>(含块级子;仅 inline 内容的形态已被
                // 上方 _alignedInlineParagraph 截获):透明拆壳递归内部节点。
                // 语义 div(math/poll/grid/video/spoiler…)已被前面特判接住,
                // 走到这里的 div 只是布局容器,若掉 default 纯文本兜底会丢图/
                // 丢结构 —— 典型:手写 <div align="center"> 包上传图,cooked 的
                // <p><div class="lightbox-wrapper"> 非法嵌套被 html 解析修正
                // (p 提前闭合)后,wrapper 成 div 的直接块级子。
                // 容器带对齐时下放到无自身对齐的段落/标题(近似 text-align 继承)。
                final containerAlign =
                    tag == 'center' ? TextAlign.center : _readTextAlign(node);
                final unwrapped = _parseBlocks(
                    node.nodes, nextId, nextImageIndex,
                    depth: depth);
                out.addAll(containerAlign == null
                    ? unwrapped
                    : unwrapped.map((b) => _inheritAlign(b, containerAlign)));
              default:
                // 未识别块级:fallback 为 paragraph,只取纯 textContent,
                // 不识别内部 inline tag(因为我们还不知道该块的语义 ——
                // 比如 <pre><code> 在 code_block 节点实现前,fallback 应该
                // 是平铺源码,而不是把 <code> 当成 inline code 渲染灰底)。
                //
                // 但跳过 skip 元素(svg / d-icon / meta / lb-spacer),
                // 它们没有有意义的文字内容(只是 UI 占位)。
                if (_isSkipElement(tag, node)) break;
                _recordUnhandled(tag); // 诊断:未覆盖块级 → 纯文本兜底
                final text = node.text;
                if (text.trim().isNotEmpty) {
                  out.add(ParagraphNode(
                    id: nextId(),
                    inlines: List.unmodifiable([_proseText(text)]),
                  ));
                }
            }
          }
        case dom.Text():
          final text = _collapseWs(node.text);
          if (text.trim().isNotEmpty) {
            pendingInlines.add(_proseText(text));
          }
        // 其他节点类型(注释 / 文档类型等)忽略
      }
    }

    flushInlines();
    return List.unmodifiable(_applyBlankLinePolicy(out, keepBlankEdges));
  }

  /// 按容器决定空段落(BlankLineNode)是否真渲染成空行 —— 近似浏览器/Discourse
  /// 的 CSS margin 折叠规则:
  ///
  /// - **保留**:位于「有 padding 的盒子容器(blockquote/callout/details/
  ///   quote_card/spoiler/policy)」首/尾的空段落。padding 阻止其 margin 折叠
  ///   出去 → 框内显示一行留白(诗句上下居中即靠此)。
  /// - **丢弃**:其余全部 —— 顶层首尾(margin 折叠出 body)、容器中间(被相邻
  ///   块 margin 吸收)、列表项/表格 cell。避免给图片残留 / 段尾平白加空行。
  ///
  /// [keepEdge] 由调用点传:盒子容器 true,顶层/列表项/cell false。
  List<BlockNode> _applyBlankLinePolicy(List<BlockNode> out, bool keepEdge) {
    if (!out.any((n) => n is BlankLineNode)) return out;
    final firstReal = out.indexWhere((n) => n is! BlankLineNode);
    if (firstReal == -1) {
      // 容器内全是空行 → 无意义,全丢。
      return out.where((n) => n is! BlankLineNode).toList();
    }
    final lastReal = out.lastIndexWhere((n) => n is! BlankLineNode);
    final result = <BlockNode>[];
    for (var i = 0; i < out.length; i++) {
      final n = out[i];
      if (n is! BlankLineNode) {
        result.add(n);
        continue;
      }
      final isEdge = i < firstReal || i > lastReal;
      if (isEdge && keepEdge) result.add(n);
      // 其余空段落(中间 / 非盒子边缘)→ margin 折叠 → 丢弃。
    }
    return result;
  }

  /// 把 `<ul>` / `<ol>` 解析成 ListNode,递归处理嵌套子 list。
  ListNode _parseList(
    dom.Element listEl, {
    required bool ordered,
    required int depth,
    required String Function() nextId,
    required int Function() nextImageIndex,
  }) {
    final items = <ListItem>[];
    for (final child in listEl.nodes) {
      if (child is! dom.Element) continue;
      if (child.localName?.toLowerCase() != 'li') continue;

      // li 含真块级子(h4/p/pre/blockquote/table 等;ul/ol 仍走 inline 快路径的
      // 嵌套 subList)→ 块级形态:整个 li 走 _parseBlocks,渲染为 marker + Column。
      final hasBlock = child.children.any((c) {
        final t = c.localName?.toLowerCase() ?? '';
        return t != 'br' && t != 'ul' && t != 'ol' && !_isInlineTag(t);
      });
      if (hasBlock) {
        items.add(ListItem(
          // 块级 li 内的嵌套列表比本列表深一层 → depth+1,marker 形状/缩进才对。
          blocks: _parseBlocks(child.nodes, nextId, nextImageIndex,
              depth: depth + 1),
        ));
        continue;
      }

      final inlines = <InlineNode>[];
      final subLists = <ListNode>[];
      for (final liChild in child.nodes) {
        if (liChild is dom.Element) {
          final liTag = liChild.localName?.toLowerCase() ?? '';
          if (liTag == 'ul' || liTag == 'ol') {
            subLists.add(_parseList(
              liChild,
              ordered: liTag == 'ol',
              depth: depth + 1,
              nextId: nextId,
              nextImageIndex: nextImageIndex,
            ));
            continue;
          }
        }
        // 跳过 li 直属的纯空白文本(HTML 缩进 + 换行,markdown 渲染时
        // 自动加的,在浏览器里不显示;不跳过会让 InlineSpanText 多渲染
        // 一行 `\n`,跟下面的子 list 之间空一截)
        if (liChild is dom.Text && liChild.text.trim().isEmpty) continue;
        _collectInlineFromAnyNode(liChild, inlines, nextImageIndex);
      }
      // 把首尾 TextRun 的 leading/trailing whitespace(`\n`、缩进 space)
      // 去掉,但保留中间 inline 之间的空格(`"x <em>y</em> z"` 里两端空格
      // 是有意义的)。
      _normalizeWhitespace(inlines);
      items.add(ListItem(
        inlines: List.unmodifiable(inlines),
        children: subLists.isEmpty ? null : List.unmodifiable(subLists),
      ));
    }
    return ListNode(
      id: nextId(),
      ordered: ordered,
      depth: depth,
      start: ordered
          ? (int.tryParse(listEl.attributes['start']?.trim() ?? '') ?? 1)
          : 1,
      items: List.unmodifiable(items),
    );
  }

  /// 读元素的块级对齐:`align` 属性 / `style="text-align:..."`(对齐 fwfh)。
  /// 无 → null。
  TextAlign? _readTextAlign(dom.Element el) {
    var v = el.attributes['align']?.trim().toLowerCase();
    if (v == null || v.isEmpty) {
      final style = (el.attributes['style'] ?? '').toLowerCase();
      v = RegExp(r'text-align\s*:\s*([a-z\-]+)').firstMatch(style)?.group(1);
    }
    switch (v) {
      case 'center':
        return TextAlign.center;
      case 'right':
      case 'end':
        return TextAlign.right;
      case 'left':
      case 'start':
        return TextAlign.left;
      case 'justify':
        return TextAlign.justify;
      default:
        return null;
    }
  }

  /// `<center>` / 带对齐的 `<div>` 且**只含 inline 内容**(无块级子、非 skip)→
  /// 返回该对齐(作对齐段落渲染);否则 null(走原有逻辑,不在此处理)。
  TextAlign? _alignedInlineParagraph(String tag, dom.Element el) {
    if (tag != 'center' && tag != 'div') return null;
    if (_isSkipElement(tag, el)) return null;
    final align = tag == 'center' ? TextAlign.center : _readTextAlign(el);
    if (align == null) return null;
    if (_hasBlockChild(el)) return null;
    return align;
  }

  /// 元素是否含块级子(非 inline 标签的子元素)。
  bool _hasBlockChild(dom.Element el) => el.children.any((c) {
        final t = c.localName?.toLowerCase() ?? '';
        return t != 'br' && !_isInlineTag(t);
      });

  /// 容器(div[align] / center)拆壳时把容器对齐下放到子块:仅填充**无自身
  /// 对齐**的段落/标题(子块显式 align/style 优先,近似 CSS text-align 继承)。
  /// 其余块类型(图组/表格/引用…)不受 text-align 影响,原样返回。
  BlockNode _inheritAlign(BlockNode node, TextAlign align) {
    if (node is ParagraphNode && node.textAlign == null) {
      return ParagraphNode(
          id: node.id, inlines: node.inlines, textAlign: align);
    }
    if (node is HeadingNode && node.textAlign == null) {
      return HeadingNode(
        id: node.id,
        level: node.level,
        inlines: node.inlines,
        textAlign: align,
      );
    }
    return node;
  }

  /// `<p>` 是否「无可见内容」(空段落候选,可能渲染为空行 BlankLineNode)。
  ///
  /// 判定:无可见文字(textContent trim 为空)且不含媒体(img/emoji/svg/
  /// 视频/iframe)。命中 `<p></p>` / `<p><em></em></p>` / `<p><br></p>`。
  /// 含 `<img>`(emoji 在 cooked 里也是 <img>)→ 不算空。
  ///
  /// 注意:是否真的产生空行由 [_applyBlankLinePolicy] 按容器决定 —— 对齐
  /// 浏览器/Discourse 的 CSS margin 折叠:空 `<p>` 的 margin 只在「有 padding
  /// 的盒子容器(blockquote/callout/details…)首尾」显示;顶层/段落间会被相邻
  /// margin 折叠掉。
  bool _isBlankParagraph(dom.Element el) {
    if (el.text.trim().isNotEmpty) return false;
    return el.querySelector('img, picture, svg, video, audio, iframe') == null;
  }

  /// 读 blockquote 的 `data-fxd-pos` 属性 → 装饰下放分块位置(默认 whole)。
  /// 主项目拆大引用块时给每片 re-wrap 的 `<blockquote data-fxd-pos="...">` 标位置。
  BlockquoteChunkPos _blockquoteChunkPos(dom.Element node) {
    switch (node.attributes['data-fxd-pos']) {
      case 'first':
        return BlockquoteChunkPos.first;
      case 'mid':
        return BlockquoteChunkPos.mid;
      case 'last':
        return BlockquoteChunkPos.last;
      default:
        return BlockquoteChunkPos.whole;
    }
  }

  /// 把 `<dl>` 解析成 DefinitionListNode。
  ///
  /// 规则(对齐浏览器/fwfh 默认 dl 语义):
  /// - 顺序扫描 dl 直接子元素;遇 <dt> 开一个新条目(term = dt 行内);
  /// - 遇 <dd> 把其块级内容(_parseBlocks)追加到「当前条目」的 definitions;
  /// - 「孤儿 dd」(出现在任何 dt 之前):自动开一个 term 为空的条目承载;
  /// - 忽略 dl 下的裸文本/空白与非 dt/dd 元素(浏览器同样不渲染 dl 直属裸文本)。
  ///
  /// 全空(无任何 dt/dd 有效内容)返回 null,调用方不产节点。
  DefinitionListNode? _parseDefinitionList(
    dom.Element dlEl,
    String Function() nextId,
    int Function() nextImageIndex,
  ) {
    final items = <DefinitionItem>[];
    List<InlineNode>? pendingTerm; // 当前条目的 dt 行内(null = 尚未遇 dt)
    var pendingDefs = <List<BlockNode>>[]; // 当前条目累计的 dd 块级组

    void flushItem() {
      // 当前条目有 term 或有 dd 才产出(避免空条目)。
      if (pendingTerm == null && pendingDefs.isEmpty) return;
      items.add(DefinitionItem(
        term: List.unmodifiable(pendingTerm ?? const <InlineNode>[]),
        definitions: List.unmodifiable(
          pendingDefs.map((d) => List<BlockNode>.unmodifiable(d)).toList(),
        ),
      ));
      pendingTerm = null;
      pendingDefs = <List<BlockNode>>[];
    }

    for (final child in dlEl.nodes) {
      if (child is! dom.Element) continue;
      final t = child.localName?.toLowerCase();
      if (t == 'dt') {
        // 新 term 开新条目:先 flush 上一条。
        flushItem();
        final inlines = <InlineNode>[];
        for (final c in child.nodes) {
          _collectInlineFromAnyNode(c, inlines, nextImageIndex);
        }
        _normalizeWhitespace(inlines);
        pendingTerm = inlines;
      } else if (t == 'dd') {
        // dd 块级内容(支持 dd 内嵌段落/列表/引用)。
        final blocks = _parseBlocks(child.nodes, nextId, nextImageIndex);
        pendingDefs.add(blocks);
      }
      // 其他元素(罕见)忽略,对齐浏览器 dl 直属非 dt/dd 不渲染。
    }
    flushItem();

    if (items.isEmpty) return null;
    return DefinitionListNode(
      id: nextId(),
      items: List.unmodifiable(items),
    );
  }

  /// 解析 `<aside class="quote">` 为 QuoteCardNode。
  ///
  /// 提取 data-username / data-topic / data-post + img.avatar + title 标题 +
  /// blockquote 内容(递归 _parseBlocks)。
  ///
  /// 兼容两种标题形态:
  /// - 新版:`.quote-title__text-content > a`
  /// - 老版:`.title > a`(legacy quote_card_builder 同样回退)
  QuoteCardNode _parseQuoteCard(
    dom.Element asideEl,
    String Function() nextId,
    int Function() nextImageIndex,
  ) {
    final username = asideEl.attributes['data-username']?.trim() ?? '';
    final topicId = int.tryParse(asideEl.attributes['data-topic'] ?? '');
    final postNumber = int.tryParse(asideEl.attributes['data-post'] ?? '');
    // raw 往返字段:full:true / 显示名(序列化写回 [quote=…] 参数用)
    final full = asideEl.attributes['data-full']?.trim() == 'true';
    final displayName = asideEl.attributes['data-display-name']?.trim();

    final avatarEl = asideEl.querySelector('img.avatar');
    final avatarUrl = avatarEl?.attributes['src']?.trim();

    // 标题:新版 .quote-title__text-content > a;老版 .title > a
    final titleAEl = asideEl.querySelector(
          '.quote-title__text-content a',
        ) ??
        asideEl.querySelector('.title a');
    String? titleText;
    String? titleHref;
    final titleInlines = <InlineNode>[];
    if (titleAEl != null) {
      titleText = titleAEl.text.trim();
      titleHref = titleAEl.attributes['href']?.trim();
      if (titleText.isEmpty) titleText = null;
      if ((titleHref ?? '').isEmpty) titleHref = null;
      // 标题行内(保留 emoji / 链接,对齐 legacy htmlBuilder(titleHtml));
      // titleAEl 是 <a> → _collectInline 产 LinkRun(children 含文字 + emoji)。
      _collectInline(titleAEl, titleInlines, nextImageIndex);
      _normalizeWhitespace(titleInlines);
    }

    // 分类徽章 .badge-category__wrapper:legacy 从标题 remove 出来单独渲染彩色
    // 标签;新引擎结构化提取(名称 + 底色 + 文字色 + 跳分类链接)自绘 chip。
    String? categoryName;
    String? categoryColor;
    String? categoryTextColor;
    String? categoryHref;
    final badgeEl = asideEl.querySelector('.badge-category__wrapper');
    if (badgeEl != null) {
      categoryHref = badgeEl.attributes['href']?.trim();
      categoryName =
          badgeEl.querySelector('.badge-category__name')?.text.trim();
      final badgeSpan = badgeEl.querySelector('.badge-category');
      final style = badgeSpan?.attributes['style'] ?? '';
      categoryColor = _cssProp(style, '--category-badge-color');
      categoryTextColor = _cssProp(style, '--category-badge-text-color');
      if ((categoryName ?? '').isEmpty) categoryName = null;
      if ((categoryHref ?? '').isEmpty) categoryHref = null;
    }

    final blockquoteEl = asideEl.querySelector('blockquote');
    final children = blockquoteEl == null
        ? const <BlockNode>[]
        : _parseBlocks(blockquoteEl.nodes, nextId, nextImageIndex,
            keepBlankEdges: true);

    return QuoteCardNode(
      id: nextId(),
      username: username,
      avatarUrl: (avatarUrl ?? '').isEmpty ? null : avatarUrl,
      titleText: titleText,
      titleInlines: List.unmodifiable(titleInlines),
      titleHref: titleHref,
      topicId: topicId,
      postNumber: postNumber,
      categoryName: categoryName,
      categoryColor: categoryColor,
      categoryTextColor: categoryTextColor,
      categoryHref: categoryHref,
      children: children,
      full: full,
      displayName:
          (displayName == null || displayName.isEmpty) ? null : displayName,
      oneboxUrl: asideEl.attributes['data-fluxdo-onebox-url'],
    );
  }

  /// 解析 `<aside class="onebox">` / `<aside class="*-onebox">` 为 OneboxNode。
  ///
  /// 子包只提结构化关键字段 + 保留 rawHtml(给主项目 OneboxBuilder 兜底)。
  /// kind 识别参考 legacy `onebox_type.dart::detectOneboxType` 的 6 大类
  /// (不细化到 githubRepo / githubIssue 等 24 种子类型 — 那是 builder 内
  /// 基于 URL 二次判断的事)。
  OneboxNode _parseOnebox(dom.Element asideEl, String Function() nextId) {
    final classes = <String>{};
    classes.addAll(asideEl.classes);
    // 嵌套 article / 子 aside 的 class 也算(legacy 同套路)
    final articleEl = asideEl.querySelector('article');
    if (articleEl != null) classes.addAll(articleEl.classes);

    OneboxKind kind;
    if (classes.contains('user-onebox')) {
      kind = OneboxKind.user;
    } else if (classes.contains('github-onebox') ||
        classes.contains('onebox-github') ||
        classes.any((c) => c.startsWith('github'))) {
      kind = OneboxKind.github;
    } else if (classes.contains('twitterstatus') ||
        classes.contains('twitter-tweet') ||
        classes.contains('reddit') ||
        classes.contains('reddit-onebox') ||
        classes.contains('instagram-onebox') ||
        classes.contains('instagram') ||
        classes.contains('threads-onebox') ||
        classes.contains('tiktok-onebox')) {
      kind = OneboxKind.social;
    } else if (classes.contains('youtube-onebox') ||
        classes.contains('lazyYT') ||
        classes.contains('vimeo-onebox') ||
        classes.contains('loom-onebox')) {
      kind = OneboxKind.video;
    } else if (classes.contains('stackexchange-onebox') ||
        classes.contains('stackoverflow-onebox') ||
        classes.contains('hackernews-onebox') ||
        classes.contains('ycombinator') ||
        classes.contains('pastebin-onebox') ||
        classes.contains('googledocs-onebox') ||
        classes.contains('pdf-onebox') ||
        classes.contains('amazon-onebox')) {
      kind = OneboxKind.tech;
    } else {
      kind = OneboxKind.defaultKind;
    }

    // url:data-onebox-src 优先 → header a / h3 a / h4 a
    String url = asideEl.attributes['data-onebox-src']?.trim() ?? '';
    if (url.isEmpty) {
      final headerA = asideEl.querySelector('header a');
      url = headerA?.attributes['href']?.trim() ?? '';
    }
    if (url.isEmpty) {
      final h3a = asideEl.querySelector('h3 a');
      url = h3a?.attributes['href']?.trim() ?? '';
    }
    if (url.isEmpty) {
      final h4a = asideEl.querySelector('h4 a');
      url = h4a?.attributes['href']?.trim() ?? '';
    }

    // title:h3 a / h4 a / h3 / h4 text
    final titleA = asideEl.querySelector('h4 a') ??
        asideEl.querySelector('h3 a');
    final title = titleA?.text.trim() ??
        asideEl.querySelector('h3')?.text.trim() ??
        asideEl.querySelector('h4')?.text.trim() ??
        '';

    // description:第一个 p
    final description = asideEl.querySelector('p')?.text.trim() ?? '';

    // favicon:img.site-icon / img.favicon
    final iconEl = asideEl.querySelector('img.site-icon') ??
        asideEl.querySelector('img.favicon');
    final faviconUrl = iconEl?.attributes['src']?.trim() ?? '';

    // thumbnail:.thumbnail / .aspect-image img
    final thumbEl = asideEl.querySelector('img.thumbnail') ??
        asideEl.querySelector('.aspect-image img') ??
        asideEl.querySelector('.thumbnail');
    final thumbnailUrl = thumbEl?.attributes['src']?.trim() ?? '';

    // sourceName:.source a / .source
    final sourceEl = asideEl.querySelector('.source a') ??
        asideEl.querySelector('.source');
    final sourceName = sourceEl?.text.trim() ?? '';

    return OneboxNode(
      id: nextId(),
      kind: kind,
      url: url.isEmpty ? null : url,
      title: title.isEmpty ? null : title,
      description: description.isEmpty ? null : description,
      faviconUrl: faviconUrl.isEmpty ? null : faviconUrl,
      thumbnailUrl: thumbnailUrl.isEmpty ? null : thumbnailUrl,
      sourceName: sourceName.isEmpty ? null : sourceName,
      rawHtml: asideEl.outerHtml,
    );
  }

  /// 解析 `<details>` 为 DetailsNode。
  ///
  /// - summary:`<summary>` 子节点的 textContent(trim)
  /// - children:除 summary 外所有节点递归 _parseBlocks
  /// - initiallyOpen:`<details open>` 属性
  DetailsNode _parseDetails(
    dom.Element detailsEl,
    String Function() nextId,
    int Function() nextImageIndex,
  ) {
    final summaryEl = detailsEl.querySelector('summary');
    final summary = summaryEl?.text.trim() ?? '';

    // 收集非 summary 子节点用于递归解析
    final bodyNodes = <dom.Node>[];
    for (final c in detailsEl.nodes) {
      if (c is dom.Element && c.localName?.toLowerCase() == 'summary') {
        continue;
      }
      bodyNodes.add(c);
    }
    final children = _parseBlocks(bodyNodes, nextId, nextImageIndex,
        keepBlankEdges: true);

    return DetailsNode(
      id: nextId(),
      summary: summary,
      children: children,
      initiallyOpen: detailsEl.attributes.containsKey('open'),
    );
  }

  /// 尝试把 `<blockquote>` 识别为 Obsidian Callout(`[!type](+|-)?`)。
  ///
  /// 命中条件:第一个直接子 `<p>` 的 textContent 首行(`<br>` 分割前)
  /// 匹配 `^\[!([^\]]+)\]([+-])?\s*(.*)`。匹配失败返回 null,由外层
  /// 回落到普通 BlockquoteNode。
  ///
  /// 命中后的处理:
  /// - kind:`CalloutKind.fromType(type.toLowerCase())`
  /// - foldable:`+ → true`,`- → false`,否则 null
  /// - title:首行剥掉 `[!type](+|-)?\s*` 后的剩余文本(空时 null)
  /// - children:
  ///   - 首段 `<br>` 后的剩余 inline → 一个新 ParagraphNode(若非空)
  ///   - 首段之后的所有兄弟节点 → 递归 _parseBlocks
  CalloutNode? _tryParseCallout(
    dom.Element blockquoteEl,
    String Function() nextId,
    int Function() nextImageIndex,
  ) {
    // 第一个直接子 <p>(不递归嵌套 blockquote 内的 p)
    dom.Element? firstP;
    var firstPIndex = -1;
    for (var i = 0; i < blockquoteEl.children.length; i++) {
      final c = blockquoteEl.children[i];
      if (c.localName?.toLowerCase() == 'p') {
        firstP = c;
        firstPIndex = i;
        break;
      }
    }
    if (firstP == null) return null;

    // 取首段 textContent,只看第一行(<br> 之前)做 callout 标记识别
    final firstParaHtml = firstP.innerHtml;
    final brMatch = RegExp(r'<br\s*/?>', caseSensitive: false)
        .firstMatch(firstParaHtml);
    final beforeBr = brMatch == null
        ? firstParaHtml
        : firstParaHtml.substring(0, brMatch.start);
    final firstLineText = beforeBr.replaceAll(RegExp(r'<[^>]*>'), '').trim();

    final match =
        RegExp(r'^\[!([^\]]+)\]([+-])?\s*(.*)').firstMatch(firstLineText);
    if (match == null) return null;

    final typeRaw = match.group(1)!.trim().toLowerCase();
    final foldMarker = match.group(2);
    final titleRaw = match.group(3)?.trim();
    final bool? foldable = switch (foldMarker) {
      '+' => true,
      '-' => false,
      _ => null,
    };

    // 收集首段 <br> 之后的剩余 inline(若有)→ 单独一个 ParagraphNode
    final childNodes = <dom.Node>[];
    if (brMatch != null) {
      // trim 掉 <br> 后的 leading/trailing 空白(典型 cooked 里 `<br>\n正文`,
      // 不 trim 的话 fragment.parse 产生的 TextNode 带头部 \n,渲染时占一
      // 整行空高度 — 视觉上 callout 标题和正文之间多一行空白)
      final afterBrHtml = firstParaHtml.substring(brMatch.end).trim();
      if (afterBrHtml.isNotEmpty) {
        // 用 fragment parse 让它产生跟原 DOM 一致的节点
        final frag = html_parser.parseFragment(afterBrHtml);
        childNodes.addAll(frag.nodes);
      }
    }

    // 首段之后的所有兄弟节点都加进 children DOM 流
    // (用 nodes 而非 children,以保留文本节点和其他 inline)
    final allNodes = blockquoteEl.nodes;
    // 找到首段在 nodes 中的位置(children 用的是 element-only 索引,
    // 这里需要 nodes 索引)
    var firstPNodeIndex = -1;
    var skipped = 0;
    for (var i = 0; i < allNodes.length; i++) {
      final n = allNodes[i];
      if (n is dom.Element && n.localName?.toLowerCase() == 'p') {
        if (skipped == firstPIndex) {
          firstPNodeIndex = i;
          break;
        }
        skipped++;
      }
    }
    if (firstPNodeIndex >= 0) {
      for (var i = firstPNodeIndex + 1; i < allNodes.length; i++) {
        childNodes.add(allNodes[i]);
      }
    }

    // 标题 inline 版(保留 `<a>` 链接/格式):解析首行 HTML(beforeBr)→ 剥掉
    // `[!type]±` 前缀。渲染时用它让标题里的链接可点;为空回退纯文本 title。
    // 在 children 解析前算,保证标题里的图片(罕见)indexInPost 在正文之前。
    List<InlineNode>? titleInlines;
    {
      final frag = html_parser.parseFragment(beforeBr);
      final inls = <InlineNode>[];
      for (final n in frag.nodes) {
        _collectInlineFromAnyNode(n, inls, nextImageIndex);
      }
      _stripCalloutMarkerPrefix(inls);
      _normalizeWhitespace(inls);
      if (inls.isNotEmpty) titleInlines = List.unmodifiable(inls);
    }

    // 把首段剩余 inline + 后续节点 一起递归解析成 BlockNode
    // (剩余 inline 会被 _parseBlocks 收成 pendingInlines → ParagraphNode)
    final children = childNodes.isEmpty
        ? const <BlockNode>[]
        : _parseBlocks(childNodes, nextId, nextImageIndex,
            keepBlankEdges: true);

    return CalloutNode(
      id: nextId(),
      kind: CalloutKind.fromType(typeRaw),
      typeRaw: typeRaw,
      title: (titleRaw == null || titleRaw.isEmpty) ? null : titleRaw,
      titleInlines: titleInlines,
      foldable: foldable,
      children: children,
      chunkPos: _blockquoteChunkPos(blockquoteEl),
    );
  }

  /// 剥掉 callout 首行 inline 开头的 `[!type]±` 标记前缀(及其后空白)。
  /// 标记恒为首个 TextRun 起始的字面文本,剥后剩余即标题 inline(保留链接)。
  void _stripCalloutMarkerPrefix(List<InlineNode> inlines) {
    if (inlines.isEmpty) return;
    final first = inlines.first;
    if (first is! TextRun) return;
    final m = RegExp(r'^\s*\[![^\]]+\][+-]?\s*').firstMatch(first.text);
    if (m == null) return;
    final rest = first.text.substring(m.end);
    if (rest.isEmpty) {
      inlines.removeAt(0);
    } else {
      inlines[0] = TextRun(rest);
    }
  }

  /// 装饰下放:大 callout 拆出的中/尾片(`<blockquote data-fxd-callout="kind"
  /// data-fxd-pos="mid|last">body</blockquote>`,无 `[!type]` 文本)→ CalloutNode。
  /// 只在不可折叠 callout 上拆,故 foldable 恒 null;标题只首片有(走文本识别)。
  CalloutNode _calloutFromAttrs(
    dom.Element node,
    String kindRaw,
    String Function() nextId,
    int Function() nextImageIndex,
  ) {
    final typeRaw = kindRaw.trim().toLowerCase();
    final title = node.attributes['data-fxd-callout-title'];
    return CalloutNode(
      id: nextId(),
      kind: CalloutKind.fromType(typeRaw),
      typeRaw: typeRaw,
      title: (title == null || title.isEmpty) ? null : title,
      foldable: null,
      children: _parseBlocks(node.nodes, nextId, nextImageIndex,
          keepBlankEdges: true),
      chunkPos: _blockquoteChunkPos(node),
    );
  }

  /// HTML 空白折叠(近似浏览器 `white-space: normal`):把连续空白
  /// (空格 / tab / 换行 / 缩进)折叠为单个空格。Discourse cooked 里
  /// `<br>\n正文` 的字面 `\n` 若不折叠会被 RichText 当成第二个换行 → 多出空行。
  static final _wsRun = RegExp(r'[ \t\r\n\f\v]+');
  String _collapseWs(String s) => s.replaceAll(_wsRun, ' ');

  /// inline 列表的 HTML 空白规整(在 _collapseWs 折叠基础上):去掉序列
  /// 首尾、以及紧邻 `<br>`(LineBreakRun)两侧的空白 —— 浏览器里换行处的
  /// 空白不渲染。删除因此变空的 TextRun。原地修改。
  void _normalizeWhitespace(List<InlineNode> inlines) {
    for (var i = 0; i < inlines.length; i++) {
      final n = inlines[i];
      if (n is! TextRun) continue;
      final prevBreak = i == 0 || inlines[i - 1] is LineBreakRun;
      final nextBreak =
          i == inlines.length - 1 || inlines[i + 1] is LineBreakRun;
      var t = n.text;
      if (prevBreak) t = t.trimLeft();
      if (nextBreak) t = t.trimRight();
      if (t.isEmpty) {
        inlines.removeAt(i);
        i--;
      } else if (t != n.text) {
        inlines[i] = TextRun(t);
      }
    }
    // 末尾 `<br>` 对齐浏览器排版:块/列表项的**最后一个** `<br>` 被边界吸收
    // (不占行),其余各占一行。故只裁掉**一个**末尾 LineBreakRun:
    //   `x<br><br>` → 余 1 个 → 一行空隙(网页就是一行);
    //   `x<br>`     → 余 0 个 → 无空隙。
    // 中间的 `<br>`(含 `A<br><br>B` 的故意空行)与开头的 `<br>` 全部保留。
    if (inlines.isNotEmpty && inlines.last is LineBreakRun) {
      inlines.removeLast();
    }
  }

  /// 从 `<div class="lightbox-wrapper">` 元素提取 ImageRun。
  ///
  /// 结构:
  ///   <div class="lightbox-wrapper">
  ///     <a class="lightbox" href="原图URL">
  ///       <img src="缩略图URL" alt="..." width=... height=...>
  ///       <div class="meta">...filename + 尺寸 + svg icons</div>
  ///     </a>
  ///   </div>
  ///
  /// 找不到内嵌 img 时返回 null(调用方应跳过)。
  ImageRun? _imageRunFromLightboxWrapper(
    dom.Element wrapperEl,
    int Function() nextImageIndex,
  ) {
    final aEl = wrapperEl.querySelector('a.lightbox');
    if (aEl != null) {
      return _imageRunFromLightboxAnchor(aEl, nextImageIndex);
    }
    final img = wrapperEl.querySelector('a.lightbox > img') ??
        wrapperEl.querySelector('img');
    if (img == null) return null;
    return _imageRunFromImg(img, nextImageIndex);
  }

  ImageRun? _imageRunFromLightboxAnchor(
    dom.Element aEl,
    int Function() nextImageIndex,
  ) {
    final img = aEl.querySelector('img');
    if (img == null) return null;
    final run = _imageRunFromImg(img, nextImageIndex);
    if (run == null) return null;
    final lightboxUrl = aEl.attributes['href']?.trim();
    final info = _parseInformations(aEl);
    if ((lightboxUrl == null || lightboxUrl.isEmpty) && info == null) {
      return run;
    }
    return run.withLightboxMeta(
      lightboxUrl:
          (lightboxUrl == null || lightboxUrl.isEmpty) ? null : lightboxUrl,
      naturalWidth: info?.width,
      naturalHeight: info?.height,
      fileSizeText: info?.sizeText,
    );
  }

  /// 解析 lightbox `.meta > .informations` 的原图信息(Discourse 契约:
  /// `"1686×128 15.7 KB"` = 原图 W×H + 人类可读大小;`add_lightbox!` 用
  /// `×`(U+00D7)连接)。img 的 width/height 是**显示尺寸**,原图尺寸
  /// 只有这里有。解析失败静默 null(容错)。
  static ({double? width, double? height, String? sizeText})?
      _parseInformations(dom.Element aEl) {
    final text = aEl.querySelector('.informations')?.text.trim() ?? '';
    if (text.isEmpty) return null;
    final match =
        RegExp(r'^(\d+)\s*[×x]\s*(\d+)\s*(.*)$').firstMatch(text);
    if (match == null) return null;
    final w = double.tryParse(match.group(1)!);
    final h = double.tryParse(match.group(2)!);
    final size = match.group(3)?.trim();
    if (w == null && h == null) return null;
    return (
      width: w,
      height: h,
      sizeText: (size == null || size.isEmpty) ? null : size,
    );
  }

  /// 解析 `<figure>` 容器为 BlockNode 序列(对齐 legacy fwfh `figure`+`figcaption`
  /// 默认渲染,但 figcaption 升级为居中小字)。
  ///
  /// 形态(Discourse / 通用):
  /// ```html
  /// <figure>
  ///   <img src="a.png" alt="x" width="600" height="400">   <!-- 或 lightbox / picture -->
  ///   <figcaption>图片说明</figcaption>
  /// </figure>
  /// ```
  ///
  /// 处理:
  /// - 先用 [_collectFigureImages] 扫内部全部内容图(lightbox-wrapper / a.lightbox /
  ///   picture / 裸 img,跳 emoji & skip 图),按出现序分配 indexInPost。
  /// - figcaption 文本(`<figcaption>` 的 textContent,trim)→ 居中小字 ParagraphNode。
  /// - 有图:产 image-only ParagraphNode(多图用 LineBreakRun 分隔,与连续
  ///   lightbox 合并行为一致)+(若有)caption 段。
  /// - 无图(figure 包 table/video/纯 caption 等):退回 _parseBlocks 递归内部
  ///   非 figcaption 子节点,避免丢内容;末尾再补 caption 段。
  List<BlockNode> _parseFigure(
    dom.Element figureEl,
    String Function() nextId,
    int Function() nextImageIndex,
  ) {
    final out = <BlockNode>[];
    final images = _collectFigureImages(figureEl, nextImageIndex);

    // figcaption 文本(取第一个 figcaption 的 textContent)。
    final capEl = figureEl.querySelector('figcaption');
    final caption = capEl?.text.trim() ?? '';

    if (images.isNotEmpty) {
      // image-only 段落:多图之间插 LineBreakRun(对齐连续 lightbox 合并形态,
      // 避免每图各产段落叠加段间距)。
      final inlines = <InlineNode>[];
      for (var i = 0; i < images.length; i++) {
        if (i > 0) inlines.add(const LineBreakRun());
        inlines.add(images[i]);
      }
      out.add(ParagraphNode(id: nextId(), inlines: List.unmodifiable(inlines)));
    } else {
      // 无内部图:递归内部块级(排除 figcaption,它单独处理),避免丢 table/
      // video/list 等被 figure 包裹的内容。
      final bodyNodes = <dom.Node>[];
      for (final c in figureEl.nodes) {
        if (c is dom.Element &&
            c.localName?.toLowerCase() == 'figcaption') {
          continue;
        }
        bodyNodes.add(c);
      }
      out.addAll(_parseBlocks(bodyNodes, nextId, nextImageIndex));
    }

    final cap = _captionParagraph(caption, nextId);
    if (cap != null) out.add(cap);
    return out;
  }

  /// 解析块级 `<picture>` 为 BlockNode 序列。优先内部 `<img>`(浏览器/fwfh 的
  /// fallback 渲染对象);无 img 时取首个 `<source srcset>` 的首个 URL。
  /// 产单图 image-only ParagraphNode;都取不到则空(容错跳过)。
  List<BlockNode> _parsePictureBlock(
    dom.Element pictureEl,
    String Function() nextId,
    int Function() nextImageIndex,
  ) {
    // 优先 a.lightbox(罕见但保留 lightboxUrl),再裸 img,再 source srcset。
    final aEl = pictureEl.querySelector('a.lightbox');
    ImageRun? run;
    if (aEl != null) {
      run = _imageRunFromLightboxAnchor(aEl, nextImageIndex);
    }
    if (run == null) {
      final img = pictureEl.querySelector('img');
      if (img != null && !_isSkipImage(img)) {
        run = _imageRunFromImg(img, nextImageIndex);
      }
    }
    if (run == null) {
      final candidates = _pictureSourceSrcset(pictureEl);
      if (candidates.isNotEmpty) {
        run = ImageRun(
          src: candidates.first.url,
          indexInPost: nextImageIndex(),
          srcset: candidates,
        );
      }
    }
    if (run == null) return const [];
    return [
      ParagraphNode(id: nextId(), inlines: List.unmodifiable([run])),
    ];
  }

  /// 扫 figure 内部全部内容图,按出现序产 ImageRun(分配 indexInPost)。
  /// 优先级与去重对齐 [_parseImageGrid]:lightbox-wrapper → a.lightbox → 裸 img
  /// → picture(内部 img / source srcset)。跳 emoji / avatar / thumbnail 等
  /// skip 图,跳 figcaption 子树内的图(说明里的图不算主内容图)。
  List<ImageRun> _collectFigureImages(
    dom.Element figureEl,
    int Function() nextImageIndex,
  ) {
    final images = <ImageRun>[];
    final consumed = <dom.Element>{};

    bool inFigcaption(dom.Element img) {
      dom.Element? p = img.parent;
      while (p != null) {
        if (p.localName?.toLowerCase() == 'figcaption') return true;
        p = p.parent;
      }
      return false;
    }

    // 1) lightbox-wrapper(拿 lightboxUrl)
    for (final wrapper in figureEl.querySelectorAll('div.lightbox-wrapper')) {
      final innerImg = wrapper.querySelector('a.lightbox > img') ??
          wrapper.querySelector('img');
      if (innerImg == null || inFigcaption(innerImg)) continue;
      if (_isSkipImage(innerImg)) continue;
      final run = _imageRunFromLightboxWrapper(wrapper, nextImageIndex);
      if (run != null) {
        images.add(run);
        consumed.add(innerImg);
      }
    }
    // 2) 裸 a.lightbox(无 wrapper 包裹)
    for (final anchor in figureEl.querySelectorAll('a.lightbox')) {
      final innerImg = anchor.querySelector('img');
      if (innerImg == null || consumed.contains(innerImg)) continue;
      if (inFigcaption(innerImg) || _isSkipImage(innerImg)) continue;
      final run = _imageRunFromLightboxAnchor(anchor, nextImageIndex);
      if (run != null) {
        images.add(run);
        consumed.add(innerImg);
      }
    }
    // 3) 剩余裸 img(含 <picture> 内的 fallback <img>)
    for (final img in figureEl.querySelectorAll('img')) {
      if (consumed.contains(img)) continue;
      if (inFigcaption(img) || _isSkipImage(img)) continue;
      final run = _imageRunFromImg(img, nextImageIndex);
      if (run != null) {
        images.add(run);
        consumed.add(img);
      }
    }
    // 4) 只有 <picture><source> 无任何 img 的兜底:取 source srcset 全档
    if (images.isEmpty) {
      for (final pic in figureEl.querySelectorAll('picture')) {
        final candidates = _pictureSourceSrcset(pic);
        if (candidates.isNotEmpty) {
          images.add(ImageRun(
            src: candidates.first.url,
            indexInPost: nextImageIndex(),
            srcset: candidates,
          ));
        }
      }
    }
    return images;
  }

  /// 从一个普通 `<img>` 元素提 ImageRun(src/alt/width/height + indexInPost)。
  /// src 为空返回 null。emoji / skip 判定由调用方负责。
  ///
  /// **客户端 cook 预览形态**:raw 里的 `upload://` 图被 cook 成
  /// `src="/images/transparent.png" data-orig-src="upload://…"`(真实 URL
  /// 只有服务端知道)。此时把 src 还原为短链(渲染层 DiscourseImage 能解析
  /// upload://),origSrc 存原始短链供 markdown 序列化写回。
  ///
  /// 预览形态还会给可缩放图注入兄弟 `span.button-wrapper` 控件
  /// (image-controls feature):从中提取当前缩放档(`scale-btn active`
  /// 的 data-scale)与 data-image-index,承载「100%/75%/50%」缩放能力
  /// (legacy 引擎渲染控件 HTML 原文,新引擎结构化后由渲染层出原生控件)。
  ImageRun? _imageRunFromImg(
    dom.Element img,
    int Function() nextImageIndex,
  ) {
    var src = img.attributes['src']?.trim() ?? '';
    final origSrc = img.attributes['data-orig-src']?.trim();
    if (origSrc != null && origSrc.startsWith('upload://')) {
      src = origSrc;
    }
    if (src.isEmpty) return null;
    final alt = img.attributes['alt']?.trim() ?? '';
    final w = double.tryParse(img.attributes['width'] ?? '');
    final h = double.tryParse(img.attributes['height'] ?? '');
    final controls = _imageControlsOf(img);
    final dominant = img.attributes['data-dominant-color']?.trim();
    final base62 = img.attributes['data-base62-sha1']?.trim();
    return ImageRun(
      src: src,
      alt: alt,
      width: w,
      height: h,
      indexInPost: nextImageIndex(),
      origSrc: (origSrc == null || origSrc.isEmpty) ? null : origSrc,
      scale: controls?.scale,
      previewImageIndex: controls?.imageIndex,
      origWidth: controls?.origWidth,
      origHeight: controls?.origHeight,
      srcset: _parseSrcset(img.attributes['srcset']),
      dominantColor:
          (dominant == null || dominant.isEmpty) ? null : dominant,
      base62Sha1: (base62 == null || base62.isEmpty) ? null : base62,
    );
  }

  /// 解析 srcset 属性为候选列表(Discourse responsive images 契约:
  /// `"主src, url 1.5x, url 2x"`,首项无描述符 = 1x)。
  ///
  /// 只认 `Nx` 密度描述符;`Nw` 宽度描述符(Discourse 不产)按序退化为
  /// 无档位(scale 递增占位),保证仍能按"越靠后越大"取档。
  static List<ImageSrcsetCandidate> _parseSrcset(String? raw) {
    final srcset = raw?.trim() ?? '';
    if (srcset.isEmpty) return const [];
    final out = <ImageSrcsetCandidate>[];
    for (final part in srcset.split(',')) {
      final candidate = part.trim();
      if (candidate.isEmpty) continue;
      final pieces = candidate.split(RegExp(r'\s+'));
      final url = pieces.first.trim();
      if (url.isEmpty) continue;
      double scale = 1.0;
      if (pieces.length > 1) {
        final desc = pieces[1].toLowerCase();
        if (desc.endsWith('x')) {
          scale = double.tryParse(desc.substring(0, desc.length - 1)) ?? 1.0;
        } else {
          // Nw 等非密度描述符:按出现序给递增档位,保底可用。
          scale = out.isEmpty ? 1.0 : out.last.scale + 0.5;
        }
      }
      out.add(ImageSrcsetCandidate(url: url, scale: scale));
    }
    return List.unmodifiable(out);
  }

  /// 从 img 的 `span.image-wrapper` 祖先里找兄弟 `span.button-wrapper`,
  /// 提取缩放档与图片序号,并反推 raw 声明尺寸。非预览形态(服务端
  /// baked)无 wrapper → null。
  ///
  /// 反推:cook engine 对 `|WxH, N%` 做 parseInt(W * N/100)(截断)后写
  /// width 属性 —— 序列化写回必须用未乘的原始 WxH。ceil 整数反推
  /// W' = ceil(cookW * 100 / N) 满足 floor(W' * N/100) == cookW(N ≤ 100),
  /// 往返 cook 逐像素一致。
  ({double? scale, int? imageIndex, double? origWidth, double? origHeight})?
      _imageControlsOf(dom.Element img) {
    dom.Element? wrapper = img.parent;
    // image-wrapper 直接包 img(官方 ruleWithImageControls 结构),留 2 层
    // 余量容忍未来插层。
    for (var i = 0; wrapper != null && i < 2; i++) {
      if (wrapper.classes.contains('image-wrapper')) break;
      wrapper = wrapper.parent;
    }
    if (wrapper == null || !wrapper.classes.contains('image-wrapper')) {
      return null;
    }
    final btnWrapper = wrapper.querySelector('span.button-wrapper');
    if (btnWrapper == null) return null;
    final imageIndex = int.tryParse(
        btnWrapper.attributes['data-image-index']?.trim() ?? '');
    final active = btnWrapper.querySelector('span.scale-btn.active');
    final scale = double.tryParse(active?.attributes['data-scale'] ?? '');
    if (imageIndex == null && scale == null) return null;

    double? origW, origH;
    if (scale != null && scale > 0 && scale != 100) {
      final s = scale.round();
      final w = double.tryParse(img.attributes['width'] ?? '');
      final h = double.tryParse(img.attributes['height'] ?? '');
      double rev(double v) => ((v.round() * 100 + s - 1) ~/ s).toDouble();
      if (w != null) origW = rev(w);
      if (h != null) origH = rev(h);
    }
    return (
      scale: scale,
      imageIndex: imageIndex,
      origWidth: origW,
      origHeight: origH,
    );
  }

  /// 取 `<picture>` 内首个 `<source srcset>` 的候选档位列表(结构化,
  /// 保留倍率描述符)。无 source/srcset 返回空列表。
  List<ImageSrcsetCandidate> _pictureSourceSrcset(dom.Element pictureEl) {
    final source = pictureEl.querySelector('source');
    return _parseSrcset(source?.attributes['srcset']);
  }

  /// figcaption 文本 → 居中小字 ParagraphNode(对齐浏览器图注视觉:0.833x +
  /// 居中)。复用 StyledRun.small(fwfh smaller 同值)+ ParagraphNode.textAlign,
  /// 不引入新节点/新样式机制。文本为空返回 null(不产空段)。
  ParagraphNode? _captionParagraph(String caption, String Function() nextId) {
    if (caption.isEmpty) return null;
    return ParagraphNode(
      id: nextId(),
      inlines: List.unmodifiable([
        StyledRun(
          kind: InlineStyleKind.small,
          children: List.unmodifiable([_proseText(caption)]),
        ),
      ]),
      textAlign: TextAlign.center,
    );
  }

  /// 解析 `<div class="d-image-grid">` 为 ImageGridNode。
  ///
  /// 形态:
  /// ```html
  /// <div class="d-image-grid" data-columns="3" data-mode="grid">
  ///   <div class="lightbox-wrapper">
  ///     <a class="lightbox" href="原图"><img src="缩略" width=.. height=..></a>
  ///   </div>
  ///   <img src="..." />  <!-- 也可能直接是裸 img -->
  /// </div>
  /// ```
  ///
  /// 处理:
  /// - `data-columns`:int 解析,默认 2(legacy 默认值)
  /// - `data-mode="carousel"` 或 class 含 `d-image-grid--carousel` →
  ///   [ImageGridMode.carousel],否则 [ImageGridMode.grid]
  /// - 收集所有后代 `<img>`,但跳过 emoji / avatar / thumbnail / yt 缩略图
  ///   (legacy `extractGridImages` 同套路 — 这些是 UI 占位非内容图)
  /// - lightbox-wrapper 包裹的 img → 复用 `_imageRunFromLightboxWrapper`
  ///   提取 lightboxUrl;裸 img → 直接 ImageRun(无 lightboxUrl)
  ImageGridNode _parseImageGrid(
    dom.Element gridEl,
    String Function() nextId,
    int Function() nextImageIndex,
  ) {
    final cols = int.tryParse(gridEl.attributes['data-columns'] ?? '') ?? 2;
    final mode = (gridEl.attributes['data-mode'] == 'carousel' ||
            gridEl.classes.contains('d-image-grid--carousel'))
        ? ImageGridMode.carousel
        : ImageGridMode.grid;

    final images = <ImageRun>[];
    // 已被 lightbox-wrapper 收过的 img,后续直接 img 遍历时要跳过去重
    final consumedImgs = <dom.Element>{};

    // 先扫 lightbox-wrapper(优先它们,这样能拿到 lightboxUrl)
    for (final wrapper in gridEl.querySelectorAll('div.lightbox-wrapper')) {
      final innerImg = wrapper.querySelector('a.lightbox > img') ??
          wrapper.querySelector('img');
      if (innerImg == null) continue;
      if (_isSkipImage(innerImg)) continue;
      final run = _imageRunFromLightboxWrapper(wrapper, nextImageIndex);
      if (run != null) {
        images.add(run);
        consumedImgs.add(innerImg);
      }
    }

    // 再扫不带 lightbox-wrapper 的 a.lightbox(Discourse Web 也以 a.lightbox
    // 为 PhotoSwipe 数据源)。
    for (final anchor in gridEl.querySelectorAll('a.lightbox')) {
      final innerImg = anchor.querySelector('img');
      if (innerImg == null || consumedImgs.contains(innerImg)) continue;
      if (_isSkipImage(innerImg)) continue;
      final run = _imageRunFromLightboxAnchor(anchor, nextImageIndex);
      if (run != null) {
        images.add(run);
        consumedImgs.add(innerImg);
      }
    }

    // 再扫剩余裸 img(不在已消费集合内)
    for (final img in gridEl.querySelectorAll('img')) {
      if (consumedImgs.contains(img)) continue;
      if (_isSkipImage(img)) continue;
      final run = _imageRunFromImg(img, nextImageIndex);
      if (run != null) images.add(run);
    }

    return ImageGridNode(
      id: nextId(),
      images: List.unmodifiable(images),
      columns: cols,
      mode: mode,
    );
  }

  /// d-image-grid 内应跳过的图(emoji / 头像 / 缩略 / yt 占位等 UI 元素)。
  /// 对齐 legacy `extractGridImages` 的 skip list。
  bool _isSkipImage(dom.Element img) {
    final classes = img.classes;
    return classes.contains('emoji') ||
        classes.contains('avatar') ||
        classes.contains('thumbnail') ||
        classes.contains('ytp-thumbnail-image');
  }

  /// 解析 `<div class="lazy-video-container">` 为 LazyVideoNode。
  ///
  /// 形态(legacy lazy_video_builder.dart 同结构):
  /// ```html
  /// <div class="lazy-video-container"
  ///      data-provider-name="youtube"
  ///      data-video-id="abc"
  ///      data-video-title="标题"
  ///      data-video-start-time="1m30s">
  ///   <a class="title-link" href="https://youtube.com/watch?v=abc">
  ///     <img src="缩略图.jpg" />
  ///   </a>
  /// </div>
  /// ```
  ///
  /// 处理:
  /// - data-provider-name → LazyVideoProvider.fromName
  /// - data-video-id / data-video-title / data-video-start-time 直接提
  /// - 缩略图:取 div 内 `<img>` 的 src
  /// - 链接:取 `a.title-link` 的 href,fallback 到第一个 `<a>` 的 href
  LazyVideoNode _parseLazyVideo(
    dom.Element divEl,
    String Function() nextId,
  ) {
    final attrs = divEl.attributes;
    final provider = LazyVideoProvider.fromName(
      attrs['data-provider-name']?.trim() ?? '',
    );
    final videoId = attrs['data-video-id']?.trim() ?? '';
    final title = attrs['data-video-title']?.trim() ?? '';
    final startTime = attrs['data-video-start-time']?.trim() ?? '';

    final img = divEl.querySelector('img');
    final thumbnailUrl = img?.attributes['src']?.trim() ?? '';

    final titleA = divEl.querySelector('a.title-link') ??
        divEl.querySelector('a');
    final url = titleA?.attributes['href']?.trim() ?? '';

    return LazyVideoNode(
      id: nextId(),
      provider: provider,
      videoId: videoId,
      title: title,
      thumbnailUrl: thumbnailUrl,
      startTime: startTime,
      url: url,
    );
  }

  /// 解析 `<div class="policy">` 为 PolicyNode(对齐 legacy
  /// `policy_builder.dart::buildPolicy`)。
  ///
  /// HTML 形态:
  /// ```html
  /// <div class="policy" data-version="1" data-groups="staff"
  ///      data-accept="..." data-revoke="..." ...>
  ///   <div class="policy-body">  <!-- 可选包裹 -->
  ///     <p>正文</p>
  ///   </div>
  /// </div>
  /// ```
  ///
  /// 处理:
  /// - 如果有 `<div class="policy-body">` 单层包裹,递归它的子节点;
  ///   否则直接递归 div.policy 自身的子节点
  /// - 提全部 data-* 属性(version/groups/accept/revoke/renewalDays 等)
  /// - data-private = "true" → isPrivate
  PolicyNode _parsePolicy(
    dom.Element divEl,
    String Function() nextId,
    int Function() nextImageIndex,
  ) {
    // 找 .policy-body 子 div(单层包裹,legacy 同处理)
    dom.Element bodyEl = divEl;
    for (final c in divEl.children) {
      if (c.localName?.toLowerCase() == 'div' &&
          c.classes.contains('policy-body')) {
        bodyEl = c;
        break;
      }
    }
    final children = _parseBlocks(bodyEl.nodes, nextId, nextImageIndex,
        keepBlankEdges: true);

    final attrs = divEl.attributes;
    String? optStr(String key) {
      final v = attrs[key]?.trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    return PolicyNode(
      id: nextId(),
      children: children,
      version: optStr('data-version'),
      groups: optStr('data-groups'),
      acceptLabel: optStr('data-accept'),
      revokeLabel: optStr('data-revoke'),
      renewalDays: optStr('data-renewal-days'),
      renewalStart: optStr('data-renewal-start'),
      reminder: optStr('data-reminder'),
      isPrivate: attrs['data-private'] == 'true',
      rawHtml: divEl.outerHtml,
    );
  }

  /// 解析 `<div class="poll">` 为 PollNode。
  ///
  /// poll 数据全在 API(post.polls),cooked 只给 data-poll-name + 标题。
  /// 标题优先级对齐 legacy `_extractPollTitle`:
  ///   data-poll-question > data-poll-title > .poll-title 文本 >
  ///   .poll-question 文本。
  PollNode _parsePoll(dom.Element divEl, String Function() nextId) {
    final attrs = divEl.attributes;
    final pollName = attrs['data-poll-name']?.trim().isNotEmpty == true
        ? attrs['data-poll-name']!.trim()
        : 'poll';

    String? title;
    final attrTitle =
        attrs['data-poll-question']?.trim() ?? attrs['data-poll-title']?.trim();
    if (attrTitle != null && attrTitle.isNotEmpty) {
      title = attrTitle;
    } else {
      final titleEl = divEl.querySelector('.poll-title') ??
          divEl.querySelector('.poll-question');
      final t = titleEl?.text.trim();
      if (t != null && t.isNotEmpty) title = t;
    }

    return PollNode(
      id: nextId(),
      pollName: pollName,
      title: title,
      rawHtml: divEl.outerHtml,
    );
  }

  /// 解析 `<div class="chat-transcript">` 为 ChatTranscriptNode。
  ///
  /// 纯 DOM(不依赖 post API)。提结构化字段给 fallback 用 + rawHtml 给
  /// 主项目喂 legacy buildChatTranscript。对齐 legacy chat_transcript_builder。
  ChatTranscriptNode _parseChatTranscript(
    dom.Element divEl,
    String Function() nextId,
  ) {
    final attrs = divEl.attributes;
    String? optStr(String key) {
      final v = attrs[key]?.trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    final avatarEl = divEl.querySelector('img.avatar');
    final messagesEl = divEl.querySelector('.chat-transcript-messages');

    return ChatTranscriptNode(
      id: nextId(),
      username: optStr('data-username') ?? '',
      avatarUrl: avatarEl?.attributes['src']?.trim(),
      datetime: optStr('data-datetime'),
      channelName: optStr('data-channel-name'),
      isChained: divEl.classes.contains('chat-transcript-chained'),
      messagesHtml: messagesEl?.innerHtml ?? '',
      rawHtml: divEl.outerHtml,
    );
  }

  /// 解析 `<iframe>` 为 IframeNode(对齐 legacy
  /// `IframeAttributes.fromElement`)。
  ///
  /// - src 优先 `src`,fallback `data-src`(lazy 形态)
  /// - width/height tryParse
  /// - sandbox / allow 按空白 / 分号拆分
  /// - allowfullscreen:属性存在 / 值为 true / "" / allow 含 fullscreen
  /// - loading="lazy" → lazyLoad=true
  IframeNode _parseIframe(dom.Element el, String Function() nextId) {
    final attrs = el.attributes;

    final src = (attrs['src']?.trim().isNotEmpty == true
            ? attrs['src']
            : attrs['data-src']) ??
        '';
    final width = double.tryParse(attrs['width'] ?? '');
    final height = double.tryParse(attrs['height'] ?? '');
    final title = attrs['title']?.trim();

    final sandboxRaw = attrs['sandbox'];
    final sandboxFlags = sandboxRaw == null
        ? <String>{}
        : sandboxRaw
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toSet();

    final allowRaw = attrs['allow'];
    final allowFlags = allowRaw == null
        ? <String>{}
        : allowRaw
            .split(';')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet();

    final fullscreenAttr = attrs['allowfullscreen'];
    final allowFullscreen = attrs.containsKey('allowfullscreen') &&
            (fullscreenAttr == null ||
                fullscreenAttr == 'true' ||
                fullscreenAttr == '' ||
                fullscreenAttr == 'allowfullscreen') ||
        allowFlags.any((p) => p.startsWith('fullscreen'));

    final referrerPolicy = attrs['referrerpolicy']?.trim();
    final lazyLoad = attrs['loading']?.trim() == 'lazy';

    return IframeNode(
      id: nextId(),
      src: src,
      width: width,
      height: height,
      title: (title == null || title.isEmpty) ? null : title,
      sandboxFlags: sandboxFlags,
      allowFlags: allowFlags,
      allowFullscreen: allowFullscreen,
      referrerPolicy:
          (referrerPolicy == null || referrerPolicy.isEmpty) ? null : referrerPolicy,
      lazyLoad: lazyLoad,
      cssClasses: el.classes.toSet(),
    );
  }

  /// 解析视频节点 —— 统一处理 video-placeholder-container / video-onebox /
  /// 裸 <video> 三种形态。
  ///
  /// - placeholder div:src=data-video-src,poster=data-thumbnail-src,
  ///   width/height 该 div 上一般没有 → null（主项目 16:9 兜底）。
  /// - 含 <video> 的 div / 裸 video:src=首个 source[src] 或 video[src]，
  ///   poster=video[poster]，width/height=video 属性，mime=source[type]。
  VideoNode _parseVideo(dom.Element el, String Function() nextId) {
    final tag = el.localName?.toLowerCase() ?? '';
    // 形态 1：placeholder 容器(自身或后代不含真 <video>，src 在 data-* 上)
    final isDiv = tag == 'div';
    final videoEl = tag == 'video' ? el : el.querySelector('video');

    String src = '';
    String? poster;
    double? width;
    double? height;
    String? mime;
    bool loop = false;
    String? origSrc;

    if (isDiv && videoEl == null) {
      // 纯 placeholder：只有 data-video-src / data-thumbnail-src
      origSrc = el.attributes['data-orig-src']?.trim();
      src = (el.attributes['data-video-src']?.trim().isNotEmpty == true
              ? el.attributes['data-video-src']
              : origSrc) ??
          '';
      final thumb = el.attributes['data-thumbnail-src']?.trim();
      poster = (thumb == null || thumb.isEmpty) ? null : thumb;
    } else if (videoEl != null) {
      // 含真 <video>：从 source / video 属性取
      final source = videoEl.querySelector('source');
      final srcAttr = source?.attributes['src']?.trim();
      final origAttr = source?.attributes['data-orig-src']?.trim();
      origSrc = origAttr;
      final videoSrcAttr = videoEl.attributes['src']?.trim();
      src = (srcAttr != null && srcAttr.isNotEmpty)
          ? srcAttr
          : (origAttr != null && origAttr.isNotEmpty)
              ? origAttr
              : (videoSrcAttr ?? '');
      mime = source?.attributes['type']?.trim();
      final posterAttr = videoEl.attributes['poster']?.trim();
      poster = (posterAttr == null || posterAttr.isEmpty)
          ? (el.attributes['data-thumbnail-src']?.trim())
          : posterAttr;
      if (poster != null && poster.isEmpty) poster = null;
      width = double.tryParse(videoEl.attributes['width'] ?? '');
      height = double.tryParse(videoEl.attributes['height'] ?? '');
      loop = videoEl.attributes.containsKey('loop');
    }

    return VideoNode(
      id: nextId(),
      src: src,
      poster: poster,
      width: width,
      height: height,
      mime: (mime == null || mime.isEmpty) ? null : mime,
      loop: loop,
      origSrc: (origSrc == null || origSrc.isEmpty) ? null : origSrc,
    );
  }

  /// 解析音频节点 —— <audio><source src .. type ..><a>文本</a></audio>。
  /// [voice] = 位于 `[wrap=voice]` 语音消息容器内。
  AudioNode _parseAudio(dom.Element el, String Function() nextId,
      {bool voice = false}) {
    final source = el.querySelector('source');
    final srcAttr = source?.attributes['src']?.trim();
    final origAttr = source?.attributes['data-orig-src']?.trim();
    final audioSrcAttr = el.attributes['src']?.trim();
    final src = (srcAttr != null && srcAttr.isNotEmpty)
        ? srcAttr
        : (origAttr != null && origAttr.isNotEmpty)
            ? origAttr
            : (audioSrcAttr ?? '');
    final mime = source?.attributes['type']?.trim();
    final anchor = el.querySelector('a');
    final title = anchor?.text.trim();
    return AudioNode(
      id: nextId(),
      src: src,
      title: (title == null || title.isEmpty) ? null : title,
      mime: (mime == null || mime.isEmpty) ? null : mime,
      origSrc: (origAttr == null || origAttr.isEmpty) ? null : origAttr,
      voice: voice,
    );
  }

  /// 解析 `<table>` 为 TableNode。
  ///
  /// 形态:
  /// - 含 `<thead><tr>...<th>...</th></tr></thead><tbody><tr>...</tr></tbody>`
  /// - 或只有 `<tbody><tr>...</tr></tbody>`
  /// - 或裸 `<tr>...</tr>`(无 thead/tbody)
  ///
  /// 处理:
  /// - thead 内每个 tr → header 行(cell.isHeader=true)
  /// - tbody / 裸 tr → body 行
  /// - cell.children = _parseBlocks(td/th.nodes)(支持 cell 内 inline +
  ///   嵌套 block;绝大多数 cell 就是单段 ParagraphNode)
  /// - columnCount = max(row.length)
  ///
  /// 返回 null:无任何 tr。
  TableNode? _parseTable(
    dom.Element tableEl,
    String Function() nextId,
    int Function() nextImageIndex,
  ) {
    final rows = <List<TableCellData>>[];
    var hasHeader = false;

    final theads = tableEl.getElementsByTagName('thead');
    if (theads.isNotEmpty) {
      hasHeader = true;
      for (final tr in theads.first.getElementsByTagName('tr')) {
        rows.add(_parseTableRow(tr, nextId, nextImageIndex, forceHeader: true));
      }
    }

    final tbodies = tableEl.getElementsByTagName('tbody');
    if (tbodies.isNotEmpty) {
      for (final tr in tbodies.first.getElementsByTagName('tr')) {
        rows.add(_parseTableRow(tr, nextId, nextImageIndex));
      }
    } else if (theads.isEmpty) {
      // 裸 tr(无 thead/tbody)— 全当 body
      for (final tr in tableEl.getElementsByTagName('tr')) {
        rows.add(_parseTableRow(tr, nextId, nextImageIndex));
      }
    }

    if (rows.isEmpty) return null;

    final columnCount =
        rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    if (columnCount == 0) return null;

    return TableNode(
      id: nextId(),
      rows: List.unmodifiable(rows.map(List<TableCellData>.unmodifiable)),
      columnCount: columnCount,
      hasHeader: hasHeader,
    );
  }

  /// 解析 `<tr>` 内的 `<th>` / `<td>`,每个 cell 走 _parseBlocks 递归。
  ///
  /// [forceHeader]:thead 内的 tr,即使是 `<td>` 也算 header。
  List<TableCellData> _parseTableRow(
    dom.Element tr,
    String Function() nextId,
    int Function() nextImageIndex, {
    bool forceHeader = false,
  }) {
    final cells = <TableCellData>[];
    for (final child in tr.children) {
      final tag = child.localName?.toLowerCase() ?? '';
      if (tag != 'th' && tag != 'td') continue;
      final isHeader = forceHeader || tag == 'th';
      final children = _parseBlocks(child.nodes, nextId, nextImageIndex);
      cells.add(TableCellData(
        children: List.unmodifiable(children),
        isHeader: isHeader,
      ));
    }
    return cells;
  }

  /// 把一个 inline element 转成 InlineNode 加入 out。
  void _collectInline(
    dom.Element el,
    List<InlineNode> out,
    int Function() nextImageIndex,
  ) {
    final tag = el.localName?.toLowerCase() ?? '';
    // 纯展示 / 占位元素:Discourse cooked 注入的 UI 图标 / 元数据容器,
    // 不参与文字流。不跳过会进 textContent 当文字渲染(出现 use href
    // 字面值 / filename 重复 / fa-... 占位文字 等)
    if (_isSkipElement(tag, el)) return;
    final children = <InlineNode>[];
    for (final child in el.nodes) {
      _collectInlineFromAnyNode(child, children, nextImageIndex);
    }
    switch (tag) {
      case 'em' || 'i':
        out.add(EmRun(children: List.unmodifiable(children)));
      case 'strong' || 'b':
        out.add(StrongRun(children: List.unmodifiable(children)));
      case 'br':
        out.add(const LineBreakRun());
      case 'u':
        // `<u>` 下划线(对齐 fwfh)。
        out.add(StyledRun(
            kind: InlineStyleKind.underline,
            children: List.unmodifiable(children)));
      case 'ins':
        // 编辑历史 diff 新增:fwfh 默认渲染为下划线(绿底是 Discourse 特化,
        // 简化为下划线)。
        out.add(StyledRun(
            kind: InlineStyleKind.underline,
            children: List.unmodifiable(children)));
      case 'del' || 's' || 'strike':
        // `<del>`/`<s>`/`<strike>` 删除线(对齐 fwfh line-through)。
        out.add(StyledRun(
            kind: InlineStyleKind.lineThrough,
            children: List.unmodifiable(children)));
      case 'small':
        out.add(StyledRun(
            kind: InlineStyleKind.small,
            children: List.unmodifiable(children)));
      case 'big':
        out.add(StyledRun(
            kind: InlineStyleKind.big,
            children: List.unmodifiable(children)));
      case 'mark':
        out.add(StyledRun(
            kind: InlineStyleKind.mark,
            children: List.unmodifiable(children)));
      case 'kbd' || 'samp' || 'tt':
        // fwfh 默认这几个仅等宽字体(非带框按键),对齐之。
        out.add(StyledRun(
            kind: InlineStyleKind.monospace,
            children: List.unmodifiable(children)));
      case 'sup' || 'sub':
        // sup.footnote-ref 单独识别为 FootnoteRefRun(主项目可点弹脚注)。
        // 形态:<sup class="footnote-ref"><a href="#fn:abc">1</a></sup>
        if (tag == 'sup' && el.classes.contains('footnote-ref')) {
          final aEl = el.querySelector('a');
          final href = aEl?.attributes['href']?.trim() ?? '';
          // 取 a 文本作为编号(legacy 形态可能已是 "1" 也可能已是 "[1]")
          var number = (aEl?.text ?? '').trim();
          number = number.replaceAll(RegExp(r'^\[|\]$'), '');
          // fnId 从 href "#fn:abc" 提取
          final fnId = href.startsWith('#') ? href.substring(1) : '';
          if (number.isNotEmpty && fnId.isNotEmpty) {
            out.add(FootnoteRefRun(
              number: number,
              fnId: fnId,
              contentHtml: _footnotes[fnId],
            ));
            return;
          }
          // 解析失败 → 降级走上标样式
        }
        // 普通 <sup>/<sub>(化学式 / 数学等)→ 上/下标(0.833x + 垂直偏移)。
        out.add(StyledRun(
            kind: tag == 'sup'
                ? InlineStyleKind.superscript
                : InlineStyleKind.subscript,
            children: List.unmodifiable(children)));
      case 'a':
        final href = el.attributes['href']?.trim() ?? '';
        // heading 自带锚(`<h2><a class="anchor" href="#h-2"></a>标题</h2>`):
        // 无可见内容的纯导航节点,产 LinkRun 会让 heading 因白名单外节点
        // 整体岛化(编辑已有帖子时所有标题不可编辑),序列化还会吐
        // `[](#h-2)` 垃圾 —— 直接跳过。
        if (el.classes.contains('anchor') && children.isEmpty) {
          return;
        }
        if (href.isEmpty) {
          // 空 href:fallback 为纯样式(展平子节点,不可点)
          out.addAll(children);
        } else if (el.classes.contains('mention')) {
          // class="mention" 优先识别为 MentionRun,跳用户卡;
          // 内部可能含 <img class="emoji mention-status"> 状态 emoji,
          // 把它从展平的 children 里挑出来,纯文本拼回 username
          EmojiRun? statusEmoji;
          final textBuf = StringBuffer();
          for (final c in children) {
            switch (c) {
              case TextRun(:final text):
                textBuf.write(text);
              case EmojiRun():
                statusEmoji ??= c;
              case _:
                // mention 内不期望其他 inline 节点;真出现就丢弃
                break;
            }
          }
          // username 去掉 @ 前缀
          final username = textBuf.toString().trim().replaceFirst(RegExp(r'^@'), '');
          out.add(MentionRun(
            username: username,
            href: href,
            statusEmoji: statusEmoji,
          ));
        } else if (el.classes.contains('attachment')) {
          // class="attachment":Discourse 下载链接(形如
          // `[name.pdf|attachment](upload://…)` cook 出来,锚点文本=文件名,
          // 尾部 `(1.2 MB)` 是锚点外兄弟文本节点,这里不管,自然走 TextRun)。
          // 抓锚点纯文本作下载建议文件名(对齐 legacy element.text.trim())。
          final filenameBuf = StringBuffer();
          for (final c in children) {
            if (c is TextRun) filenameBuf.write(c.text);
          }
          out.add(LinkRun(
            href: href,
            children: List.unmodifiable(children),
            isAttachment: true,
            filename: filenameBuf.toString().trim(),
            origHref: () {
              // 客户端 cook 预览:href="/404" + data-orig-href="upload://…"
              final orig = el.attributes['data-orig-href']?.trim();
              return (orig == null || orig.isEmpty) ? null : orig;
            }(),
          ));
        } else if (el.classes.contains('lightbox')) {
          var hasImage = false;
          for (final child in children) {
            if (child is ImageRun) {
              hasImage = true;
              out.add(child.copyWith(lightboxUrl: href));
            } else {
              out.add(child);
            }
          }
          if (!hasImage) {
            out.removeRange(out.length - children.length, out.length);
            out.add(LinkRun(href: href, children: List.unmodifiable(children)));
          }
        } else if (el.classes.contains('hashtag-cooked')) {
          // hashtag(#分类/#标签):渲染当普通链接,但记 hashtagRef ——
          // markdown 序列化写回 `#{ref}` 保持 hashtag 语义(写 URL 会
          // 让往返后的 raw 退化成死链接)。data-ref 只在带层级/显式类型
          // 后缀时出现,缺失时 data-slug 就是 ref。
          final ref = el.attributes['data-ref']?.trim().isNotEmpty == true
              ? el.attributes['data-ref']!.trim()
              : el.attributes['data-slug']?.trim();
          out.add(LinkRun(
            href: href,
            children: List.unmodifiable(children),
            hashtagRef: (ref == null || ref.isEmpty) ? null : ref,
          ));
        } else {
          out.add(LinkRun(
            href: href,
            children: List.unmodifiable(children),
            // onebox 系链接:inline-onebox(行内,锚文本=动态取回的页面
            // 标题)与 onebox(未展开的裸链)。raw 里都是裸 URL ——
            // 序列化写回裸 href,不能固化 `[标题](url)` 形态。
            isOneboxLink: el.classes.contains('inline-onebox') ||
                el.classes.contains('onebox'),
          ));
        }
      case 'code':
        // 浏览器 `<code>` 的实际语义:展示原始字面值,内部 markup 视觉
        // 被 monospace 盖住意义。这里直接把所有 textContent 拼成一段,
        // 不保留嵌套样式。
        out.add(InlineCodeRun(_textContent(el)));
      case 'img':
        final src = el.attributes['src']?.trim() ?? '';
        // class="emoji" 走 EmojiRun(行内表情图)
        if (el.classes.contains('emoji')) {
          // alt/title 里去掉首尾 `:`(Discourse 形如 `:heart:`)
          final raw = (el.attributes['title'] ?? el.attributes['alt'] ?? '').trim();
          final name = raw.replaceAll(RegExp(r'^:|:$'), '');
          out.add(EmojiRun(
            name: name,
            url: src,
            isOnlyEmoji: el.classes.contains('only-emoji'),
          ));
        } else {
          // 普通内容图片走 ImageRun(主项目注入 builder)。
          // 统一走 _imageRunFromImg:短链还原/缩放控件/srcset/
          // dominant-color/base62 等契约字段一处提取,防两处漂移。
          final run = _imageRunFromImg(el, nextImageIndex);
          if (run != null) out.add(run);
        }
      case 'picture':
        // 行内 <picture>(罕见,出现在 <p> 内):children 已在上方按 el.nodes
        // 递归收过 —— 内部 <img> 已成 ImageRun、<source> 见下方 case 跳过。
        // 直接展平 children 保留 ImageRun(不再 _recordUnhandled('picture'))。
        out.addAll(children);
        return;
      case 'source':
        // <picture>/<video>/<audio> 的 <source>:纯响应式候选,无可见文字。
        // 行内场景跳过(srcset 的取用在块级 _parsePictureBlock 里处理)。
        return;
      case 'span':
        // 客户端 cook 预览的图片编辑控件(image-controls feature,
        // previewing=true 才注入):
        // - span.image-wrapper:包住 img + 控件,透明拆壳(children 里的
        //   ImageRun 已收好,直接展平);
        // - span.button-wrapper:缩放按钮/alt 编辑等纯 UI,整棵丢弃 ——
        //   不丢的话按钮文字("100% 75% 50%"等)混进正文。
        if (el.classes.contains('image-wrapper')) {
          out.addAll(children);
          return;
        }
        if (el.classes.contains('button-wrapper')) {
          return;
        }
        // span.chcklst-box:checklist 复选框(cook 产物,靠 class 表达
        //勾选态,无文本)。序列化写回 `[x]`/`[ ]`,渲染层暂当纯文本
        // 方框(编辑场景保真优先;阅读端 fixture 无此形态)。
        if (el.classes.any((c) => c == 'chcklst-box')) {
          out.add(TextRun(el.classes.contains('checked')
              ? (el.classes.contains('permanent') ? '[X]' : '[x]')
              : '[ ]'));
          return;
        }
        // span.spoiler / span.spoiled → SpoilerRun
        if (el.classes.contains('spoiler') || el.classes.contains('spoiled')) {
          out.add(SpoilerRun(children: List.unmodifiable(children)));
          return;
        }
        // span.hashtag-raw:未验证 hashtag(#nonexist 预览降级形态)——
        // 文本就是 `#slug` 本身,展平 children 即还原
        if (el.classes.contains('hashtag-raw')) {
          out.addAll(children);
          return;
        }
        // BBCode 直译 span(cook 对 [u]/[b]/[i]/[s] 的产物;服务端同形态):
        // bbcode-u/-s 已有 StyledRun 语义;bbcode-b/-i 对齐 strong/em。
        if (el.classes.contains('bbcode-u')) {
          out.add(StyledRun(
              kind: InlineStyleKind.underline,
              children: List.unmodifiable(children)));
          return;
        }
        if (el.classes.contains('bbcode-s')) {
          out.add(StyledRun(
              kind: InlineStyleKind.lineThrough,
              children: List.unmodifiable(children)));
          return;
        }
        if (el.classes.contains('bbcode-b')) {
          out.add(StrongRun(children: List.unmodifiable(children)));
          return;
        }
        if (el.classes.contains('bbcode-i')) {
          out.add(EmRun(children: List.unmodifiable(children)));
          return;
        }
        // span.discourse-local-date → LocalDateRun(主项目接 builder 渲染
        // 真实带时区换算的 chip;子包 fallback 显示服务端预渲染文本)
        if (el.classes.contains('discourse-local-date')) {
          final attrs = el.attributes;
          final date = attrs['data-date']?.trim() ?? '';
          if (date.isEmpty) {
            // 无效:date 必填,降级展平
            out.addAll(children);
            return;
          }
          final time = attrs['data-time']?.trim();
          final timezone = attrs['data-timezone']?.trim();
          final timezonesRaw = attrs['data-timezones']?.trim() ?? '';
          final timezones = timezonesRaw.isEmpty
              ? const <String>[]
              : timezonesRaw
                  .split('|')
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .toList(growable: false);
          out.add(LocalDateRun(
            date: date,
            time: (time == null || time.isEmpty) ? null : time,
            timezone: (timezone == null || timezone.isEmpty) ? null : timezone,
            timezones: timezones,
            format: attrs['data-format']?.trim(),
            displayedTimezone: attrs['data-displayed-timezone']?.trim(),
            countdown: attrs.containsKey('data-countdown'),
            range: attrs['data-range']?.trim(),
            fallbackText: el.text.trim(),
          ));
          return;
        }
        // span.click-count → ClickCountRun(链接旁的点击数小 chip,
        // 纯展示节点;Discourse 用 _injectClickCounts 在 <a> 后注入)
        if (el.classes.contains('click-count')) {
          final raw = el.text.trim();
          // legacy 用 thin space ( ) 包数字,去掉首尾让数字纯净
          final count = raw.replaceAll(RegExp(r'^ | $'), '').trim();
          if (count.isNotEmpty) {
            out.add(ClickCountRun(count));
            return;
          }
        }
        // span.math → MathInlineRun(行内数学公式,markdown-it-math)
        if (el.classes.contains('math')) {
          final latex = el.text.trim();
          if (latex.isNotEmpty) {
            out.add(MathInlineRun(latex));
            return;
          }
        }
        // 其他 span:读行内 CSS color / background-color → ColoredRun(对齐
        // fwfh 默认渲染 style 里的着色;Discourse [color]/[bgcolor] BBCode 产出)。
        // 解析不出颜色但带 style(如仅 font-size)→ 仍记诊断,让对齐守护暴露
        // 这块未实现的内联 CSS。
        final style = el.attributes['style'];
        if (style != null) {
          final fg = _parseCssColor(_cssProp(style, 'color'));
          final bg = _parseCssColor(_cssProp(style, 'background-color'));
          // 字号:Discourse [size=N] BBCode → `font-size:N%`。与着色可同时
          // 出现在一个 span 上,所以先套字号再套颜色(顺序不影响语义)。
          final scale = _parseCssFontScale(_cssProp(style, 'font-size'));
          var inner = children;
          if (scale != null) {
            inner = [SizedRun(scale: scale, children: List.unmodifiable(children))];
          }
          if (fg != null || bg != null) {
            out.add(ColoredRun(
              color: fg,
              background: bg,
              children: List.unmodifiable(inner),
            ));
            return;
          }
          if (scale != null) {
            out.addAll(inner);
            return;
          }
          _recordUnhandled('span[style]');
        }
        out.addAll(children);
      default:
        // 未识别 inline:展平子节点
        _recordUnhandled(tag); // 诊断:未覆盖 inline → 展平兜底
        out.addAll(children);
    }
  }

  /// 把任意 DOM 节点(文本 / inline element / 不该出现的块级)转成 InlineNode。
  void _collectInlineFromAnyNode(
    dom.Node node,
    List<InlineNode> out,
    int Function() nextImageIndex,
  ) {
    switch (node) {
      case dom.Text():
        final text = _collapseWs(node.text);
        if (text.isNotEmpty) {
          out.add(_proseText(text));
        }
      case dom.Element():
        _collectInline(node, out, nextImageIndex);
      // 其他节点忽略
    }
  }

  /// 散文文本 → TextRun,顺手做 ASCII 箭头连字(`->` → `→`)。
  ///
  /// **只用于散文**:行内代码走 InlineCodeRun、代码块走 CodeBlockNode,
  /// 都不经过这里,所以代码里的 `->` 不会被改坏。
  static TextRun _proseText(String text) => TextRun(applyArrowLigatures(text));

  /// 已支持的 inline 标签集合。
  static const _inlineTags = {
    'em', 'i', 'strong', 'b', 'br', 'a', 'code', 'img', 'span',
    'ins', 'del', 's', 'strike', 'sup', 'sub', // diff / 上下标
    'u', 'small', 'big', 'mark', 'kbd', 'samp', 'tt', // 行内样式(对齐 fwfh)
  };

  bool _isInlineTag(String tag) => _inlineTags.contains(tag);

  /// 判断元素是否为「块级媒体」(video / audio / video-placeholder 容器),
  /// 这些在 cooked 里常被包进 `<p>`(Discourse 段落包裹),但语义是块级,
  /// 需从段落里提出来单独成 VideoNode / AudioNode。
  ///
  /// 命中返回对应 BlockNode,否则返回 null(交回 inline 流处理)。
  BlockNode? _mediaBlockFromElement(dom.Element el, String Function() nextId) {
    final tag = el.localName?.toLowerCase() ?? '';
    if (tag == 'video') return _parseVideo(el, nextId);
    if (tag == 'audio') return _parseAudio(el, nextId);
    if (tag == 'div' &&
        (el.classes.contains('video-placeholder-container') ||
            el.classes.contains('video-container') ||
            el.classes.contains('video-onebox'))) {
      return _parseVideo(el, nextId);
    }
    return null;
  }

  /// 从行内 `style` 串里取某属性值(如 `color` / `background-color`)。
  /// 按 `;` 拆声明、`:` 拆键值,键大小写不敏感、精确匹配(避免 `color` 误中
  /// `background-color`)。取不到返回 null。
  static String? _cssProp(String style, String prop) {
    for (final decl in style.split(';')) {
      final i = decl.indexOf(':');
      if (i < 0) continue;
      if (decl.substring(0, i).trim().toLowerCase() == prop) {
        final v = decl.substring(i + 1).trim();
        return v.isEmpty ? null : v;
      }
    }
    return null;
  }

  /// 解析 `font-size` → 相对父字号的倍数。
  ///
  /// 只认**百分比**:Discourse 的 `[size=N]` BBCode 产出就是 `font-size:N%`
  /// (实测 `[size=0]`→`0%`、`[size=150]`→`150%`)。绝对单位(px/em/rem…)
  /// 语义不是"相对父级倍数",这里不认,交回 `_recordUnhandled` 暴露。
  /// `0%` 合法(= 视觉隐藏,与网页端一致);负数/解析失败 → null。
  static double? _parseCssFontScale(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (!s.endsWith('%')) return null;
    final n = double.tryParse(s.substring(0, s.length - 1).trim());
    if (n == null || n < 0) return null;
    return n / 100.0;
  }

  /// 解析 CSS 颜色字符串 → [Color](对齐 fwfh:hex 3/4/6/8 位 + rgb()/rgba()
  /// + 完整命名色 + transparent)。`inherit`/`currentcolor` 等无具体值 → null
  /// (不覆盖父级色)。解析失败 → null。
  static Color? _parseCssColor(String? raw) {
    if (raw == null) return null;
    final s = raw.trim().toLowerCase();
    if (s.isEmpty ||
        s == 'inherit' ||
        s == 'currentcolor' ||
        s == 'initial' ||
        s == 'unset' ||
        s == 'none') {
      return null;
    }
    if (s == 'transparent') return const Color(0x00000000);

    // #hex(3 / 4 / 6 / 8 位)。CSS 顺序 RGB[A] → Flutter ARGB,需把 A 提前。
    if (s.startsWith('#')) {
      final h = s.substring(1);
      String? hex8; // AARRGGBB
      switch (h.length) {
        case 3: // #rgb
          hex8 = 'ff${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}';
        case 4: // #rgba
          hex8 = '${h[3]}${h[3]}${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}';
        case 6: // #rrggbb
          hex8 = 'ff$h';
        case 8: // #rrggbbaa
          hex8 = '${h.substring(6, 8)}${h.substring(0, 6)}';
      }
      if (hex8 == null) return null;
      final v = int.tryParse(hex8, radix: 16);
      return v == null ? null : Color(v);
    }

    // rgb() / rgba()。分量支持整数或百分比;alpha 为 0–1 浮点。
    if (s.startsWith('rgb')) {
      final open = s.indexOf('(');
      final close = s.indexOf(')');
      if (open < 0 || close < 0 || close < open) return null;
      final parts =
          s.substring(open + 1, close).split(RegExp('[,/ ]+')).where((p) => p.isNotEmpty).toList();
      if (parts.length < 3) return null;
      int chan(String p) {
        if (p.endsWith('%')) {
          final pct = double.tryParse(p.substring(0, p.length - 1));
          return pct == null ? 0 : (pct * 255 / 100).round().clamp(0, 255);
        }
        return (double.tryParse(p) ?? 0).round().clamp(0, 255);
      }
      final r = chan(parts[0]);
      final g = chan(parts[1]);
      final b = chan(parts[2]);
      var a = 255;
      if (parts.length >= 4) {
        final av = parts[3];
        a = av.endsWith('%')
            ? ((double.tryParse(av.substring(0, av.length - 1)) ?? 100) * 255 / 100)
                .round()
                .clamp(0, 255)
            : ((double.tryParse(av) ?? 1) * 255).round().clamp(0, 255);
      }
      return Color.fromARGB(a, r, g, b);
    }

    // 命名色。
    final named = _cssNamedColors[s];
    return named == null ? null : Color(named);
  }

  /// CSS Level 4 标准命名色(ARGB,均不透明)。对齐 fwfh 的完整命名色表。
  static const Map<String, int> _cssNamedColors = {
    'black': 0xff000000, 'silver': 0xffc0c0c0, 'gray': 0xff808080,
    'grey': 0xff808080, 'white': 0xffffffff, 'maroon': 0xff800000,
    'red': 0xffff0000, 'purple': 0xff800080, 'fuchsia': 0xffff00ff,
    'magenta': 0xffff00ff, 'green': 0xff008000, 'lime': 0xff00ff00,
    'olive': 0xff808000, 'yellow': 0xffffff00, 'navy': 0xff000080,
    'blue': 0xff0000ff, 'teal': 0xff008080, 'aqua': 0xff00ffff,
    'cyan': 0xff00ffff, 'orange': 0xffffa500, 'aliceblue': 0xfff0f8ff,
    'antiquewhite': 0xfffaebd7, 'aquamarine': 0xff7fffd4, 'azure': 0xfff0ffff,
    'beige': 0xfff5f5dc, 'bisque': 0xffffe4c4, 'blanchedalmond': 0xffffebcd,
    'blueviolet': 0xff8a2be2, 'brown': 0xffa52a2a, 'burlywood': 0xffdeb887,
    'cadetblue': 0xff5f9ea0, 'chartreuse': 0xff7fff00, 'chocolate': 0xffd2691e,
    'coral': 0xffff7f50, 'cornflowerblue': 0xff6495ed, 'cornsilk': 0xfffff8dc,
    'crimson': 0xffdc143c, 'darkblue': 0xff00008b, 'darkcyan': 0xff008b8b,
    'darkgoldenrod': 0xffb8860b, 'darkgray': 0xffa9a9a9, 'darkgrey': 0xffa9a9a9,
    'darkgreen': 0xff006400, 'darkkhaki': 0xffbdb76b, 'darkmagenta': 0xff8b008b,
    'darkolivegreen': 0xff556b2f, 'darkorange': 0xffff8c00,
    'darkorchid': 0xff9932cc, 'darkred': 0xff8b0000, 'darksalmon': 0xffe9967a,
    'darkseagreen': 0xff8fbc8f, 'darkslateblue': 0xff483d8b,
    'darkslategray': 0xff2f4f4f, 'darkslategrey': 0xff2f4f4f,
    'darkturquoise': 0xff00ced1, 'darkviolet': 0xff9400d3,
    'deeppink': 0xffff1493, 'deepskyblue': 0xff00bfff, 'dimgray': 0xff696969,
    'dimgrey': 0xff696969, 'dodgerblue': 0xff1e90ff, 'firebrick': 0xffb22222,
    'floralwhite': 0xfffffaf0, 'forestgreen': 0xff228b22, 'gainsboro': 0xffdcdcdc,
    'ghostwhite': 0xfff8f8ff, 'gold': 0xffffd700, 'goldenrod': 0xffdaa520,
    'greenyellow': 0xffadff2f, 'honeydew': 0xfff0fff0, 'hotpink': 0xffff69b4,
    'indianred': 0xffcd5c5c, 'indigo': 0xff4b0082, 'ivory': 0xfffffff0,
    'khaki': 0xfff0e68c, 'lavender': 0xffe6e6fa, 'lavenderblush': 0xfffff0f5,
    'lawngreen': 0xff7cfc00, 'lemonchiffon': 0xfffffacd, 'lightblue': 0xffadd8e6,
    'lightcoral': 0xfff08080, 'lightcyan': 0xffe0ffff,
    'lightgoldenrodyellow': 0xfffafad2, 'lightgray': 0xffd3d3d3,
    'lightgrey': 0xffd3d3d3, 'lightgreen': 0xff90ee90, 'lightpink': 0xffffb6c1,
    'lightsalmon': 0xffffa07a, 'lightseagreen': 0xff20b2aa,
    'lightskyblue': 0xff87cefa, 'lightslategray': 0xff778899,
    'lightslategrey': 0xff778899, 'lightsteelblue': 0xffb0c4de,
    'lightyellow': 0xffffffe0, 'limegreen': 0xff32cd32, 'linen': 0xfffaf0e6,
    'mediumaquamarine': 0xff66cdaa, 'mediumblue': 0xff0000cd,
    'mediumorchid': 0xffba55d3, 'mediumpurple': 0xff9370db,
    'mediumseagreen': 0xff3cb371, 'mediumslateblue': 0xff7b68ee,
    'mediumspringgreen': 0xff00fa9a, 'mediumturquoise': 0xff48d1cc,
    'mediumvioletred': 0xffc71585, 'midnightblue': 0xff191970,
    'mintcream': 0xfff5fffa, 'mistyrose': 0xffffe4e1, 'moccasin': 0xffffe4b5,
    'navajowhite': 0xffffdead, 'oldlace': 0xfffdf5e6, 'olivedrab': 0xff6b8e23,
    'orangered': 0xffff4500, 'orchid': 0xffda70d6, 'palegoldenrod': 0xffeee8aa,
    'palegreen': 0xff98fb98, 'paleturquoise': 0xffafeeee,
    'palevioletred': 0xffdb7093, 'papayawhip': 0xffffefd5, 'peachpuff': 0xffffdab9,
    'peru': 0xffcd853f, 'pink': 0xffffc0cb, 'plum': 0xffdda0dd,
    'powderblue': 0xffb0e0e6, 'rosybrown': 0xffbc8f8f, 'royalblue': 0xff4169e1,
    'saddlebrown': 0xff8b4513, 'salmon': 0xfffa8072, 'sandybrown': 0xfff4a460,
    'seagreen': 0xff2e8b57, 'seashell': 0xfffff5ee, 'sienna': 0xffa0522d,
    'skyblue': 0xff87ceeb, 'slateblue': 0xff6a5acd, 'slategray': 0xff708090,
    'slategrey': 0xff708090, 'snow': 0xfffffafa, 'springgreen': 0xff00ff7f,
    'steelblue': 0xff4682b4, 'tan': 0xffd2b48c, 'thistle': 0xffd8bfd8,
    'tomato': 0xffff6347, 'turquoise': 0xff40e0d0, 'violet': 0xffee82ee,
    'wheat': 0xfff5deb3, 'whitesmoke': 0xfff5f5f5, 'yellowgreen': 0xff9acd32,
    'rebeccapurple': 0xff663399,
  };


  /// 判断元素是否应该**整体跳过**(不渲染、不取 textContent)。
  ///
  /// Discourse cooked 里有几类元素仅作 UI 占位,不该出现在文字流:
  /// - `<svg>`(d-icon / Discourse 自带图标 / lightbox 展开图标 等)
  /// - `.d-icon`(同上)
  /// - `.meta`(lightbox 的文件名 + 尺寸 + KB 容器,我们已用结构化字段)
  /// - `.lb-spacer`(legacy 给 lightbox 之间留间距的固定高度块)
  ///
  /// 不跳过时:
  /// - `<svg><use href="#far-image"/></svg>` 的 textContent 是空,但同
  ///   段落出现这个会让 paragraph 多出空 inline 噪音
  /// - `.meta` 的 `<span class="filename">hash</span><span class="informations">1686×128 15.7 KB</span>`
  ///   会被 fallback textContent 收成 "hash 1686×128 15.7 KB" 字符串,
  ///   就是用户截图里看到的乱码
  /// 判断 `<svg>` 是否为**内容型**(应渲染),而非 Discourse 的 UI 图标。
  ///
  /// 逐字对齐 legacy `_buildInlineSvg`(discourse_html_content_widget.dart:944-950)
  /// 的判定 + 643-647 的 .d-icon 拦截:
  /// - `class` 含 `d-icon` → 图标(false)。
  /// - 既无 `viewBox` 又无显式 `width`/`height` → 图标占位(false)。
  /// - 否则(有 viewBox 或有宽高)→ 内容 svg(true)。
  bool _isContentSvg(dom.Element el) {
    if (el.classes.contains('d-icon')) return false;
    final hasViewBox = (el.attributes['viewBox'] ?? '').trim().isNotEmpty;
    final hasWidth = (el.attributes['width'] ?? '').trim().isNotEmpty;
    final hasHeight = (el.attributes['height'] ?? '').trim().isNotEmpty;
    return hasViewBox || hasWidth || hasHeight;
  }

  bool _isSkipElement(String tag, dom.Element el) {
    // svg 在 inline 流里一律跳过(d-icon 图标 + 防止内容 svg 破坏文字流);
    // 内容型 svg 的渲染只在**块级** switch 的 case 'svg' 处理(产 SvgNode)。
    if (tag == 'svg') return true;
    final classes = el.classes;
    if (classes.contains('d-icon')) return true;
    if (classes.contains('meta')) return true;
    if (classes.contains('lb-spacer')) return true;
    return false;
  }

  /// 把元素子树的所有 text 节点拼成一段(用于 InlineCodeRun)。
  /// 不递归 attribute、不做 trim、保留所有空白。
  String _textContent(dom.Element el) {
    final buf = StringBuffer();
    void visit(dom.Node n) {
      if (n is dom.Text) {
        buf.write(n.text);
      } else if (n is dom.Element) {
        for (final c in n.nodes) {
          visit(c);
        }
      }
    }
    for (final c in el.nodes) {
      visit(c);
    }
    return buf.toString();
  }
}
