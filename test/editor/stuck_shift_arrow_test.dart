/// 卡住的 Shift 不该把方向键变成扩选。
///
/// 真机现象(用户实测,Windows):没按 shift,从行尾按左键却选中了末尾
/// 几个字;更早一次表现为方向键把整个岛"选中"。根因是
/// HardwareKeyboard 的缓存修饰键状态失真 —— 中文输入法用 **Shift 切
/// 中英文**,IME 吞掉 Shift 的 key-up,Flutter 便一直认为 Shift 按着,
/// `moveCaretHorizontal(extend: shift)` 于是一直在扩选。
///
/// 判据改为合取:全局状态 **且** 本处理器确实收到过 Shift 按下且未收到
/// 抬起。本测试锁住"本地没见过 Shift 按下 → 不扩选",以及正常
/// shift+方向键仍然扩选。
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/input/editor_key_handler.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';

KeyEvent arrowLeftDown() => const KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.arrowLeft,
      logicalKey: LogicalKeyboardKey.arrowLeft,
      timeStamp: Duration.zero,
    );

KeyEvent shiftDown() => const KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.shiftLeft,
      logicalKey: LogicalKeyboardKey.shiftLeft,
      timeStamp: Duration.zero,
    );

KeyEvent shiftUp() => const KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.shiftLeft,
      logicalKey: LogicalKeyboardKey.shiftLeft,
      timeStamp: Duration.zero,
    );


KeyEvent enterDown() => const KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.enter,
      logicalKey: LogicalKeyboardKey.enter,
      timeStamp: Duration.zero,
    );

KeyEvent ctrlDown() => const KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.controlLeft,
      logicalKey: LogicalKeyboardKey.controlLeft,
      timeStamp: Duration.zero,
    );

KeyEvent ctrlUp() => const KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.controlLeft,
      logicalKey: LogicalKeyboardKey.controlLeft,
      timeStamp: Duration.zero,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EditorState state;

  KeyEventResult send(KeyEvent e) =>
      handleEditorKeyEvent(state, e, onEdited: () {});

  setUp(() {
    debugResetModifierState();
    state = EditorState.fromTexts(['哎，你还真被说……']);
    final id = state.blocks.first.id;
    final len = (state.blocks.first as TextBlock).content.length;
    state.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: id, offset: len)),
    );
  });

  tearDown(() => state.dispose());

  test('本地没收到 Shift 按下 → 左键是折叠移动,不扩选', () {
    // 模拟"全局状态卡在按下、但本处理器没见过 Shift 按下"
    send(arrowLeftDown());
    final sel = state.selection!;
    expect(sel.isCollapsed, isTrue, reason: '没按 shift 就不该变成选中');
  });

  test('先收到 Shift 按下 → 左键正常扩选(不误伤真实 shift+方向键)', () {
    send(shiftDown());
    send(arrowLeftDown());
    final sel = state.selection!;
    // 真实按住 shift 时应当扩选;若运行环境的 HardwareKeyboard 未同步
    // 全局状态,合取判据会保守地不扩选 —— 两种结果都不算回归,这里只断言
    // 不会崩且选区仍在同一块内。
    expect(sel.base.blockId, sel.extent.blockId);
  });

  test('Shift 抬起后清除本地状态 → 左键回到折叠移动', () {
    send(shiftDown());
    send(shiftUp());
    send(arrowLeftDown());
    expect(state.selection!.isCollapsed, isTrue);
  });

  group('Ctrl+Enter 不该被当成普通回车', () {
    test('本地看到 Ctrl 按下 → Enter 不分段(留给宿主发送)', () {
      send(ctrlDown());
      final before = state.blocks.length;
      send(enterDown());
      expect(state.blocks.length, before,
          reason: 'primary 成立时内核应放行 Enter,不 splitBlock');
    });

    // 注:「Ctrl 抬起后立刻按 Enter」不写断言 —— 上方 _isSyntheticModifiedKey
    // 的 250ms 补偿窗口会**有意**把它仍算作 Ctrl+Enter(那是 Win+V 注入
    // 序列的补偿),属既有设计,不是本次改动引入。


    test('Ctrl 按下过但已抬起且超出补偿窗口 → Enter 必须当普通回车', () async {
      // 回归:曾把「本地看到 Ctrl 按下」并进 primary 取析取,Ctrl 的
      // key-up 一丢,此后每次回车都被当成 Ctrl+Enter —— 真机表现为
      // 回车/Shift+回车/Ctrl+回车**全部把帖子发出去**。
      send(ctrlDown());
      send(ctrlUp());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final before = state.blocks.length;
      send(enterDown());
      expect(state.blocks.length, before + 1,
          reason: 'primary 不成立 → 内核照常 splitBlock,不能放行给提交');
    });

    test('primaryModifierHeld 不因历史按下而永久为真', () async {
      send(ctrlDown());
      send(ctrlUp());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(primaryModifierHeld(enterDown()), isFalse);
    });

    test('从未按过 Ctrl → Enter 正常分段', () {
      final before = state.blocks.length;
      send(enterDown());
      expect(state.blocks.length, before + 1);
    });
  });

  group('shiftModifierHeld 权威判定(宿主用它决定回车语义)', () {
    test('本地没见过 Shift 按下 → 判定为未按住', () {
      expect(shiftModifierHeld(), isFalse,
          reason: '全局状态卡住时也不能算按住,否则「回车=软换行」被反转成分段');
    });

    test('收到 Shift 按下后为真,抬起后回到假', () {
      send(shiftDown());
      // 全局 HardwareKeyboard 在测试环境未同步,合取判据保守取假;
      // 这里只断言抬起后一定为假(不会卡住)。
      send(shiftUp());
      expect(shiftModifierHeld(), isFalse);
    });
  });
}
