/// fluxdo_render 编辑内核副入口(WYSIWYG,阶段 M1)。
///
/// 与主入口 `fluxdo_render.dart`(只读渲染)分开导出:编辑 API 面还在
/// 快速演进,主 app 只在 composer 场景 import 本入口。
///
/// M1 范围:纯文本段落文档 —— 光标/中文 IME(composing 下划线)/
/// 退格/回车分段/段首合并/拖选删除/undo-redo。见 docs 与
/// src/editor/ 各文件头注释。
library;

export 'src/editor/input/editor_ime_client.dart' show EditorImeClient;
export 'src/editor/input/editor_key_handler.dart' show primaryModifierHeld, shiftModifierHeld;
export 'src/editor/model/doc_converter.dart';
export 'src/editor/model/editable_text_content.dart';
export 'src/editor/model/editor_block.dart';
export 'src/editor/model/editor_image_commands.dart';
export 'src/editor/model/editor_state.dart';
export 'src/editor/model/markdown_serializer.dart';
export 'src/editor/widget/editor_island.dart';
export 'src/editor/widget/editor_image_grid.dart';
export 'src/editor/widget/editor_code_block.dart';
export 'src/editor/widget/editor_collapsed_handle.dart'
    show kCollapsedHandleKey;
export 'src/editor/widget/editor_toolbar.dart';
export 'src/editor/widget/fluxdo_editor.dart';
