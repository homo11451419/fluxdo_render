/// Markdown 快捷语法(input rules)—— 类 Notion 输入体验的核心。
///
/// 对齐官方 ProseMirror composer 的 buildInputRules(core/inputrules.js):
/// - **块级**(行首标记 + 空格触发):`# `→标题、`- `/`* `→无序列表、
///   `1. `→有序列表、`> `→引用层;
/// - **行内**(收尾定界符触发):`**x**`→粗体、`*x*`→斜体、`` `x` ``→
///   行内代码、`~~x~~`→删除线;
/// - **hr**(`---` + 空格):由 [InputRuleOutcome.hrRequest] 上抛,视图层
///   经 cook 链路插分隔线岛(状态层不造岛)。
///
/// 触发时机:IME 文本落地后、无 composing 时(EditorImeClient 调用)。
/// 中文 composing 期间绝不触发 —— 预编辑文本是临时的。
///
/// 撤销语义(官方 undoable 同款):规则应用前 seal —— undo 一步回到
/// 字面文本(`**粗**` 原样),再 undo 才删字符。
///
/// 排除:光标处于 inlineCode mark 内时行内规则不触发(代码里写 `*` 是
/// 字面量);块级规则对 heading/listItem 块不触发(已是结构块)。
library;

import '../model/editable_text_content.dart';
import '../model/editor_state.dart';
import '../model/markdown_serializer.dart' show parseImageMarkdown;

/// 规则应用结果。
enum InputRuleOutcome {
  /// 无规则命中。
  none,

  /// 已应用(文档已变,调用方需 reconcile IME)。
  applied,

  /// `---` 命中:请求视图层插入分隔线(状态层不产岛节点)。
  /// 触发行文本已清空。
  hrRequest,
}

/// 对 [blockId] 块在光标处尝试应用 input rules。
///
/// [typedChar]:本次输入落地的最后一个字符(触发器判定用;IME 批量
/// 上屏时为末字符)。只有 ' '(块级触发)与定界符尾字符(行内触发)
/// 才可能命中,其余字符 O(1) 直接返回。
InputRuleOutcome tryApplyInputRules(
  EditorState state,
  String blockId, {
  required String typedChar,
}) {
  if (state.hasComposing) return InputRuleOutcome.none;
  final sel = state.selection;
  if (sel == null || !sel.isCollapsed || sel.extent.blockId != blockId) {
    return InputRuleOutcome.none;
  }
  final block = state.textBlockById(blockId);
  if (block == null) return InputRuleOutcome.none;

  if (typedChar == ' ') {
    return _tryBlockRules(state, block, sel.extent.offset);
  }
  // mark 展开区内是字面标记编辑态(光标在边界展开的 `**`),行内规则
  // 必须避让 —— 否则规则会把展开的标记立即折叠回 mark,编辑功能被吃掉。
  if (state.caretInRevealedRegion) return InputRuleOutcome.none;
  if (typedChar == ')') {
    return _tryImageOrLinkRule(state, block, sel.extent.offset);
  }
  if (typedChar == '*' || typedChar == '`' || typedChar == '~' || typedChar == '_') {
    final tail = _tryInlineRules(state, block, sel.extent.offset);
    if (tail != InputRuleOutcome.none) return tail;
    // 收尾定界符先打、开定界符后补的场景(`诚邀你测试~~` 打完再回行首
    // 补 `~~`)：此时光标停在**开**定界符之后,上面的 `$` 锚定规则看的是
    // 光标左边,永远命中不了。
    return _tryOpenDelimRules(state, block, sel.extent.offset);
  }
  // 光标后紧跟闭定界符:先打好 `****` 再回中间填内容的场景(收尾定
  // 界符不是最后敲的,上面的 $ 锚定规则永远不会命中)—— 把光标后的
  // 闭定界符拼上再匹配,补齐"实时渲染"预期。
  return _tryInsidePairRules(state, block, sel.extent.offset);
}

// ---------------------------------------------------------------------
// 块级规则(行首标记 + 空格)
// ---------------------------------------------------------------------

final _headingRe = RegExp(r'^(#{1,6}) $');
final _bulletRe = RegExp(r'^[-*] $');
final _orderedRe = RegExp(r'^(\d{1,9})[.)] $');
final _quoteRe = RegExp(r'^> $');
final _hrRe = RegExp(r'^(---|\*\*\*|___) $');

