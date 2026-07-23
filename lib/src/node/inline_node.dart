/// 行内节点 sealed family。
///
/// 阶段 1 范围:Text / Em / Strong / LineBreak / Link / InlineCode / Emoji /
/// Mention / Image / Spoiler
/// 后续会扩展更多行内节点。

library;

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

/// 所有行内节点的基类。
@immutable
sealed class InlineNode {
  const InlineNode();
}

/// 纯文本片段。
@immutable
class TextRun extends InlineNode {
  const TextRun(this.text);

  final String text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextRun &&
          runtimeType == other.runtimeType &&
          text == other.text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'TextRun(${text.length} chars)';
}

/// `<em>` / `<i>` 斜体,可包含嵌套行内子节点。
@immutable
class EmRun extends InlineNode {
  const EmRun({required this.children});

  final List<InlineNode> children;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EmRun &&
          runtimeType == other.runtimeType &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hashAll(children);

  @override
  String toString() => 'EmRun(${children.length} children)';
}

/// `<strong>` / `<b>` 粗体,可包含嵌套行内子节点。
@immutable
class StrongRun extends InlineNode {
  const StrongRun({required this.children});

  final List<InlineNode> children;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StrongRun &&
          runtimeType == other.runtimeType &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hashAll(children);

  @override
  String toString() => 'StrongRun(${children.length} children)';
}

/// 行内样式标签的样式种类(对齐 fwfh core_widget_factory 默认值)。
/// - [underline] `<u>`/`<ins>`:下划线
/// - [lineThrough] `<s>`/`<strike>`/`<del>`:删除线
/// - [small] `<small>`:字号 0.833x(fwfh smaller)
/// - [big] `<big>`:字号 1.2x(fwfh larger)
/// - [mark] `<mark>`:高亮(fwfh #ff0 底 / #000 字)
/// - [superscript] `<sup>` / [subscript] `<sub>`:上/下标(0.833x + 垂直偏移)
/// - [monospace] `<kbd>`/`<samp>`/`<tt>`:等宽字体(fwfh 默认仅等宽,非带框)
enum InlineStyleKind {
  underline,
  lineThrough,
  small,
  big,
  mark,
  superscript,
  subscript,
  monospace,
}

/// 行内样式包裹节点 —— 统一承载 fwfh 默认支持但新引擎此前漏掉的一批样式标签
/// (`<u>`/`<s>`/`<del>`/`<ins>`/`<small>`/`<big>`/`<mark>`/`<sup>`/`<sub>`/
/// `<kbd>`/`<samp>`/`<tt>`)。形态同 [EmRun]/[StrongRun]:按 [kind] 应用样式,
/// 可嵌套行内子节点。渲染分两类(见 InlineFlattener):
/// - 纯 TextStyle 类(下划/删除/small/big/mark/monospace)→ TextSpan(随文换行、
///   可选区);
/// - 需占位类(superscript/subscript 垂直偏移)→ WidgetSpan(占 1 ￼,投影原子)。
@immutable
class StyledRun extends InlineNode {
  const StyledRun({required this.kind, required this.children});

  final InlineStyleKind kind;
  final List<InlineNode> children;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StyledRun &&
          runtimeType == other.runtimeType &&
          kind == other.kind &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hash(kind, Object.hashAll(children));

  @override
  String toString() => 'StyledRun($kind, ${children.length} children)';
}

/// 行内 CSS 着色节点 —— 承载 `<span style="color:…/background-color:…">`(及
/// 其他带行内 color 的 inline 元素)的**值承载**样式(对齐 fwfh 默认读取
/// `style` 里的 color / background-color)。区别于枚举式 [StyledRun]:着色是
/// 任意值,不是固定 kind。Discourse 由 `[color=…]` / `[bgcolor=…]` BBCode 产出。
///
/// 形态同 [EmRun]:按 [color]/[background] 应用 TextStyle,可嵌套行内子节点。
/// 渲染走 TextSpan(随文换行、可选区);投影/图片计数对 [children] 透明递归。
/// [color] 与 [background] 至少一个非 null(parser 解析不出颜色时不建本节点)。
@immutable
class ColoredRun extends InlineNode {
  const ColoredRun({this.color, this.background, required this.children});

