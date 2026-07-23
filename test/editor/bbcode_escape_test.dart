/// 手打 BBCode 不该被转义成字面文本。
///
/// 回归:在富文本编辑器里打 `[size=1]a[/size]`,序列化会把方括号转义成
/// `\[size=1\]a\[/size\]`,于是标签永远生效不了,用户看到的是带反斜杠的
/// 字面文本。与已有的 checklist(`[x]`)例外同理放行。
///
/// 放行范围**刻意收窄**到本地 cook 真正会转换的标签,避免把用户想当
/// 字面文本写的 `[foo]` 也吞掉。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';

String raw(String text) => docToMarkdown([
      TextBlock(id: 'e_0', content: EditableTextContent(text: text)),
    ]);

void main() {
  group('已知 BBCode 不转义', () {
    for (final t in [
      '[size=1]a[/size]',
      '[size=150]大[/size]',
      '[color=#ff0000]红[/color]',
      '[bgcolor=red]底[/bgcolor]',
      '[spoiler]秘密[/spoiler]',
      '[u]下划线[/u]',
    ]) {
      test(t, () => expect(raw(t), t));
    }
  });

  group('不该放行的照旧转义', () {
    test('未知标签', () {
      expect(raw('[foo]x[/foo]'), r'\[foo\]x\[/foo\]');
    });

    test('标签名像但带空格', () {
      expect(raw('[size =1]x'), r'\[size =1\]x');
    });

    test('普通方括号', () {
      expect(raw('数组[0]'), r'数组\[0\]');
    });

    test('markdown 链接语法仍转义(不能让它变成真链接)', () {
      expect(raw('[text](url)'), r'\[text\](url)');
    });
  });

  test('checklist 例外没被破坏(回归)', () {
    expect(raw('[x] 已完成'), '[x] 已完成');
    expect(raw('[ ] 待办'), '[ ] 待办');
  });
}