InputRuleOutcome _tryBlockRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  // 块级标记必须在**行首起敲**:光标前的全部文本就是标记本身。
  // (含 '\n' 软换行的段落里,只认真正的块首 —— 对齐官方
  // textblockTypeInputRule 的 ^ 锚定。)
  final before = block.content.text.substring(0, caret);
  if (before.contains('\n')) return InputRuleOutcome.none;
  // 标记区不能有原子(emoji 后打 "# " 不是标题意图)
  for (var i = 0; i < caret; i++) {
    if (block.content.isAtomAt(i)) return InputRuleOutcome.none;
  }

  // hr:任何块类型都可触发(空段打 --- )
  final hr = _hrRe.firstMatch(before);
  if (hr != null && block.isParagraph) {
    state.sealHistory();
    state.applyBlockInputRule(
      block.id,
      markerLength: caret,
      transform: (b) => b, // 类型不变,仅清标记;岛由视图层插
    );
    return InputRuleOutcome.hrRequest;
  }

  // 已是结构块(heading/listItem)不再转换;引用层可继续叠标记
  final heading = _headingRe.firstMatch(before);
  if (heading != null && !block.isHeading && !block.isListItem) {
    final level = heading.group(1)!.length;
    state.sealHistory();
    state.applyBlockInputRule(
      block.id,
      markerLength: caret,
      transform: (b) => b.asHeading(level),
    );
    return InputRuleOutcome.applied;
  }

  if (_bulletRe.hasMatch(before) && !block.isListItem && !block.isHeading) {
    state.sealHistory();
    state.applyBlockInputRule(
      block.id,
      markerLength: caret,
      transform: (b) => b.asListItem(ordered: false),
    );
    return InputRuleOutcome.applied;
  }

  final ordered = _orderedRe.firstMatch(before);
  if (ordered != null && !block.isListItem && !block.isHeading) {
    final start = int.tryParse(ordered.group(1)!) ?? 1;
    state.sealHistory();
    state.applyBlockInputRule(
      block.id,
      markerLength: caret,
      transform: (b) => b.asListItem(ordered: true, listStart: start),
    );
    return InputRuleOutcome.applied;
  }

  if (_quoteRe.hasMatch(before) && block.isParagraph) {
    state.sealHistory();
    state.applyBlockInputRule(
      block.id,
      markerLength: caret,
      transform: (b) => b.copyWith(
        containers: [
          QuoteFrame(groupId: nextFrameGroupId()),
          ...b.containers,
        ],
      ),
    );
    return InputRuleOutcome.applied;
  }

  return InputRuleOutcome.none;
}

// ---------------------------------------------------------------------
// 行内规则(收尾定界符)
// ---------------------------------------------------------------------

/// (正则, mark, 定界符)。按特异性排序:长定界符优先(`**` 先于 `*`)。
/// 内容组不允许含定界字符本身(官方 [^*]+ 同款),且首尾非空格
/// (`** x**` 不触发 —— CommonMark 语义)。
final List<(RegExp, MarkKind, String)> _inlineRules = [
  (RegExp(r'\*\*([^*\s](?:[^*]*[^*\s])?)\*\*$'), MarkKind.strong, '**'),
  (RegExp(r'__([^_\s](?:[^_]*[^_\s])?)__$'), MarkKind.strong, '__'),
  (RegExp(r'~~([^~\s](?:[^~]*[^~\s])?)~~$'), MarkKind.lineThrough, '~~'),
  (RegExp(r'`([^`]+)`$'), MarkKind.inlineCode, '`'),
  // 单 * 斜体:前面不能还是 *(否则和 ** 混淆)
  (RegExp(r'(?<!\*)\*([^*\s](?:[^*]*[^*\s])?)\*$'), MarkKind.em, '*'),
  (RegExp(r'(?<!_)_([^_\s](?:[^_]*[^_\s])?)_$'), MarkKind.em, '_'),
];

