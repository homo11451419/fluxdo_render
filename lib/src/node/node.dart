/// 渲染节点的根类型族。
///
/// 数据模型设计原则:
/// - sealed class + Dart 3 switch exhaustiveness,新增节点必须改所有 dispatch
/// - 全部 immutable,`==`/`hashCode` 让 widget rebuild diff 廉价
/// - 块级与行内严格分层:`BlockNode` 顶层渲染,行内只在某 `BlockNode` 内
/// - 每个 `BlockNode` 自带稳定 `id` — 为阶段 5 自研选区
///   (`LogicalPosition { blockId, inlineIndex, charOffset }`)铺路
///
/// 阶段 1.1 范围:Paragraph + 行内 Text/Em/Strong/LineBreak
/// 后续阶段会扩展 HeadingNode / ListNode / CodeBlockNode 等。

library;

import 'dart:ui' show TextAlign;

import 'package:flutter/foundation.dart';

import 'inline_node.dart';

export 'inline_node.dart';

/// 所有块级节点的基类。
///
/// 一份 cooked HTML 解析后产物是 `List<BlockNode>`。每个 BlockNode
/// 自带稳定 [id],由 parser 在解析时分配("b_0", "b_1", ...),同一份
/// HTML 解析两次 id 相同。
///
/// id 仅作"节点身份"用,**不参与 ==/hashCode**(让节点 immutable +
/// 内容比较仍然便宜)。阶段 5 自研选区时 `LogicalPosition` 用 id
/// 寻址,行内通过 (id, inlineIndex, charOffset) 三元组定位。
@immutable
sealed class BlockNode {
  const BlockNode({required this.id});

  final String id;
}

/// 段落 — 一段连续的行内内容。
///
/// 对应 HTML 中的 `<p>...</p>`。
@immutable
class ParagraphNode extends BlockNode {
  const ParagraphNode({required super.id, required this.inlines, this.textAlign});

  /// 段落内的行内节点序列。
  final List<InlineNode> inlines;

  /// 块级对齐(`<div align>` / `<p align>` / `style="text-align"` / `<center>`)。
  /// null = 默认(随文本方向起始对齐)。
  final TextAlign? textAlign;

  /// 编辑器(src/editor)替换行内内容用;id/textAlign 保持。
  ParagraphNode copyWith({List<InlineNode>? inlines}) => ParagraphNode(
        id: id,
        inlines: inlines ?? this.inlines,
        textAlign: textAlign,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParagraphNode &&
          runtimeType == other.runtimeType &&
          textAlign == other.textAlign &&
          listEquals(inlines, other.inlines);

  @override
  int get hashCode => Object.hash(textAlign, Object.hashAll(inlines));

  @override
  String toString() => 'ParagraphNode($id, ${inlines.length} inlines'
      '${textAlign == null ? "" : ", $textAlign"})';
}

/// 标题 — h1/h2/h3/h4/h5/h6,字号由 [level] 决定。
///
/// 对应 HTML 中的 `<h1>` - `<h6>`。
@immutable
class HeadingNode extends BlockNode {
  const HeadingNode({
    required super.id,
    required this.level,
    required this.inlines,
    this.textAlign,
  }) : assert(level >= 1 && level <= 6, 'heading level must be 1..6');

  /// 标题级别,1-6。
  final int level;

  /// 标题内的行内节点序列。
  final List<InlineNode> inlines;

  /// 块级对齐(同 ParagraphNode)。
  final TextAlign? textAlign;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HeadingNode &&
          runtimeType == other.runtimeType &&
          level == other.level &&
          textAlign == other.textAlign &&
          listEquals(inlines, other.inlines);

  @override
  int get hashCode => Object.hash(level, textAlign, Object.hashAll(inlines));

  @override
  String toString() => 'HeadingNode($id, h$level, ${inlines.length} inlines'
      '${textAlign == null ? "" : ", $textAlign"})';
}

/// 列表项 — inline 内容 + 可选嵌套子列表(li 内 ul/ol);或**块级子节点**
/// (li 内含 `<h4>`/`<p>`/`<pre>`/`<blockquote>` 等,如 FAQ 的 Q/A 结构)。
///
/// 不是 BlockNode,只是 ListNode 内部的数据结构。
///
/// 两种形态(互斥):
/// - **inline 快路径**([blocks] == null):li 只含 inline → [inlines] + 可选
///   嵌套 [children] 子 list。绝大多数列表项。
/// - **块级形态**([blocks] != null):li 含块级元素 → [blocks] 为其块级子序列
///   (含嵌套 list),渲染为 marker + Column;[inlines]/[children] 不用。
@immutable
class ListItem {
  const ListItem({
    this.inlines = const [],
    this.children,
    this.blocks,
  });

  /// 列表项的 inline 内容(li 直属 text/em/link/...)。块级形态下为空。
  final List<InlineNode> inlines;

  /// 嵌套子列表(li 内含 ul/ol),null 表示叶子项。块级形态下为 null。
  final List<ListNode>? children;

  /// 块级子节点(li 含 h4/p/pre/blockquote 等真块级时)。null = inline 快路径。
  final List<BlockNode>? blocks;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ListItem &&
          runtimeType == other.runtimeType &&
          listEquals(inlines, other.inlines) &&
          listEquals(children, other.children) &&
          listEquals(blocks, other.blocks);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(inlines),
        children == null ? 0 : Object.hashAll(children!),
        blocks == null ? 0 : Object.hashAll(blocks!),
      );

  @override
  String toString() => blocks != null
      ? 'ListItem(${blocks!.length} blocks)'
      : 'ListItem(${inlines.length} inlines'
          '${children == null ? "" : ", ${children!.length} sub-lists"})';
}

/// 列表 — `<ul>` 或 `<ol>`,可嵌套。
///
/// 对应 HTML 中的 `<ul>...</ul>` / `<ol>...</ol>`。深度 [depth] 由 parser
/// 在递归时填(顶层 0,每嵌套一层 +1),renderer 用 depth 决定缩进倍数。
///
/// 视觉对齐 legacy(DiscourseHtmlContentWidget customStylesBuilder):
///   ul/ol: padding-left 20px, margin 8px 上下
///   li:    margin 4px 上下, line-height 1.5
///   有序列表 marker 用等宽数字(FontFeature.tabularFigures)。
@immutable
class ListNode extends BlockNode {
  const ListNode({
    required super.id,
    required this.ordered,
    required this.items,
    this.depth = 0,
    this.start = 1,
  });

  /// true = `<ol>`(有序,marker 是数字),false = `<ul>`(无序,marker 是 ·)
  final bool ordered;

  /// 列表项序列。
  final List<ListItem> items;

  /// 嵌套深度(顶层 = 0)。
  final int depth;

  /// 有序列表起始序号(`<ol start="N">`,对齐浏览器/fwfh;`<ul>` 恒为 1 不用)。
  /// 第 i 项 marker = `start + i`。Discourse 续接列表会产出 `start="2"` 等。
  final int start;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ListNode &&
          runtimeType == other.runtimeType &&
          ordered == other.ordered &&
          depth == other.depth &&
          start == other.start &&
          listEquals(items, other.items);

  @override
  int get hashCode => Object.hash(ordered, depth, start, Object.hashAll(items));

  @override
  String toString() =>
      'ListNode($id, ${ordered ? "ol" : "ul"}, depth=$depth, '
      '${start == 1 ? "" : "start=$start, "}${items.length} items)';
}

/// 引用块 — `<blockquote>`,内部含任意 BlockNode 子节点(支持嵌套)。
///
/// 视觉对齐 legacy(`blockquote_builder.dart` 普通引用分支):
///   margin 上下 8
///   padding L 12 / 上下 8 / R 12
///   背景 colorScheme.surfaceContainerHighest @ 0.3
///   左边 4px outline 竖条
///   右上 / 右下 圆角 4
///   字色 onSurfaceVariant + 行高 1.5
///
/// **Obsidian Callout**(`[!note]` / `[!warning]` 等)是 Discourse 在
/// blockquote 内的特殊语法,渲染为带图标的彩色卡片 —— 那是独立节点
/// (`NodeKind.callout`),阶段 1 不在 scope,parser 暂时把 callout 形态
/// 当普通 blockquote 处理。
/// 引用块在「装饰下放」分块中的位置 —— 大 blockquote 被拆成多个 sliver 片时,
/// 每片重套 blockquote 标签并标位置,子包按此渲染连续装饰(左条+背景每片都画,
/// 仅首片留上外边距/上圆角、尾片留下外边距/下圆角,中间片无边距无圆角无缝拼接)。
/// [whole] = 未拆分的完整引用块(默认)。
enum BlockquoteChunkPos { whole, first, mid, last }

@immutable
class BlockquoteNode extends BlockNode {
  const BlockquoteNode({
    required super.id,
    required this.children,
    this.chunkPos = BlockquoteChunkPos.whole,
  });

