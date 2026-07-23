import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  group('applyArrowLigatures', () {
    test('基本双向替换', () {
      expect(applyArrowLigatures('a -> b'), 'a → b');
      expect(applyArrowLigatures('a <- b'), 'a ← b');
      expect(applyArrowLigatures('a <-> b'), 'a ↔ b');
    });

    test('破折号连写整体归一,不留半截', () {
      expect(applyArrowLigatures('a --> b'), 'a → b');
      expect(applyArrowLigatures('a <-- b'), 'a ← b');
      expect(applyArrowLigatures('a <--> b'), 'a ↔ b');
    });

    test('无 dash 原样返回', () {
      expect(applyArrowLigatures('普通文本'), '普通文本');
      expect(applyArrowLigatures('a < b > c'), 'a < b > c');
    });

    test('不误伤普通连字符', () {
      expect(applyArrowLigatures('well-known'), 'well-known');
      expect(applyArrowLigatures('2026-07-20'), '2026-07-20');
      expect(applyArrowLigatures('---'), '---');
    });

    test('必须前后有空白 —— 紧贴单词的不算箭头', () {
      expect(applyArrowLigatures('a->b'), 'a->b');
      expect(applyArrowLigatures('a<-b'), 'a<-b');
      expect(applyArrowLigatures('x-->y'), 'x-->y');
      expect(applyArrowLigatures('fn() -> T'), 'fn() → T');
    });

    test('行首行尾算边界', () {
      expect(applyArrowLigatures('-> b'), '→ b');
      expect(applyArrowLigatures('a <-'), 'a ←');
      expect(applyArrowLigatures('->'), '→');
    });

    test('多处替换', () {
      expect(applyArrowLigatures('A -> B -> C'), 'A → B → C');
    });
  });

  group('normalizeArrowsInCooked', () {
    test('转义形态归一到同一字形', () {
      expect(normalizeArrowsInCooked('<p>a -&gt; b</p>'), '<p>a → b</p>');
      expect(normalizeArrowsInCooked('<p>a &lt;- b</p>'), '<p>a ← b</p>');
      expect(normalizeArrowsInCooked('<p>a &lt;-&gt; b</p>'), '<p>a ↔ b</p>');
    });

    test('已是字形的一侧保持不变 —— 门禁两侧才能相等', () {
      const back = '<p>a → b</p>';
      expect(normalizeArrowsInCooked(back), back);
      expect(normalizeArrowsInCooked('<p>a -&gt; b</p>'), back);
    });

    test('不动 HTML 标签本身', () {
      expect(
        normalizeArrowsInCooked('<p class="a-b">x</p>'),
        '<p class="a-b">x</p>',
      );
    });
  });

  group('ParagraphParser 接线', () {
    test('散文里的箭头被连字', () {
      final nodes = ParagraphParser().parse('<p>a -&gt; b</p>');
      final p = nodes.single as ParagraphNode;
      expect((p.inlines.single as TextRun).text, 'a → b');
    });

    test('行内代码不被连字', () {
      final nodes = ParagraphParser().parse('<p><code>a -&gt; b</code></p>');
      final p = nodes.single as ParagraphNode;
      expect((p.inlines.single as InlineCodeRun).text, 'a -> b');
    });
  });
}
