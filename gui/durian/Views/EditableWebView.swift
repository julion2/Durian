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
    let backgroundColor: NSColor
    let placeholderText: String
    @Binding var formatCommand: String?
    @Binding var fontSizeCommand: Int?
    @Binding var fontFamilyCommand: String?
    @Binding var htmlBody: String
    var onFormatStateChange: ((_ bold: Bool, _ italic: Bool, _ underline: Bool, _ strikethrough: Bool, _ fontSize: Int, _ fontFamily: String, _ alignment: String) -> Void)?

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

        // Update signature via JS instead of reloading (preserves user formatting)
        if context.coordinator.lastLoadedSignature != htmlSignature {
            context.coordinator.lastLoadedSignature = htmlSignature
            if context.coordinator.initialLoadDone {
                let escaped = (htmlSignature ?? "")
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "")
                webView.evaluateJavaScript("updateSignature('\(escaped)')")
            } else {
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

        // Execute formatting command if requested
        if let cmd = formatCommand {
            DispatchQueue.main.async {
                self.formatCommand = nil
            }
            let js: String
            if cmd == "insertUnorderedList" || cmd == "insertOrderedList" {
                let tag = cmd == "insertUnorderedList" ? "ul" : "ol"
                js = """
                restoreSelection();
                toggleList('\(tag)');
                """
            } else if cmd == "removeFormat" {
                js = """
                (function() {
                    const editor = document.getElementById('editor');
                    editor.focus();
                    restoreSelection();
                    const sel = window.getSelection();
                    if (!sel.rangeCount) return;
                    const range = sel.getRangeAt(0);
                    if (range.collapsed) return;
                    const fragment = range.extractContents();
                    const tmp = document.createElement('div');
                    tmp.appendChild(fragment);
                    // Strip all attributes from every element
                    tmp.querySelectorAll('*').forEach(function(el) {
                        while (el.attributes.length > 0) {
                            el.removeAttribute(el.attributes[0].name);
                        }
                    });
                    // Unwrap inline/presentational elements, keep block structure (div, p, br, ul, ol, li)
                    const inline = ['SPAN','FONT','B','I','U','S','STRIKE','STRONG','EM','SUB','SUP','MARK','A','ABBR','CITE','CODE','SMALL','BIG','DEL','INS'];
                    tmp.querySelectorAll(inline.join(',')).forEach(function(el) {
                        while (el.firstChild) el.parentNode.insertBefore(el.firstChild, el);
                        el.parentNode.removeChild(el);
                    });
                    // Re-insert cleaned fragment
                    const cleaned = document.createDocumentFragment();
                    while (tmp.firstChild) cleaned.appendChild(tmp.firstChild);
                    range.insertNode(cleaned);
                    window.webkit.messageHandlers.htmlChanged.postMessage(getEditorHTML());
                    notifyFormatState();
                })();
                """
            } else {
                js = """
                document.getElementById('editor').focus();
                restoreSelection();
                document.execCommand('\(cmd)', false, null);
                window.webkit.messageHandlers.htmlChanged.postMessage(getEditorHTML());
                notifyFormatState();
                """
            }
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
                restoreSelection();
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

        // Execute font family command if requested
        if let family = fontFamilyCommand {
            DispatchQueue.main.async {
                self.fontFamilyCommand = nil
            }
            let stacks: [String: String] = [
                "Helvetica": "'Helvetica Neue', Helvetica, Arial, sans-serif",
                "Arial": "Arial, Helvetica, sans-serif",
                "Times New Roman": "'Times New Roman', Times, serif",
                "Georgia": "Georgia, 'Times New Roman', serif",
                "Courier": "'Courier New', Courier, monospace",
            ]
            let stack = stacks[family] ?? "'\(family)', sans-serif"
            let js = """
            (function() {
                const editor = document.getElementById('editor');
                editor.focus();
                restoreSelection();
                const sel = window.getSelection();
                if (!sel.rangeCount || sel.isCollapsed) return;
                const range = sel.getRangeAt(0);
                const fragment = range.extractContents();
                const span = document.createElement('span');
                span.style.fontFamily = "\(stack)";
                span.appendChild(fragment);
                span.querySelectorAll('[style]').forEach(function(el) {
                    el.style.removeProperty('font-family');
                    if (!el.getAttribute('style') || !el.getAttribute('style').trim()) el.removeAttribute('style');
                });
                span.querySelectorAll('font[face]').forEach(function(f) { f.removeAttribute('face'); });
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

    private static func resolveHex(_ color: NSColor, dark: Bool) -> String {
        let name: NSAppearance.Name = dark ? .darkAqua : .aqua
        guard let appearance = NSAppearance(named: name) else {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            return String(format: "#%02x%02x%02x",
                Int(resolved.redComponent * 255),
                Int(resolved.greenComponent * 255),
                Int(resolved.blueComponent * 255))
        }
        var hex = "#000000"
        appearance.performAsCurrentDrawingAppearance {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            hex = String(format: "#%02x%02x%02x",
                Int(resolved.redComponent * 255),
                Int(resolved.greenComponent * 255),
                Int(resolved.blueComponent * 255))
        }
        return hex
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

        let lightTextHex = Self.resolveHex(textColor, dark: false)
        let darkTextHex = Self.resolveHex(textColor, dark: true)
        let lightBgHex = Self.resolveHex(backgroundColor, dark: false)
        let darkBgHex = Self.resolveHex(backgroundColor, dark: true)

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                ul, ol { padding-left: 1.5em; margin: 0.3em 0; }
                li > ul, li > ol { margin: 0; }
                html, body {
                    overflow: hidden;
                    height: auto;
                }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: \(font.pointSize)px;
                    line-height: 1.47;
                    color-scheme: light dark;
                    padding: 0;
                }
                @media (prefers-color-scheme: light) {
                    html, body { background-color: \(lightBgHex); color: \(lightTextHex); }
                }
                @media (prefers-color-scheme: dark) {
                    html, body { background-color: \(darkBgHex); color: \(darkTextHex); }
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
                    // Empty-line divs: <div><br></div> = single newline
                    html = html.replace(/<div><br\\s*\\/?><\\/div>/gi, '\\n');
                    // Block elements: opening tag = line break
                    html = html.replace(/<div[^>]*>/gi, '\\n');
                    html = html.replace(/<\\/div>/gi, '');
                    // Inline line breaks
                    html = html.replace(/<br\\s*\\/?>/gi, '\\n');
                    // Paragraphs
                    html = html.replace(/<p[^>]*>/gi, '\\n');
                    html = html.replace(/<\\/p>/gi, '');
                    // Strip remaining tags
                    html = html.replace(/<[^>]+>/g, '');
                    // Decode HTML entities
                    const ta = document.createElement('textarea');
                    ta.innerHTML = html;
                    let text = ta.value;
                    // Trim leading and trailing newlines
                    text = text.replace(/^\\n+/, '');
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
                        // Strip trailing <br> (visual separator before signature, not user content)
                        let html = container.innerHTML;
                        html = html.replace(/<br\\s*\\/?>$/i, '');
                        return html;
                    }
                    return editor.innerHTML;
                }

                // Save selection on every change so toolbar clicks can restore it
                var savedRange = null;
                document.addEventListener('selectionchange', function() {
                    const sel = window.getSelection();
                    if (sel.rangeCount > 0 && editor.contains(sel.anchorNode)) {
                        savedRange = sel.getRangeAt(0).cloneRange();
                    }
                });
                function restoreSelection() {
                    if (!savedRange) return;
                    editor.focus();
                    const sel = window.getSelection();
                    sel.removeAllRanges();
                    sel.addRange(savedRange);
                }

                function toggleList(tag) {
                    const sel = window.getSelection();
                    if (!sel.rangeCount) return;
                    // Check if cursor is already inside a list of this type
                    let node = sel.anchorNode;
                    while (node && node !== editor) {
                        if (node.nodeName === tag.toUpperCase()) {
                            // Unwrap: replace each <li> with a <div>
                            const parent = node.parentNode;
                            Array.from(node.children).forEach(function(li) {
                                const div = document.createElement('div');
                                div.innerHTML = li.innerHTML;
                                parent.insertBefore(div, node);
                            });
                            parent.removeChild(node);
                            notifyFormatState();
                            return;
                        }
                        node = node.parentNode;
                    }
                    // Create list from selection or current line
                    const range = sel.getRangeAt(0);
                    const text = range.toString();
                    const list = document.createElement(tag);
                    if (text.trim()) {
                        const lines = text.split('\\n');
                        lines.forEach(function(line) {
                            const li = document.createElement('li');
                            li.textContent = line || '';
                            list.appendChild(li);
                        });
                    } else {
                        const li = document.createElement('li');
                        li.innerHTML = '<br>';
                        list.appendChild(li);
                    }
                    range.deleteContents();
                    range.insertNode(list);
                    // Place cursor in first li
                    const firstLi = list.querySelector('li');
                    const nr = document.createRange();
                    nr.setStart(firstLi, firstLi.childNodes.length);
                    nr.collapse(true);
                    sel.removeAllRanges();
                    sel.addRange(nr);
                    notifyFormatState();
                }

                function notifyFormatState() {
                    const b = document.queryCommandState('bold');
                    const i = document.queryCommandState('italic');
                    const u = document.queryCommandState('underline');
                    const s = document.queryCommandState('strikeThrough');
                    let fs = 13;
                    let ff = 'Helvetica';
                    const sel = window.getSelection();
                    if (sel && sel.rangeCount > 0) {
                        let node = sel.anchorNode;
                        if (node && node.nodeType === 3) node = node.parentNode;
                        if (node && node.nodeType === 1) {
                            const cs = window.getComputedStyle(node);
                            fs = Math.round(parseFloat(cs.fontSize)) || 13;
                            const raw = cs.fontFamily;
                            const known = ['Helvetica', 'Arial', 'Times New Roman', 'Georgia', 'Courier'];
                            for (const k of known) {
                                if (raw.indexOf(k) !== -1) { ff = k; break; }
                            }
                        }
                    }
                    let align = 'left';
                    if (document.queryCommandState('justifyCenter')) align = 'center';
                    else if (document.queryCommandState('justifyRight')) align = 'right';
                    else if (document.queryCommandState('justifyFull')) align = 'justify';
                    window.webkit.messageHandlers.formatState.postMessage({bold: b, italic: i, underline: u, strikethrough: s, fontSize: fs, fontFamily: ff, alignment: align});
                }

                editor.addEventListener('input', function(e) {
                    // Auto-list: "- " → bullet list, "1. " → numbered list
                    if (e.inputType === 'insertText' && /^\\s$/.test(e.data)) {
                        const sel = window.getSelection();
                        if (sel.rangeCount > 0 && sel.anchorNode && sel.anchorNode.nodeType === 3) {
                            const node = sel.anchorNode;
                            const text = node.textContent;
                            const offset = sel.anchorOffset;
                            const before = text.substring(0, offset);
                            let listTag = null;
                            let prefixLen = 0;
                            if (/^-\\s$/.test(before)) {
                                listTag = 'ul';
                                prefixLen = 2;
                            } else if (/^\\d+\\.\\s$/.test(before)) {
                                listTag = 'ol';
                                prefixLen = before.length;
                            }
                            if (listTag) {
                                // Remove the prefix text, then create the list
                                const rest = text.substring(prefixLen);
                                node.textContent = rest;
                                // Place cursor at start
                                const r = document.createRange();
                                r.setStart(node, 0);
                                r.collapse(true);
                                sel.removeAllRanges();
                                sel.addRange(r);
                                toggleList(listTag);
                                return;
                            }
                        }
                    }
                    const text = getPlainText();
                    window.webkit.messageHandlers.textChanged.postMessage(text);
                    window.webkit.messageHandlers.htmlChanged.postMessage(getEditorHTML());
                    setTimeout(notifyHeight, 10);
                    notifyFormatState();
                });

                // Tab key: indent/outdent in lists, insert tab otherwise
                editor.addEventListener('keydown', function(e) {
                    if (e.key === 'Tab') {
                        e.preventDefault();
                        // Check if cursor is inside a list
                        let node = window.getSelection().anchorNode;
                        let inList = false;
                        while (node && node !== editor) {
                            if (node.nodeName === 'UL' || node.nodeName === 'OL') { inList = true; break; }
                            node = node.parentNode;
                        }
                        if (inList) {
                            if (e.shiftKey) {
                                document.execCommand('outdent', false, null);
                            } else {
                                document.execCommand('indent', false, null);
                            }
                        } else {
                            document.execCommand('insertText', false, '\\t');
                        }
                    }
                });

                // Track bold/italic/underline state on selection/cursor change
                document.addEventListener('selectionchange', notifyFormatState);

                // MutationObserver: catch all DOM changes (formatting, Cmd+B, etc.)
                new MutationObserver(function() {
                    window.webkit.messageHandlers.htmlChanged.postMessage(getEditorHTML());
                    notifyFormatState();
                }).observe(editor, { childList: true, subtree: true, characterData: true, attributes: true });

                // Update signature without reloading (preserves user formatting)
                function updateSignature(html) {
                    const sig = document.getElementById('sig');
                    if (html && html.length > 0) {
                        if (sig) {
                            sig.innerHTML = html;
                        } else {
                            const br = document.createElement('br');
                            const span = document.createElement('span');
                            span.id = 'sig';
                            span.innerHTML = html;
                            editor.appendChild(br);
                            editor.appendChild(span);
                        }
                    } else {
                        if (sig) {
                            // Remove the <br> before sig too
                            const prev = sig.previousSibling;
                            if (prev && prev.nodeName === 'BR') prev.remove();
                            sig.remove();
                        }
                    }
                    setTimeout(notifyHeight, 10);
                }

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
        var initialLoadDone = false
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
                    let strikethrough = dict["strikethrough"] as? Bool ?? false
                    let fontSize = dict["fontSize"] as? Int ?? 13
                    let fontFamily = dict["fontFamily"] as? String ?? "Helvetica"
                    let alignment = dict["alignment"] as? String ?? "left"
                    DispatchQueue.main.async {
                        self.parent?.onFormatStateChange?(bold, italic, underline, strikethrough, fontSize, fontFamily, alignment)
                    }
                }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            initialLoadDone = true
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
