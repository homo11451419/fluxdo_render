/// 轻量行内 markdown 解析(纯文本粘贴降级用)。
///
/// 宿主接了 markdownImporter(走服务端 cook)时**不经过这里** —— 那条
/// 路产物更全(onebox/表格/代码块…)。这里只管「没有 importer / cook
/// 失败」的降级路径:从别处复制一段 `**加粗**` 过来,总不该原样躺成
/// 字面星号。
///
/// 覆盖:`**`/`__`(strong)、`*`/`_`(em)、`~~`(del)、`` ` ``(code)、
/// `[文字](href)`(link mark)、`![alt](src)`(图片原子)。
/// 不覆盖:嵌套强调的全部 CommonMark 边界情形、引用/列表等块级结构
/// (块级由 [pastePlainText] 按行前缀处理)。
library;

import 'editable_text_content.dart';
import 'markdown_serializer.dart' show parseImageMarkdown;

/// (正则, kind)。长定界符优先 —— `**` 必须先于 `*`。
final List<(RegExp, MarkKind)> _rules = [
  (RegExp(r'\*\*([^*\s](?:[^*]*[^*\s])?)\*\*'), MarkKind.strong),
  (RegExp(r'__([^_\s](?:[^_]*[^_\s])?)__'), MarkKind.strong),
  (RegExp(r'~~([^~\s](?:[^~]*[^~\s])?)~~'), MarkKind.lineThrough),
  (RegExp(r'`([^`\n]+)`'), MarkKind.inlineCode),
  (RegExp(r'(?<!\*)\*([^*\s](?:[^*]*[^*\s])?)\*(?!\*)'), MarkKind.em),
  (RegExp(r'(?<!_)_([^_\s](?:[^_]*[^_\s])?)_(?!_)'), MarkKind.em),
];

final RegExp _imageRe = RegExp(r'!\[[^\]]*\]\([^)\s]*\)');
final RegExp _linkRe = RegExp(r'(?<!!)\[([^\]]+)\]\(([^)\s]*)\)');

/// 解析行内 markdown;没有任何标记时等价于 [EditableTextContent] 直建。
EditableTextContent parseInlineMarkdown(String source) {
  if (source.isEmpty) return EditableTextContent(text: source);

  var content = EditableTextContent(text: source);

  // 1. 图片原子(最先:`![…]` 的 `[` 不能被链接规则吃掉)
  for (;;) {
    final m = _imageRe.firstMatch(content.text);
    if (m == null) break;
    final img = parseImageMarkdown(m.group(0)!);
    if (img == null) break;
    content = content.delete(m.start, m.end).insertAtom(m.start, img);
  }

  // 2. 链接:内容留下,href 进 mark attr
  for (var searchFrom = 0;;) {
    final m = _linkRe.firstMatch(content.text.substring(searchFrom));
    if (m == null) break;
    final start = searchFrom + m.start;
    final label = m.group(1)!;
    final href = m.group(2)!;
    if (label.contains(kAtomChar)) {
      // 标签里是图片原子(`[![…](…)](href)`):跳过,不拆原子。
      searchFrom = start + m.group(0)!.length;
      continue;
    }
    content = content
        .delete(start, searchFrom + m.end)
        .insert(start, label)
        .applyMark(start, start + label.length, MarkKind.link, attr: href);
    searchFrom = start + label.length;
  }

  // 3. 强调类:每轮取全文最靠前的一处命中,删定界符后重新扫
  //    (删除会让后面的偏移变,逐轮重扫最省心且不会错位)。
  for (;;) {
    RegExpMatch? best;
    MarkKind? bestKind;
    for (final (re, kind) in _rules) {
      final m = re.firstMatch(content.text);
      if (m == null) continue;
      if (best == null || m.start < best.start) {
        best = m;
        bestKind = kind;
      }
    }
    if (best == null || bestKind == null) break;
    final inner = best.group(1)!;
    // 已在 inlineCode 里的定界符是字面量,不再解析
    if (content.marksAt(best.start).contains(MarkKind.inlineCode)) break;
    final delimLen = (best.group(0)!.length - inner.length) ~/ 2;
    if (delimLen <= 0) break; // 防御:不前进就会死循环
    content = content
        .delete(best.end - delimLen, best.end)
        .delete(best.start, best.start + delimLen)
        .applyMark(best.start, best.start + inner.length, bestKind);
  }

  return content;
}
