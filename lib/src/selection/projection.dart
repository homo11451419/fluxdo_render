/// 渲染偏移 ↔ 逻辑投影文本 的映射表。
///
/// 一个段落压平成 Text.rich 后有两套坐标系:
/// - **渲染偏移**:RenderParagraph 看到的字符偏移,emoji/mention/image 等
///   WidgetSpan 各占 1 个 ￼(U+FFFC)。命中(getPositionForOffset)/高亮
///   (getBoxesForSelection)都认这个。
/// - **逻辑投影**:复制/引用要的纯文本,emoji→`:name:`、mention→`@username`。
///   这个要喂主项目 HtmlTextMapper 在原始 cooked 里匹配。
///
/// 映射表在 InlineFlattener 压平时**同步构建**(投影规则与 span 构造同源),
/// 每个 InlineSpan 叶子产出一条 [ProjectionEntry]。复制时 [RenderTextProjection.project]
/// 把渲染选区区间翻译成逻辑文本。
library;

import 'package:flutter/foundation.dart';

import '../flatten/soft_break.dart' show kSoftBreakChar;

/// 投影条目的来源类型(调试 + 占位符原子性判定用)。
enum ProjectionKind {
  text,
  lineBreak,
  inlineCode,

  /// 行内代码两侧注入的 NBSP 粘性内边距(见 kInlineCodePadChar)。
  /// 渲染占 1 字符、逻辑投影恒为空串(不属于内容,复制/引用不带出)。
  codePad,
  emoji,

  /// WidgetSpan 版 mention(带状态 emoji 时仍走此路径):原子占位。
  mention,

  /// 纯 TextSpan 版 mention 的文本体(`@username`,renderLen == 逻辑长,
  /// 可按字符切):行内代码同款三件套,药丸底色由 painter 按本区间自绘。
  mentionText,

  /// mentionText 两侧的 NBSP 粘性内边距,语义同 [codePad]。
  mentionPad,
  image,
  spoiler,
  footnote,
  localDate,
  clickCount,
  mathInline,
}

/// 一段连续渲染偏移区间 `[renderStart, renderStart+renderLen)` → 逻辑文本。
///
/// - **文本类**(text/inlineCode/lineBreak):renderLen == logicalText 的渲染
///   长度,可按字符 substring 部分投影。
/// - **占位类**(emoji/mention/image/...):renderLen 恒为 1(一个 ￼),
///   [logicalText] 是整体投影串(如 `:heart:`),**原子** —— 选区相交即整条
///   计入,不切半。
/// - [logicalText] 为空串 = 不贡献文本(空名 emoji / 空 alt image / clickCount)。
@immutable
class ProjectionEntry {
  const ProjectionEntry({
    required this.renderStart,
    required this.renderLen,
    required this.logicalText,
    required this.kind,
  });

  final int renderStart;
  final int renderLen;
  final String logicalText;
  final ProjectionKind kind;

  /// 渲染偏移区间末端(不含)。
  int get renderEnd => renderStart + renderLen;

  /// 占位类(￼,原子,不可按字符切)。
  bool get isAtomic => kind != ProjectionKind.text &&
      kind != ProjectionKind.inlineCode &&
      kind != ProjectionKind.mentionText &&
      kind != ProjectionKind.lineBreak;

  @override
  String toString() =>
      'ProjectionEntry($kind [$renderStart,$renderEnd) "$logicalText")';
}

/// 一个段落(一个 RenderParagraph)的完整映射表。
@immutable
class RenderTextProjection {
  RenderTextProjection(List<ProjectionEntry> entries)
      : entries = List.unmodifiable(entries),
        renderLength = entries.isEmpty ? 0 : entries.last.renderEnd;

  /// 按 renderStart 升序、连续覆盖整段(无空洞、无重叠)。
  final List<ProjectionEntry> entries;

  /// 总渲染长度,应 == RenderParagraph.text.toPlainText().length。
  final int renderLength;

  /// 本段是否含行内代码区间。供 SelectableTextBox 决定是否挂灰底
  /// painter —— 绝大多数段落无行内代码,不挂即省一个 RenderCustomPaint
  /// 与其每次重录制的空跑 paint。entries 量级为段内 run 数,any 短路。
  bool get hasInlineCode =>
      entries.any((e) => e.kind == ProjectionKind.inlineCode);

  /// 本段是否含 TextSpan 版 mention 区间(药丸底色由 painter 自绘)。
  bool get hasSpanMention =>
      entries.any((e) => e.kind == ProjectionKind.mentionText);

  static final RenderTextProjection empty = RenderTextProjection(const []);

  /// 把渲染偏移区间 `[renderStart, renderEnd)` 投影成逻辑文本。
  ///
  /// - 文本类:取与区间交集的 substring。
  /// - 占位类(￼ 原子):只要区间与该条目有任何交集,就整条写入 [logicalText]。
  ///
  /// 入参越界自动 clamp;start >= end 返回空串。
  String project(int renderStart, int renderEnd) {
    var start = renderStart;
    var end = renderEnd;
    if (start > end) {
      final t = start;
      start = end;
      end = t;
    }
    start = start.clamp(0, renderLength);
    end = end.clamp(0, renderLength);
    if (start >= end) return '';

    final buf = StringBuffer();
    for (final e in entries) {
      // 与 [start, end) 无交集 → 跳过。
      if (e.renderEnd <= start || e.renderStart >= end) continue;

      if (e.isAtomic) {
        // ￼ 原子:相交即整条。
        buf.write(e.logicalText);
        continue;
      }

      // 文本类:logicalText 渲染长度 == renderLen,按字符切交集。
      // (text/inlineCode/lineBreak 的 logicalText.length 应 == renderLen;
      //  lineBreak 是 '\n' 长度 1 == renderLen 1。)
      final localStart = (start - e.renderStart).clamp(0, e.renderLen);
      final localEnd = (end - e.renderStart).clamp(0, e.renderLen);
      if (localStart >= localEnd) continue;
      // 防御:logicalText 可能与 renderLen 不等长(理论不应发生),clamp 到串长。
      final s = localStart.clamp(0, e.logicalText.length);
      final t = localEnd.clamp(0, e.logicalText.length);
      if (s < t) buf.write(e.logicalText.substring(s, t));
    }
    return buf.toString();
  }

