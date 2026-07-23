/// 编辑器硬件键盘处理。
///
/// 职责边界(对齐 appflowy keyboard_service_widget 的分层):
/// - **可打印字符不在这里处理** —— 全部走 IME(updateEditingValue);
/// - 本层只管导航/结构键:方向、Backspace/Delete、Enter、Cmd/Ctrl 组合;
/// - **composing 非空时一律让路**(返回 ignored,平台把按键交给 IME 处理
///   候选窗上下移动/翻页等)。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../model/editable_text_content.dart' show MarkKind;
import '../model/editor_state.dart';

/// 处理结果由调用方(FluxdoEditor 的 Focus.onKeyEvent)透传给框架。
///
/// [onMoveVertical]:上下键的垂直光标移动。需要行几何(RenderParagraph),
/// 纯 EditorState 做不了 → 由 FluxdoEditor 注入实现。
///
/// [onClipboardCopy]/[onClipboardCut]/[onClipboardPaste]:剪贴板三键。
/// 剪贴板 IO(Clipboard API)与粘贴的 markdown 导入(cook 链路,异步)
/// 都不属于纯状态层 → 由 FluxdoEditor 注入;未注入时按键不处理(ignored)。
///
/// 退格/删除/回车在**框架侧本地处理**并返回 handled(EditableText +
/// DefaultTextEditingShortcuts 同款,平台不再收到该键)。与平台 insertText
/// 流的一致性由两道围栏保证:macOS 键盘管理器逐键串行(应答前不路由下一
/// 键,setEditingState 先于应答入队)+ 段落切换时重开输入连接(框架按
/// client ID 丢弃旧连接的迟到消息,见 EditorImeClient.syncFromState)。
KeyEventResult handleEditorKeyEvent(
  EditorState state,
  KeyEvent event, {
  required void Function() onEdited,
  void Function(int direction, {required bool extend})? onMoveVertical,
  void Function()? onClipboardCopy,
  void Function()? onClipboardCut,
  void Function()? onClipboardPaste,
}) {
  // 修饰键自跟踪必须在下面的 KeyUp 早退**之前**做,否则永远收不到抬起,
  // 本地状态会一直卡在按下。
  _trackShift(event);
  _trackModifierDown(event, isMac: defaultTargetPlatform == TargetPlatform.macOS);

  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }

  // IME 预编辑中:候选窗需要方向/回车/退格 —— 用 skipRemainingHandlers
  // 而非 ignored:事件仍交还平台(IME 正常收到),但**不再冒泡**到上层
  // Shortcuts(否则方向键会触发 DirectionalFocusIntent,焦点被遍历走)。
  if (state.hasComposing) {
    return KeyEventResult.skipRemainingHandlers;
  }

  final isMac = defaultTargetPlatform == TargetPlatform.macOS;
  final pressed = HardwareKeyboard.instance;
  final primary = (isMac ? pressed.isMetaPressed : pressed.isControlPressed) ||
      (!_producedPrintable(event) && _isSyntheticModifiedKey(event));
  final shift = _shiftHeld(event, pressed);

  // 跨段选区 + 可打印字符:IME 窗口只覆盖单段,平台模型里没有这个跨段
  // 选区 —— 直接放行会让平台把字符插进**过期的单段模型**,再经 diff 写进
  // 错误位置。先本地删选区(收敛为单段折叠光标,监听器会同步 setEditingState
  // 刷新平台模型),然后 skipRemainingHandlers 把按键交还平台 IME:
  // 渠道 FIFO 保证平台先应用新模型再处理该键 → 字符插在正确位置。
  final sel = state.selection;
  if (sel != null && !sel.isSingleBlock) {
    final ch = event.character;
    final isPrintable = ch != null &&
        ch.isNotEmpty &&
        !primary &&
        ch.codeUnitAt(0) >= 0x20;
    if (isPrintable) {
      state.deleteSelection();
      onEdited();
      return KeyEventResult.skipRemainingHandlers;
    }
  }

  bool handled = true;
  switch (event.logicalKey) {
    case LogicalKeyboardKey.arrowLeft:
      state.moveCaretHorizontal(-1, extend: shift);
    case LogicalKeyboardKey.arrowRight:
      state.moveCaretHorizontal(1, extend: shift);
    case LogicalKeyboardKey.arrowUp:
      onMoveVertical?.call(-1, extend: shift);
    case LogicalKeyboardKey.arrowDown:
      onMoveVertical?.call(1, extend: shift);
    case LogicalKeyboardKey.backspace:
      state.backspace();
      onEdited();
    case LogicalKeyboardKey.delete:
      state.deleteForward();
      onEdited();
    // primary+Enter 不吃:落到底部返回 ignored('\n' < 0x20 不触发
    // skipRemainingHandlers),冒泡给宿主的提交快捷键(Cmd/Ctrl+Enter 发送)。
    case LogicalKeyboardKey.enter when !primary:
    case LogicalKeyboardKey.numpadEnter when !primary:
      state.sealHistory();
      state.splitBlock();
      onEdited();
    case LogicalKeyboardKey.tab:
      // 列表项:缩进/反缩进;普通文本块:插入制表符(Shift+Tab 无操作,
      // 但仍 handled —— 防 Tab 焦点遍历把焦点带走)。
      final sel = state.selection;
      final block =
          sel == null ? null : state.textBlockById(sel.extent.blockId);
      if (block != null && block.isListItem) {
        if (shift) {
          state.outdentListItem();
        } else {
          state.indentListItem();
        }
      } else if (!shift) {
        state.insertText('\t');
      }
      onEdited();
    // ---- 格式快捷键(M2) ----
    case LogicalKeyboardKey.keyB when primary:
      state.toggleMark(MarkKind.strong);
      onEdited();
    case LogicalKeyboardKey.keyI when primary:
      state.toggleMark(MarkKind.em);
      onEdited();
    case LogicalKeyboardKey.keyE when primary:
      state.toggleMark(MarkKind.inlineCode);
      onEdited();
    case LogicalKeyboardKey.keyX when primary && shift:
      state.toggleMark(MarkKind.lineThrough);
      onEdited();
    // 块级格式(对齐 Discourse composer toolbar 键位):
    // Cmd/Ctrl+Shift+7/8/9 列表与引用、Cmd/Ctrl+Alt+0..4 段落/标题。
    // 注:键位清单同步维护于宿主 composer_shortcuts.dart(帮助浮层/
    // tooltip 事实源),改动需两处同步。
    case LogicalKeyboardKey.digit7 when primary && shift:
      state.toggleList(ordered: true);
      onEdited();
    case LogicalKeyboardKey.digit8 when primary && shift:
      state.toggleList(ordered: false);
      onEdited();
    case LogicalKeyboardKey.digit9 when primary && shift:
      state.toggleQuote();
      onEdited();
    case LogicalKeyboardKey.digit0 when primary && pressed.isAltPressed:
      state.setHeading(null);
      onEdited();
    case LogicalKeyboardKey.digit1 when primary && pressed.isAltPressed:
      state.setHeading(1);
      onEdited();
    case LogicalKeyboardKey.digit2 when primary && pressed.isAltPressed:
      state.setHeading(2);
      onEdited();
    case LogicalKeyboardKey.digit3 when primary && pressed.isAltPressed:
      state.setHeading(3);
      onEdited();
    case LogicalKeyboardKey.digit4 when primary && pressed.isAltPressed:
      state.setHeading(4);
      onEdited();
    // ---- 剪贴板 ----
    case LogicalKeyboardKey.keyC when primary:
      if (onClipboardCopy == null) {
        handled = false;
      } else {
        onClipboardCopy();
      }
    case LogicalKeyboardKey.keyX when primary:
      if (onClipboardCut == null) {
        handled = false;
      } else {
        onClipboardCut();
      }
    case LogicalKeyboardKey.keyV when primary:
      if (onClipboardPaste == null) {
        handled = false;
      } else {
        onClipboardPaste();
      }
    case LogicalKeyboardKey.keyA when primary:
      state.selectAll();
    case LogicalKeyboardKey.keyZ when primary && shift:
      state.redo();
      onEdited();
    case LogicalKeyboardKey.keyZ when primary:
      state.undo();
      onEdited();
    default:
      handled = false;
  }
  if (handled) return KeyEventResult.handled;

  // 无修饰可打印字符:skipRemainingHandlers —— 事件交还平台走 IME
  // insertText 路径(注:不能 handled,否则嵌入层不再路由给
  // NSTextInputContext,字符进不了输入通道),同时**不冒泡** Flutter
  // 框架内的上层 handler。否则宿主 app 的全局单键快捷键(j/k/d/s
  // 话题导航等,其文本输入豁免只认 EditableText 祖先)会把字母抢走,
  // 表现为"很多字母打不出来"。
  final ch = event.character;
  if (!primary &&
      ch != null &&
      ch.isNotEmpty &&
      ch.codeUnitAt(0) >= 0x20 &&
      ch.codeUnitAt(0) != 0x7f) {
    return KeyEventResult.skipRemainingHandlers;
  }
  return KeyEventResult.ignored;
}

