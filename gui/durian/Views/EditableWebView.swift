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
    var onVimModeChange: ((_ mode: String) -> Void)?
    var vimInsertExitKeys: [String] = []

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
        config.userContentController.add(handler, name: "vimModeChanged")
        config.userContentController.add(handler, name: "vimYank")
        config.userContentController.add(handler, name: "vimPaste")

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
        let exitKeysJS = "[" + vimInsertExitKeys.map { "\"\($0)\"" }.joined(separator: ",") + "]"
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

                // Vim modal editing engine
                const vim = {
                    mode: 'insert',
                    register: '',
                    registerIsLine: false,
                    visual: '',
                    pending: '',
                    pendingCount: 0,
                    count: '',
                    exitSeqs: \(exitKeysJS),
                    insertPending: '',
                    insertTimer: null,

                    notifyMode() {
                        let m = this.mode;
                        if (this.visual === 'char') m = 'visual';
                        else if (this.visual === 'line') m = 'visual_line';
                        window.webkit.messageHandlers.vimModeChanged.postMessage(m);
                    },

                    setMode(m) {
                        this.mode = m;
                        this.visual = '';
                        this.pending = '';
                        this.count = '';
                        editor.classList.toggle('vim-normal', m === 'normal');
                        this.notifyMode();
                    },

                    getCurrentBlock() {
                        const sel = window.getSelection();
                        if (!sel.rangeCount) return null;
                        let node = sel.anchorNode;
                        if (node === editor) return editor.firstChild;
                        while (node && node.parentNode !== editor) node = node.parentNode;
                        return node;
                    },

                    // Execute a motion in 'move' or 'extend' mode
                    execMotion(key, n, mode) {
                        const sel = window.getSelection();
                        if (!sel.rangeCount) return false;
                        switch(key) {
                            case 'h': for(let i=0;i<n;i++) sel.modify(mode,'backward','character'); return true;
                            case 'l': for(let i=0;i<n;i++) sel.modify(mode,'forward','character'); return true;
                            case 'j': for(let i=0;i<n;i++) sel.modify(mode,'forward','line'); return true;
                            case 'k': for(let i=0;i<n;i++) sel.modify(mode,'backward','line'); return true;
                            case 'w': for(let i=0;i<n;i++) sel.modify(mode,'forward','word'); return true;
                            case 'b': for(let i=0;i<n;i++) sel.modify(mode,'backward','word'); return true;
                            case 'e': for(let i=0;i<n;i++) sel.modify(mode,'forward','word'); return true;
                            case '0': sel.modify(mode,'backward','lineboundary'); return true;
                            case '$': sel.modify(mode,'forward','lineboundary'); return true;
                            default: return false;
                        }
                    },

                    // Apply operator (d/c/y) on current selection
                    applyOperator(op) {
                        const sel = window.getSelection();
                        if (sel.isCollapsed) return;
                        const text = sel.toString();
                        this.register = text;
                        this.registerIsLine = false;
                        window.webkit.messageHandlers.vimYank.postMessage(text);
                        if (op === 'd' || op === 'c') {
                            document.execCommand('delete');
                            if (op === 'c') this.setMode('insert');
                        } else {
                            sel.collapseToStart();
                        }
                    },

                    // cc: change entire line content
                    changeLine(n) {
                        const sel = window.getSelection();
                        if (!sel.rangeCount) return;
                        sel.modify('move','backward','lineboundary');
                        for (let i = 0; i < n - 1; i++) sel.modify('extend','forward','line');
                        sel.modify('extend','forward','lineboundary');
                        if (!sel.isCollapsed) {
                            this.register = sel.toString();
                            this.registerIsLine = true;
                            window.webkit.messageHandlers.vimYank.postMessage(this.register);
                            document.execCommand('delete');
                        }
                        this.setMode('insert');
                    },

                    // Custom w motion for move mode (handles punctuation)
                    moveW(n) {
                        const sel = window.getSelection();
                        for(let i=0;i<n;i++) {
                            const wn = sel.focusNode;
                            if (wn && wn.nodeType === 3) {
                                const wt = wn.textContent;
                                let wp = sel.focusOffset;
                                if (wp < wt.length && /\\w/.test(wt[wp])) {
                                    while (wp < wt.length && /\\w/.test(wt[wp])) wp++;
                                    while (wp < wt.length && !/\\w/.test(wt[wp])) wp++;
                                } else {
                                    while (wp < wt.length && !/\\w/.test(wt[wp])) wp++;
                                }
                                if (wp > sel.focusOffset && wp <= wt.length) {
                                    const wr = document.createRange();
                                    wr.setStart(wn, wp);
                                    wr.collapse(true);
                                    sel.removeAllRanges();
                                    sel.addRange(wr);
                                } else {
                                    sel.modify('move','forward','word');
                                }
                            } else {
                                sel.modify('move','forward','word');
                            }
                        }
                    },

                    handleNormal(e) {
                        const key = e.key;
                        if (e.ctrlKey && key === 'r') { document.execCommand('redo'); return; }

                        if (/^[1-9]$/.test(key) || (this.count && /^[0-9]$/.test(key))) {
                            this.count += key;
                            return;
                        }
                        const n = parseInt(this.count) || 1;
                        this.count = '';
                        const sel = window.getSelection();

                        // Pending operator handling
                        if (this.pending) {
                            const op = this.pending;
                            const combo = op + key;
                            const pn = this.pendingCount;
                            this.pending = '';
                            this.pendingCount = 0;

                            // r: replace char with next typed char
                            if (op === 'r' && key.length === 1 && key !== 'Escape') {
                                this.replaceChar(key, pn);
                                this.recordAction(['r', key]);
                                return;
                            }
                            if (op === 'r') return; // Escape cancels r

                            // f/t/F/T: find char on line
                            if ((op === 'f' || op === 't' || op === 'F' || op === 'T') && key.length === 1 && key !== 'Escape') {
                                const dir = (op === 'f' || op === 't') ? 'forward' : 'backward';
                                const till = (op === 't' || op === 'T');
                                for (let i = 0; i < pn; i++) this.findChar(key, dir, till);
                                return;
                            }
                            if (op === 'f' || op === 't' || op === 'F' || op === 'T') return;

                            // Line ops: dd, cc, yy, gg
                            if (combo === 'dd') { this.deleteLine(pn); this.recordAction(['dd']); return; }
                            if (combo === 'cc') { this.changeLine(pn); return; }
                            if (combo === 'yy') { this.yankLine(pn); return; }
                            if (combo === 'gg') { this.goToTop(); return; }

                            // Operator + motion (dw, cw, yw, d$, etc.)
                            if ((op === 'd' || op === 'c' || op === 'y') && this.execMotion(key, pn, 'extend')) {
                                this.applyOperator(op);
                                if (op === 'd') this.recordAction([op, key]);
                                return;
                            }
                            return;
                        }

                        // Visual mode: operators apply on selection directly
                        if (this.visual && (key === 'd' || key === 'c' || key === 'y')) {
                            this.applyOperator(key);
                            this.visual = '';
                            this.notifyMode();
                            return;
                        }

                        // Visual mode: motions extend selection
                        const mot = this.visual ? 'extend' : 'move';

                        switch(key) {
                            // Visual mode toggles
                            case 'v':
                                if (this.visual === 'char') {
                                    this.visual = '';
                                    sel.collapseToEnd();
                                } else {
                                    this.visual = 'char';
                                    sel.modify('extend','forward','character');
                                }
                                this.notifyMode();
                                break;
                            case 'V':
                                if (this.visual === 'line') {
                                    this.visual = '';
                                    sel.collapseToEnd();
                                } else {
                                    this.visual = 'line';
                                    if (sel.rangeCount) {
                                        sel.modify('move','backward','lineboundary');
                                        sel.modify('extend','forward','lineboundary');
                                    }
                                }
                                this.notifyMode();
                                break;
                            // Insert mode entries (not in visual)
                            case 'i': if (!this.visual) this.setMode('insert'); break;
                            case 'a': if (!this.visual) { if (sel.rangeCount) sel.modify('move','forward','character'); this.setMode('insert'); } break;
                            case 'I': if (!this.visual) { if (sel.rangeCount) sel.modify('move','backward','lineboundary'); this.setMode('insert'); } break;
                            case 'A': if (!this.visual) { if (sel.rangeCount) sel.modify('move','forward','lineboundary'); this.setMode('insert'); } break;
                            case 'o': if (!this.visual) { this.openLineBelow(); this.setMode('insert'); } break;
                            case 'O': if (!this.visual) { this.openLineAbove(); this.setMode('insert'); } break;
                            // Navigation (extend in visual, move in normal)
                            case 'h': for(let i=0;i<n;i++) sel.modify(mot,'backward','character'); break;
                            case 'l': for(let i=0;i<n;i++) sel.modify(mot,'forward','character'); break;
                            case 'j': for(let i=0;i<n;i++) sel.modify(mot,'forward','line'); break;
                            case 'k': for(let i=0;i<n;i++) sel.modify(mot,'backward','line'); break;
                            case 'w': if (this.visual) { for(let i=0;i<n;i++) sel.modify('extend','forward','word'); } else { this.moveW(n); } break;
                            case 'b': for(let i=0;i<n;i++) sel.modify(mot,'backward','word'); break;
                            case 'e': for(let i=0;i<n;i++) sel.modify(mot,'forward','word'); break;
                            case '0': if (sel.rangeCount) sel.modify(mot,'backward','lineboundary'); break;
                            case '$': if (sel.rangeCount) sel.modify(mot,'forward','lineboundary'); break;
                            case 'G': if (this.visual) { sel.modify('extend','forward','documentboundary'); } else { this.goToBottom(); } break;
                            // Editing
                            case 'x': this.deleteForward(n); this.recordAction(['x']); if (this.visual) { this.visual = ''; this.notifyMode(); } break;
                            case 'X': this.deleteBackward(n); if (this.visual) { this.visual = ''; this.notifyMode(); } break;
                            case 'u': document.execCommand('undo'); break;
                            case 'p': this.pasteAfter(); break;
                            case 'P': this.pasteBefore(); break;
                            // New: r (replace), ~ (toggle case), J (join)
                            case 'r': this.pending = 'r'; this.pendingCount = n; break;
                            case '~': this.toggleCase(n); this.recordAction(['~']); break;
                            case 'J': this.joinLines(n); this.recordAction(['J']); break;
                            // New: f/t/F/T (find char), ;/, (repeat find)
                            case 'f': this.pending = 'f'; this.pendingCount = n; break;
                            case 't': this.pending = 't'; this.pendingCount = n; break;
                            case 'F': this.pending = 'F'; this.pendingCount = n; break;
                            case 'T': this.pending = 'T'; this.pendingCount = n; break;
                            case ';': this.repeatFind(false); break;
                            case ',': this.repeatFind(true); break;
                            // New: . (repeat last action)
                            case '.': this.repeatLastAction(n); break;
                            // Shortcuts: C = c$, D = d$
                            case 'C': if (sel.rangeCount) { sel.modify('extend','forward','lineboundary'); this.applyOperator('c'); } break;
                            case 'D': if (sel.rangeCount) { sel.modify('extend','forward','lineboundary'); this.applyOperator('d'); this.recordAction(['D']); } break;
                            // Operators (pending, not in visual — visual handled above)
                            case 'd': this.pending = 'd'; this.pendingCount = n; break;
                            case 'c': this.pending = 'c'; this.pendingCount = n; break;
                            case 'y': this.pending = 'y'; this.pendingCount = n; break;
                            case 'g': this.pending = 'g'; this.pendingCount = n; break;
                            case 'Escape':
                                if (this.visual) { this.visual = ''; sel.collapseToEnd(); this.notifyMode(); }
                                this.pending = '';
                                break;
                        }
                    },

                    deleteLine(n) {
                        let block = this.getCurrentBlock();
                        if (!block || block.id === 'sig') return;
                        const sel = window.getSelection();
                        let lines = [];
                        let lastBlock = block;
                        lines.push(block.textContent);
                        for (let i = 1; i < n; i++) {
                            const next = lastBlock.nextElementSibling || lastBlock.nextSibling;
                            if (!next || next.id === 'sig') break;
                            lines.push(next.textContent);
                            lastBlock = next;
                        }
                        this.register = lines.join('\\n');
                        this.registerIsLine = true;
                        window.webkit.messageHandlers.vimYank.postMessage(this.register);
                        const range = document.createRange();
                        range.setStartBefore(block);
                        range.setEndAfter(lastBlock);
                        sel.removeAllRanges();
                        sel.addRange(range);
                        document.execCommand('delete');
                        if (!editor.textContent.trim() && !editor.querySelector('#sig')) {
                            editor.innerHTML = '<br>';
                            this.placeCursorAt(editor);
                        }
                        this.notifyTextChange();
                    },

                    yankLine(n) {
                        let block = this.getCurrentBlock();
                        if (!block) return;
                        let lines = [];
                        for (let i = 0; i < n && block; i++) {
                            lines.push(block.textContent);
                            block = block.nextElementSibling || block.nextSibling;
                        }
                        this.register = lines.join('\\n');
                        this.registerIsLine = true;
                        window.webkit.messageHandlers.vimYank.postMessage(this.register);
                    },

                    openLineBelow() {
                        const block = this.getCurrentBlock();
                        const div = document.createElement('div');
                        div.innerHTML = '<br>';
                        if (block && block.nextSibling) editor.insertBefore(div, block.nextSibling);
                        else editor.appendChild(div);
                        this.placeCursorAt(div);
                        this.notifyTextChange();
                    },

                    openLineAbove() {
                        const block = this.getCurrentBlock();
                        const div = document.createElement('div');
                        div.innerHTML = '<br>';
                        if (block) editor.insertBefore(div, block);
                        else editor.appendChild(div);
                        this.placeCursorAt(div);
                        this.notifyTextChange();
                    },

                    doPaste(text, before) {
                        if (!text) return;
                        editor.focus();
                        const sel = window.getSelection();
                        if (this.registerIsLine && text === this.register) {
                            if (before) {
                                if (sel.rangeCount) sel.modify('move','backward','lineboundary');
                                document.execCommand('insertParagraph');
                                sel.modify('move','backward','line');
                            } else {
                                if (sel.rangeCount) sel.modify('move','forward','lineboundary');
                                document.execCommand('insertParagraph');
                            }
                            document.execCommand('insertText', false, text);
                        } else {
                            document.execCommand('insertText', false, text);
                        }
                        this.notifyTextChange();
                    },

                    pasteAfter() {
                        window.webkit.messageHandlers.vimPaste.postMessage({before: false});
                    },

                    pasteBefore() {
                        window.webkit.messageHandlers.vimPaste.postMessage({before: true});
                    },

                    deleteForward(n) {
                        for (let i = 0; i < n; i++) document.execCommand('forwardDelete');
                    },

                    deleteBackward(n) {
                        for (let i = 0; i < n; i++) document.execCommand('delete');
                    },

                    goToTop() {
                        const range = document.createRange();
                        range.setStart(editor, 0);
                        range.collapse(true);
                        const sel = window.getSelection();
                        sel.removeAllRanges();
                        sel.addRange(range);
                    },

                    goToBottom() {
                        const sel = window.getSelection();
                        const range = document.createRange();
                        range.selectNodeContents(editor);
                        range.collapse(false);
                        sel.removeAllRanges();
                        sel.addRange(range);
                    },

                    placeCursorAt(node) {
                        const sel = window.getSelection();
                        const range = document.createRange();
                        if (node.childNodes.length > 0 && node.childNodes[0].nodeType === 3) {
                            range.setStart(node.childNodes[0], 0);
                        } else {
                            range.setStart(node, 0);
                        }
                        range.collapse(true);
                        sel.removeAllRanges();
                        sel.addRange(range);
                    },

                    notifyTextChange() {
                        window.webkit.messageHandlers.textChanged.postMessage(getPlainText());
                        setTimeout(notifyHeight, 10);
                    },

                    // r: replace char under cursor with next typed char
                    replaceChar(ch, n) {
                        const sel = window.getSelection();
                        if (!sel.rangeCount) return;
                        for (let i = 0; i < n; i++) {
                            sel.modify('extend', 'forward', 'character');
                            document.execCommand('insertText', false, ch);
                        }
                        // Move cursor back to last replaced char
                        sel.modify('move', 'backward', 'character');
                        this.notifyTextChange();
                    },

                    // ~: toggle case of char under cursor
                    toggleCase(n) {
                        const sel = window.getSelection();
                        if (!sel.rangeCount) return;
                        for (let i = 0; i < n; i++) {
                            sel.modify('extend', 'forward', 'character');
                            const ch = sel.toString();
                            if (!ch) break;
                            const toggled = ch === ch.toUpperCase() ? ch.toLowerCase() : ch.toUpperCase();
                            document.execCommand('insertText', false, toggled);
                        }
                        this.notifyTextChange();
                    },

                    // J: join current line with next line
                    joinLines(n) {
                        const sel = window.getSelection();
                        if (!sel.rangeCount) return;
                        for (let i = 0; i < n; i++) {
                            sel.modify('move', 'forward', 'lineboundary');
                            // Delete the line break and any leading whitespace on next line
                            sel.modify('extend', 'forward', 'character');
                            const br = sel.toString();
                            if (!br || br === '') break;
                            document.execCommand('insertText', false, ' ');
                            // Trim leading whitespace of the joined line
                            while (true) {
                                sel.modify('extend', 'forward', 'character');
                                const c = sel.toString();
                                if (c === ' ' || c === '\\t') {
                                    document.execCommand('delete');
                                } else {
                                    sel.collapseToStart();
                                    break;
                                }
                            }
                        }
                        this.notifyTextChange();
                    },

                    // f/t/F/T: find char on current line
                    lastFind: null,
                    findChar(ch, direction, till) {
                        this.lastFind = { ch, direction, till };
                        const sel = window.getSelection();
                        if (!sel.rangeCount) return;
                        const node = sel.focusNode;
                        if (!node || node.nodeType !== 3) return;
                        const text = node.textContent;
                        let pos = sel.focusOffset;
                        if (direction === 'forward') {
                            const idx = text.indexOf(ch, pos + 1);
                            if (idx === -1) return;
                            const target = till ? idx - 1 : idx;
                            if (target <= pos) return;
                            const mot = this.visual ? 'extend' : 'move';
                            for (let i = 0; i < target - pos; i++) sel.modify(mot, 'forward', 'character');
                        } else {
                            const idx = text.lastIndexOf(ch, pos - 1);
                            if (idx === -1) return;
                            const target = till ? idx + 1 : idx;
                            if (target >= pos) return;
                            const mot = this.visual ? 'extend' : 'move';
                            for (let i = 0; i < pos - target; i++) sel.modify(mot, 'backward', 'character');
                        }
                    },

                    // ;/,: repeat last f/t/F/T
                    repeatFind(reverse) {
                        if (!this.lastFind) return;
                        const { ch, direction, till } = this.lastFind;
                        const dir = reverse ? (direction === 'forward' ? 'backward' : 'forward') : direction;
                        this.findChar(ch, dir, till);
                    },

                    // . repeat: last editing action
                    lastAction: null,

                    recordAction(keys) {
                        this.lastAction = keys;
                    },

                    repeatLastAction(n) {
                        if (!this.lastAction) return;
                        const saved = this.lastAction;
                        this.lastAction = null; // prevent overwrite during replay
                        if (n > 1) this.count = String(n);
                        for (const k of saved) {
                            this.handleNormal({ key: k, ctrlKey: false, preventDefault() {} });
                        }
                        this.lastAction = saved; // restore
                    }
                };

                // Unified keydown handler (vim + tab)
                editor.addEventListener('keydown', function(e) {
                    // Normal mode: vim handles everything
                    if (vim.mode === 'normal') {
                        if (e.metaKey) return;
                        e.preventDefault();
                        vim.handleNormal(e);
                        return;
                    }

                    // Insert mode: Escape enters normal mode
                    if (e.key === 'Escape') {
                        e.preventDefault();
                        vim.insertPending = '';
                        clearTimeout(vim.insertTimer);
                        vim.setMode('normal');
                        const sel = window.getSelection();
                        if (sel.rangeCount) sel.modify('move', 'backward', 'character');
                        return;
                    }

                    // Insert mode: configurable exit sequences (e.g. jk)
                    if (vim.exitSeqs.length > 0 && e.key.length === 1) {
                        const pending = vim.insertPending + e.key;
                        if (vim.exitSeqs.indexOf(pending) !== -1) {
                            e.preventDefault();
                            clearTimeout(vim.insertTimer);
                            vim.insertPending = '';
                            for (let i = 0; i < pending.length - 1; i++) document.execCommand('delete');
                            vim.setMode('normal');
                            const esel = window.getSelection();
                            if (esel.rangeCount) esel.modify('move', 'backward', 'character');
                            return;
                        }
                        const hasPartial = vim.exitSeqs.some(function(s) { return s.startsWith(pending) && s !== pending; });
                        if (hasPartial) {
                            vim.insertPending = pending;
                            clearTimeout(vim.insertTimer);
                            vim.insertTimer = setTimeout(function() { vim.insertPending = ''; }, 200);
                            return;
                        }
                        vim.insertPending = '';
                        clearTimeout(vim.insertTimer);
                    }

                    // Insert mode: Tab handling
                    if (e.key === 'Tab') {
                        e.preventDefault();
                        let node = window.getSelection().anchorNode;
                        let inList = false;
                        while (node && node !== editor) {
                            if (node.nodeName === 'UL' || node.nodeName === 'OL') { inList = true; break; }
                            node = node.parentNode;
                        }
                        if (inList) {
                            document.execCommand(e.shiftKey ? 'outdent' : 'indent', false, null);
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
            case "vimModeChanged":
                if let mode = message.body as? String {
                    DispatchQueue.main.async {
                        self.parent?.onVimModeChange?(mode)
                    }
                }
            case "vimYank":
                if let text = message.body as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            case "vimPaste":
                let before = (message.body as? [String: Any])?["before"] as? Bool ?? false
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                let escaped = text
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "")
                webView?.evaluateJavaScript("vim.doPaste('\(escaped)', \(before))")
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