  /// 字色(`color`),无则 null。
  final Color? color;

  /// 背景色(`background-color`),无则 null。
  final Color? background;

  final List<InlineNode> children;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ColoredRun &&
          runtimeType == other.runtimeType &&
          color == other.color &&
          background == other.background &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hash(color, background, Object.hashAll(children));

  @override
  String toString() =>
      'ColoredRun(color: $color, bg: $background, ${children.length} children)';
}

/// 字号缩放(`<span style="font-size:N%">`;Discourse `[size=N]` BBCode 产出)。
///
/// [scale] 是**相对父字号的倍数**(网页端语义:`[size=150]` → `150%` →
/// 1.5;`[size=0]` → `0%` → 0 = 视觉隐藏)。阅读端对齐网页端原样生效,
/// 不夹上下限;编辑端把它当行内原子渲染成固定块(见 doc_converter),
/// 免得 0 倍隐形/超大撑破编辑器。
@immutable
class SizedRun extends InlineNode {
  const SizedRun({required this.scale, required this.children});

  /// 相对父字号的倍数(1.0 = 100%)。
  final double scale;

  final List<InlineNode> children;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SizedRun &&
          runtimeType == other.runtimeType &&
          scale == other.scale &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hash(scale, Object.hashAll(children));

  @override
  String toString() => 'SizedRun(${scale}x, ${children.length} children)';
}

/// `<br>` 强制换行。
@immutable
class LineBreakRun extends InlineNode {
  const LineBreakRun();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LineBreakRun;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'LineBreakRun()';
}

/// `<a href="...">` 链接,可嵌套行内子节点。
///
/// 点击行为不由子包决定 —— 渲染时通过 [NodeFactory.linkHandler] 注入,
/// 主项目负责 URL 路由(launchUrl / 内部话题跳转 / 用户卡跳转 等)。
///
/// **附件链接**(`<a class="attachment">`,Discourse 形如
/// `[name.pdf|attachment](upload://…)` cook 出来的下载链接):parser 命中
/// `class="attachment"` 时把 [isAttachment] 置 true,并把锚点文本(=文件名)
/// 抓进 [filename]。渲染(见 InlineFlattener._buildLinkSpan)在链接前加一个
/// 下载图标;点击优先走主项目注入的 [NodeFactory.onDownloadAttachment]
/// (带 href+filename → 内置下载器),未注入时降级到普通 linkHandler
/// (主项目 launchContentLink 内部仍能按 /uploads/ 路径识别附件并下载/外开)。
///
/// 阶段 1 暂不带 click_count 注入(那是 post.linkCounts 数据,跟主项目
/// model 强耦合),留到阶段 2 link 体系细化时再加。
@immutable
class LinkRun extends InlineNode {
  const LinkRun({
    required this.href,
    required this.children,
    this.isAttachment = false,
    this.filename = '',
    this.origHref,
    this.hashtagRef,
    this.isOneboxLink = false,
  });

  /// 已解析的链接 URL(parser 阶段不做 CDN 重写,显示给 LinkHandler)。
  final String href;

  /// 链接显示内容,可嵌套样式(em/strong)。
  final List<InlineNode> children;

  /// 是否是 Discourse 附件下载链接(`<a class="attachment">`)。
  /// true 时渲染加下载图标 + 点击走附件下载链路。
  final bool isAttachment;

  /// 附件文件名(锚点 textContent,如 `report.pdf`)。
  /// 仅 [isAttachment] 为 true 时有意义,作为下载建议文件名传给主项目。
  /// 可能为空串(锚点无文本时,主项目下载器会回退到 HEAD/URL 推断)。
  final String filename;

  /// `data-orig-href` 的 `upload://` 短链(客户端 cook 预览的附件形态:
  /// `href="/404" data-orig-href="upload://…"`)。markdown 序列化写回
  /// `[name|attachment](短链)` 时优先用它。服务端 baked 无此属性 → null。
  final String? origHref;

  /// hashtag 引用串(`<a class="hashtag-cooked">` 时非 null:取
  /// `data-ref` 优先,缺失时 `data-slug`)。markdown 序列化写回 `#{ref}`
  /// 而非普通链接 —— 否则往返后 hashtag 退化成死链接。渲染不受影响
  /// (仍走普通 LinkRun 链路)。
  final String? hashtagRef;