  /// 整段逻辑文本(渲染全区间投影)。
  String projectAll() => project(0, renderLength);

  /// 整段逻辑文本长度(所有 entry 的 logicalText 长度和,**含**软换行 ZWSP)。
  int get logicalLength =>
      entries.fold(0, (sum, e) => sum + e.logicalText.length);

  // -------------------------------------------------------------------
  // 内容空间 ↔ 渲染空间(编辑器坐标换算,src/editor)
  //
  // **内容空间** = 编辑文档文本(EditableTextContent.text)的偏移系:
  // - 软换行 ZWSP(kSoftBreakChar,soft_break 注入,渲染/投影都有)宽 0;
  // - codePad(NBSP 粘性内边距,logicalText '')宽 0;
  // - 文本类 entry 其余字符 1:1;
  // - **emoji/mention 原子宽 1**(编辑模型里是一个 U+FFFC 哨兵,M2);
  // - 其余原子类按投影串计长(编辑器 TextBlock 不出现,防御口径)。
  //
  // 在编辑器可出现的 entry 集(text/lineBreak/inlineCode/codePad/
  // emoji/mention)上,两向映射是**严格双射**。
  //
  // 与「逻辑投影空间」(projectAll,含 ZWSP,给复制/HtmlTextMapper)是
  // **两个不同空间** —— 编辑器曾直接混用,30 字符(软换行阈值)以上
  // 光标错位、段尾无法选中,就是这个混淆。
  // -------------------------------------------------------------------

  /// 单个 entry 的内容空间宽度。
  static int _contentLenOfEntry(ProjectionEntry e) => switch (e.kind) {
        // localDate/image 同 emoji/mention:编辑模型是一个 FFFC 哨兵原子
        // (M5/行内图);投影文本(预渲染串/alt)只用于复制/引用,
        // 不参与编辑坐标。
        ProjectionKind.emoji ||
        ProjectionKind.mention ||
        ProjectionKind.localDate ||
        ProjectionKind.image =>
          1,
        // **mentionText 同样宽 1**:无状态 emoji 的 mention 走纯 TextSpan
        // 路径(药丸底色由 painter 自绘),渲染占 '@username' 那么多字符,
        // 但编辑模型里仍旧只是一个 FFFC 原子。漏了这条就会按字符计长 ——
        // 光标被算进药丸内部(真机症状:@arch_linux 的光标停在 "ar|ch"),
        // 且原子之后的所有偏移全部错位。
        ProjectionKind.mentionText => 1,
        // 药丸内边距:同 codePad,不属于内容,光标不停。
        ProjectionKind.mentionPad => 0,
        _ when e.isAtomic => e.logicalText.length,
        _ => _contentLenOf(e.logicalText),
      };

  /// 内容空间总长度。
  int get contentLength =>
      entries.fold(0, (n, e) => n + _contentLenOfEntry(e));

  /// 内容偏移 → 渲染偏移。
  ///
  /// 语义:内容前 [contentOffset] 个字符之后的渲染位置。
  /// - 边界(恰在某 entry 内容末)**延迟归属**:跳过零内容 entry
  ///   (codePad/纯 ZWSP),落到下一个内容 entry 的 renderStart —— 光标
  ///   不停在 NBSP 粘性内边距上;
  /// - 多字符原子(防御口径)内部归到原子末端(不可切);
  /// - 入参越界自动 clamp。
  int renderOffsetForContent(int contentOffset) {
    var remaining = contentOffset.clamp(0, contentLength);
    for (final e in entries) {
      final entryContentLen = _contentLenOfEntry(e);
      if (remaining <= 0) {
        if (entryContentLen == 0) continue; // pad/ZWSP:光标不停这
        return e.renderStart;
      }
      if (remaining < entryContentLen) {
        if (e.isAtomic) return e.renderEnd; // 多字符原子内部 → 末端
        var seen = 0;
        final s = e.logicalText;
        for (var i = 0; i < s.length; i++) {
          if (s[i] != kSoftBreakChar) {
            seen++;
            if (seen == remaining) return e.renderStart + i + 1;
          }
        }
      }
      remaining -= entryContentLen;
    }
    return renderLength;
  }

  static int _contentLenOf(String s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] != kSoftBreakChar) n++;
    }
    return n;
  }

  /// 渲染偏移 → 内容偏移(命中/选区结果换算到编辑坐标)。
  int contentOffsetForRender(int renderOffset) {
    final target = renderOffset.clamp(0, renderLength);
    var content = 0;
    for (final e in entries) {
      if (target <= e.renderStart) return content;
      final entryContentLen = _contentLenOfEntry(e);
      if (e.isAtomic) {
        if (target < e.renderEnd) return content + entryContentLen;
        content += entryContentLen;
      } else {
        final s = e.logicalText;
        final upTo = target < e.renderEnd ? target - e.renderStart : s.length;
        for (var i = 0; i < upTo; i++) {
          if (s[i] != kSoftBreakChar) content++;
        }
        if (target < e.renderEnd) return content;
      }
    }
    return content;
  }

  @override
  String toString() =>
      'RenderTextProjection(len=$renderLength, ${entries.length} entries)';
}
