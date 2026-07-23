/// 可编辑段落的扁平行内模型。
///
/// 编辑操作(插入/删除/切分/合并)在**扁平坐标**上做:一个段落 =
/// 一段纯文本 + 样式区间([MarkSpan]) + 原子表([atoms])。这与
/// ProseMirror 的 inline 表示(text + marks + 原子 node)同构 ——
/// 编辑是 O(区间数) 的简单区间调整,不需要在嵌套树上找路径。
///
/// **原子节点**(M2):emoji/mention 在文本里用 [kAtomChar](U+FFFC,
/// OBJECT REPLACEMENT CHARACTER)占 1 个 code unit,身份存 [atoms]
/// (offset → 原 InlineNode 引用)。选型依据:
/// - FFFC 恰是 Flutter WidgetSpan 的渲染占位字符,渲染/投影层的原子
///   entry 机制已存在;
/// - 与 IME pad(空格)/软换行 ZWSP(U+200B)/codePad NBSP(U+00A0)
///   互不冲突;
/// - grapheme 步长恒 1 → M1 的退格/光标移动逻辑天然把原子当一个单位。
/// 用户输入里的裸 FFFC 由 [sanitizeText] 剥除(防 IME 回显幻造原子)。
///
/// 渲染时通过 [toInlines] 转回 [InlineNode] 树喂现有 InlineFlattener,
/// 保证编辑态与阅读态视觉零差异(行内代码 NBSP 灰底等精调全部复用)。
library;

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../../node/inline_node.dart';

/// 原子哨兵字符(U+FFFC OBJECT REPLACEMENT CHARACTER)。
const String kAtomChar = '\uFFFC';

/// 行内样式种类(编辑模型用)。
enum MarkKind {
  em,
  strong,
  inlineCode,
  underline,
  lineThrough,

  /// 行内剧透 `[spoiler]…[/spoiler]`(SpoilerRun)。编辑态显示淡遮罩
  /// 底纹(内容可见可编辑,对齐官方 rich editor 的 spoiler-blurred
  /// decoration 思路的简化版)。
  spoilerInline,

  /// 链接 `[text](href)`(LinkRun)。带 attr(href)—— 见 [MarkSpan.attr]。
  /// 编辑态蓝色下划线,不可点(编辑器语义)。
  link,

  /// 前景色 `[color=#rrggbb]…[/color]`(ColoredRun.color)。attr 存色值。
  ///
  /// 做成 mark 而不是留给 ColoredRun 岛化,是因为岛是**不可编辑**的:
  /// 打完一句带色的话整行会变成只读岛、光标直接消失(实测复现)。
  /// 做成 mark 后文字照常可编辑,颜色只是区间样式。
  textColor,

  /// 背景色 `[bgcolor=#rrggbb]…[/bgcolor]`(ColoredRun.background)。
  bgColor,
}

/// 一段样式区间 `[start, end)`(扁平文本坐标)。
///
/// [attr]:mark 的附加值([MarkKind.link] 的 href、颜色系的色值)。同 kind
/// 不同 attr 的区间**不合并**(两个不同链接相邻仍是两个链接)。
@immutable
class MarkSpan {
  const MarkSpan({
    required this.start,
    required this.end,
    required this.kind,
    this.attr,
  });

  final int start;
  final int end;
  final MarkKind kind;

  /// kind 相关附加值:link=href;其余 null。
  final String? attr;

  bool get isEmpty => start >= end;

  MarkSpan copyWith({int? start, int? end}) => MarkSpan(
        start: start ?? this.start,
        end: end ?? this.end,
        kind: kind,
        attr: attr,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MarkSpan &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end &&
          kind == other.kind &&
          attr == other.attr;

  @override
  int get hashCode => Object.hash(start, end, kind, attr);

  @override
  String toString() =>
      'MarkSpan($kind [$start,$end)${attr == null ? "" : " $attr"})';
}

/// 段落的扁平可编辑内容(不可变;编辑原语返回新实例)。
@immutable
class EditableTextContent {
  EditableTextContent({
    required this.text,
    List<MarkSpan> marks = const [],
    Map<int, InlineNode> atoms = const {},
  })  : marks = List.unmodifiable(
          marks.where((m) => !m.isEmpty).toList()
            ..sort((a, b) {
              final c = a.start.compareTo(b.start);
              return c != 0 ? c : a.end.compareTo(b.end);
            }),
        ),
        atoms = Map.unmodifiable(atoms),
        assert(
          atoms.keys.every(
            (o) => o >= 0 && o < text.length && text[o] == kAtomChar,
          ),
          'atoms 的每个 offset 必须指向文本中的 kAtomChar',
        );

  static final EditableTextContent empty = EditableTextContent(text: '');

  final String text;

  /// 按 start 升序;同 kind 区间不重叠(编辑原语与 [toggleMarkInRange]
  /// 维护该语义,构造器只做排序/去空)。
  final List<MarkSpan> marks;