  /// 引用块内部的块级子节点(可嵌套 blockquote / paragraph / list)。
  final List<BlockNode> children;

  /// 装饰下放分块位置(整帖渲染 / 未拆分时为 [BlockquoteChunkPos.whole])。
  final BlockquoteChunkPos chunkPos;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlockquoteNode &&
          runtimeType == other.runtimeType &&
          chunkPos == other.chunkPos &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hash(chunkPos, Object.hashAll(children));

  @override
  String toString() =>
      'BlockquoteNode($id, ${children.length} children'
      '${chunkPos == BlockquoteChunkPos.whole ? "" : ", $chunkPos"})';
}

/// 分割线 — `<hr>`。无字段。
///
/// 视觉对齐 legacy:`vertical padding 12 + 1px line(outlineVariant @ 0.5)`。
///
/// id 仍存在(BlockNode 协议要求),给阶段 5 自研选区时按 id 寻址用。
@immutable
class HorizontalRuleNode extends BlockNode {
  const HorizontalRuleNode({required super.id});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HorizontalRuleNode && runtimeType == other.runtimeType;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'HorizontalRuleNode($id)';
}

/// 空行 — 空 `<p>`(`<p></p>` / `<p><em></em></p>` / `<p><br></p>`)。
///
/// fwfh 给每个 `<p>` 加 margin,空段落因此渲染成一段垂直留白(空行);
/// 作者常用连续空 `<p>` 做内容的上下留白 / 视觉居中。新引擎自研 parser
/// 默认会把空段落直接丢弃 —— 与 fwfh 不一致(留白丢失)。用本节点显式承载
/// 「一个空行」的垂直间距,渲染为 SizedBox(无文字,不参与选区)。
///
/// 注意:只对「无文字且无图片」的段落生成;含 `<img>` 的段落不是空行。
class BlankLineNode extends BlockNode {
  const BlankLineNode({required super.id});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlankLineNode && runtimeType == other.runtimeType;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'BlankLineNode($id)';
}

/// 代码块 — `<pre><code>`,可带语言标识。
///
/// 视觉对齐 legacy `code_block_builder.dart`:
///   灰底容器(surfaceContainer)+ 圆角 8
///   顶栏:语言 chip + 复制按钮
///   主体:横向滚动 + monospace + 行号(可选)
///
/// **不含语法高亮**:子包不依赖 highlight.js / mermaid / chart 等
/// 重量级库,通过 [CodeBlockHighlighter] callback 由主项目注入。
/// 不传时纯 monospace 显示。
///
/// [language] 是 cooked HTML 里 `class="lang-xxx"` 提取的语言标识
/// (`'dart'` / `'python'` / `'mermaid'` 等);无则 null。
@immutable
class CodeBlockNode extends BlockNode {
  const CodeBlockNode({
    required super.id,
    required this.code,
    this.language,
  });

  /// 代码原始字面值(parser 已解码 HTML 实体,末尾换行已去掉)。
  final String code;

  /// 语言标识(小写),如 `'dart'` / `'python'` / `'mermaid'`;
  /// 未指定 / 未识别时 null。
  final String? language;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CodeBlockNode &&
          runtimeType == other.runtimeType &&
          code == other.code &&
          language == other.language;

  @override
  int get hashCode => Object.hash(code, language);

  @override
  String toString() =>
      'CodeBlockNode($id, lang=${language ?? "?"}, ${code.length} chars)';
}

/// 回复引用卡 — `<aside class="quote">`,Discourse 最常见的"@回复"形态。
///
/// HTML 形态(简化):
/// ```html
/// <aside class="quote" data-username="alice" data-post="3" data-topic="999">
///   <div class="title">
///     <img class="avatar" src="...">
///     alice:
///     <a href="/t/topic-slug/999/3">原帖标题</a>
///   </div>
///   <blockquote>
///     <p>这是被引用的内容</p>
///   </blockquote>
/// </aside>
/// ```
///
/// 视觉对齐 legacy `quote_card_builder.dart`:
///   margin 上下 8;灰底 + 左 4px 竖条 + 右上右下圆角 4
///   头部:头像 + "username:" + 可选标题(主色)
///   内容:嵌套 BlockNode 递归渲染(走 buildBlockquote 同样的子样式)
///
/// **不持 categoryHtml**:Discourse badge 是独立组件,主项目接入再补。
/// 头像复用主项目 [imageContentBuilder](通过一个 ImageRun adapter),
/// 这样头像也走 discourseImageProvider 缓存池。
@immutable
class QuoteCardNode extends BlockNode {
  const QuoteCardNode({
    required super.id,
    required this.username,
    this.avatarUrl,
    this.titleText,
    this.titleInlines = const [],
    this.titleHref,
    this.topicId,
    this.postNumber,
    this.categoryName,
    this.categoryColor,
    this.categoryTextColor,
    this.categoryHref,
    this.children = const [],
    this.full = false,
    this.displayName,
    this.oneboxUrl,
  });

  /// `data-username`,主项目用它构造用户卡跳转(同 MentionRun.username)。
  /// 缺失时空串。
  final String username;

  /// `data-full="true"`(raw 里 `full:true` —— 引用了原帖全文)。
  /// markdown 序列化写回时必须保留,否则"全文引用"退化成"节选"。
  final bool full;

  /// `data-display-name`(raw 里 `[quote="张三, …, username:sam"]` 的
  /// 显示名形态)。null = raw 第一段就是 username。序列化写回用。
  final String? displayName;

  /// 非 null = 本卡是**站内链接 onebox 的展开物**(编辑器预览 cook 的
  /// `data-fluxdo-onebox-url` 标记):raw 是裸 URL 而非 [quote] 块,
  /// 序列化必须写回该 URL —— 固化成引用块即毁帖(语义从"跟随原帖的
  /// onebox"变成"静态引用")。服务端 cooked 无此标记,恒 null。
  final String? oneboxUrl;

  /// `img.avatar` 的 src(原始 URL,parser 不重写)。
  /// 缺失时 null,渲染走首字母 chip fallback。
  final String? avatarUrl;

  /// 引用标题的纯文本(fallback / 相等用;渲染优先 [titleInlines])。
  final String? titleText;

  /// 引用标题的行内内容(保留 emoji / 链接,对齐 legacy htmlBuilder(titleHtml))。
  /// 为空时渲染回退 [titleText] 纯文本。
  final List<InlineNode> titleInlines;

  /// 引用标题里的 `<a href>`,主项目用 LinkHandler 跳原帖。
  /// 优先级:有 titleHref → 用它;无则 topicId + postNumber 拼。
  final String? titleHref;

  /// `data-topic`(`int.tryParse` 失败时 null)。
  final int? topicId;

  /// `data-post`(`int.tryParse` 失败时 null)。
  final int? postNumber;

  /// 分类徽章名(`.badge-category__name`),无徽章时 null。
  final String? categoryName;

  /// 徽章底色(`--category-badge-color` 原始串,如 `#32c3c3`),渲染时 parse。
  final String? categoryColor;

  /// 徽章文字色(`--category-badge-text-color`)。
  final String? categoryTextColor;

  /// 徽章链接(`/c/xxx`),点击跳分类。
  final String? categoryHref;

  /// `<blockquote>` 内的递归 BlockNode。
  final List<BlockNode> children;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QuoteCardNode &&
          runtimeType == other.runtimeType &&
          username == other.username &&
          avatarUrl == other.avatarUrl &&
          titleText == other.titleText &&
          listEquals(titleInlines, other.titleInlines) &&
          titleHref == other.titleHref &&
          topicId == other.topicId &&
          postNumber == other.postNumber &&
          categoryName == other.categoryName &&
          categoryColor == other.categoryColor &&
          categoryTextColor == other.categoryTextColor &&
          categoryHref == other.categoryHref &&
          full == other.full &&
          displayName == other.displayName &&
          oneboxUrl == other.oneboxUrl &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hash(
        username,
        avatarUrl,
        titleText,
        Object.hashAll(titleInlines),
        titleHref,
        topicId,
        postNumber,
        categoryName,
        categoryColor,
        categoryTextColor,
        categoryHref,
        full,
        displayName,
        oneboxUrl,
        Object.hashAll(children),
      );

  @override
  String toString() =>
      'QuoteCardNode($id, @$username'
      '${topicId == null ? "" : ", t=$topicId/p=$postNumber"}, '
      '${children.length} children)';
}

/// 块级 spoiler — `<div class="spoiler">`,默认遮蔽,点击展开。
///
/// 视觉(子包简化版,无粒子动画):
///   未揭示:灰底框 + "点击显示剧透" 提示
///   揭示后:正常渲染 children
///
/// 状态由 NodeFactory 内的 StatefulWidget 管。阶段 5 自研选区时再
/// 加粒子动画。
@immutable
class SpoilerBlockNode extends BlockNode {
  const SpoilerBlockNode({required super.id, required this.children});

