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
    @Binding var formatCommand: String?
    @Binding var fontSizeCommand: Int?
    @Binding var htmlBody: String
    var onFormatStateChange: ((_ bold: Bool, _ italic: Bool, _ underline: Bool, _ fontSize: Int) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Message handler for content changes
        let handler = context.coordinator
        config.userContentController.add(handler, name: "textChanged")
        config.userContentController.add(handler, name: "htmlChanged")
        config.userContentController.add(handler, name: "heightChanged")
        config.userContentController.add(handler, name: "formatState")

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

        // Execute formatting command if requested
        if let cmd = formatCommand {
            DispatchQueue.main.async {
                self.formatCommand = nil
            }
            let js = """
            document.getElementById('editor').focus();
            document.execCommand('\(cmd)', false, null);
            window.webkit.messageHandlers.htmlChanged.postMessage(getEditorHTML());
            notifyFormatState();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // Execute font size command if requested
        if let size = fontSizeCommand {
            DispatchQueue.main.async {
                self.fontSizeCommand = nil
            }
            let js = """
            (function() {
                const editor = document.getElementById('editor');
                editor.focus();
                const sel = window.getSelection();
                if (!sel.rangeCount || sel.isCollapsed) return;
                const range = sel.getRangeAt(0);
                const fragment = range.extractContents();
                const span = document.createElement('span');
                span.style.fontSize = '\(size)px';
                span.appendChild(fragment);
                // Strip inherited font-size from extracted ancestors so our size wins
                span.querySelectorAll('[style]').forEach(function(el) {
                    el.style.removeProperty('font-size');
                    if (!el.getAttribute('style') || !el.getAttribute('style').trim()) el.removeAttribute('style');
                });
                span.querySelectorAll('font[size]').forEach(function(f) { f.removeAttribute('size'); });
                range.insertNode(span);
                sel.removeAllRanges();
                const nr = document.createRange();
                nr.selectNodeContents(span);
                sel.addRange(nr);
                notifyFormatState();
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func buildEditableHTML(plainText: String, signature: String?, font: NSFont, textColor: NSColor, placeholder: String) -> String {
        let escapedText = plainText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")

        // Build content: user text + signature in one editable area
        let hasSignature = signature != nil && !signature!.isEmpty
        var content = escapedText.isEmpty && !hasSignature ? "" : (escapedText.isEmpty ? "<br>" : escapedText)
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
                    line-height: 1.47;
                    color: \(colorHex);
                    color-scheme: light dark;
                    padding: 0;
                }
                #editor {
                    outline: none;
                    min-height: 100px;
                    word-wrap: break-word;
                    padding: 8px 5px;
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

                function getEditorHTML() {
                    // Get innerHTML of user content (excluding signature)
                    const sig = document.getElementById('sig');
                    if (sig) {
                        const range = document.createRange();
                        range.setStart(editor, 0);
                        range.setEndBefore(sig);
                        const container = document.createElement('div');
                        container.appendChild(range.cloneContents());
                        return container.innerHTML;
                    }
                    return editor.innerHTML;
                }

                function notifyFormatState() {
                    const b = document.queryCommandState('bold');
                    const i = document.queryCommandState('italic');
                    const u = document.queryCommandState('underline');
                    let fs = 13;
                    const sel = window.getSelection();
                    if (sel && sel.rangeCount > 0) {
                        let node = sel.anchorNode;
                        if (node && node.nodeType === 3) node = node.parentNode;
                        if (node && node.nodeType === 1) {
                            const computed = window.getComputedStyle(node).fontSize;
                            fs = Math.round(parseFloat(computed)) || 13;
                        }
                    }
                    window.webkit.messageHandlers.formatState.postMessage({bold: b, italic: i, underline: u, fontSize: fs});
                }

                editor.addEventListener('input', function() {
                    const text = getPlainText();
                    window.webkit.messageHandlers.textChanged.postMessage(text);
                    window.webkit.messageHandlers.htmlChanged.postMessage(getEditorHTML());
                    setTimeout(notifyHeight, 10);
                    notifyFormatState();
                });

                // Track bold/italic/underline state on selection/cursor change
                document.addEventListener('selectionchange', notifyFormatState);

                // MutationObserver: catch all DOM changes (formatting, Cmd+B, etc.)
                new MutationObserver(function() {
                    window.webkit.messageHandlers.htmlChanged.postMessage(getEditorHTML());
                    notifyFormatState();
                }).observe(editor, { childList: true, subtree: true, characterData: true, attributes: true });

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
            case "htmlChanged":
                if let html = message.body as? String, !isUpdating {
                    DispatchQueue.main.async {
                        self.parent?.htmlBody = html
                    }
                }
            case "heightChanged":
                if let height = message.body as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self.parent?.contentHeight = max(height, 100)
                    }
                }
            case "formatState":
                if let dict = message.body as? [String: Any] {
                    let bold = dict["bold"] as? Bool ?? false
                    let italic = dict["italic"] as? Bool ?? false
                    let underline = dict["underline"] as? Bool ?? false
                    let fontSize = dict["fontSize"] as? Int ?? 13
                    DispatchQueue.main.async {
                        self.parent?.onFormatStateChange?(bold, italic, underline, fontSize)
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