  /// 原子表:offset(指向 text 中的 [kAtomChar])→ 原 InlineNode
  /// (EmojiRun/MentionRun;M2 白名单,其他类型由 doc_converter 拦在岛外)。
  final Map<int, InlineNode> atoms;

  int get length => text.length;

  /// 剥除文本里的裸 FFFC(用户/IME 输入不允许自带哨兵 —— 只能经
  /// [insertAtom]/fromInlines 建立原子)。
  static String sanitizeText(String input) =>
      input.contains(kAtomChar) ? input.replaceAll(kAtomChar, '') : input;

  /// Color → `#rrggbb`(mark attr 存这个形态,与序列化口径一致)。
  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// 倍数 → 百分比字符串(`1.5` → `150`;整数不写小数点,与 raw 口径一致)。
  static String _pct(double scale) {
    final v = scale * 100;
    return v == v.roundToDouble() ? v.round().toString() : '$v';
  }

  /// 百分比字符串 → 倍数(`150` → `1.5`);解析不出返回 null。
  static double? parsePct(String? v) {
    if (v == null) return null;
    final n = double.tryParse(v.trim());
    return (n == null || n < 0) ? null : n / 100.0;
  }

  /// `#rgb` / `#rrggbb` → Color;解析不出返回 null。
  static Color? parseHex(String? v) {
    if (v == null) return null;
    var h = v.trim();
    if (!h.startsWith('#')) return null;
    h = h.substring(1);
    if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
    if (h.length != 6) return null;
    final n = int.tryParse(h, radix: 16);
    return n == null ? null : Color(0xFF000000 | n);
  }

  /// [offset] 处(其后)的字符是否原子。
  bool isAtomAt(int offset) => atoms.containsKey(offset);

  // -----------------------------------------------------------------
  // InlineNode 树 ↔ 扁平 双向转换
  // -----------------------------------------------------------------

  /// 从渲染节点树构建扁平模型。
  ///
  /// 支持:TextRun / EmRun / StrongRun / InlineCodeRun /
  /// StyledRun(underline|lineThrough) / LineBreakRun(转 '\n')/
  /// **EmojiRun / MentionRun(原子,M2)/ SpoilerRun / LinkRun(M5)**。
  ///
  /// 其余节点(image/footnote/...)不在编辑白名单 —— 调用方
  /// (doc_converter.isEditableInline)负责拦截整块岛化,此处的降级
  /// 分支仅作纯文本兜底(防御,不应在正常链路走到)。
  factory EditableTextContent.fromInlines(List<InlineNode> inlines) {
    final buf = StringBuffer();
    final marks = <MarkSpan>[];
    final atoms = <int, InlineNode>{};
    _flattenInto(inlines, buf, marks, atoms, const []);
    return EditableTextContent(
      text: buf.toString(),
      marks: marks,
      atoms: atoms,
    );
  }

  /// 活动 mark 帧:kind + 可选 attr(link 的 href)。
  static void _flattenInto(
    List<InlineNode> nodes,
    StringBuffer buf,
    List<MarkSpan> marks,
    Map<int, InlineNode> atoms,
    List<(MarkKind, String?)> activeKinds,
  ) {
    for (final node in nodes) {
      switch (node) {
        case TextRun(:final text):
          _appendText(buf, marks, activeKinds, sanitizeText(text));
        case LineBreakRun():
          _appendText(buf, marks, activeKinds, '\n');
        case EmRun(:final children):
          _flattenInto(children, buf, marks, atoms,
              [...activeKinds, (MarkKind.em, null)]);
        case StrongRun(:final children):
          _flattenInto(children, buf, marks, atoms,
              [...activeKinds, (MarkKind.strong, null)]);
        case InlineCodeRun(:final text):
          _appendText(
            buf,
            marks,
            [...activeKinds, (MarkKind.inlineCode, null)],
            sanitizeText(text),
          );
        case StyledRun(:final kind, :final children):
          final mapped = switch (kind) {
            InlineStyleKind.underline => MarkKind.underline,
            InlineStyleKind.lineThrough => MarkKind.lineThrough,
            _ => null,
          };
          _flattenInto(
            children,
            buf,
            marks,
            atoms,
            mapped == null ? activeKinds : [...activeKinds, (mapped, null)],
          );
        // ---- M5 白名单:行内剧透 / 链接(mark 化,内容可编辑) ----
        case SpoilerRun(:final children):
          _flattenInto(children, buf, marks, atoms,
              [...activeKinds, (MarkKind.spoilerInline, null)]);
        case LinkRun(:final href, :final children, :final isOneboxLink):
          if (isOneboxLink) {
            // 裸 URL 的 linkify 链接:编辑器显示 URL 本身(锚文本可能
            // 是 cook 种子取回的页面标题,但 raw 是裸 URL —— 显示 href
            // 才能让序列化的 text==attr 裸 URL 规则保住往返)
            _appendText(buf, marks,
                [...activeKinds, (MarkKind.link, href)], sanitizeText(href));
          } else {
            _flattenInto(children, buf, marks, atoms,
                [...activeKinds, (MarkKind.link, href)]);
          }
        // ---- 原子(一等公民):哨兵占位 + 身份入表 ----
        case EmojiRun():
          atoms[buf.length] = node;
          _appendText(buf, marks, activeKinds, kAtomChar);
        case MentionRun():
          atoms[buf.length] = node;
          _appendText(buf, marks, activeKinds, kAtomChar);
        case LocalDateRun():
          // 时间 chip:行内原子(M5;序列化写回 [date=…])
          atoms[buf.length] = node;
          _appendText(buf, marks, activeKinds, kAtomChar);
        case ImageRun():
          // 图片:行内原子,无条件(isEditableInline 同判据 —— 官方
          // ProseMirror image 是 inline:true 一等行内节点)
          atoms[buf.length] = node;
          _appendText(buf, marks, activeKinds, kAtomChar);
        case SizedRun(:final children):
          // 正常链路走不到:doc_converter 已把含 [size] 的段落整体岛化。
          // 这里只作防御兜底(同其他白名单外节点),摊平子节点不丢字。
          _flattenInto(children, buf, marks, atoms, activeKinds);
        case ColoredRun(:final color, :final background, :final children):
          // 颜色 → 带 attr 的 mark(见 MarkKind.textColor 注释:岛化会
          // 让整行变只读、光标消失)
          _flattenInto(children, buf, marks, atoms, [
            ...activeKinds,
            if (background != null) (MarkKind.bgColor, _hex(background)),
            if (color != null) (MarkKind.textColor, _hex(color)),
          ]);
        // ---- 白名单外(防御降级,正常链路由 doc_converter 拦截岛化) ----
        case FootnoteRefRun():
        case ClickCountRun():
        case MathInlineRun():
          break;
      }
    }
  }

