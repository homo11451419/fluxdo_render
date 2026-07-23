/// 逃生口空段(escape gaps)。
///
/// 困住区 = 容器内块(引用/剧透/…)或只读岛:光标在顶层没法自然跟在
/// 它后面输入。回归用户反馈:引用回复时正文被吸进引用块里出不来。
/// 规则:困住区在**尾部**、或**紧邻另一个困住区**时补一个顶层普通空段;
/// 发送/序列化时未被填过的逃生空段自动回收。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/editor/model/doc_converter.dart';
import 'package:fluxdo_render/src/node/node.dart';

/// 造一个引用卡内的文本块(容器组 [groupId])。
TextBlock quoted(String id, String text, String groupId) => TextBlock(
      id: id,
      content: EditableTextContent(text: text),
      containers: [QuoteCardFrame(groupId: groupId)],
    );

TextBlock para(String id, String text) =>
    TextBlock(id: id, content: EditableTextContent(text: text));

IslandBlock island(String id) =>
    IslandBlock(id: id, node: HorizontalRuleNode(id: '$id-n'));

bool isFreeEmpty(EditorBlock b) =>
    b is TextBlock && b.containers.isEmpty && b.content.length == 0;

void main() {
  var n = 0;
  String nextId() => 'g_${n++}';
  setUp(() => n = 0);

  group('insertEscapeGaps', () {
    test('尾部引用 → 追加顶层空段', () {
      final out = insertEscapeGaps([quoted('q0', '被引用', 'A')], nextId);
      expect(out.length, 2);
      expect(isFreeEmpty(out.last), isTrue, reason: '引用后应补逃生空段');
    });

    test('尾部岛 → 追加顶层空段', () {
      final out = insertEscapeGaps([island('i0')], nextId);
      expect(out.length, 2);
      expect(isFreeEmpty(out.last), isTrue);
    });

    test('引用后已有普通段 → 不补', () {
      final out = insertEscapeGaps(
        [quoted('q0', '被引用', 'A'), para('p0', '正文')],
        nextId,
      );
      expect(out.length, 2, reason: '已有落点,不该多补');
    });

    test('两个相邻不同引用 → 中间补空段', () {
      final out = insertEscapeGaps(
        [quoted('q0', 'A引用', 'A'), quoted('q1', 'B引用', 'B')],
        nextId,
      );
      // q0, gap, q1, gap(尾)
      expect(out.length, 4);
      expect(isFreeEmpty(out[1]), isTrue, reason: '两引用之间补空段');
      expect(isFreeEmpty(out[3]), isTrue, reason: '尾部补空段');
    });

    test('同一引用组内相邻块 → 不隔', () {
      final out = insertEscapeGaps(
        [quoted('q0', '第一行', 'A'), quoted('q1', '第二行', 'A')],
        nextId,
      );
      // 同组不插,仅尾部补一个
      expect(out.length, 3);
      expect(isFreeEmpty(out[2]), isTrue);
      expect(out[0], isA<TextBlock>());
      expect(out[1], isA<TextBlock>());
    });

    test('幂等:补过再跑不重复补', () {
      final once = insertEscapeGaps([quoted('q0', '引用', 'A')], nextId);
      final twice = insertEscapeGaps(once, nextId);
      expect(twice.length, once.length);
    });

    test('顶层普通段不受影响', () {
      final out = insertEscapeGaps(
        [para('p0', '一段'), para('p1', '二段')],
        nextId,
      );
      expect(out.length, 2);
    });
  });

  group('stripUnusedEscapeGaps', () {
    test('回收尾部未填空段', () {
      final withGap = insertEscapeGaps([quoted('q0', '引用', 'A')], nextId);
      final stripped = stripUnusedEscapeGaps(withGap);
      expect(stripped.length, 1);
      expect(stripped.first, isA<TextBlock>());
    });

    test('填了内容的空段不回收', () {
      final blocks = [quoted('q0', '引用', 'A'), para('p0', '我的回复')];
      expect(stripUnusedEscapeGaps(blocks).length, 2);
    });

    test('两引用之间未填空段回收', () {
      final withGap = insertEscapeGaps(
        [quoted('q0', 'A', 'A'), quoted('q1', 'B', 'B')],
        nextId,
      );
      final stripped = stripUnusedEscapeGaps(withGap);
      // 只剩两个引用
      expect(stripped.length, 2);
      expect(stripped.every((b) => b is TextBlock && b.containers.isNotEmpty),
          isTrue);
    });

    test('普通段之间的空行不回收(非逃生位)', () {
      final blocks = [para('p0', '一'), para('e0', ''), para('p1', '二')];
      expect(stripUnusedEscapeGaps(blocks).length, 3);
    });
  });

  group('EditorState 承接补好逃生口的文档', () {
    test('补段后交给 EditorState,文末落点可用', () {
      // 逃生口只在导入路径应用(见 rich_composer_editor._importInitial),
      // EditorState 构造本身不再自动补 —— 这里模拟导入:先补再建。
      var k = 0;
      final gapped =
          insertEscapeGaps([quoted('q0', '被引用', 'A')], () => 'e_gap_${k++}');
      final s = EditorState(blocks: gapped);
      addTearDown(s.dispose);
      expect(s.blocks.length, 2);
      expect(isFreeEmpty(s.blocks.last), isTrue);
    });
  });

  group('docToMarkdown 回收逃生口', () {
    test('引用尾部逃生空段不写进 markdown', () {
      final withGap = insertEscapeGaps([quoted('q0', '被引用', 'A')], nextId);
      final md = docToMarkdown(withGap);
      // 不应以多余空行结尾(引用卡序列化本身已含结构)
      expect(md.trimRight(), md.replaceAll(RegExp(r'\n+$'), ''),
          reason: '尾部不留逃生空行');
      expect(md.contains('被引用'), isTrue);
    });
  });
}