  /// onebox 系链接(`<a class="inline-onebox">` 行内 onebox,或
  /// `<a class="onebox">` 未展开的裸链)。两者 raw 里都是裸 URL:
  /// 行内 onebox 的锚文本是 cook 异步取回的页面标题(不能固化进 raw),
  /// 裸 onebox 链接的锚文本就是 URL 本身(写 `[url](url)` 会失去
  /// 独行 onebox 展开资格)。markdown 序列化一律写回裸 [href]。
  final bool isOneboxLink;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LinkRun &&
          runtimeType == other.runtimeType &&
          href == other.href &&
          isAttachment == other.isAttachment &&
          filename == other.filename &&
          origHref == other.origHref &&
          hashtagRef == other.hashtagRef &&
          isOneboxLink == other.isOneboxLink &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hash(href, isAttachment, filename, origHref,
      hashtagRef, isOneboxLink, Object.hashAll(children));

  @override
  String toString() => 'LinkRun($href'
      '${isAttachment ? ", attachment=$filename" : ""}'
      '${hashtagRef == null ? "" : ", #$hashtagRef"}'
      ', ${children.length} children)';
}

/// `<code>` 行内代码片段。
///
/// 设计上**只持纯文本**,不再嵌套样式(跟浏览器 `<code>` 实际行为一致 ——
/// `<code>` 内的 `<strong>` 在 Discourse cooked 里会被保留,但视觉上
/// monospace 已盖住样式;且 inline code 主要意图是展示原始字面值,
/// 嵌套样式只会带来视觉噪音)。parser 收到嵌套样式时把所有 textContent
/// 拼成一段。
@immutable
class InlineCodeRun extends InlineNode {
  const InlineCodeRun(this.text);

  final String text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InlineCodeRun &&
          runtimeType == other.runtimeType &&
          text == other.text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'InlineCodeRun(${text.length} chars)';
}

/// `<img class="emoji">` 行内表情图。
///
/// Discourse cooked 形态:
/// ```html
/// <img src="https://.../images/emoji/twitter/heart.png" alt=":heart:"
///      class="emoji" title=":heart:">
/// <img src="..." class="emoji only-emoji">  <!-- 整段独立大表情 -->
/// ```
///
/// 子包**不实际加载图片**:渲染时通过 [NodeFactory.emojiImageBuilder]
/// callback 由主项目注入(主项目用 emojiImageProvider + 独立缓存池)。
/// 子包默认 fallback 是 `Image.network`,便于 example gallery 演示。
///
/// **尺寸约定**:
/// - 普通 emoji:1em(跟随父字号,h1 里比 p 里大)
/// - only-emoji:32dp(对齐 Discourse `img.emoji.only-emoji { 32px }`)
@immutable
class EmojiRun extends InlineNode {
  const EmojiRun({
    required this.name,
    required this.url,
    this.isOnlyEmoji = false,
  });

  /// emoji 短名,如 'heart' / ':heart:' 去掉冒号,主要给可访问性 + 选区文本用。
  /// 可能为空串(alt/title 缺失时)。
  final String name;

  /// 完整图片 URL(parser 直接从 src 提取,**不做 CDN 重写**;
  /// CDN 重写由主项目在 emojiImageBuilder 内处理)。
  final String url;

  /// `class="only-emoji"` —— 整段仅含 emoji 的大表情,显示 32dp。
  final bool isOnlyEmoji;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EmojiRun &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          url == other.url &&
          isOnlyEmoji == other.isOnlyEmoji;

  @override
  int get hashCode => Object.hash(name, url, isOnlyEmoji);

  @override
  String toString() =>
      'EmojiRun($name${isOnlyEmoji ? ", only" : ""}, $url)';
}

/// `<a class="mention" href="/u/username">@username</a>` 用户提及。
///
/// 跟 LinkRun 是**平级 sibling**(parser 看到 a.mention 时优先产 MentionRun,
/// 不产 LinkRun)—— 因为 mention 的视觉/交互完全独立于普通链接:
/// chip 样式(灰底圆角)+ 跳用户卡(不是 launchUrl)。
///
/// 状态 emoji([statusEmoji])是 Discourse 注入到 mention link 内的
/// `<img class="emoji mention-status">`(显示用户在线/状态),parser
/// 把它从 a 子树里挑出来填到这个字段。**渲染时 emoji 在 username 右侧**。
///
/// tap 路由由主项目通过 [MentionTapHandler] 注入。
@immutable
class MentionRun extends InlineNode {
  const MentionRun({
    required this.username,
    required this.href,
    this.statusEmoji,
  });

