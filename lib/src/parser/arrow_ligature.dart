/// ASCII 箭头连字:把 `->` / `<-` / `<->` 渲染成**一个**字形。
///
/// Discourse 的 cook 不做这件事(实测 `a -> b` 原样产出 `a -&gt; b`),
/// 所以这是纯客户端表现层约定 —— 帖子渲染、boost、编辑器三处共用同一
/// 张表,才能"从哪看都是一体的"。
///
/// 只在**散文文本**上用:行内代码(InlineCodeRun)、代码块、链接 href
/// 都不能过这一层,否则会把代码里的 `->` 改坏。解析器只在 TextRun 的
/// 构造点调用,天然满足。
///
/// 破折号连写(`-->`、`<--`)一并归一到同一个箭头 —— 只吃掉末尾的
/// `->` 会留下 `a-→b` 这种半截产物,比不转换更难看。
library;

const String kRightArrow = '→'; // →
const String kLeftArrow = '←'; // ←
const String kLeftRightArrow = '↔'; // ↔

/// 必须**前后有空白**(或行首行尾)才连字 —— 对齐 Discourse:紧贴着
/// 单词的 `a->b`、`well-known`、CSS 里的 `-->` 都不该变成箭头,只有
/// 独立成词的 `a -> b` 才是用户在写箭头。
///
/// 双向箭头必须先匹配:否则 `<->` 会被 `<-+` 先吃成 `←>`。
final RegExp _arrowRe = RegExp(r'(?<=^|\s)(?:<-+>|-+>|<-+)(?=\s|$)');

/// cooked HTML 里的转义形态(`<`/`>` 已被 cook 转义)。
final RegExp _escapedArrowRe =
    RegExp(r'(?<=^|\s)(?:&lt;-+&gt;|-+&gt;|&lt;-+)(?=\s|$)');

/// 把纯文本里的 ASCII 箭头替换成单字形箭头。
String applyArrowLigatures(String text) {
  if (!text.contains('-')) return text;
  return text.replaceAllMapped(_arrowRe, (m) => _glyphOf(m.group(0)!));
}

/// 把 **cooked HTML** 里的转义箭头归一成单字形。
///
/// 富文本导入的往返门禁比对的是 cooked 字符串:原 raw 的 `->` cook 后是
/// `-&gt;`,而经解析器连字后的文档序列化回去已经是 `→`,两侧 cooked 天然
/// 不等 —— 门禁会误判"往返有损"而降级源码模式。两侧都过这一层即可,
/// 因为连字本就是我们声明的显示等价。
String normalizeArrowsInCooked(String html) {
  if (!html.contains('-')) return html;
  return html.replaceAllMapped(_escapedArrowRe, (m) => _glyphOf(m.group(0)!));
}

String _glyphOf(String s) {
  final left = s.startsWith('<') || s.startsWith('&lt;');
  final right = s.endsWith('>') || s.endsWith('&gt;');
  if (left && right) return kLeftRightArrow;
  return right ? kRightArrow : kLeftArrow;
}