// ---------------------------------------------------------------------
// 合成按键的修饰键补偿(Windows 剪贴板历史 Win+V)
// ---------------------------------------------------------------------
//
// Win+V 面板选中条目后,系统用 SendInput 模拟 Ctrl+V。真机日志实测:
// 注入的 `V` 消息**自身不带 Ctrl 修饰位**,Flutter 据此合成了一次 Ctrl
// 抬起 —— 处理 `V` 时 isControlPressed 已经是 false。于是既不算粘贴、
// 也不算打字(character 为 null,系统认为 Ctrl 按着没产生字符),表现
// 为「Win+V 完全没反应」。对照组手按 Ctrl+V 时 V 事件 ctrl=true。
//
// 判据取两个条件的合取,避免误伤:
// - character == null:裸敲 `v` 一定带 character('v'),为 null 说明确
//   实有修饰键压制了字符 —— 中文输入法下拼音 `v` 也带 character,不命中;
// - 主修饰键刚按下过(_modifierWindow 内):Win+V 的注入序列里 Ctrl 按下
//   紧挨着 V,而普通打字前不会有这个前缀。
const Duration _modifierWindow = Duration(milliseconds: 250);
DateTime? _lastModifierDownAt;

// ---------------------------------------------------------------------
// Shift 状态自跟踪(Windows 输入法切中英文导致的卡键)
// ---------------------------------------------------------------------
//
// HardwareKeyboard 的缓存修饰键状态在 Windows 上会失真:中文输入法用
// **Shift 切中英文**,IME 会吞掉 Shift 的 key-up,Flutter 便一直认为
// Shift 按着。此后按方向键 → `extend: true` → 光标移动变成扩选。真机
// 现象:用户没按 shift,从行尾按左键却选中了末尾几个字(还有更早一次
// 表现为方向键把整个岛"选中")。同一文件上方 Win+V 那段注释是同类问题
// 的另一例 —— 平台注入/IME 介入时修饰键状态不可信。
//
// 判据改为**合取**:全局状态说按着 **且** 本处理器确实收到过 Shift 按下
// 而没收到抬起。编辑器有焦点时真实的 shift+方向键两个事件都会到这里,
// 不影响正常扩选;而"焦点在 IME 窗口时丢掉的抬起"不会污染本地状态。
bool _localShiftDown = false;