  /// 去掉 `@` 前缀的纯用户名,如 `alice`。
  final String username;

  /// a 标签的 href 原值,如 `/u/alice`(parser 不做 URL 重写)。
  final String href;

  /// 用户状态 emoji(可选)。
  final EmojiRun? statusEmoji;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MentionRun &&
          runtimeType == other.runtimeType &&
          username == other.username &&
          href == other.href &&
          statusEmoji == other.statusEmoji;

  @override
  int get hashCode => Object.hash(username, href, statusEmoji);

  @override
  String toString() =>
      'MentionRun(@$username, $href${statusEmoji == null ? "" : ", emoji"})';
}

/// `<img>` 行内图片(不含 `class="emoji"` 的那种,emoji 走 [EmojiRun])。
///
/// Discourse cooked 形态:
/// ```html
/// <img src="https://.../upload/..." alt="screenshot" width="600" height="400">
/// <img src="https://example.com/foo.png">
/// ```
///
/// 子包**不实际加载图片 / 不做 gallery / 不做 lightbox**(主项目有 Hero
/// + 长按菜单 + upload:// 短链解析 + emojiImageProvider 等复杂逻辑),
/// 渲染时通过 [ImageContentBuilder] callback 由主项目注入。子包默认
/// fallback 是 `Image.network` + broken-image icon。
///
/// **不持 ImageProvider**:子包不依赖任何具体 image loading 实现,
/// 只把 raw src 字符串原值暴露给 builder,主项目自己解析 + 重写 CDN。
///
/// [indexInPost]:parser 在一次 parse 内按 image 出现顺序自增分配
/// (0, 1, 2, ...),给主项目算 Hero tag / gallery index 用。同一个
/// `<img src>` 在不同 post 内的 indexInPost 不同;**节点 == 比较时
/// 也参与**(防止重排时主项目误以为是同一张图)。
@immutable
class ImageRun extends InlineNode {
  const ImageRun({
    required this.src,
    this.alt = '',
    this.width,
    this.height,
    this.indexInPost = 0,
    this.lightboxUrl,
    this.origSrc,
    this.scale,
    this.previewImageIndex,
    this.origWidth,
    this.origHeight,
    this.srcset = const [],
    this.dominantColor,
    this.base62Sha1,
    this.naturalWidth,
    this.naturalHeight,
    this.fileSizeText,
  });

  /// 完整图片 URL(parser 不做任何重写;含 upload:// 短链时由主项目解析)。
  ///
  /// **缩略图**(若是 lightbox 包装):指向 `_2_690x52` 这种压缩版,
  /// 列表渲染用。
  final String src;

  /// `data-orig-src` 的 `upload://` 短链(客户端 cook 预览形态才有;
  /// 服务端 baked cooked 无此属性 → null)。
  ///
  /// 客户端 cook 会把 raw 里的 `upload://` 图渲染成
  /// `src="/images/transparent.png" data-orig-src="upload://…"`(真实 URL
  /// 只有服务端知道)。parser 遇到该形态时把 [src] 还原为短链(渲染层
  /// 走 upload:// 解析),同时在这里保留原始短链 —— **markdown 序列化
  /// 必须写短链**(raw 的规范形态),写 CDN/占位 URL 都是错的。
  final String? origSrc;

  /// alt 文本,a11y + 加载失败时占位。
  final String alt;

  /// HTML attribute 里的 width(px),null 表示由 builder 决定。
  final double? width;

  /// HTML attribute 里的 height(px),null 表示由 builder 决定。
  final double? height;

  /// 在当前 post 内的 0-based 顺序索引。parser 分配。
  ///
  /// 主项目接入示意:
  /// ```dart
  /// final heroTag = 'post_${post.id}_img_${image.indexInPost}';
  /// ```
  final int indexInPost;