  /// 被遮蔽的块级子节点(可嵌套 paragraph / list / blockquote 等)。
  final List<BlockNode> children;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SpoilerBlockNode &&
          runtimeType == other.runtimeType &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hashAll(children);

  @override
  String toString() =>
      'SpoilerBlockNode($id, ${children.length} children)';
}

/// Onebox 类型 —— 跟 legacy `OneboxType` enum 一致(`docs/node_priority.md`
/// 阶段 2 第 1 节点)。
///
/// 子包**只识别归类**,不实现真渲染:
/// - 6 大类(github / video / social / tech / user / default)
/// - 主项目 OneboxBuilder callback 内根据 [kind] dispatch 到具体 builder
///
/// 不细化 GitHub 子类型(repo/blob/issue/pr/commit/...)— 主项目 builder
/// 内基于 url 自己再细分。子包暴露 [OneboxNode.url] 即可。
enum OneboxKind {
  /// `class="user-onebox"` — 用户卡(头像 + 名字 + bio)
  user,

  /// `class="github-onebox" | "onebox-github" | "github*"` —— GitHub 系列
  github,

  /// twitter / reddit / instagram / threads / tiktok
  social,

  /// youtube / vimeo / loom
  video,

  /// stackexchange / hackernews / pastebin / googledocs / pdf / amazon
  tech,

  /// 通用链接预览卡片(无明确类型识别 / `class="onebox"` 兜底)
  defaultKind,
}

/// 链接预览卡片 — `<aside class="onebox">`(Discourse 经典外链卡)。
///
/// HTML 形态:Discourse 后端用 onebox gem 抓取目标 URL 元数据,渲染成
/// 一个 `<aside class="onebox <type>-onebox">` 卡片,典型字段:
/// - `header > a.source` / `.source a` — 来源(站点名)
/// - `img.site-icon` / `img.favicon` — 站点图标
/// - `h3 a` / `h4 a` — 标题
/// - `p` — 描述
/// - `img.thumbnail` / `.aspect-image img` — 缩略图
///
/// 子包只提结构化关键字段 + 保留 [rawHtml] 兜底。主项目 OneboxBuilder
/// callback 拿 [kind] dispatch 到 6 种子 builder(legacy 已有完整实现,
/// 直接调即可,不必移植 4000 行)。
///
/// 不传 OneboxBuilder 时子包用通用卡片样式渲染(对齐 legacy
/// `default_onebox_builder`)。
@immutable
class OneboxNode extends BlockNode {
  const OneboxNode({
    required super.id,
    required this.kind,
    this.url,
    this.title,
    this.description,
    this.faviconUrl,
    this.thumbnailUrl,
    this.sourceName,
    this.rawHtml = '',
  });

  /// Onebox 类型(给主项目 builder dispatch 用)。
  final OneboxKind kind;

  /// 卡片对应的真实 URL(`data-onebox-src` 优先,fallback 到 header a /
  /// h3 a / h4 a 的 href)。null 表示未识别(罕见,容错占位)。
  final String? url;

  /// 标题(典型来自 `h3 a` / `h4 a` 的 text)。
  final String? title;

  /// 描述(典型来自 `p` 的 text)。
  final String? description;

  /// 站点图标(典型来自 `img.site-icon` / `img.favicon` 的 src)。
  final String? faviconUrl;

  /// 缩略图(典型来自 `img.thumbnail` / `.aspect-image img` 的 src)。
  final String? thumbnailUrl;

  /// 站点名(典型来自 `.source a` 的 text)。
  final String? sourceName;

  /// 原始 cooked HTML 片段(`aside.onebox.outerHtml`)。
  ///
  /// 给主项目 builder 兜底用:legacy 的 GitHub/video/social 等
  /// builder 大量依赖 DOM 内部结构(如 `.github-row` / `.author` /
  /// `.body` 等),结构化字段拿不全,需要 rawHtml 重 parse。
  /// 不强制使用,主项目 builder 优先用结构化字段。
  final String rawHtml;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OneboxNode &&
          runtimeType == other.runtimeType &&
          kind == other.kind &&
          url == other.url &&
          title == other.title &&
          description == other.description &&
          faviconUrl == other.faviconUrl &&
          thumbnailUrl == other.thumbnailUrl &&
          sourceName == other.sourceName &&
          rawHtml == other.rawHtml;

  @override
  int get hashCode => Object.hash(
        kind,
        url,
        title,
        description,
        faviconUrl,
        thumbnailUrl,
        sourceName,
        rawHtml,
      );

  @override
  String toString() =>
      'OneboxNode($id, $kind${url == null ? "" : ", $url"})';
}

/// Obsidian Callout 类型 — 对齐 legacy `callout_config.dart::getCalloutConfig`
/// 13 大类。
///
/// Discourse 在 `<blockquote>` 内首段以 `[!type]` 起头表示 callout(Obsidian
/// 语法),渲染成带图标的彩色卡片。子包只识别归类 + 暴露字段;具体颜色 /
/// 图标在 NodeFactory.buildCallout 内按 kind 派发(对齐 legacy)。
///
/// `unknown` = legacy 里走 "未知类型 → 灰色 + 首字母大写" 兜底分支。
enum CalloutKind {
  note,
  summary,
  info,
  todo,
  tip,
  success,
  question,
  warning,
  failure,
  danger,
  bug,
  example,
  quote,
  unknown;

  /// 解析 type 关键字到 enum(对齐 legacy 别名)。
  ///
  /// 未识别返回 [unknown](保留原始 typeRaw,渲染层做首字母大写标题)。
  static CalloutKind fromType(String type) {
    switch (type) {
      case 'note':
        return CalloutKind.note;
      case 'abstract':
      case 'summary':
      case 'tldr':
        return CalloutKind.summary;
      case 'info':
        return CalloutKind.info;
      case 'todo':
        return CalloutKind.todo;
      case 'tip':
      case 'hint':
      case 'important':
        return CalloutKind.tip;
      case 'success':
      case 'check':
      case 'done':
        return CalloutKind.success;
      case 'question':
      case 'help':
      case 'faq':
        return CalloutKind.question;
      case 'warning':
      case 'caution':
      case 'attention':
        return CalloutKind.warning;
      case 'failure':
      case 'fail':
      case 'missing':
        return CalloutKind.failure;
      case 'danger':
      case 'error':
        return CalloutKind.danger;
      case 'bug':
        return CalloutKind.bug;
      case 'example':
        return CalloutKind.example;
      case 'quote':
      case 'cite':
        return CalloutKind.quote;
      default:
        return CalloutKind.unknown;
    }
  }
}

/// Obsidian Callout — `<blockquote><p>[!type](+|-)?\s*title<br>...</p>...</blockquote>`。
///
/// HTML 形态(简化):
/// ```html
/// <blockquote>
///   <p>[!note]+ 提示标题<br>提示正文第一行</p>
///   <p>提示正文第二段</p>
/// </blockquote>
/// ```
///
/// 标记规则:
/// - `[!type]` — 不可折叠(`foldable=null`)
/// - `[!type]+` — 可折叠,默认展开(`foldable=true`)
/// - `[!type]-` — 可折叠,默认折叠(`foldable=false`)
/// - `[!type]` 后空格 + 自定义标题(可空,空时用 kind 默认标题)
///
/// 视觉对齐 legacy `callout_builder.dart`:
///   margin 上下 8;callout 主色背景 @ 10% + 左 4px 主色竖条 + 右上右下圆角 4
///   头部:Row(icon 18px + 标题 + 可折叠箭头)
///   内容:Padding(12, 8, 12, 12) + DefaultTextStyle(onSurfaceVariant + 1.5)
///   可折叠:头部点击切换 + heightFactor 200ms easeInOut + 箭头旋转 0→0.5 turns
///
/// **简化**:
/// - 不持原始 cooked html;首段 callout 标记行在 parser 阶段就被剥掉,
///   children 已是"正文 BlockNode"。
/// - title 只持纯文本(legacy 支持 titleHtml 渲染样式,简化忽略 ——
///   实际几乎所有 callout 标题都是纯文本)。
@immutable
class CalloutNode extends BlockNode {
  const CalloutNode({
    required super.id,
    required this.kind,
    required this.typeRaw,
    this.title,
    this.titleInlines,
    this.foldable,
    this.children = const [],
    this.chunkPos = BlockquoteChunkPos.whole,
  });

  /// 识别后的类型;[CalloutKind.unknown] 时用 [typeRaw] 做首字母大写默认标题。
  final CalloutKind kind;

  /// 原始 type 字符串(已 lowercase),保留给 [CalloutKind.unknown] 兜底
  /// 显示用("[!xyz]" → typeRaw="xyz",默认标题渲染成 "Xyz")。
  final String typeRaw;