InputRuleOutcome _tryInlineRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final before = block.content.text.substring(0, caret);
  // 光标处于 inlineCode mark 内:字面量区,不触发
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  for (final (re, kind, delim) in _inlineRules) {
    final m = re.firstMatch(before);
    if (m == null) continue;
    final contentText = m.group(1)!;
    final matchStart = m.start + (m.group(0)!.length -
        (contentText.length + delim.length * 2));
    // 区间内含原子:FFFC 参与正则会当普通字符 —— 允许(emoji 可加粗),
    // 但含 '\n' 不允许(跨软换行不成对)。
    if (contentText.contains('\n')) continue;

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: matchStart,
      delimLength: delim.length,
      contentLength: contentText.length,
      kind: kind,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// 补打**开**定界符触发:右边已经有配对的闭定界符。
///
/// `~~诚邀你测试~~` 这种"先打后半截、再回来补前半截"的写法,光标停在开
/// 定界符之后,[_tryInlineRules] 的 `$` 锚定正则只看光标左边,一条都命中
/// 不了 —— 表现为怎么打都不渲染。这里把光标**右边**到闭定界符的那段拼
/// 回去,用同一批正则判定,规则集保持单一来源。
///
/// 闭定界符只在当前**行**内找(不跨软换行),跟其它规则同口径。
InputRuleOutcome _tryOpenDelimRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final text = block.content.text;
  if (caret <= 0 || caret >= text.length) return InputRuleOutcome.none;
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  for (final (re, kind, delim) in _inlineRules) {
    final open = caret - delim.length;
    if (open < 0) continue;
    // 光标左边恰好是一个完整的开定界符
    if (!text.startsWith(delim, open)) continue;
    // 再往左不能还是同类定界字符(`***x**` 归属不明,不触发)
    if (open > 0 && text[open - 1] == delim[0]) continue;

    final rest = text.substring(caret);
    final nl = rest.indexOf('\n');
    final line = nl < 0 ? rest : rest.substring(0, nl);
    final closeAt = line.indexOf(delim);
    if (closeAt <= 0) continue; // 没有闭定界符 / 内容为空
    // 闭定界符后面不能还是同类定界字符
    final afterClose = closeAt + delim.length;
    if (afterClose < line.length && line[afterClose] == delim[0]) continue;

    final candidate = delim + line.substring(0, afterClose);
    final m = re.firstMatch(candidate);
    // 必须整段命中,否则 `~~a~~b~~` 这种会切错边界
    if (m == null || m.start != 0 || m.group(0)!.length != candidate.length) {
      continue;
    }
    final contentText = m.group(1)!;
    if (contentText.contains('\n')) continue;

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: open,
      delimLength: delim.length,
      contentLength: contentText.length,
      kind: kind,
      // 光标本来就在内容首,别甩到尾巴上
      caretAtEnd: false,
    );
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// 光标后紧跟闭定界符的"填内容"匹配:`**|**` 里打字 → 光标后是 `**`,
/// 把它拼到光标前文本上正则匹配。命中 = 完整 `**x**` 模式,内容恰好
/// 终于光标(闭定界符位于光标处)。
InputRuleOutcome _tryInsidePairRules(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final text = block.content.text;
  if (caret >= text.length) return InputRuleOutcome.none;
  final next = text[caret];
  if (next != '*' && next != '`' && next != '~' && next != '_') {
    return InputRuleOutcome.none;
  }
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  final before = text.substring(0, caret);
  for (final (re, kind, delim) in _inlineRules) {
    if (!text.startsWith(delim, caret)) continue;
    // 闭定界符后不能还是同类定界字符(`**q***` 归属不明,不触发)。
    final after = caret + delim.length;
    if (after < text.length && text[after] == delim[0]) continue;
    final m = re.firstMatch(before + delim);
    if (m == null) continue;
    final contentText = m.group(1)!;
    if (contentText.contains('\n')) continue;
    final matchStart = m.start + (m.group(0)!.length -
        (contentText.length + delim.length * 2));

    state.sealHistory();
    state.applyInlineInputRule(
      block.id,
      matchStart: matchStart,
      delimLength: delim.length,
      contentLength: contentText.length,
      kind: kind,
    );
    // 立刻回到展开(字面)态:光标还夹在定界符之间 = 正在编辑这段内容,
    // 此时渲染会打断输入。mark 已建好,光标走出闭定界符时自然折叠。
    state.revealMarkAtCaret();
    return InputRuleOutcome.applied;
  }
  return InputRuleOutcome.none;
}

/// `![alt](src)` / `[文字](href)` 收尾 `)` 触发。图片变原子,链接变
/// link mark(href 进 attr)。
InputRuleOutcome _tryImageOrLinkRule(
  EditorState state,
  TextBlock block,
  int caret,
) {
  final before = block.content.text.substring(0, caret);
  if (block.content.marksAt(caret).contains(MarkKind.inlineCode)) {
    return InputRuleOutcome.none;
  }

  final imgM = _imageTailRe.firstMatch(before);
  if (imgM != null) {
    final img = parseImageMarkdown(imgM.group(0)!);
    if (img != null) {
      state.sealHistory();
      state.applyImageInputRule(block.id,
          start: imgM.start, end: caret, image: img);
      return InputRuleOutcome.applied;
    }
  }

  final linkM = _linkTailRe.firstMatch(before);
  if (linkM != null) {
    final label = linkM.group(1)!;
    // 标签里含原子(哨兵)不拆:`[![图](…)](href)` 这种嵌套交给 cook。
    if (!label.contains(kAtomChar)) {
      state.sealHistory();
      state.applyLinkInputRule(block.id,
          start: linkM.start,
          end: caret,
          label: label,
          href: linkM.group(2)!);
      return InputRuleOutcome.applied;
    }
  }
  return InputRuleOutcome.none;
}

final _imageTailRe = RegExp(r'!\[[^\]]*\]\([^)\s]*\)$');
final _linkTailRe = RegExp(r'(?<!!)\[([^\]]+)\]\(([^)\s]*)\)$');