void _trackShift(KeyEvent event) {
  final k = event.logicalKey;
  if (k != LogicalKeyboardKey.shiftLeft && k != LogicalKeyboardKey.shiftRight) {
    return;
  }
  if (event is KeyDownEvent) _localShiftDown = true;
  if (event is KeyUpEvent) _localShiftDown = false;
}

bool _shiftHeld(KeyEvent event, HardwareKeyboard pressed) =>
    pressed.isShiftPressed && _localShiftDown;

/// 本地看到的主修饰键是否按下(**仅用于诊断/保留,不参与 primary 判定**)。
///
/// 曾把它并进 primary 取析取,结果是灾难:Ctrl 的 key-up 一旦丢失,
/// _localPrimaryDown 永久为真 → **此后每一次回车都被当成 Ctrl+Enter**,
/// 直接把帖子发出去(实测:回车 / Shift+回车 / Ctrl+回车 全部发送)。
/// 而它对 Win+V 那个场景本就没用 —— 那里 Flutter 合成的是 Ctrl **抬起**,
/// 本地跟踪同样会被清掉,真正兜住的是 [_isSyntheticModifiedKey] 的 250ms
/// 窗口。故 primary 回到「HardwareKeyboard 或 250ms 窗口」这套已验证的判据。
///
/// 教训:修饰键判据宁可漏认(顶多快捷键不生效),**绝不能多认** —— 多认
/// 会触发发送/删除这类不可逆动作。Shift 那条取合取正是这个道理。
///
/// 与 [_localShiftDown] 同源问题、**方向相反**:Ctrl 会被平台/IME 弄成
/// 假的「已抬起」(见上方 Win+V 注释),导致 `primary` 为 false ——
/// Ctrl+Enter 于是被当成普通回车:内核 `splitBlock()` 分一段、宿主的软
/// 换行再插一个,真机表现为**按一次换两行**,而且发不出去。
/// 既有的 [_isSyntheticModifiedKey] 只覆盖 250ms 窗口,按住 Ctrl 稍久
/// 再敲 Enter 就失效。
///
/// 所以这里取**析取**(任一为真即认):宁可多认一次 Ctrl(最坏是少插一个
/// 换行),也不能漏认(漏认会毁掉正在写的内容)。Shift 那条相反,取合取。
void _trackModifierDown(KeyEvent event, {required bool isMac}) {
  if (event is! KeyDownEvent) return;
  final k = event.logicalKey;
  final isPrimaryModifier = isMac
      ? (k == LogicalKeyboardKey.metaLeft || k == LogicalKeyboardKey.metaRight)
      : (k == LogicalKeyboardKey.controlLeft ||
          k == LogicalKeyboardKey.controlRight);
  if (isPrimaryModifier) _lastModifierDownAt = DateTime.now();
}