  /// 原图 URL(若是 `<div class="lightbox-wrapper"><a class="lightbox"
  /// href="原图.png"><img src="缩略图.png"></a></div>` 形态)。
  ///
  /// null 表示这不是 lightbox 图片(直接 `<img>`),[src] 已经是显示用
  /// 的最佳 URL。主项目点击放大时优先用 lightboxUrl,fallback 到 src。
  final String? lightboxUrl;

  /// 当前缩放档百分比(100/75/50…),仅**客户端 cook 预览形态**且 raw 里
  /// 写了 `![alt|WxH, 75%](upload://…)` 或注入了 image-controls 控件时有值。
  ///
  /// **编辑器语义:null 与 100 等价**(有效档 = `scale ?? 100`;序列化对
  /// 两者都不写后缀)。官方三档 50/75/100,step 25(MIN_SCALE=50)。
  ///
  /// 来源:cook previewing=true 给可缩放 upload 图注入 `button-wrapper`
  /// 控件,parser 从 `scale-btn active` 的 data-scale 提取。**[width]/
  /// [height] 是乘过 scale 的显示尺寸**(cook engine 行为);原始声明
  /// 尺寸见 [origWidth]/[origHeight]。服务端 baked cooked 无控件 → null。
  final double? scale;

  /// 预览控件的 data-image-index(button-wrapper 携带,= raw 里可缩放
  /// upload 图的出现序号)。缩放按钮回调用它定位 raw 中第 N 个图片
  /// markdown(对齐官方 composer `_handleImageScaleButtonClick`)。
  /// 仅预览形态有值。
  final int? previewImageIndex;

  /// raw 里声明的原始宽度(`|WxH` 的 W,未乘 scale)。仅当 [scale] 非
  /// null 且能从显示尺寸反推时有值 —— markdown 序列化写回必须用它
  /// (写乘过的尺寸会让缩放语义在往返中塌陷)。
  final double? origWidth;

  /// raw 里声明的原始高度(`|WxH` 的 H,未乘 scale)。同 [origWidth]。
  final double? origHeight;

  /// `img[srcset]` 的候选档位(Discourse responsive images 契约:
  /// `"主src, url 1.5x, url 2x"`,首项无描述符 = 1x)。空列表 = 无 srcset。
  ///
  /// 主项目按设备 dpr 选档(浏览器语义:scale ≥ dpr 的最小档,不足取
  /// 最大档);parser 只结构化,不做选择。
  final List<ImageSrcsetCandidate> srcset;

  /// `img[data-dominant-color]`,6 位十六进制主色(如 `"E8F0D5"`)。
  ///
  /// Discourse 官方唯一的加载占位语义(web 端加载中即此纯色背景;
  /// data-small-upload LQIP 已废弃)。原样保存,颜色转换是渲染层的事。
  final String? dominantColor;

  /// `img[data-base62-sha1]`,上传文件的稳定标识(可拼
  /// `/uploads/short-url/<base62>.<ext>`)。跨 URL 变体(CDN/原图/
  /// optimized)恒定,主项目用作画廊去重 / Hero key。
  final String? base62Sha1;

  /// 原图像素宽(lightbox `.informations` 的 `"1686×128 15.7 KB"` 解析;
  /// 非 lightbox 或解析失败 → null)。
  ///
  /// 与 [origWidth] 不同:那是**编辑器 raw 声明尺寸**(scale 反推),
  /// 这是**服务端原图实际尺寸**。二者来源互斥(预览态无 .informations,
  /// baked 态无 scale 控件),刻意分字段避免语义混流。
  final double? naturalWidth;

  /// 原图像素高。同 [naturalWidth]。
  final double? naturalHeight;

  /// `.informations` 的人类可读文件大小(如 `"15.7 KB"`),查看器展示用。
  final String? fileSizeText;

