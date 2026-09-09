import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Markdown 渲染（T9 修正 F3-5，BQ1 bench 选型）。
///
/// 选型 **gpt_markdown 1.2.1**：LLM 对话场景专用（流式容忍、代码块/表格/
/// 链接/行内代码齐备）；备选 flutter_markdown_plus 1.0.12 /
/// markdown_widget 2.3.2+8——换库只需改本文件。
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.data, {super.key, this.style});

  final String data;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return GptMarkdown(
      data,
      style: style,
      codeBuilder: _codeBlock,
    );
  }

  /// 围栏代码块：与应用代码块风格一致（深底等宽）。
  Widget _codeBlock(BuildContext context, String? name, String code, bool closed) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (name != null && name.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(name,
                  style: const TextStyle(
                      fontSize: 10,
                      color: Color(0x66FFFFFF),
                      fontFamily: 'Consolas, monospace')),
            ),
          SelectableText(
            code,
            style: const TextStyle(
                fontFamily: 'Consolas, monospace',
                fontSize: 12,
                color: Color(0xFFE6E6E6)),
          ),
        ],
      ),
    );
  }
}