/// 本次按键是否**产出了可打印字符**。
///
/// 产出字符 = 用户在打字,此时不能把本地跟踪的修饰键当成快捷键修饰位 ——
/// 否则 Ctrl 状态卡住时,中文输入法敲拼音 `v` 会被误判成 Ctrl+V 粘贴
/// (既有 _isSyntheticModifiedKey 正是靠 character==null 防这个)。
/// 阈值取 0x20:回车等控制字符(0x0A)不算「打字」。
bool _producedPrintable(KeyEvent event) {
  final ch = event.character;
  return ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 0x20;
}

/// Shift 是否按下 —— **权威判定**,宿主按键拦截层必须用这个。
///
/// 与 [primaryModifierHeld] 同源:`HardwareKeyboard` 的缓存状态在 Windows
/// 上会失真(中文输入法用 Shift 切中英文,IME 吞掉 key-up)。取**合取**:
/// 全局说按着 且 本处理器确实收到过 Shift 按下且未收到抬起。
///
/// 漏用它的实测后果:宿主 `_handleEnterAsSoftBreak` 的判据是
/// `soft == shift`,Shift 卡住时「回车=软换行」被反转成分段 —— 用户设置
/// 了「回车不空行」,回车却插出空行。
bool shiftModifierHeld() =>
    HardwareKeyboard.instance.isShiftPressed && _localShiftDown;

/// 主修饰键(Windows/Linux 的 Ctrl、macOS 的 Cmd)是否按下 —— **权威判定**。
///
/// 宿主的按键拦截层必须用这个,而不是直接读 `HardwareKeyboard`:后者在
/// 平台注入/IME 介入时会失真(见上方 Win+V 与 _localPrimaryDown 的注释)。
/// 两边口径不一致的后果是 Ctrl+Enter 被当普通回车 —— 内核分段、宿主再插
/// 软换行,一次按键换两行还发不出去。
/// 清空修饰键的本地跟踪状态。
///
/// 这些状态是**模块级全局**(编辑器同时只有一个焦点实例,不必按实例存)。
/// 测试之间必须重置,否则上个用例按下的 Ctrl 会连同 250ms 补偿窗口一起
/// 污染下一个用例。
@visibleForTesting
void debugResetModifierState() {
  _localShiftDown = false;
  _lastModifierDownAt = null;
}

bool primaryModifierHeld(KeyEvent event) {
  final isMac = defaultTargetPlatform == TargetPlatform.macOS;
  final pressed = HardwareKeyboard.instance;
  return (isMac ? pressed.isMetaPressed : pressed.isControlPressed) ||
      (!_producedPrintable(event) && _isSyntheticModifiedKey(event));
}

bool _isSyntheticModifiedKey(KeyEvent event) {
  if (event.character != null) return false;
  final at = _lastModifierDownAt;
  if (at == null) return false;
  return DateTime.now().difference(at) <= _modifierWindow;
}
