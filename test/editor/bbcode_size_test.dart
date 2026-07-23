/// `[size=N]` 字号:解析 → 编辑原子 → 序列化 往返。
///
/// 基准取服务端真实 cooked 样本:
/// - `[size=0]`   → `<span style="font-size:0%">收到请回复123</span>`(视觉隐藏)
/// - `[size=150]` → `<span style="font-size:150%">hifumi！</span>`
///
/// 阅读端对齐网页端原样生效(0 倍即隐藏,不夹上下限);编辑端把它当行内
/// 原子(固定块),免得 0 倍隐形/超大撑破编辑器。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

ParagraphNode para(String html) =>
    ParagraphParser().parse(html).first as ParagraphNode;

void main() {
  group('解析 span[style] 的 font-size', () {
    test('真实样本:size=0 → 0 倍(视觉隐藏)', () {
      final p = para('<p><span style="font-size:0%">收到请回复123</span></p>');
      final run = p.inlines.single as SizedRun;
      expect(run.scale, 0.0);
      expect((run.children.single as TextRun).text, '收到请回复123');
    });

    test('真实样本:size=150 → 1.5 倍', () {
      final p = para('<p><span style="font-size:150%">hifumi！</span></p>');
      expect((p.inlines.single as SizedRun).scale, 1.5);
    });

    test('字号与颜色同 span:嵌套不互相吞', () {
      final p =
          para('<p><span style="font-size:150%;color:#ff0000">又大又红</span></p>');
      final colored = p.inlines.single as ColoredRun;
      expect(colored.color, isNotNull);
      expect((colored.children.single as SizedRun).scale, 1.5);
    });

    test('绝对单位不认(语义不是相对父级倍数)', () {
      final p = para('<p><span style="font-size:12px">绝对单位</span></p>');
      expect(p.inlines.single, isA<TextRun>());
    });

    test('只有颜色时行为不变(回归)', () {
      final p = para('<p><span style="color:#ff0000">只有色</span></p>');
      expect(p.inlines.single, isA<ColoredRun>());
    });
  });

  group('编辑端:整段岛化成块(与分割线同款)', () {
    test('不进白名单 —— 靠岛化成块', () {
      expect(isEditableInline(const SizedRun(scale: 0, children: [])), isFalse);
    });

    test('含 size 的段落 → IslandBlock(块,不是文字)', () {
      var n = 0;
      final doc = blockNodesToDoc(
        [para('<p>前<span style="font-size:150%">大</span>后</p>')],
        () => 'e_${n++}',
      );
      expect(doc.single, isA<IslandBlock>(),
          reason: '整段成块:双击/回车进去改源码,与分割线一致');
    });

    test('岛序列化写回 BBCode,内容不丢', () {
      var n = 0;
      final doc = blockNodesToDoc(
        [para('<p>前<span style="font-size:0%">隐</span>后</p>')],
        () => 'e_${n++}',
      );
      final md = docToMarkdown(doc);
      expect(md, contains('[size=0]隐[/size]'));
      expect(md, contains('前'));
      expect(md, contains('后'));
    });
  });

  group('显形编辑(同分割线思路)', () {
    test('原子能展开成字面 BBCode', () {
      const run = SizedRun(scale: 1.5, children: [TextRun('大')]);
      expect(atomToMarkdown(run), '[size=150]大[/size]');
    });

    test('改过的字面能解析回原子', () {
      final r = parseSizeMarkdown('[size=200]改大了[/size]')!;
      expect(r.scale, 2.0);
      expect((r.children.single as TextRun).text, '改大了');
    });

    test('size=0 字面往返', () {
      expect(parseSizeMarkdown('[size=0]隐[/size]')!.scale, 0.0);
    });

    test('语法不完整 → null(保持字面文本,不吞内容)', () {
      expect(parseSizeMarkdown('[size=150]没闭合'), isNull);
      expect(parseSizeMarkdown('[size=abc]x[/size]'), isNull);
    });
  });

  group('序列化写回 BBCode', () {
    test('size=0 往返', () {
      final p = para('<p><span style="font-size:0%">收到请回复123</span></p>');
      var n = 0;
      final doc = blockNodesToDoc([p], () => 'e_${n++}');
      expect(docToMarkdown(doc), contains('[size=0]收到请回复123[/size]'));
    });

    test('size=150 往返', () {
      final p = para('<p><span style="font-size:150%">hifumi！</span></p>');
      var n = 0;
      final doc = blockNodesToDoc([p], () => 'e_${n++}');
      expect(docToMarkdown(doc), contains('[size=150]hifumi！[/size]'));
    });

    test('写整数不写 150.0', () {
      final p = para('<p><span style="font-size:150%">x</span></p>');
      var n = 0;
      final doc = blockNodesToDoc([p], () => 'e_${n++}');
      expect(docToMarkdown(doc), isNot(contains('150.0')));
    });
  });
}