  /// 自定义标题纯文本(`[!type] 这里的标题`),空时 NodeFactory 用 kind 默认值。
  /// 仅作 toString/相等/默认判定用;实际渲染优先用 [titleInlines](保留链接等)。
  final String? title;

  /// 自定义标题的**行内节点**(保留 `<a>` 链接/格式)。非空时渲染走
  /// InlineSpanText(标题里的链接可点);为 null/空则回退纯文本 [title] / 默认标题。
  final List<InlineNode>? titleInlines;

  /// 折叠形态:`null` = 不可折叠;`true` = 可折叠 + 默认展开;
  /// `false` = 可折叠 + 默认折叠。
  final bool? foldable;

  /// 正文 BlockNode(parser 已把首段 callout 标记行剥掉)。
  final List<BlockNode> children;

  /// 装饰下放分块位置(复用 [BlockquoteChunkPos];未拆分时 whole)。大 callout
  /// 拆片时:首片保留 `[!type]` 标记走文本识别(出标题头),中/尾片用
  /// `data-fxd-callout` 属性识别(只 kind + body),都带 `data-fxd-pos`。
  final BlockquoteChunkPos chunkPos;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CalloutNode &&
          runtimeType == other.runtimeType &&
          kind == other.kind &&
          typeRaw == other.typeRaw &&
          title == other.title &&
          listEquals(titleInlines, other.titleInlines) &&
          foldable == other.foldable &&
          chunkPos == other.chunkPos &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hash(
        kind,
        typeRaw,
        title,
        titleInlines == null ? 0 : Object.hashAll(titleInlines!),
        foldable,
        chunkPos,
        Object.hashAll(children),
      );

  @override
  String toString() =>
      'CalloutNode($id, $kind${title == null ? "" : "/\"$title\""}'
      '${foldable == null ? "" : ", foldable=$foldable"}'
      '${chunkPos == BlockquoteChunkPos.whole ? "" : ", $chunkPos"}, '
      '${children.length} children)';
}

/// 折叠块 — `<details><summary>标题</summary>内容</details>`。
///
/// 视觉对齐 legacy `details_builder.dart`:
///   外:margin 上下 8 + outline 边框 + 圆角 8
///   头:可点击灰底 + 旋转箭头 + summary 文字
///   体:折叠时不构建,展开后递归渲染 [children];动画 200ms easeInOut
///
/// `<details open>` 默认展开;无 `open` 默认折叠。
///
/// **简化**:
/// - summary 只持纯文本(legacy 也只用 text,不渲染嵌套样式)
/// - 不做"渐进式分块渲染"(legacy 用 HtmlChunker 切长内容降低首屏卡顿;
///   子包 parser 速度比 legacy 快 10x,无必要分块)
@immutable
class DetailsNode extends BlockNode {
  const DetailsNode({
    required super.id,
    required this.summary,
    required this.children,
    this.initiallyOpen = false,
  });

  /// summary 文本(`<summary>` 子节点的 textContent)。
  /// 空时主项目 / 子包应用本地化兜底标签("详情"/"Details")。
  final String summary;

  /// `<details>` 内除 summary 外的所有块级子节点(递归 parse)。
  final List<BlockNode> children;

  /// `<details open>` 属性,默认 false。
  final bool initiallyOpen;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DetailsNode &&
          runtimeType == other.runtimeType &&
          summary == other.summary &&
          initiallyOpen == other.initiallyOpen &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hash(
        summary,
        initiallyOpen,
        Object.hashAll(children),
      );

  @override
  String toString() =>
      'DetailsNode($id, "$summary", ${children.length} children'
      '${initiallyOpen ? ", open" : ""})';
}

/// 图片网格的展示形态。
///
/// 对齐 legacy:`<div class="d-image-grid" data-mode="carousel">` 走 carousel
/// 模式(横向滑动 + 分页指示),其他走 grid 模式(`data-columns` 列网格)。
enum ImageGridMode {
  /// 默认网格(`data-columns` 列,Wrap 布局)。
  grid,

  /// 横向轮播(`data-mode="carousel"` 或 class 含 `d-image-grid--carousel`)。
  /// 子包 fallback 渲染:不做真 carousel,降级为单列大图(legacy 的
  /// carousel 含分页 / 计数器 / 预加载,主项目可通过自定义 builder 注入)。
  carousel,
}

/// 图片网格 — `<div class="d-image-grid">`(Discourse 多图布局)。
///
/// HTML 形态:
/// ```html
/// <div class="d-image-grid" data-columns="3" data-mode="grid">
///   <div class="lightbox-wrapper">
///     <a class="lightbox" href="原图URL"><img src="缩略" width="..." height="..."></a>
///   </div>
///   <!-- 也可能直接是裸 <img>,跟 lightbox-wrapper 混排 -->
/// </div>
/// ```
///
/// 视觉对齐 legacy `image_grid_builder.dart`:
///   外:Padding vertical 8
///   主体:LayoutBuilder + Wrap(spacing 6, runSpacing 6)
///     列宽 = (avail - (cols-1)*6) / cols,瓦片高 = 宽 * (h/w) clamp 80..300
///     无尺寸时高 = 宽 * 0.75
///   瓦片:ClipRRect 圆角 4 + 走 imageContentBuilder
///
/// **简化**:
/// - 子包不依赖 visibility_detector,瓦片不做 lazy load(主项目可在
///   imageContentBuilder 内自管 lazy load)
/// - carousel 模式 fallback 为单列大图(主项目可注入 imageContentBuilder
///   或额外 builder 实现真 carousel)
///
/// images 内部是 [ImageRun] 列表 — 每个 ImageRun 已含 `lightboxUrl` /
/// `indexInPost`,渲染时复用现有图片路径(`imageContentBuilder`)。
@immutable
class ImageGridNode extends BlockNode {
  const ImageGridNode({
    required super.id,
    required this.images,
    this.columns = 2,
    this.mode = ImageGridMode.grid,
  });

  /// 网格内的图片列表(每张已是带 lightboxUrl 的 ImageRun)。
  final List<ImageRun> images;

  /// `data-columns` 列数,默认 2(与 legacy 一致)。
  final int columns;

  /// 展示形态(grid / carousel)。
  final ImageGridMode mode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImageGridNode &&
          runtimeType == other.runtimeType &&
          columns == other.columns &&
          mode == other.mode &&
          listEquals(images, other.images);

  @override
  int get hashCode => Object.hash(columns, mode, Object.hashAll(images));

  @override
  String toString() =>
      'ImageGridNode($id, ${images.length} images, cols=$columns, $mode)';
}

/// 单条脚注 entry —— 对应 `<li id="fn:x"><p>正文 <a class="footnote-backref">↩︎</a></p></li>`。
///
/// parser 解析 section.footnotes 时为每个 `<li>` 产一条,正文已 strip backref
/// 并解析成 [inlines](保留链接/格式/emoji,渲染走 InlineSpanText)。
@immutable
class FootnoteEntry {
  const FootnoteEntry({
    required this.id,
    required this.number,
    required this.inlines,
  });

  /// 锚点 id(`fn:abc`)。与 [FootnoteRefRun.fnId] 对应,供未来「点上标滚到底部」用。
  final String id;

  /// 显示编号(`<li>` 在列表中的序号文本,典型 "1"/"2")。
  final String number;

  /// 脚注正文 inline(已 strip backref,保留链接/样式/emoji)。
  final List<InlineNode> inlines;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FootnoteEntry &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          number == other.number &&
          _listEq(inlines, other.inlines);

  @override
  int get hashCode => Object.hash(id, number, Object.hashAll(inlines));

  @override
  String toString() => 'FootnoteEntry(#$number $id, ${inlines.length} inlines)';
}