  /// 换 alt / lightboxUrl / 尺寸 / 缩放档,其余字段保持。
  /// alt 非空 String(默认 ''):传 '' = 清空,null = 不改,无 sentinel 歧义。
  /// 缩放档切换用法:`copyWith(scale: 75, width: origW*0.75, ...)`,
  /// origWidth/origHeight 首次从 100 档缩小时固化。
  ImageRun copyWith({
    String? alt,
    String? lightboxUrl,
    double? width,
    double? height,
    double? scale,
    double? origWidth,
    double? origHeight,
  }) =>
      ImageRun(
        src: src,
        alt: alt ?? this.alt,
        width: width ?? this.width,
        height: height ?? this.height,
        indexInPost: indexInPost,
        lightboxUrl: lightboxUrl ?? this.lightboxUrl,
        origSrc: origSrc,
        scale: scale ?? this.scale,
        previewImageIndex: previewImageIndex,
        origWidth: origWidth ?? this.origWidth,
        origHeight: origHeight ?? this.origHeight,
        srcset: srcset,
        dominantColor: dominantColor,
        base62Sha1: base62Sha1,
        naturalWidth: naturalWidth,
        naturalHeight: naturalHeight,
        fileSizeText: fileSizeText,
      );

  /// lightbox 包装解析专用:一次带上 anchor 侧的全部契约字段。
  ImageRun withLightboxMeta({
    String? lightboxUrl,
    double? naturalWidth,
    double? naturalHeight,
    String? fileSizeText,
  }) =>
      ImageRun(
        src: src,
        alt: alt,
        width: width,
        height: height,
        indexInPost: indexInPost,
        lightboxUrl: lightboxUrl ?? this.lightboxUrl,
        origSrc: origSrc,
        scale: scale,
        previewImageIndex: previewImageIndex,
        origWidth: origWidth,
        origHeight: origHeight,
        srcset: srcset,
        dominantColor: dominantColor,
        base62Sha1: base62Sha1,
        naturalWidth: naturalWidth ?? this.naturalWidth,
        naturalHeight: naturalHeight ?? this.naturalHeight,
        fileSizeText: fileSizeText ?? this.fileSizeText,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImageRun &&
          runtimeType == other.runtimeType &&
          src == other.src &&
          alt == other.alt &&
          width == other.width &&
          height == other.height &&
          indexInPost == other.indexInPost &&
          lightboxUrl == other.lightboxUrl &&
          origSrc == other.origSrc &&
          scale == other.scale &&
          previewImageIndex == other.previewImageIndex &&
          origWidth == other.origWidth &&
          origHeight == other.origHeight &&
          listEquals(srcset, other.srcset) &&
          dominantColor == other.dominantColor &&
          base62Sha1 == other.base62Sha1 &&
          naturalWidth == other.naturalWidth &&
          naturalHeight == other.naturalHeight &&
          fileSizeText == other.fileSizeText;

  @override
  int get hashCode => Object.hash(
      src,
      alt,
      width,
      height,
      indexInPost,
      lightboxUrl,
      origSrc,
      scale,
      previewImageIndex,
      origWidth,
      origHeight,
      Object.hashAll(srcset),
      dominantColor,
      base62Sha1,
      naturalWidth,
      naturalHeight,
      fileSizeText);

  @override
  String toString() =>
      'ImageRun(#$indexInPost $src'
      '${width == null ? "" : ", ${width}x$height"}'
      '${lightboxUrl == null ? "" : ", lightbox=$lightboxUrl"})';
}

/// [ImageRun.srcset] 的单个候选:URL + 像素密度倍率(`1.5x` → 1.5)。
@immutable
class ImageSrcsetCandidate {
  const ImageSrcsetCandidate({required this.url, required this.scale});

  final String url;
  final double scale;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImageSrcsetCandidate &&
          url == other.url &&
          scale == other.scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() => '$url ${scale}x';
}

/// `<span class="spoiler">` 行内剧透,默认遮蔽,点击展开。
///
/// Discourse cooked 形态:
/// ```html
/// 答案是 <span class="spoiler">42</span>。
/// ```
///
/// 渲染策略(对齐 legacy):
/// - 未揭示:粒子云 + 不透明页面背景色完全遮盖文字(Ticker 驱动动画);
///   reduce-motion(MediaQuery.disableAnimations)时退化为静态灰块遮罩。
/// - 揭示后:正常显示子节点(可再点击隐藏)。
/// - 状态由 _SpoilerInlineWidget 内部 StatefulWidget 管,**不跨同份 cookedHtml 同步**。
///
/// 粒子由 GPU fragment shader 程序化生成(见 render/spoiler_effect.dart)。
@immutable
class SpoilerRun extends InlineNode {
  const SpoilerRun({required this.children});

