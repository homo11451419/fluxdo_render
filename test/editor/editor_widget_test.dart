/// FluxdoEditor 端到端 widget 测试 —— 忠实平台模拟器。
///
/// 复现真机报障路径:「连续输入到软换行长度后光标错乱、后面文字无法选中」。
/// 模拟方式:维护一份"平台侧 TextEditingValue"(初始 = 编辑器 attach 时
/// setEditingState 喂的值,含 pad),每敲一键在平台值上就地插入字符 →
/// tester.testTextInput.updateEditingValue 回推给编辑器(与 macOS
/// insertText: 行为一致);编辑器若 setEditingState 纠偏,从
/// tester.testTextInput.log 捕获并更新平台值(平台总是接受)。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';

/// 从 TestTextInput.log 取最后一次 setEditingState 的值(无则 null)。
TextEditingValue? lastSetEditingState(WidgetTester tester) {
  TextEditingValue? out;
  for (final call in tester.testTextInput.log) {
    if (call.method == 'TextInput.setEditingState') {
      out = TextEditingValue.fromJSON(
        (call.arguments as Map).cast<String, dynamic>(),
      );
    }
  }
  return out;
}

Map<String, dynamic>? lastSetClientConfiguration(WidgetTester tester) {
  Map<String, dynamic>? out;
  for (final call in tester.testTextInput.log) {
    if (call.method == 'TextInput.setClient') {
      final arguments = call.arguments as List<dynamic>;
      out = (arguments[1] as Map).cast<String, dynamic>();
    }
  }
  return out;
}

class _Harness {
  _Harness(this.tester, this.state);

  final WidgetTester tester;
  final EditorState state;

  /// 平台侧文本模型(pad 后坐标,与真实 NSTextInputContext 对应)。
  TextEditingValue platform = TextEditingValue.empty;

  /// 应用编辑器可能发出的 setEditingState(平台无条件接受)。
  void absorbSetEditingState() {
    final v = lastSetEditingState(tester);
    if (v != null) platform = v;
    tester.testTextInput.log.clear();
  }

  /// 模拟平台插入一个字符(insertText: 语义,在平台模型光标处)。
  Future<void> typeChar(String ch) async {
    absorbSetEditingState();
    final sel = platform.selection;
    final text = platform.text.replaceRange(sel.start, sel.end, ch);
    platform = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: sel.start + ch.length),
    );
    tester.testTextInput.updateEditingValue(platform);
    await tester.pump();
    await tester.pump();
    absorbSetEditingState();
  }
}

void main() {
  Future<(_Harness, EditorState)> pumpEditor(
    WidgetTester tester, {
    List<String> paragraphs = const ['第一段', 'abc'],
  }) async {
    final state = EditorState.fromTexts(paragraphs);
    // dispose 取消 seal 空闲定时器,否则 teardown 报 pending timer
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: FluxdoEditor(
              state: state,
              autofocus: true,
              baseTextStyle: const TextStyle(fontSize: 16, height: 1.6),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (_Harness(tester, state), state);
  }

  testWidgets('TextInput client carries the owning Flutter view id', (
    tester,
  ) async {
    await pumpEditor(tester, paragraphs: ['']);

    final editor = find.byType(FluxdoEditor);
    await tester.tapAt(tester.getRect(editor).center);
    await tester.pump();

    final configuration = lastSetClientConfiguration(tester);
    expect(configuration, isNotNull);
    expect(configuration!['viewId'], View.of(tester.element(editor)).viewId);
  });

  testWidgets('连续输入 60 字符(跨软换行)不丢字不乱序,光标随行', (tester) async {
    final (h, state) = await pumpEditor(tester, paragraphs: ['第一段', '']);

    // 点进第二段(空段)
    final editor = find.byType(FluxdoEditor);
    final rect = tester.getRect(editor);
    await tester.tapAt(Offset(rect.left + 10, rect.bottom - 10));
    await tester.pump();
    expect(
      tester.testTextInput.hasAnyClients,
      isTrue,
      reason: '点击后应 attach IME',
    );
    h.absorbSetEditingState();
    expect(h.platform.text, ' ', reason: '空段 attach 应喂 pad');

    // 连续敲 60 个 '1'(测试视口 800px,fontSize16 必然软换行)
    for (var i = 0; i < 60; i++) {
      await h.typeChar('1');
    }

    expect(
      (state.blocks[1] as TextBlock).content.text,
      '1' * 60,
      reason: '60 连击后文档不丢字不重复',
    );
    expect(state.selection!.extent.offset, 60, reason: '光标应在末尾');
    // 平台模型与文档一致(无纠偏残留/回环)
    expect(h.platform.text, ' ${'1' * 60}');
    // 排掉 800ms seal 空闲定时器再结束
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('长文本(已换行)后:拖选后段文字可选中', (tester) async {
    final text = '1' * 120; // 800px 视口必然 ≥2 行(内容长 120)
    final (_, state) = await pumpEditor(tester, paragraphs: ['第一段', text]);

    final editor = find.byType(FluxdoEditor);
    final rect = tester.getRect(editor);
    // 末行(第三行)行内:编辑器底部往上半行。回归背景:软换行 ZWSP 使
    // 渲染偏移 > 内容长度,旧换算把第二行起的所有命中 clamp 到段尾 →
    // 拖选恒折叠(= 报障"后面的文字无法选中")。
    final line3y = rect.bottom - 18;
    // kind: mouse —— 触摸 pan 已按设备分流让给滚动(移动端选区靠长按+手柄)
    final g = await tester.startGesture(
      Offset(rect.left + 8, line3y),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 40));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();

    final sel = state.selection;
    expect(sel, isNotNull);
    expect(sel!.isCollapsed, isFalse, reason: '拖选末行应产生非折叠选区');
    expect(sel.extent.blockId, state.blocks[1].id);
    expect(sel.extent.offset, greaterThan(sel.base.offset));
    // 选区落在换行之后的行(offset 超过首行容量 ~46)
    expect(sel.base.offset, greaterThan(46), reason: '起点应在第二行之后(内容偏移,不含 ZWSP)');
    expect(
      sel.extent.offset,
      lessThanOrEqualTo(120),
      reason: '偏移必须在内容长度内(旧 bug:被 clamp 到 120 折叠)',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('在长文本中部输入:后方文字保持完整,光标不跳', (tester) async {
    final tail = '2' * 40;
    final (h, state) = await pumpEditor(tester, paragraphs: ['第一段', tail]);

    // 点第二段行首
    final editor = find.byType(FluxdoEditor);
    final rect = tester.getRect(editor);
    await tester.tapAt(Offset(rect.left + 2, rect.bottom - 14));
    await tester.pump();
    h.absorbSetEditingState();
    expect(h.platform.selection.baseOffset, 1, reason: '行首点击 → pad 后偏移 1');

    for (var i = 0; i < 50; i++) {
      await h.typeChar('1');
    }

    expect(
      (state.blocks[1] as TextBlock).content.text,
      '${'1' * 50}$tail',
      reason: '前插 50 字后尾部 40 个 2 应原样保留',
    );
    expect(state.selection!.extent.offset, 50);
    await tester.pump(const Duration(seconds: 1));
  });
}
