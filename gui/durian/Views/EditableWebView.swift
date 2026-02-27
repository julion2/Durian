//
//  EditableWebView.swift
//  Durian
//
//  A contentEditable WKWebView for composing emails with HTML support.
//  Used when HTML signatures or formatting are present.
//

import SwiftUI
import WebKit

struct EditableWebView: NSViewRepresentable {
    @Binding var plainText: String
    var htmlSignature: String?
    @Binding var contentHeight: CGFloat
    let font: NSFont
    let textColor: NSColor
    let placeholderText: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Message handler for content changes
        let handler = context.coordinator
        config.userContentController.add(handler, name: "textChanged")
        config.userContentController.add(handler, name: "heightChanged")

        let webView = ScrollPassthroughWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor

        // Allow editing
        webView.setValue(true, forKey: "drawsBackground")
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.webView = webView
        context.coordinator.parent = self

        let html = buildEditableHTML(
            plainText: plainText,
            signature: htmlSignature,
            font: font,
            textColor: textColor,
            placeholder: placeholderText
        )
        context.coordinator.lastLoadedSignature = htmlSignature
        webView.loadHTMLString(html, baseURL: nil)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self

        // Only reload if signature changed (not on every text edit)
        if context.coordinator.lastLoadedSignature != htmlSignature {
            context.coordinator.lastLoadedSignature = htmlSignature
            let html = buildEditableHTML(
                plainText: plainText,
                signature: htmlSignature,
                font: font,
                textColor: textColor,
                placeholder: placeholderText
            )
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func buildEditableHTML(plainText: String, signature: String?, font: NSFont, textColor: NSColor, placeholder: String) -> String {
        let escapedText = plainText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")

        // Build content: user text + two blank lines + signature in one editable area
        var content = escapedText.isEmpty ? "<br>" : escapedText
        if let sig = signature {
            content += "<br><span id=\"sig\">\(sig)</span>"
        }

        let r = Int(textColor.redComponent * 255)
        let g = Int(textColor.greenComponent * 255)
        let b = Int(textColor.blueComponent * 255)
        let colorHex = String(format: "#%02x%02x%02x", r, g, b)

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body {
                    background-color: transparent;
                    overflow: hidden;
                    height: auto;
                }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: \(font.pointSize)px;
                    line-height: 1.5;
                    color: \(colorHex);
                    color-scheme: light dark;
                    padding: 8px 4px;
                }
                #editor {
                    outline: none;
                    min-height: 80px;
                    word-wrap: break-word;
                }
                #editor:empty::before {
                    content: "\(placeholder)";
                    color: #717182;
                    pointer-events: none;
                }
            </style>
        </head>
        <body>
            <div id="editor" contenteditable="true">\(content)</div>
            <script>
                const editor = document.getElementById('editor');

                function notifyHeight() {
                    const h = document.body.scrollHeight;
                    window.webkit.messageHandlers.heightChanged.postMessage(h);
                }

                function getPlainText() {
                    // Get only the text before the signature marker
                    const sig = document.getElementById('sig');
                    let range;
                    if (sig) {
                        // Get text content before the sig element
                        range = document.createRange();
                        range.setStart(editor, 0);
                        range.setEndBefore(sig);
                    }

                    // Extract from the relevant portion
                    const container = document.createElement('div');
                    if (range) {
                        container.appendChild(range.cloneContents());
                    } else {
                        container.innerHTML = editor.innerHTML;
                    }

                    let html = container.innerHTML;
                    html = html.replace(/<br\\s*\\/?>/gi, '\\n');
                    html = html.replace(/<\\/div>/gi, '\\n');
                    html = html.replace(/<\\/p>/gi, '\\n');
                    html = html.replace(/<[^>]+>/g, '');
                    // Decode HTML entities
                    const ta = document.createElement('textarea');
                    ta.innerHTML = html;
                    let text = ta.value;
                    // Trim trailing newlines
                    text = text.replace(/\\n+$/, '');
                    return text;
                }

                editor.addEventListener('input', function() {
                    const text = getPlainText();
                    window.webkit.messageHandlers.textChanged.postMessage(text);
                    setTimeout(notifyHeight, 10);
                });

                // Initial height
                setTimeout(notifyHeight, 50);
            </script>
        </body>
        </html>
        """
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var parent: EditableWebView?
        var lastLoadedSignature: String?
        private var isUpdating = false

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "textChanged":
                if let text = message.body as? String, !isUpdating {
                    isUpdating = true
                    DispatchQueue.main.async {
                        self.parent?.plainText = text
                        self.isUpdating = false
                    }
                }
            case "heightChanged":
                if let height = message.body as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self.parent?.contentHeight = max(height, 100)
                    }
                }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Measure initial height
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
                if let height = result as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self?.parent?.contentHeight = max(height, 100)
                    }
                }
            }
        }

        // Open links in browser
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