  /// 被遮蔽的行内子节点(可嵌套样式 / link / inline_code 等)。
  final List<InlineNode> children;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SpoilerRun &&
          runtimeType == other.runtimeType &&
          listEquals(children, other.children);

  @override
  int get hashCode => Object.hashAll(children);

  @override
  String toString() => 'SpoilerRun(${children.length} children)';
}

/// 脚注引用 — `<sup class="footnote-ref"><a href="#fn-id">N</a></sup>`。
///
/// Discourse 用 markdown-it-footnote 渲染,典型 cooked:
/// ```html
/// 正文里 <sup class="footnote-ref"><a href="#fn:abc">1</a></sup> 这里。
/// <hr class="footnotes-sep">
/// <section class="footnotes">
///   <ol class="footnotes-list">
///     <li id="fn:abc"><p>脚注正文 <a class="footnote-backref" href="#fnref:abc">↩︎</a></p></li>
///   </ol>
/// </section>
/// ```
///
/// 渲染对齐 legacy `footnote_builder.dart`:
///   上标蓝字 `[N]`(11px / w600,Transform y-3 抬起视觉为上标)
///   点击 → popover 显示脚注 [contentHtml]
///
/// 子包简化:
/// - parser 一次性扫 fragment 建 `fnId → contentHtml` 映射,sup 命中时
///   就把对应 contentHtml 内联到 FootnoteRefRun(避免渲染时再 lookup)
/// - 子包不依赖 popover,弹窗交给主项目 `footnoteTapHandler` callback;
///   不传 handler 时点击无反应(同 linkHandler 兜底)
@immutable
class FootnoteRefRun extends InlineNode {
  const FootnoteRefRun({
    required this.number,
    required this.fnId,
    this.contentHtml,
  });

  /// 脚注编号(`<a>` 文本,典型 "1" / "2",legacy 用 `[N]` 包装显示)。
  final String number;

  /// 脚注锚点 id(`href="#fn:abc"` 的 `fn:abc`)。给主项目跳转用。
  final String fnId;

  /// 脚注正文 HTML(parser 从 section.footnotes 内 `<li id="fnId">` 提取,
  /// 已 strip 末尾 `<a class="footnote-backref">↩︎</a>`)。
  /// 找不到时 null(罕见 — cooked 损坏或前后段拆开 parse)。
  final String? contentHtml;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FootnoteRefRun &&
          runtimeType == other.runtimeType &&
          number == other.number &&
          fnId == other.fnId &&
          contentHtml == other.contentHtml;

  @override
  int get hashCode => Object.hash(number, fnId, contentHtml);

  @override
  String toString() =>
      'FootnoteRefRun(#$number → $fnId${contentHtml == null ? "" : ", ${contentHtml!.length} chars"})';
}

/// Discourse 本地日期 — `<span class="discourse-local-date">` 行内时间 chip。
///
/// cooked 形态(Discourse 插件 `discourse-local-dates` 渲染):
/// ```html
/// <span class="discourse-local-date"
///       data-date="2026-04-01"
///       data-time="22:00"
///       data-timezone="Asia/Shanghai"
///       data-timezones="Europe/Paris|America/Los_Angeles"
///       data-format="LLL"
///       data-countdown
///       data-range="from"
///       data-displayed-timezone="Asia/Shanghai">
///   2026年4月1日 22:00 ← 服务端预渲染文本(中文 / 各 locale)
/// </span>
/// ```
///
/// 子包**只持原始字段**,不做时区换算(需要 `timezone`/`flutter_timezone`
/// 等重依赖):
/// - 主项目通过 [LocalDateBuilder] callback 注入完整 chip(虚线下划线 +
///   图标 + 本地时区文本 + 点击弹多时区 popover)
/// - 不传 builder 时子包用内置 fallback:展示 [fallbackText](服务端预
///   渲染的字符串)+ 时钟图标,无时区换算
///
/// [fallbackText] 是 span 元素的 textContent —— Discourse 服务端按帖子作者
/// 时区预渲染了一段可读字符串,主项目即使没接 builder,也能看到原始时间。
@immutable
class LocalDateRun extends InlineNode {
  const LocalDateRun({
    required this.date,
    required this.fallbackText,
    this.time,
    this.timezone,
    this.timezones = const [],
    this.format,
    this.displayedTimezone,
    this.countdown = false,
    this.range,
  });