  static void _appendText(
    StringBuffer buf,
    List<MarkSpan> marks,
    List<(MarkKind, String?)> activeKinds,
    String text,
  ) {
    if (text.isEmpty) return;
    final start = buf.length;
    buf.write(text);
    final end = buf.length;
    // 去重:嵌套同类标签(<em><strong><em>)会让 kind 重复出现,
    // 重复处理会产出重叠区间(破坏"同 kind 不重叠"语义与往返不动点)。
    // link 按 (kind, attr) 去重 —— 不同 href 的嵌套链接理论不存在
    // (HTML 不允许 a 嵌 a),同帧只会有一个 href。
    for (final frame in {...activeKinds}) {
      final (kind, attr) = frame;
      // 与紧邻的同 kind 同 attr 区间合并(嵌套展开会产生相邻碎段)。
      final lastIdx =
          marks.lastIndexWhere((m) => m.kind == kind && m.attr == attr);
      if (lastIdx >= 0 && marks[lastIdx].end == start) {
        marks[lastIdx] = marks[lastIdx].copyWith(end: end);
      } else {
        marks.add(MarkSpan(start: start, end: end, kind: kind, attr: attr));
      }
    }
  }

  /// 转回 InlineNode 树(渲染用)。
  ///
  /// 策略:按所有区间边界 + 原子位置切文本为片段;原子片段直接吐回
  /// [atoms] 里的原节点(样式区间对原子不生效 —— emoji 图片没有粗体;
  /// 但 spoiler/link 包装保留,原子也在剧透/链接里)。
  /// 嵌套顺序固定:spoiler > link > strong > em > underline > lineThrough;
  /// inlineCode 独占。
  ///
  /// [forEditing]:编辑段落渲染模式。spoilerInline/link **不包装**为
  /// SpoilerRun/LinkRun(前者是 WidgetSpan 粒子遮罩会破坏文本编辑,
  /// 后者的 TapGestureRecognizer 会抢编辑器手势),改用纯 TextSpan 视觉
  /// 替代:spoiler=淡灰底纹(内容可见可编辑,对齐官方 rich editor 光标
  /// 内显形语义的简化),link=[editingLinkColor] 字色 + 下划线。
  /// [markerRanges]:展开态的字面 markdown 标记区间(`**`/`> ` 等)。
  /// 落在区间内的文本用 [markerColor] 淡化 —— 视觉上是「标记」而非正文。
  List<InlineNode> toInlines({
    bool forEditing = false,
    Color? editingLinkColor,
    List<(int, int)> markerRanges = const [],
    Color? markerColor,
  }) {
    if (text.isEmpty) return const [];

    // 1. 收集切点
    final cuts = <int>{0, text.length};
    for (final m in marks) {
      cuts.add(m.start.clamp(0, text.length));
      cuts.add(m.end.clamp(0, text.length));
    }
    for (final (a, b) in markerRanges) {
      cuts.add(a.clamp(0, text.length));
      cuts.add(b.clamp(0, text.length));
    }
    // '\n' 与原子单独成段
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '\n' || text[i] == kAtomChar) {
        cuts.add(i);
        cuts.add(i + 1);
      }
    }
    final points = cuts.toList()..sort();

