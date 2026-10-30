import SwiftUI
import UIKit

/// 多行输入框，换掉 TextEditor 用。
///
/// TextEditor 所在的页面一重画（聊天在收消息、记忆页在刷新），它会把整段字重新塞回去，
/// 光标就被挤到最后：点了第一行想删，删掉的却是最后一个字。这里只在字真的变了、
/// 而且不是正在拼音选字的时候才改，改的时候把光标放回原处。
struct StableTextView: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 14
    /// 跟着字长高（放在 ScrollView 里用）；不长高就自己滚，填满给它的地方。
    var grows = false
    var focusOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = UIColor(Theme.text)
        view.text = text
        view.isScrollEnabled = !grows
        view.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if focusOnAppear {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        // 正在选字（拼音还没上屏）时不碰它，不然字会被打断。
        guard view.markedTextRange == nil, view.text != text else { return }
        let selected = view.selectedRange
        view.text = text
        let length = (text as NSString).length
        let location = min(selected.location, length)
        view.selectedRange = NSRange(location: location, length: min(selected.length, length - location))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard grows, let width = proposal.width, width.isFinite else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            if text.wrappedValue != textView.text { text.wrappedValue = textView.text }
            textView.invalidateIntrinsicContentSize()
        }
    }
}
