/// Win+V(Windows 剪贴板历史)粘贴:注入的 `V` 不带 Ctrl 修饰位,
/// 需靠「character==null + 主修饰键刚按下」补偿。真机日志固化。
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/input/editor_key_handler.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';

KeyEvent down(LogicalKeyboardKey key, {String? character}) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyV,
      logicalKey: key,
      character: character,
      timeStamp: Duration.zero,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EditorState state;
  late int pasteCount;

  KeyEventResult send(KeyEvent e) => handleEditorKeyEvent(
        state,
        e,
        onEdited: () {},
        onClipboardPaste: () => pasteCount++,
      );

  setUp(() {
    // 修饰键跟踪是模块级全局,跨用例/跨文件会互相污染,必须重置
    debugResetModifierState();
    state = EditorState.fromTexts(['abc']);
    state.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: state.blocks.first.id, offset: 0)));
    pasteCount = 0;
  });

  tearDown(() => state.dispose());

  test('Win+V 注入序列:Ctrl 按下后紧跟无修饰位的 V → 认粘贴', () {
    // 真机日志:Meta Left ↓、Control Left ↓、V(ctrl=false, char=null)
    send(down(LogicalKeyboardKey.metaLeft));
    send(down(LogicalKeyboardKey.controlLeft));
    expect(send(down(LogicalKeyboardKey.keyV)), KeyEventResult.handled);
    expect(pasteCount, 1);
  });

  test('裸敲 v(带 character)不误判成粘贴', () {
    send(down(LogicalKeyboardKey.controlLeft));
    send(down(LogicalKeyboardKey.keyV, character: 'v'));
    expect(pasteCount, 0, reason: 'character 非 null = 真的在打字');
  });

  test('没按过修饰键的孤立 V 不触发粘贴', () async {
    // 隔开与上一个用例的修饰键时间窗(补偿判据用真实时钟;testWidgets
    // 的 FakeAsync 推不动它,所以这三个用例用裸 test)
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(send(down(LogicalKeyboardKey.keyV)), KeyEventResult.ignored);
    expect(pasteCount, 0);
  });
}