  /// `data-date="2026-04-01"`(YYYY-MM-DD)。空 = 无效时间(parser 会跳过)。
  final String date;

  /// `data-time="22:00"`(HH:mm 或 HH:mm:ss),null = 仅日期不带时分。
  final String? time;

  /// `data-timezone="Asia/Shanghai"`,作者所在时区。
  final String? timezone;

  /// `data-timezones="A|B|C"` 拆分后的列表(popover 多时区预览)。
  /// 空时主项目按站点默认值兜底(`Europe/Paris`, `America/Los_Angeles`)。
  final List<String> timezones;

  /// `data-format`,moment.js 格式 token(`LL` / `LLL` / `LLLL` / `LT` 等)。
  final String? format;

  /// `data-displayed-timezone`,强制以某时区显示(罕见)。
  final String? displayedTimezone;

  /// `data-countdown` 属性存在 = 倒计时模式。
  final bool countdown;

  /// `data-range="from"` / `"to"` / null,标记范围起止(可选)。
  final String? range;

  /// span 的 textContent — Discourse 服务端预渲染的兜底文本。
  /// 子包不做时区换算时直接显示这段。
  final String fallbackText;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalDateRun &&
          runtimeType == other.runtimeType &&
          date == other.date &&
          time == other.time &&
          timezone == other.timezone &&
          format == other.format &&
          displayedTimezone == other.displayedTimezone &&
          countdown == other.countdown &&
          range == other.range &&
          fallbackText == other.fallbackText &&
          listEquals(timezones, other.timezones);

  @override
  int get hashCode => Object.hash(
        date,
        time,
        timezone,
        format,
        displayedTimezone,
        countdown,
        range,
        fallbackText,
        Object.hashAll(timezones),
      );

  @override
  String toString() =>
      'LocalDateRun($date${time == null ? "" : " $time"}'
      '${timezone == null ? "" : " @$timezone"}'
      '${countdown ? ", countdown" : ""})';
}

/// 链接点击数 chip — `<span class="click-count">123</span>`。
///
/// Discourse 在帖子链接旁注入这种 span 显示点击次数(legacy 通过
/// `_injectClickCounts` 把 `<a>` 后面追加 `<span class="click-count">N</span>`)。
///
/// 视觉对齐 legacy `buildClickCountWidget`:
///   小灰底圆角(radius 10)+ horizontal 5 / vertical 1 padding
///   暗主题:bg #3a3d47 / text #9ca3af;亮:bg #e8ebef / text #6b7280
///   字号 10
///
/// 纯展示节点,无 callback,无主项目接入需求。
@immutable
class ClickCountRun extends InlineNode {
  const ClickCountRun(this.count);

  /// 点击数字符串(legacy 是 textContent.trim(),可能含 thin space  )。
  final String count;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClickCountRun &&
          runtimeType == other.runtimeType &&
          count == other.count;

  @override
  int get hashCode => count.hashCode;

  @override
  String toString() => 'ClickCountRun($count)';
}

/// 行内数学公式 — `<span class="math">LaTeX 源码</span>`。
///
/// Discourse markdown-it-math 把 `$...$` / `\(...\)` 渲染成 span.math。
/// 子包不绑 `flutter_math_fork`(对齐 [MathBlockNode]),通过
/// [MathInlineBuilder] callback 让主项目接入;fallback 显示 monospace
/// `$latex$` 原文。
///
/// 视觉对齐 legacy `math_builder.dart::buildInlineMath`:
///   InlineCustomWidget(WidgetSpan)+ Math.tex 渲染
@immutable
class MathInlineRun extends InlineNode {
  const MathInlineRun(this.latex);

  /// LaTeX 源码(已 trim)。空 = 无效公式,渲染时显示空 SizedBox。
  final String latex;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MathInlineRun &&
          runtimeType == other.runtimeType &&
          latex == other.latex;

  @override
  int get hashCode => latex.hashCode;

  @override
  String toString() => 'MathInlineRun(${latex.length} chars)';
}