/// 列表浅比较(顺序敏感)。
bool _listEq(List<Object?> a, List<Object?> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 脚注列表区域 — `<section class="footnotes">` / `<ol class="footnotes-list">`。
///
/// 渲染:**底部脚注区**(上分隔线 + 编号悬挂列表),见 NodeFactory.buildFootnotesSection。
///
/// 设计取舍:legacy `buildFootnotesList` 返回 `SizedBox.shrink()`(只靠 sup popover),
/// 但截图分享 / 长文通读场景下 popover 不可用 / 不便,故本引擎额外渲染底部列表。
/// 与上标 [FootnoteRefRun] 的 popover **并存**:上标点按即时预览,底部列表完整可读。
/// [entries] 为空时本节点渲染 `SizedBox.shrink()`(退化为隐藏,行为同 legacy)。
@immutable
class FootnotesSectionNode extends BlockNode {
  const FootnotesSectionNode({
    required super.id,
    this.entries = const [],
  });

  /// 有序脚注条目(按 `<li>` 出现序)。
  final List<FootnoteEntry> entries;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FootnotesSectionNode &&
          runtimeType == other.runtimeType &&
          _listEq(entries, other.entries);

  @override
  int get hashCode => Object.hashAll(entries);

  @override
  String toString() => 'FootnotesSectionNode($id, ${entries.length} entries)';
}

/// 懒加载视频的视频源平台 — 对齐 legacy `data-provider-name`。
///
/// 子包不实现真 embed iframe(需要 webview_flutter,跨平台依赖重)。
/// 主项目通过 [lazyVideoBuilder] callback 注入 IframeWidget;不传 callback
/// 时子包只画缩略图卡片,点击降级为打开 url。
enum LazyVideoProvider {
  /// `data-provider-name="youtube"` — 品牌色 #FF0000
  youtube,

  /// `data-provider-name="vimeo"` — 品牌色 #1AB7EA
  vimeo,

  /// `data-provider-name="tiktok"` — 品牌色 #010101
  tiktok,

  /// 其他 / 缺失 provider — 灰色兜底
  other;

  static LazyVideoProvider fromName(String name) => switch (name) {
        'youtube' => LazyVideoProvider.youtube,
        'vimeo' => LazyVideoProvider.vimeo,
        'tiktok' => LazyVideoProvider.tiktok,
        _ => LazyVideoProvider.other,
      };
}

/// 懒加载视频 — `<div class="lazy-video-container">`。
///
/// HTML 形态:
/// ```html
/// <div class="lazy-video-container"
///      data-provider-name="youtube"
///      data-video-id="abc123"
///      data-video-title="..."
///      data-video-start-time="1m30s">
///   <a class="title-link" href="https://youtube.com/watch?v=abc123">
///     <img src="缩略图.jpg" />
///   </a>
/// </div>
/// ```
///
/// 视觉对齐 legacy `lazy_video_builder.dart::_buildThumbnail`:
///   Padding vertical 8 + ClipRRect 圆角 8 + 黑底
///   AspectRatio 16:9 缩略图 + 中央播放按钮(品牌色 60x42)
///   底部标题栏(可点跳 url + onSurfaceVariant 灰底 0.5)
///
/// **简化**:
/// - 子包不嵌 iframe(无 webview 依赖),点击缩略图调 [lazyVideoTapHandler]
///   或 [linkHandler](fallback)
/// - 主项目通过 `lazyVideoBuilder` 注入自定义 iframe widget(替换默认卡片)
@immutable
class LazyVideoNode extends BlockNode {
  const LazyVideoNode({
    required super.id,
    required this.provider,
    required this.videoId,
    this.title = '',
    this.thumbnailUrl = '',
    this.startTime = '',
    this.url = '',
  });

  /// 视频源(youtube / vimeo / tiktok / other)。
  final LazyVideoProvider provider;

  /// `data-video-id`,主项目 builder 用它拼 embed URL。
  final String videoId;

  /// `data-video-title`(可空)。
  final String title;

  /// 缩略图 src(典型为 youtube/vimeo CDN 的预览图)。
  final String thumbnailUrl;

  /// `data-video-start-time`,形如 `"1h30m45s"` 或纯秒(主项目拼 embed 用)。
  final String startTime;

  /// 真实视频链接(典型为 https://youtube.com/watch?v=...)。
  /// 子包点击缩略图时降级:tap → linkHandler(url) 跳浏览器。
  final String url;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LazyVideoNode &&
          runtimeType == other.runtimeType &&
          provider == other.provider &&
          videoId == other.videoId &&
          title == other.title &&
          thumbnailUrl == other.thumbnailUrl &&
          startTime == other.startTime &&
          url == other.url;

  @override
  int get hashCode => Object.hash(
        provider,
        videoId,
        title,
        thumbnailUrl,
        startTime,
        url,
      );

  @override
  String toString() =>
      'LazyVideoNode($id, $provider/$videoId'
      '${title.isEmpty ? "" : ", \"$title\""})';
}

/// 嵌入 iframe — `<iframe src="..." width="..." height="...">`。
///
/// 形态(legacy `iframe_builder.dart::IframeAttributes` 同结构):
/// ```html
/// <iframe src="https://www.youtube.com/embed/..."
///         width="560" height="315"
///         allowfullscreen
///         allow="autoplay; encrypted-media"
///         sandbox="allow-scripts allow-same-origin"
///         referrerpolicy="no-referrer"
///         loading="lazy"
///         title="嵌入视频">
/// </iframe>
/// ```
///
/// **子包不实现 webview 渲染**(无 webview_flutter 依赖,跨平台插件量大)。
/// 渲染策略:
/// - 主项目通过 `iframeBuilder` callback 注入真实 webview widget
/// - 不传 builder 时子包用内置占位卡(图标 + 域名 + "打开链接" 按钮,
///   点击调 [linkHandler] 跳浏览器)
///
/// [src] / [width] / [height] / [title] 是主项目 webview 的核心入参;
/// [sandboxFlags] / [allowFlags] / [allowFullscreen] / [referrerPolicy]
/// 主项目按 webview_flutter 的 settings 映射。
@immutable
class IframeNode extends BlockNode {
  const IframeNode({
    required super.id,
    required this.src,
    this.width,
    this.height,
    this.title,
    this.sandboxFlags = const {},
    this.allowFlags = const {},
    this.allowFullscreen = false,
    this.referrerPolicy,
    this.lazyLoad = false,
    this.cssClasses = const {},
  });

  /// iframe 真实 URL(`src` 或 `data-src` 提取,`data-src` 是 lazy load 形态)。
  /// 空字符串 = 渲染时降级显示"无效 iframe"。
  final String src;

  /// `width` 属性,缺失时 null(主项目应用 layout 默认值,如 16:9)。
  final double? width;

  /// `height` 属性,缺失时 null。
  final double? height;

  /// `title` 属性 — webview 头部 / accessibility。
  final String? title;

  /// `sandbox="..."` 属性 split 后的集合(如 `{allow-scripts, allow-same-origin}`)。
  final Set<String> sandboxFlags;

  /// `allow="..."` Permissions Policy split 后的集合(如
  /// `{autoplay, encrypted-media, picture-in-picture}`)。
  final Set<String> allowFlags;

  /// `allowfullscreen` 属性或 `allow="fullscreen ..."`(legacy 同处理)。
  final bool allowFullscreen;

  /// `referrerpolicy` 属性(如 `no-referrer`)。
  final String? referrerPolicy;

  /// `loading="lazy"` — 主项目可挂 visibility_detector 控制 webview 加载时机。
  final bool lazyLoad;

  /// iframe 元素的 class(如 `{tiktok-onebox, embed}`),主项目按 class
  /// 做平台特定处理。
  final Set<String> cssClasses;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IframeNode &&
          runtimeType == other.runtimeType &&
          src == other.src &&
          width == other.width &&
          height == other.height &&
          title == other.title &&
          allowFullscreen == other.allowFullscreen &&
          referrerPolicy == other.referrerPolicy &&
          lazyLoad == other.lazyLoad &&
          setEquals(sandboxFlags, other.sandboxFlags) &&
          setEquals(allowFlags, other.allowFlags) &&
          setEquals(cssClasses, other.cssClasses);

  @override
  int get hashCode => Object.hash(
        src,
        width,
        height,
        title,
        allowFullscreen,
        referrerPolicy,
        lazyLoad,
        Object.hashAll(sandboxFlags),
        Object.hashAll(allowFlags),
        Object.hashAll(cssClasses),
      );

  @override
  String toString() => 'IframeNode($id, $src)';
}

/// 原生上传视频 — Discourse 上传的 mp4 等。
///
/// **两种 cooked 形态都映射到本节点**(parser 统一处理):
/// 1. **video-placeholder 形态(linux.do 主形态)**:
///    ```html
///    <div class="video-placeholder-container"
///         data-video-src="/uploads/.../x.mp4"
///         data-thumbnail-src="/uploads/.../x.png"
///         data-orig-src="upload://xxx.mp4"></div>
///    ```
///    真正的 `<video>` 是 Discourse web 端运行时(video-placeholder.js)注入的,
///    cooked 里只有这个空 div。App 拿原始 cooked,所以这是最常见形态。
///    src 取 `data-video-src`,poster 取 `data-thumbnail-src`。
/// 2. **直接 video 形态(旧式 / 直链 / onebox video-onebox)**:
///    ```html
///    <div class="onebox video-onebox">
///      <video width="100%" height="100%" controls>
///        <source src="http://x/running.mp4" type="video/mp4">
///      </video>
///    </div>
///    ```
///    src 取首个 `<source src>`(或 video[src]),poster 取 `video[poster]`。
///
/// 视觉对齐 legacy `DiscourseVideoPlayer`(chewie):AspectRatio 包播放器,
/// 有 width/height 用 w/h 比否则 16:9,封面 poster,controls 常开。
///
/// **子包不绑 chewie/video_player**(平台插件重):通过 [VideoBuilder] callback
/// 让主项目注入真播放器;不传时画占位卡(封面/图标 + "播放视频" + 点击降级
/// linkHandler 跳浏览器)。
///
/// [src] 可能是 `upload://` 短链(主项目负责解析成真实 URL)或 http(s) 直链或
/// 站内相对路径;空串 = 无有效源,渲染降级。
@immutable
class VideoNode extends BlockNode {
  const VideoNode({
    required super.id,
    required this.src,
    this.poster,
    this.width,
    this.height,
    this.mime,
    this.loop = false,
    this.origSrc,
  });

  /// 播放源 URL(`data-video-src` / 首个 `source[src]` / `video[src]`)。
  /// 可能是 `upload://` 短链;空串表示无有效源。
  final String src;

  /// `data-orig-src` 的 `upload://` 短链(baked/预览 cooked 都可能带)。
  /// markdown 序列化写回 `![|video](短链)` 用 —— raw 的规范形态是短链,
  /// 写 CDN URL 会让服务端把站内上传当外链重新拉取。
  final String? origSrc;

  /// 封面图 URL(`data-thumbnail-src` / `video[poster]`),可空。
  final String? poster;

  /// `width` 属性数值(`100%` 等非数字 → null,主项目用 16:9 兜底)。
  final double? width;

  /// `height` 属性数值(同上)。
  final double? height;

  /// 首个 `source[type]`(如 `video/mp4`),可空。
  final String? mime;

  /// `video[loop]` 属性,默认 false。
  final bool loop;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoNode &&
          runtimeType == other.runtimeType &&
          src == other.src &&
          poster == other.poster &&
          width == other.width &&
          height == other.height &&
          mime == other.mime &&
          loop == other.loop &&
          origSrc == other.origSrc;

  @override
  int get hashCode =>
      Object.hash(src, poster, width, height, mime, loop, origSrc);

  @override
  String toString() =>
      'VideoNode($id, $src${poster == null ? "" : ", poster"}'
      '${loop ? ", loop" : ""})';
}

/// 原生上传音频 — Discourse 上传的 mp3 等。
///
/// cooked 形态(终态,无运行时注入):
/// ```html
/// <audio preload="metadata" controls>
///   <source src="/uploads/.../x.mp3" data-orig-src="upload://xxx.mp3">
///   <a href="/uploads/.../x.mp3">/uploads/.../x.mp3</a>
/// </audio>
/// ```
/// src 取首个 `<source src>`(或 audio[src]);[title] 取内层 `<a>` 文本(常是
/// URL,可空,fallback 占位卡显示用)。
///
/// legacy 走 fwfh_just_audio 默认音频条;子包不绑 just_audio,通过
/// [AudioBuilder] callback 让主项目注入(主项目用 just_audio);不传时画
/// 占位卡(音乐图标 + 文件名 + 点击降级 linkHandler)。
@immutable
class AudioNode extends BlockNode {
  const AudioNode({
    required super.id,
    required this.src,
    this.title,
    this.mime,
    this.origSrc,
    this.voice = false,
  });

  /// 播放源 URL(首个 `source[src]` / `audio[src]`)。可能是 `upload://` 短链;
  /// 空串表示无有效源。
  final String src;

  /// `data-orig-src` 的 `upload://` 短链。markdown 序列化写回
  /// `![|audio](短链)` 用(同 VideoNode.origSrc)。
  final String? origSrc;

  /// 内层 `<a>` 文本(常是 URL),fallback 占位卡显示用,可空。
  final String? title;

  /// 首个 `source[type]`(如 `audio/mpeg`),可空。
  final String? mime;

  /// 语音消息(`[wrap=voice]` 容器内的 audio,本 app 约定):渲染成
  /// 紧凑语音条而非通用音频播放器。网页端无此概念 —— d-wrap 只是
  /// 无样式 div,原生 controls 照常。
  final bool voice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioNode &&
          runtimeType == other.runtimeType &&
          src == other.src &&
          title == other.title &&
          mime == other.mime &&
          origSrc == other.origSrc &&
          voice == other.voice;

  @override
  int get hashCode => Object.hash(src, title, mime, origSrc, voice);

  @override
  String toString() => 'AudioNode($id, $src)';
}

/// 表格单元格 — `<th>` / `<td>`。
///
/// [children] 是 cell 内 BlockNode 序列(parser 用 `_parseBlocks` 递归)。
/// 绝大多数 cell 就是 inline 内容(一个 ParagraphNode),少数 cell 含
/// list / quote 等块级 — children 模型一次性覆盖。
///
/// [isHeader] = `<th>` 或位于 `<thead>` 内的 cell。渲染时表头加粗 + 灰底。
///
/// 不是 BlockNode,只是 TableNode 内部数据结构(类似 ListItem)。
@immutable
class TableCellData {
  const TableCellData({
    required this.children,
    this.isHeader = false,
  });

  /// cell 内的块级子节点(递归 parse)。
  final List<BlockNode> children;

  /// 是否为表头单元格(`<th>` 或 thead 内的 `<td>`)。
  final bool isHeader;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TableCellData &&
          runtimeType == other.runtimeType &&
          isHeader == other.isHeader &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hash(isHeader, Object.hashAll(children));

  @override
  String toString() =>
      'TableCellData(${children.length} children${isHeader ? ", header" : ""})';
}

/// 表格 — `<table>`,含可选 `<thead>` + `<tbody>` + 任意 `<tr>` 行。
///
/// HTML 形态(典型 markdown table cooked):
/// ```html
/// <table>
///   <thead>
///     <tr><th>列1</th><th>列2</th></tr>
///   </thead>
///   <tbody>
///     <tr><td>值A</td><td>值B</td></tr>
///   </tbody>
/// </table>
/// ```
///
/// 视觉对齐 legacy `table_builder.dart`:
///   外:margin v8 + Container 灰边框 + 圆角 8 + 水平 SingleChildScrollView
///   表头(若有):surfaceContainerHighest 灰底 + 加粗
///   每 cell:fixed 列宽(预算 60..200 clamp)+ 8px padding + 列右 1px 分隔线
///   每行:底部 1px 分隔线
///   大表格(行数 > 30)用 ListView.builder 行虚拟化(子包简化:阈值
///   作为 [virtualizeThreshold] 字段暴露,主项目可调)
///
/// **简化(相对 legacy)**:
/// - 不实现 screenshotMode 分支(用 Table widget + FittedBox)— 主项目
///   截图场景可单独走自定义渲染
/// - 不持 `ScanBoundary`(主项目业务概念)
@immutable
class TableNode extends BlockNode {
  const TableNode({
    required super.id,
    required this.rows,
    required this.columnCount,
    this.hasHeader = false,
  });

  /// 全部行(含 header 行)。`hasHeader=true` 时第一行就是 header,
  /// 其余是 body;`hasHeader=false` 时全部 body。
  ///
  /// 这种"一锅烩"模型比拆 `headerRow + bodyRows` 简洁,渲染时按 index 0
  /// + hasHeader 判断,且能保留无 thead/tbody 标签时的原始顺序。
  final List<List<TableCellData>> rows;

  /// 列数 = `max(row.length for row in rows)`。
  /// 不够列数的行右侧补 SizedBox.shrink(legacy 同处理)。
  final int columnCount;

  /// 是否有表头行(`<thead>` 存在 或 第一行全 `<th>`)。
  final bool hasHeader;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TableNode &&
          runtimeType == other.runtimeType &&
          columnCount == other.columnCount &&
          hasHeader == other.hasHeader &&
          listEquals(rows.map(List.unmodifiable).toList(),
              other.rows.map(List.unmodifiable).toList());

  @override
  int get hashCode => Object.hash(
        columnCount,
        hasHeader,
        Object.hashAll(rows.map(Object.hashAll)),
      );

  @override
  String toString() =>
      'TableNode($id, ${rows.length} rows × $columnCount cols'
      '${hasHeader ? ", with header" : ""})';
}

/// Discourse policy 区块 — `<div class="policy" data-*="...">正文</div>`。
///
/// Discourse `discourse-policy` 插件渲染:
/// ```html
/// <div class="policy" data-version="1" data-groups="staff"
///      data-accept="我已阅读" data-revoke="取消"
///      data-renewal-days="30" data-renewal-start="..."
///      data-reminder="weekly" data-private="false">
///   <p>请阅读此政策...</p>
///   <ul><li>条款 1</li><li>条款 2</li></ul>
/// </div>
/// ```
///
/// 渲染对齐 legacy `policy_builder.dart::_PolicyWidget`:
///   外:边框容器(灰底 outline + 圆角 8 + margin v8)
///   body:子 BlockNode 递归渲染(走 compact factory)
///   footer:接受/撤销 按钮 + "X 人已接受" 状态
///
/// **子包不实现交互**:接受/撤销 涉及后端 API + 当前 post 状态,业务强
/// 耦合。子包只产 PolicyNode + 暴露 [PolicyBuilder] callback,主项目
/// 自己渲染整个 widget(含按钮 + 头像 + 接口调用)。
/// 不传 builder 时子包 fallback 渲染 body + 静态 footer 占位
/// (acceptLabel 按钮,无作用)。
@immutable
class PolicyNode extends BlockNode {
  const PolicyNode({
    required super.id,
    required this.children,
    this.version,
    this.groups,
    this.acceptLabel,
    this.revokeLabel,
    this.renewalDays,
    this.renewalStart,
    this.reminder,
    this.isPrivate = false,
    this.rawHtml = '',
  });

  /// policy 正文 BlockNode(parser 已剥可选 .policy-body 外层 div)。
  final List<BlockNode> children;

  /// `data-version`(任意字符串,主项目按需 parse 成 int)。
  final String? version;

  /// `data-groups`,逗号分隔的允许接受的用户组。
  final String? groups;

  /// `data-accept`,自定义接受按钮文案(空时主项目用默认 "接受")。
  final String? acceptLabel;

  /// `data-revoke`,自定义撤销按钮文案(空时主项目用默认 "撤销")。
  final String? revokeLabel;

  /// `data-renewal-days`,接受后多少天需要重新确认。
  final String? renewalDays;

  /// `data-renewal-start`,重新确认起始时间(ISO 字符串)。
  final String? renewalStart;

  /// `data-reminder`,提醒频率(daily/weekly 等)。
  final String? reminder;

  /// `data-private`,是否私密(只本人能看接受列表)。
  final bool isPrivate;

  /// 原始 cooked HTML 片段(`<div class="policy">...</div>` outerHtml)。
  /// 给主项目 [PolicyBuilder] 兜底用:legacy `_PolicyWidget` 通过
  /// `element.innerHtml` 走 DiscourseHtmlContent 完整渲染富文本 body(链接 /
  /// strong / em 等)。子包 BlockNode 无法精确反构造完整 HTML,所以
  /// rawHtml 是唯一干净路径。
  ///
  /// 主项目 PolicyBuilder 不强制使用,可选 children(BlockNode)走子包
  /// fallback 渲染(简化版,fixture 自检足够)。
  final String rawHtml;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PolicyNode &&
          runtimeType == other.runtimeType &&
          version == other.version &&
          groups == other.groups &&
          acceptLabel == other.acceptLabel &&
          revokeLabel == other.revokeLabel &&
          renewalDays == other.renewalDays &&
          renewalStart == other.renewalStart &&
          reminder == other.reminder &&
          isPrivate == other.isPrivate &&
          rawHtml == other.rawHtml &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hash(
        version,
        groups,
        acceptLabel,
        revokeLabel,
        renewalDays,
        renewalStart,
        reminder,
        isPrivate,
        rawHtml,
        Object.hashAll(children),
      );

  @override
  String toString() =>
      'PolicyNode($id, ${children.length} children'
      '${version == null ? "" : ", v$version"}'
      '${groups == null ? "" : ", groups=$groups"})';
}

/// 块级数学公式 — `<div class="math">LaTeX 源码</div>`。
///
/// Discourse 用 markdown-it-math 插件渲染:
/// - 块级:`$$...$$` 或 `\[...\]` → `<div class="math">`
/// - 行内:`$...$` 或 `\(...\)` → `<span class="math">`(行内见 MathInlineRun)
///
/// 子包**不绑** `flutter_math_fork`(依赖大,跨场景包体压力):
/// 通过 [MathBlockBuilder] callback 让主项目接入。fallback 显示
/// monospace `$latex$` 原文(对齐 legacy `onErrorFallback`)。
///
/// 视觉对齐 legacy `math_builder.dart::buildMathBlock`:
///   Padding v8 + Center + 水平 SingleChildScrollView(超长公式可滑)
@immutable
class MathBlockNode extends BlockNode {
  const MathBlockNode({
    required super.id,
    required this.latex,
  });

  /// LaTeX 源码(已 trim)。空 = 无效公式,渲染时显示空 SizedBox。
  final String latex;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MathBlockNode &&
          runtimeType == other.runtimeType &&
          latex == other.latex;

  @override
  int get hashCode => latex.hashCode;

  @override
  String toString() => 'MathBlockNode($id, ${latex.length} chars)';
}

/// 内容型内联 SVG — `<svg viewBox="...">...</svg>`(用户在帖子里粘贴的
/// 矢量图 / 图表,**非** Discourse 的 d-icon UI 图标)。
///
/// parser 判定(对齐 legacy `_buildInlineSvg` discourse_html_content_widget.dart:943):
/// - **跳过**(不产本节点):`class` 含 `d-icon` 的 UI 图标;或既无 `viewBox`
///   又无显式 `width`/`height` 的占位 svg(`<svg><use href="#far-image"/></svg>`)。
/// - **产节点**:有 `viewBox` 或有显式宽高的内容 svg。
///
/// 子包**不绑 `jovial_svg`**(依赖轻量化,对齐 math/iframe):只持原始 svg
/// 源串 [svgSource],主项目通过 [SvgBuilder] callback 用 `ScalableImage`
/// `.fromSvgString` 渲染。不传 builder 时子包 fallback 画占位框(图标 + 提示)。
///
/// 视觉(主项目接 builder 后,对齐 legacy):LayoutBuilder 取可用宽 → 按 svg
/// viewport 宽高比等比铺满整列宽(`fit: BoxFit.contain`)。
@immutable
class SvgNode extends BlockNode {
  const SvgNode({
    required super.id,
    required this.svgSource,
    this.width,
    this.height,
  });

  /// svg 元素的 `outerHtml` 原始源串(parser 直接取,不做任何改写)。
  /// 主项目喂给 `ScalableImage.fromSvgString`。
  final String svgSource;

  /// `width` 属性数值(px),缺失时 null —— 主项目优先用 svg viewport 自带尺寸。
  final double? width;

  /// `height` 属性数值(px),缺失时 null。
  final double? height;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SvgNode &&
          runtimeType == other.runtimeType &&
          svgSource == other.svgSource &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(svgSource, width, height);

  @override
  String toString() =>
      'SvgNode($id, ${svgSource.length} chars'
      '${width == null ? "" : ", ${width}x$height"})';
}

/// 投票块 — `<div class="poll" data-poll-name="...">`(Discourse poll 插件)。
///
/// **数据全在 API 不在 cooked**:cooked 里的 poll div 只提供 [pollName]
/// (+ 标题文本 fallback)用来从 `post.polls` match 出真实数据(选项 /
/// 票数 / 状态 / 用户投票)。投票交互要调后端 API。
///
/// 子包不持 poll 数据 / 不依赖业务 service:只产轻量节点(pollName +
/// title + rawHtml),整个渲染+交互由主项目 [PollBuilder] 接 legacy
/// `buildPoll(post: post)`。不传 builder 时 fallback 占位卡。
@immutable
class PollNode extends BlockNode {
  const PollNode({
    required super.id,
    required this.pollName,
    this.title,
    this.rawHtml = '',
  });

  /// `data-poll-name`(默认 "poll"),主项目用它从 post.polls match。
  final String pollName;

  /// poll 标题(data-poll-question / data-poll-title / .poll-title 文本),
  /// 可空。fallback 占位卡显示用。
  final String? title;

  /// 原始 cooked 片段(`<div class="poll">...</div>` outerHtml)。
  /// 给主项目 PollBuilder 喂给 legacy buildPoll(它读 data-poll-name 等)。
  final String rawHtml;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PollNode &&
          runtimeType == other.runtimeType &&
          pollName == other.pollName &&
          title == other.title &&
          rawHtml == other.rawHtml;

  @override
  int get hashCode => Object.hash(pollName, title, rawHtml);

  @override
  String toString() =>
      'PollNode($id, name=$pollName${title == null ? "" : ", \"$title\""})';
}

/// 聊天记录块 — `<div class="chat-transcript">`(Discourse chat 转帖)。
///
/// 纯 DOM 驱动(不依赖 post API,对齐 onebox)。结构:
/// ```html
/// <div class="chat-transcript [chat-transcript-chained]"
///      data-username="..." data-datetime="ISO" data-channel-name="...">
///   <img class="avatar" src="...">
///   <div class="chat-transcript-messages">消息 HTML(可递归)</div>
///   <div class="chat-transcript-reactions">...</div>
///   <details><summary>...thread-header__title...</summary></details>
/// </div>
/// ```
///
/// 子包存结构化字段(给 fallback 用)+ [rawHtml]。主项目 [ChatTranscriptBuilder]
/// 把 rawHtml 喂给 legacy buildChatTranscript(消息内容走 htmlBuilder 递归)。
@immutable
class ChatTranscriptNode extends BlockNode {
  const ChatTranscriptNode({
    required super.id,
    required this.username,
    this.avatarUrl,
    this.datetime,
    this.channelName,
    this.isChained = false,
    this.messagesHtml = '',
    this.rawHtml = '',
  });

  /// `data-username`。
  final String username;

  /// `img.avatar` 的 src(原始 URL,主项目 fallback 用 SmartAvatar 渲染)。
  final String? avatarUrl;

  /// `data-datetime`(ISO 8601 字符串)。
  final String? datetime;

  /// `data-channel-name`(可空)。
  final String? channelName;

  /// `chat-transcript-chained` class(链式引用,去边框/margin 紧贴上一条)。
  final bool isChained;

  /// `.chat-transcript-messages` 的 innerHtml(消息内容,fallback 显示纯文本)。
  final String messagesHtml;

  /// 原始 `<div class="chat-transcript">` outerHtml。
  /// 主项目 ChatTranscriptBuilder 喂给 legacy buildChatTranscript。
  final String rawHtml;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatTranscriptNode &&
          runtimeType == other.runtimeType &&
          username == other.username &&
          avatarUrl == other.avatarUrl &&
          datetime == other.datetime &&
          channelName == other.channelName &&
          isChained == other.isChained &&
          messagesHtml == other.messagesHtml &&
          rawHtml == other.rawHtml;

  @override
  int get hashCode => Object.hash(
        username,
        avatarUrl,
        datetime,
        channelName,
        isChained,
        messagesHtml,
        rawHtml,
      );

  @override
  String toString() =>
      'ChatTranscriptNode($id, @$username'
      '${channelName == null ? "" : " #$channelName"}'
      '${isChained ? ", chained" : ""})';
}

/// 定义列表的单个条目 — 一个 `<dt>`(术语)+ 其后紧邻的若干 `<dd>`(释义)。
///
/// 不是 BlockNode,只是 DefinitionListNode 内部的数据结构(类似 ListItem /
/// TableCellData)。
///
/// 对齐浏览器/fwfh 默认:一个 dt 可后跟 0..N 个 dd;允许「孤儿 dd」(无前置 dt,
/// term 为空)与「孤儿 dt」(无后续 dd,definitions 为空)。
@immutable
class DefinitionItem {
  const DefinitionItem({
    this.term = const [],
    this.definitions = const [],
  });

  /// `<dt>` 的行内内容(术语)。孤儿 dd 形态下为空。
  final List<InlineNode> term;

  /// 该 dt 后紧邻的所有 `<dd>`,每个 dd 是一组块级子节点(走 _parseBlocks,
  /// 支持 dd 内 p/list/blockquote 等)。孤儿 dt 形态下为空。
  final List<List<BlockNode>> definitions;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DefinitionItem &&
          runtimeType == other.runtimeType &&
          listEquals(term, other.term) &&
          listEquals(
            definitions.map(List.unmodifiable).toList(),
            other.definitions.map(List.unmodifiable).toList(),
          );

  @override
  int get hashCode => Object.hash(
        Object.hashAll(term),
        Object.hashAll(definitions.map(Object.hashAll)),
      );

  @override
  String toString() =>
      'DefinitionItem(${term.length} term inlines, ${definitions.length} dd)';
}

/// 定义列表 — `<dl>`,含若干 `<dt>`/`<dd>` 配对。
///
/// 对应 HTML `<dl>...</dl>`。Discourse cooked 里 markdown 不产 dl,但富文本/
/// HTML 帖可含。样式对齐 Discourse `.cooked` CSS:
///   dl: margin 1em 0;dt: 块级、字重正常(不加粗);dd: margin 1em 0 1em 1.25em。
/// 新引擎:外层上下 8(与 ListNode 同档);dt 常规字重;dd 左缩进 1.25em。
@immutable
class DefinitionListNode extends BlockNode {
  const DefinitionListNode({
    required super.id,
    required this.items,
  });

  /// dt/dd 配对条目序列。
  final List<DefinitionItem> items;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DefinitionListNode &&
          runtimeType == other.runtimeType &&
          listEquals(items, other.items);

  @override
  int get hashCode => Object.hashAll(items);

  @override
  String toString() => 'DefinitionListNode($id, ${items.length} items)';
}

/// 数一份 BlockNode 树里所有 [ImageRun] 的总数。
///
/// FluxdoRender 在 parse 完成后调用一次,把结果通过 NodeFactory 传到
/// ImageContentBuilder。这里是**所有内容图**口径,不等同于 Discourse
/// lightbox/gallery 口径。
int countImageRuns(List<BlockNode> nodes) => collectImageRuns(nodes).length;

/// 按出现顺序收集一份 BlockNode 树里所有 [ImageRun](顺序 = parser 赋的
/// indexInPost 顺序)。
///
/// 遍历范围与 [countImageRuns] 完全一致(后者 = 本函数结果的长度)。如需
/// 对齐 Discourse Web 的 lightbox/gallery,使用 [collectLightboxImageRuns]。
List<ImageRun> collectImageRuns(List<BlockNode> nodes) {
  final out = <ImageRun>[];
  void scanInlines(List<InlineNode> inlines) {
    for (final n in inlines) {
      switch (n) {
        case ImageRun():
          out.add(n);
        case EmRun(:final children):
          scanInlines(children);
        case StrongRun(:final children):
          scanInlines(children);
        case StyledRun(:final children):
          scanInlines(children);
        case ColoredRun(:final children):
          scanInlines(children);
        case SizedRun(:final children):
          scanInlines(children);
        case LinkRun(:final children):
          scanInlines(children);
        case SpoilerRun(:final children):
          scanInlines(children);
        case TextRun():
        case LineBreakRun():
        case InlineCodeRun():
        case EmojiRun():
        case MentionRun():
        case FootnoteRefRun():
        case LocalDateRun():
        case ClickCountRun():
        case MathInlineRun():
          break;
      }
    }
  }

  void scanBlock(BlockNode b) {
    switch (b) {
      case ParagraphNode(:final inlines):
        scanInlines(inlines);
      case HeadingNode(:final inlines):
        scanInlines(inlines);
      case ListNode(:final items):
        for (final item in items) {
          final blocks = item.blocks;
          if (blocks != null) {
            for (final block in blocks) {
              scanBlock(block);
            }
          } else {
            scanInlines(item.inlines);
            if (item.children != null) {
              for (final sub in item.children!) {
                scanBlock(sub);
              }
            }
          }
        }
      case BlockquoteNode(:final children):
        for (final c in children) {
          scanBlock(c);
        }
      case QuoteCardNode(:final children):
        for (final c in children) {
          scanBlock(c);
        }
      case SpoilerBlockNode(:final children):
        for (final c in children) {
          scanBlock(c);
        }
      case HorizontalRuleNode():
        break;
      case BlankLineNode():
        break;
      case CodeBlockNode():
        break;
      case OneboxNode():
        // onebox 内部图片(thumbnail / favicon)不计入 ImageRun gallery
        break;
      case DetailsNode(:final children):
        for (final c in children) {
          scanBlock(c);
        }
      case CalloutNode(:final children):
        for (final c in children) {
          scanBlock(c);
        }
      case ImageGridNode(:final images):
        // 网格内 ImageRun 直接收(它们也是有效的 post 图片,跟 gallery
        // viewer 协作)
        out.addAll(images);
      case FootnotesSectionNode():
        break;
      case LazyVideoNode():
        break;
      case IframeNode():
        break;
      case TableNode(:final rows):
        for (final row in rows) {
          for (final cell in row) {
            for (final c in cell.children) {
              scanBlock(c);
            }
          }
        }
      case PolicyNode(:final children):
        for (final c in children) {
          scanBlock(c);
        }
      case MathBlockNode():
        break;
      case SvgNode():
        // 内容 svg 不计入 ImageRun(它不走 imageContentBuilder / 画廊)
        break;
      case PollNode():
        break;
      case ChatTranscriptNode():
        break;
      case VideoNode():
        // 视频封面不计入帖子图片画廊
        break;
      case AudioNode():
        break;
      case DefinitionListNode(:final items):
        for (final item in items) {
          scanInlines(item.term);
          for (final dd in item.definitions) {
            for (final c in dd) {
              scanBlock(c);
            }
          }
        }
    }
  }

  for (final b in nodes) {
    scanBlock(b);
  }
  return out;
}

/// 按 Discourse Web lightbox 口径收集可进入 Photoswipe/gallery 的图片。
///
/// Web 版 `lightbox(elem)` 的数据源来自 DOM 里的 `a.lightbox`,不是所有
/// `<img>`。因此裸图仍可单图打开,但不参与同帖左右切换。
List<ImageRun> collectLightboxImageRuns(List<BlockNode> nodes) {
  return collectImageRuns(nodes)
      .where((image) => image.lightboxUrl != null)
      .toList(growable: false);
}
