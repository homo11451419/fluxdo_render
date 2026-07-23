/// 岛的编辑入口:双击整块 → onIslandEditRequest。
///
/// 分割线岛只有 25px 高(padding12 + 1px 线 + padding12),是所有岛里
/// 命中面积最小的一个 —— 双击"点不中"的回归专门盯它。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show HorizontalRuleNode;

void main() {
  Future<(EditorState, List<IslandBlock>)> boot(WidgetTester tester) async {
    final edits = <IslandBlock>[];
    final state = EditorState(blocks: [
      TextBlock(id: 'e_0', content: EditableTextContent(text: 'hello')),
      const IslandBlock(id: 'e_hr', node: HorizontalRuleNode(id: 'b_0')),
      TextBlock(id: 'e_1', content: EditableTextContent(text: 'world')),
    ]);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FluxdoEditor(
          state: state,
          autofocus: true,
          onIslandEditRequest: edits.add,
        ),
      ),
    ));
    await tester.pump();
    return (state, edits);
  }

  testWidgets('双击分割线岛 → 请求编辑', (tester) async {
    final (_, edits) = await boot(tester);
    final hr = find.byType(EditorIsland);
    expect(hr, findsOneWidget);

    await tester.tap(hr);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(hr);
    await tester.pump(const Duration(milliseconds: 300));

    expect(edits.map((e) => e.id), ['e_hr']);
  });

  testWidgets('单击只整选,不请求编辑', (tester) async {
    final (state, edits) = await boot(tester);
    await tester.tap(find.byType(EditorIsland));
    await tester.pump(const Duration(milliseconds: 400));

    expect(edits, isEmpty);
    expect(state.selection?.base.blockId, 'e_hr');
    expect(state.selection?.extent.blockId, 'e_hr');
  });
}