    // 2. 逐片段构建
    final out = <InlineNode>[];
    for (var i = 0; i + 1 < points.length; i++) {
      final s = points[i];
      final e = points[i + 1];
      if (s >= e) continue;
      final piece = text.substring(s, e);
      if (piece == '\n') {
        out.add(const LineBreakRun());
        continue;
      }
      final kinds = <MarkKind>{
        for (final m in marks)
          if (m.start <= s && m.end >= e) m.kind,
      };
      // link href:覆盖片段的 link mark 的 attr(同帧唯一)
      String? href;
      String? fgHex;
      String? bgHex;
      for (final m in marks) {
        if (m.start > s || m.end < e) continue;
        switch (m.kind) {
          case MarkKind.link:
            href ??= m.attr;
          case MarkKind.textColor:
            fgHex ??= m.attr;
          case MarkKind.bgColor:
            bgHex ??= m.attr;
          default:
            break;
        }
      }
      if (piece == kAtomChar) {
        final atom = atoms[s];
        if (atom != null) {
          // 原子保留 spoiler/link 包装(基础样式对原子不生效)
          out.add(_wrapAtom(atom, kinds, href, forEditing: forEditing));
        }
        // 无身份的孤儿哨兵(不变量破坏,构造器断言防):静默丢弃。
        continue;
      }
      var node = _wrapPiece(piece, kinds, href,
          forEditing: forEditing,
          editingLinkColor: editingLinkColor,
          fgHex: fgHex,
          bgHex: bgHex);
      if (markerColor != null &&
          markerRanges.any((r) => r.$1 <= s && r.$2 >= e)) {
        node = ColoredRun(color: markerColor, children: [node]);
      }
      out.add(node);
    }
    return _applyOnlyEmoji(out);
  }

  /// Discourse 大表情语义:整段**只有** emoji(空白不算内容)且不超过
  /// [_maxOnlyEmoji] 个 → 全部标 isOnlyEmoji(渲染 32dp);超了则全部
  /// 普通尺寸。规则与 cook 引擎实测一致:
  /// `:a:`→1 大 / `:a: :a: :a:`→3 全大 / 4 个→全不大。
  ///
  /// 放在 [toInlines] 里而不是只放导出路径,是因为编辑器实时渲染
  /// (editable_paragraph)和导出(doc_converter)走的是同一个出口 ——
  /// 只在导出侧标记会导致"刚插入的 emoji 是小的,切到源码再切回来才
  /// 变大"(实测复现)。
  static List<InlineNode> _applyOnlyEmoji(List<InlineNode> out) {
    var emojiCount = 0;
    for (final n in out) {
      if (n is EmojiRun) {
        emojiCount++;
        continue;
      }
      // 纯空白的文本片段不算内容;其余任何节点都让本段不再是"只有表情"
      if (n is TextRun && n.text.trim().isEmpty) continue;
      return out;
    }
    if (emojiCount == 0) return out;
    final large = emojiCount <= _maxOnlyEmoji;
    var changed = false;
    final result = [
      for (final n in out)
        if (n is EmojiRun && n.isOnlyEmoji != large)
          () {
            changed = true;
            return EmojiRun(name: n.name, url: n.url, isOnlyEmoji: large);
          }()
        else
          n,
    ];
    return changed ? result : out;
  }

  /// 超过这个数量就不再算大表情(对齐 Discourse)。
  static const int _maxOnlyEmoji = 3;

  static InlineNode _wrapAtom(
    InlineNode atom,
    Set<MarkKind> kinds,
    String? href, {
    required bool forEditing,
  }) {
    if (forEditing) return atom; // 编辑态原子裸渲染(遮罩/链接壳都不加)
    InlineNode node = atom;
    if (kinds.contains(MarkKind.link)) {
      node = LinkRun(href: href ?? '', children: [node]);
    }
    if (kinds.contains(MarkKind.spoilerInline)) {
      node = SpoilerRun(children: [node]);
    }
    return node;
  }

  static InlineNode _wrapPiece(
    String piece,
    Set<MarkKind> kinds,
    String? href, {
    required bool forEditing,
    Color? editingLinkColor,
    String? fgHex,
    String? bgHex,
  }) {
    InlineNode node;
    if (kinds.contains(MarkKind.inlineCode)) {
      node = InlineCodeRun(piece);
    } else {
      node = TextRun(piece);
      if (kinds.contains(MarkKind.lineThrough)) {
        node = StyledRun(kind: InlineStyleKind.lineThrough, children: [node]);
      }
      if (kinds.contains(MarkKind.underline) ||
          (forEditing && kinds.contains(MarkKind.link))) {
        // 编辑态 link 借下划线样式(真 LinkRun 的 recognizer 会抢手势)
        node = StyledRun(kind: InlineStyleKind.underline, children: [node]);
      }
      if (kinds.contains(MarkKind.em)) {
        node = EmRun(children: [node]);
      }
      if (kinds.contains(MarkKind.strong)) {
        node = StrongRun(children: [node]);
      }
    }
    if (forEditing) {
      // 编辑态视觉替代:link 字色经 ColoredRun(纯 TextSpan,投影透明,
      // 选区/光标/IME 全不受扰)。spoiler 的底纹+虚线框由
      // EditableParagraph._SpoilerDecorPainter 按 mark 区间自绘
      // (这里不加底纹 —— painter 的圆角框视觉更完整)。
      if (kinds.contains(MarkKind.link)) {
        node = ColoredRun(
          color: editingLinkColor ?? const Color(0xFF1F7AED),
          children: [node],
        );
      }
      return _applyColorMarks(node, kinds, fgHex, bgHex);
    }
    node = _applyColorMarks(node, kinds, fgHex, bgHex);
    // link/spoiler 包最外(阅读端 <a>/<span class=spoiler> 里嵌样式的形态)
    if (kinds.contains(MarkKind.link)) {
      node = LinkRun(href: href ?? '', children: [node]);
    }
    if (kinds.contains(MarkKind.spoilerInline)) {
      node = SpoilerRun(children: [node]);
    }
    return node;
  }

  /// 字号 mark → SizedRun。
  ///
  /// **编辑态夹下限 1 倍**:`[size=0]` 真按 0 倍画在编辑器里就是隐形的、
  /// 根本没法编辑(用户明确要求"最小为正常大小、最大不限制")。上限不夹。
  /// 阅读端([forEditing] = false)不夹,原样对齐网页端。
  /// 注意夹的只是**渲染**;raw 由 mark 的 attr 决定,发出去仍是原值。
  static InlineNode _applySizeMark(
    InlineNode node,
    String? pct, {
    required bool forEditing,
  }) {
    final scale = parsePct(pct);
    if (scale == null) return node;
    final effective = forEditing && scale < 1.0 ? 1.0 : scale;
    return SizedRun(scale: effective, children: [node]);
  }

  /// 颜色 mark → ColoredRun(前景/背景可同时存在,合成一个节点)。
  static InlineNode _applyColorMarks(
    InlineNode node,
    Set<MarkKind> kinds,
    String? fgHex,
    String? bgHex,
  ) {
    final fg = kinds.contains(MarkKind.textColor) ? parseHex(fgHex) : null;
    final bg = kinds.contains(MarkKind.bgColor) ? parseHex(bgHex) : null;
    if (fg == null && bg == null) return node;
    return ColoredRun(color: fg, background: bg, children: [node]);
  }

  // -----------------------------------------------------------------
  // 编辑原语(全部返回新实例;atoms 表随区间同步平移)
  // -----------------------------------------------------------------

  /// 在 [offset] 处插入 [inserted]。样式区间调整规则:
  /// - 区间完全在插入点前/后:不变/整体右移;
  /// - 插入点在区间内部(start < offset < end):区间拉长(延续样式,
  ///   对齐主流编辑器"在粗体中间打字仍是粗体");
  /// - 插入点恰在区间边界:不延续(在粗体结尾打字回到正常)。
  ///
  /// 注意:[inserted] 未经 [sanitizeText] —— 调用方(EditorState/
  /// insertAtom)负责;insertAtom 恰要插入哨兵本体,不能在这里一刀切剥。
  EditableTextContent insert(int offset, String inserted) {
    assert(offset >= 0 && offset <= text.length);
    if (inserted.isEmpty) return this;
    final len = inserted.length;
    final newMarks = <MarkSpan>[];
    for (final m in marks) {
      if (m.end <= offset) {
        newMarks.add(m);
      } else if (m.start >= offset) {
        newMarks.add(m.copyWith(start: m.start + len, end: m.end + len));
      } else {
        newMarks.add(m.copyWith(end: m.end + len));
      }
    }
    return EditableTextContent(
      text: text.replaceRange(offset, offset, inserted),
      marks: newMarks,
      atoms: {
        for (final e in atoms.entries)
          (e.key >= offset ? e.key + len : e.key): e.value,
      },
    );
  }

  /// 在 [offset] 处插入一个原子(哨兵 + 身份)。
  EditableTextContent insertAtom(int offset, InlineNode atom) {
    assert(offset >= 0 && offset <= text.length);
    final withChar = insert(offset, kAtomChar);
    return EditableTextContent(
      text: withChar.text,
      marks: withChar.marks,
      atoms: {...withChar.atoms, offset: atom},
    );
  }

  /// 删除 `[start, end)` 区间(区间内的原子随之消失)。
  EditableTextContent delete(int start, int end) {
    assert(start >= 0 && end <= text.length && start <= end);
    if (start == end) return this;
    final len = end - start;
    final newMarks = <MarkSpan>[];
    for (final m in marks) {
      // 区间平移/收缩:与删除区间求差。
      final ns = m.start <= start
          ? m.start
          : (m.start >= end ? m.start - len : start);
      final ne = m.end <= start ? m.end : (m.end >= end ? m.end - len : start);
      final span = m.copyWith(start: ns, end: ne);
      if (!span.isEmpty) newMarks.add(span);
    }
    return EditableTextContent(
      text: text.replaceRange(start, end, ''),
      marks: newMarks,
      atoms: {
        for (final e in atoms.entries)
          if (e.key < start)
            e.key: e.value
          else if (e.key >= end)
            e.key - len: e.value,
      },
    );
  }

  /// 取 `[start, end)` 子区间(复制/选区片段提取)。
  /// marks/atoms 随区间裁剪平移(delete 组合,先尾后头保偏移正确)。
  EditableTextContent slice(int start, int end) {
    assert(start >= 0 && end <= text.length && start <= end);
    return delete(end, text.length).delete(0, start);
  }

  /// 替换 `[start, end)` 为 [replacement](IME composing 更新的主路径)。
  EditableTextContent replace(int start, int end, String replacement) =>
      delete(start, end).insert(start, replacement);

  /// 在 [offset] 处切成两半(回车分段)。
  (EditableTextContent before, EditableTextContent after) split(int offset) {
    assert(offset >= 0 && offset <= text.length);
    final before = delete(offset, text.length);
    final after = delete(0, offset);
    return (before, after);
  }

  /// 与 [other] 拼接(段首退格合并)。
  EditableTextContent concat(EditableTextContent other) {
    final base = text.length;
    return EditableTextContent(
      text: text + other.text,
      marks: [
        ...marks,
        for (final m in other.marks)
          m.copyWith(start: m.start + base, end: m.end + base),
      ],
      atoms: {
        ...atoms,
        for (final e in other.atoms.entries) e.key + base: e.value,
      },
    );
  }

  // -----------------------------------------------------------------
  // mark 区间代数(格式命令用)
  // -----------------------------------------------------------------

  /// `[start, end)` 是否被 [kind] 完全覆盖(toggle 语义判定)。
  ///
  /// 覆盖判定容许多个同 kind 区间**无缝拼接**;区间之间有任何未覆盖
  /// 字符即 false。原子字符也计入(选中含 emoji 的一段"全是粗体"时,
  /// emoji 位置上的 mark 虽不影响渲染,但参与覆盖判定 —— 保证 toggle
  /// 幂等:两次 toggle 回到原状)。
  bool isRangeFullyMarked(int start, int end, MarkKind kind) {
    assert(start >= 0 && end <= text.length && start <= end);
    if (start == end) return false;
    var cursor = start;
    // marks 按 start 升序;同 kind 区间不重叠
    for (final m in marks) {
      if (m.kind != kind) continue;
      if (m.end <= cursor) continue;
      if (m.start > cursor) return false; // 缝隙
      cursor = m.end;
      if (cursor >= end) return true;
    }
    return cursor >= end;
  }

  /// 对 `[start, end)` 应用 [kind](幂等;与既有区间合并归一)。
  ///
  /// [attr]:link 的 href。合并只发生在**同 kind 同 attr** 之间 ——
  /// 相邻两个不同 href 的链接不吞并。施加带 attr 的 mark 前先移除
  /// 区间上同 kind 异 attr 的旧区间(改链接 = 覆盖旧链接)。
  EditableTextContent applyMark(int start, int end, MarkKind kind,
      {String? attr}) {
    assert(start >= 0 && end <= text.length && start <= end);
    if (start == end) return this;
    // 先清区间上同 kind 异 attr 的部分(removeMark 全清后重加同 attr 的)
    var base = this;
    if (kind == MarkKind.link) {
      base = base.removeMark(start, end, kind);
    }
    final same = <MarkSpan>[];
    final others = <MarkSpan>[];
    for (final m in base.marks) {
      (m.kind == kind && m.attr == attr ? same : others).add(m);
    }
    // 与 [start,end) 相交/相邻的同 kind 同 attr 区间合并成一条
    var ns = start;
    var ne = end;
    final keep = <MarkSpan>[];
    for (final m in same) {
      if (m.end < ns || m.start > ne) {
        keep.add(m);
      } else {
        if (m.start < ns) ns = m.start;
        if (m.end > ne) ne = m.end;
      }
    }
    return EditableTextContent(
      text: text,
      marks: [
        ...others,
        ...keep,
        MarkSpan(start: ns, end: ne, kind: kind, attr: attr),
      ],
      atoms: atoms,
    );
  }

  /// 从 `[start, end)` 移除 [kind](区间切分)。
  EditableTextContent removeMark(int start, int end, MarkKind kind) {
    assert(start >= 0 && end <= text.length && start <= end);
    if (start == end) return this;
    final newMarks = <MarkSpan>[];
    for (final m in marks) {
      if (m.kind != kind || m.end <= start || m.start >= end) {
        newMarks.add(m);
        continue;
      }
      // 相交:留两侧残段
      if (m.start < start) {
        newMarks.add(m.copyWith(end: start));
      }
      if (m.end > end) {
        newMarks.add(m.copyWith(start: end));
      }
    }
    return EditableTextContent(text: text, marks: newMarks, atoms: atoms);
  }

  /// toggle:全覆盖 → 移除;否则 → 补齐(主流编辑器语义)。
  EditableTextContent toggleMarkInRange(int start, int end, MarkKind kind) =>
      isRangeFullyMarked(start, end, kind)
          ? removeMark(start, end, kind)
          : applyMark(start, end, kind);

  /// 对 `[start, end)` 精确设置 marks 集合(pending style 应用:
  /// 先清区间上全部 kind,再施加 [kinds])。
  ///
  /// **link 不参与**:pending 机制不带 attr,applyMark(link) 会产
  /// href=null 的坏链接;链接中间打字的延续由 [insert] 的区间拉伸
  /// 天然保证,边界打字不延续(主流编辑器语义)。
  EditableTextContent applyExactMarks(int start, int end, Set<MarkKind> kinds) {
    var c = this;
    for (final kind in MarkKind.values) {
      if (kind == MarkKind.link) continue;
      c = kinds.contains(kind)
          ? c.applyMark(start, end, kind)
          : c.removeMark(start, end, kind);
    }
    return c;
  }

  /// [offset] 光标处的"当前样式集"(pending 初值/工具栏高亮):
  /// 取光标**前一个字符**上的 marks(行首取后一个);原子字符视为无样式。
  /// link 不计入(不参与 pending,见 [applyExactMarks])。
  Set<MarkKind> marksAt(int offset) {
    assert(offset >= 0 && offset <= text.length);
    if (text.isEmpty) return const {};
    final probe = offset > 0 ? offset - 1 : 0;
    if (isAtomAt(probe)) return const {};
    return {
      for (final m in marks)
        if (m.kind != MarkKind.link && m.start <= probe && probe < m.end)
          m.kind,
    };
  }

  /// [offset] 光标处覆盖的 link mark 完整区间(链接工具条定位/原位
  /// 编辑用)。返回 (start, end, href);无 → null。
  /// 探测口径与 [linkHrefAt] 一致:光标"贴着链接尾"也算在内(probe =
  /// offset-1,与官方 getMarkRange 的 inclusive 语义对齐)。
  (int, int, String?)? linkRangeAt(int offset) {
    assert(offset >= 0 && offset <= text.length);
    if (text.isEmpty) return null;
    final probe = offset > 0 ? offset - 1 : 0;
    for (final m in marks) {
      if (m.kind == MarkKind.link && m.start <= probe && probe < m.end) {
        return (m.start, m.end, m.attr);
      }
    }
    return null;
  }

  /// [offset] 光标处覆盖的 link href(工具栏"编辑链接"预填用);无 → null。
  String? linkHrefAt(int offset) {
    assert(offset >= 0 && offset <= text.length);
    if (text.isEmpty) return null;
    final probe = offset > 0 ? offset - 1 : 0;
    for (final m in marks) {
      if (m.kind == MarkKind.link && m.start <= probe && probe < m.end) {
        return m.attr;
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EditableTextContent &&
          runtimeType == other.runtimeType &&
          text == other.text &&
          listEquals(marks, other.marks) &&
          mapEquals(atoms, other.atoms);

  @override
  int get hashCode => Object.hash(
        text,
        Object.hashAll(marks),
        Object.hashAll(atoms.entries.map((e) => Object.hash(e.key, e.value))),
      );

  @override
  String toString() => 'EditableTextContent(${text.length} chars, '
      '${marks.length} marks, ${atoms.length} atoms)';

  // -----------------------------------------------------------------
  // Mark reveal: 光标在 mark 边界时展开标记字符
  // -----------------------------------------------------------------

  /// 查找光标所在边界的 mark(光标 == mark.start 或 == mark.end)。
  /// 返回第一个匹配的 mark；link 不参与展开。
  MarkSpan? markAtBoundary(int offset) {
    for (final m in marks) {
      // link 与颜色系不参与显形:它们的字面量带值([color=#f00] /
      // ](href)),而显形的标记表只按 kind 取串、拿不到 attr,展开会把
      // 色值/链接丢掉。这两类靠工具栏和源码模式编辑。
      // link 不参与显形(闭标记 ](href) 与链接编辑另有入口)。
      // 颜色系**参与** —— 展开成 [color=#xxx]…[/color] 字面量才能像
      // markdown 一样改色值/改范围。
      if (m.kind == MarkKind.link) continue;
      if (offset == m.start || offset == m.end) return m;
    }
    return null;
  }

  /// 展开一个 mark：移除 MarkSpan，在文本对应位置插入标记字符。
  /// 返回 (新 content, 光标偏移量调整值)。
  (EditableTextContent, int) revealMark(MarkSpan mark, int cursorOffset) {
    // 带 attr 的 mark 要把值写进字面量,否则展开再折叠就把值丢了:
    // link 的值在**闭**标记(`](href)`),颜色的值在**开**标记
    // (`[color=#f00]`)。
    final open = switch (mark.kind) {
      MarkKind.textColor => '[color=${mark.attr ?? ''}]',
      MarkKind.bgColor => '[bgcolor=${mark.attr ?? ''}]',
      _ => _markOpenTag(mark.kind),
    };
    final close = mark.kind == MarkKind.link
        ? '](${mark.attr ?? ''})'
        : _markCloseTag(mark.kind);
    // 先移除 mark
    var c = removeMark(mark.start, mark.end, mark.kind);
    // 在 end 处插入闭标记
    c = c.insert(mark.end, close);
    // 在 start 处插入开标记
    c = c.insert(mark.start, open);
    // 光标在 mark 区域内或边界上 → 跳过开标记；在 mark 之前 → 不动
    final shift = cursorOffset < mark.start ? 0 : open.length;
    return (c, shift);
  }

  /// 尝试折叠已展开的标记：检查文本中是否有匹配的标记对，
  /// 如有则移除标记字符并重建 MarkSpan。
  /// [revealStart] 是展开时的原始 mark.start（开标记插入位置）。
  /// 返回 (新 content, 新光标绝对偏移, 重建的 MarkSpan)；
  /// 若标记已被破坏则返回 null（保持现状）。
  (EditableTextContent, int, MarkSpan)? collapseMark(
    int revealStart,
    MarkKind kind,
    int cursorOffset,
  ) {
    final close = _markCloseTag(kind);
    final closeLen = close.length;
    // 开标记:颜色系带色值,长度随用户编辑变化 → 正则取;其余定长比对。
    final int openLen;
    String? openAttr;
    final openRe = switch (kind) {
      MarkKind.textColor => _colorOpenRe,
      MarkKind.bgColor => _bgColorOpenRe,
      _ => null,
    };
    if (openRe != null) {
      final m = openRe.matchAsPrefix(text, revealStart);
      if (m == null) return null;
      openLen = m.end - m.start;
      openAttr = m.group(1);
    } else {
      final open = _markOpenTag(kind);
      openLen = open.length;
      if (revealStart + openLen > text.length) return null;
      if (text.substring(revealStart, revealStart + openLen) != open) {
        return null;
      }
    }
    // 从末尾往前找配对闭标记（避免匹配用户输入的同字符）
    final contentStart = revealStart + openLen;
    final int closePos;
    final int closeLenActual;
    String? attr;
    if (kind == MarkKind.link) {
      // `](href)`:href 是用户可改的,长度不固定 —— 正则取最后一处。
      final ms = _linkCloseRe.allMatches(text, contentStart).toList();
      if (ms.isEmpty) return null;
      final m = ms.last;
      closePos = m.start;
      closeLenActual = m.end - m.start;
      attr = m.group(1);
    } else {
      closePos = text.lastIndexOf(close, text.length);
      closeLenActual = closeLen;
      attr ??= openAttr; // 颜色:值在开标记里
    }
    if (closePos < contentStart) return null;
    final closeEnd = closePos + closeLenActual;
    // 移除闭标记
    var c = delete(closePos, closeEnd);
    // 移除开标记
    c = c.delete(revealStart, revealStart + openLen);
    // 重建 MarkSpan
    final markStart = revealStart;
    final markEnd = closePos - openLen;
    if (markStart < markEnd) {
      c = c.applyMark(markStart, markEnd, kind, attr: attr);
    }
    // 精确计算新光标位置
    int newCursor;
    if (cursorOffset <= revealStart) {
      newCursor = cursorOffset;
    } else if (cursorOffset <= revealStart + openLen) {
      newCursor = revealStart;
    } else if (cursorOffset <= closePos) {
      newCursor = cursorOffset - openLen;
    } else if (cursorOffset <= closeEnd) {
      newCursor = closePos - openLen;
    } else {
      newCursor = cursorOffset - openLen - closeLenActual;
    }
    return (
      c,
      newCursor.clamp(0, c.length),
      MarkSpan(start: markStart, end: markEnd, kind: kind, attr: attr),
    );
  }
}

/// link 的闭标记 `](href)`(href 允许为空;不含 `)` 字符)。
final RegExp _linkCloseRe = RegExp(r'\]\(([^)]*)\)');

/// 颜色开标记(色值用户可改 → 正则,不能定长比对)。
final RegExp _colorOpenRe = RegExp(r'\[color=([^\]]*)\]');
final RegExp _bgColorOpenRe = RegExp(r'\[bgcolor=([^\]]*)\]');

/// mark 开标记。
String _markOpenTag(MarkKind kind) => switch (kind) {
      MarkKind.strong => '**',
      MarkKind.em => '*',
      MarkKind.inlineCode => '`',
      MarkKind.underline => '[u]',
      MarkKind.lineThrough => '~~',
      MarkKind.spoilerInline => '[spoiler]',
      MarkKind.link => '[',
      // 不参与显形(见 markAtBoundary),给个空串保 switch 穷尽
      MarkKind.textColor || MarkKind.bgColor => '',
    };

/// mark 闭标记。
String _markCloseTag(MarkKind kind) => switch (kind) {
      MarkKind.strong => '**',
      MarkKind.em => '*',
      MarkKind.inlineCode => '`',
      MarkKind.underline => '[/u]',
      MarkKind.lineThrough => '~~',
      MarkKind.spoilerInline => '[/spoiler]',
      MarkKind.link => ']',
      MarkKind.textColor => '[/color]',
      MarkKind.bgColor => '[/bgcolor]',
    };
