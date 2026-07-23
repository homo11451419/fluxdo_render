/// 编辑内核 M2 demo 页 —— 原子/格式/块类型/孤岛 全量验证场。
///
/// 初始文档 = 混合 cooked HTML 经 ParagraphParser + blockNodesToDoc
/// 导入(与"打开已有帖子进编辑器"同链路):heading/列表/引用/emoji/
/// mention 可编辑;代码块/表格是只读孤岛。
library;

import 'package:flutter/material.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ParagraphParser;

const _demoHtml = '''
<h2>编辑内核 M2 demo</h2>
<p>这是可编辑段落:支持 <strong>粗体</strong>、<em>斜体</em>、<code>行内代码</code>,
以及 emoji <img src="https://linux.do/images/emoji/twitter/smile.png" title=":smile:" class="emoji" alt=":smile:"> 和
<a class="mention" href="/u/sam">@sam</a> 原子(光标整跳、退格整删)。</p>
<p>Mark Reveal 演示:将光标移到 <strong>粗体文字</strong> 或 <em>斜体文字</em> 或 <code>代码片段</code> 的边界，格式标记会自动展开显示（如 **、*、`），方便编辑。移开光标后自动折叠恢复渲染。试试 <strong>连续</strong><em>多种</em> 格式、<del>删除线文字</del> 也支持。</p>
<blockquote>
<p>引用块里的段落,块首退格逐级退出。</p>
</blockquote>
<ul>
<li>无序列表项一(回车产生新项)</li>
<li>列表项二(Tab 缩进,Shift+Tab 反缩进)
<ol>
<li>嵌套有序子项</li>
</ol>
</li>
</ul>
<p>下面是一个只读孤岛(点击整选、退格两段式删除、上下键绕过):</p>
<pre data-code-wrap="py"><code class="lang-py">def hello():
    print("我是只读代码块孤岛")
</code></pre>
<p>孤岛后的普通段落,继续输入验证 IME。</p>
''';

class EditorDemoPage extends StatefulWidget {
  const EditorDemoPage({super.key});

  @override
  State<EditorDemoPage> createState() => _EditorDemoPageState();
}

class _EditorDemoPageState extends State<EditorDemoPage> {
  late final EditorState _state;

  // 工具栏按钮不抢编辑器焦点(编辑器工具栏惯例:canRequestFocus=false,
  // 否则点 undo 会让光标消失)
  final FocusNode _undoFocus =
      FocusNode(canRequestFocus: false, skipTraversal: true);
  final FocusNode _redoFocus =
      FocusNode(canRequestFocus: false, skipTraversal: true);

  @override
  void initState() {
    super.initState();
    // demo 页开 IME 通道日志(flutter run 控制台可见,定位真机 IME 行为)
    EditorImeClient.debugLogging = true;

    var counter = 0;
    _state = EditorState(
      blocks: blockNodesToDoc(
        ParagraphParser().parse(_demoHtml),
        () => 'e_${counter++}',
      ),
    );
  }

  @override
  void dispose() {
    _undoFocus.dispose();
    _redoFocus.dispose();
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑内核 M2 demo'),
        actions: [
          IconButton(
            tooltip: '导出 markdown(控制台)',
            focusNode: FocusNode(canRequestFocus: false, skipTraversal: true),
            icon: const Icon(Icons.output),
            onPressed: () {
              final md = docToMarkdown(_state.blocks);
              debugPrint('===== markdown =====\n$md\n===== end =====');
              showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('markdown 导出'),
                  content: SingleChildScrollView(
                    child: SelectableText(
                      md,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
              );
            },
          ),
          ListenableBuilder(
            listenable: _state,
            builder: (context, _) => Row(
              children: [
                IconButton(
                  tooltip: 'Undo',
                  focusNode: _undoFocus,
                  icon: const Icon(Icons.undo),
                  onPressed: _state.canUndo ? _state.undo : null,
                ),
                IconButton(
                  tooltip: 'Redo',
                  focusNode: _redoFocus,
                  icon: const Icon(Icons.redo),
                  onPressed: _state.canRedo ? _state.redo : null,
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: EditorToolbar(state: _state),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: FluxdoEditor(
                        state: _state,
                        autofocus: true,
                        baseTextStyle: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(height: 1.6),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 调试面板:实时观察选区/composing/文档状态
                  ListenableBuilder(
                    listenable: _state,
                    builder: (context, _) => Text(
                      'selection: ${_state.selection}\n'
                      'composing: ${_state.composing}\n'
                      'blocks: ${_state.blocks.length}  '
                      'undo: ${_state.canUndo}  redo: ${_state.canRedo}\n'
                      'pending: ${_state.pendingMarks}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            color: Theme.of(context).colorScheme.outline,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
