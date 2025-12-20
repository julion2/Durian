//
//  NonScrollingWebView.swift
//  Durian
//
//  A WKWebView that doesn't scroll and sizes itself to fit its content.
//  Used for embedding HTML content in a parent ScrollView.
//

import SwiftUI
import WebKit

// MARK: - Custom WebView that passes scroll events to parent

/// A WKWebView subclass that passes scroll wheel events to its parent ScrollView
class ScrollPassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // Pass scroll events to parent instead of handling them
        self.nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - NonScrollingWebView

/// A WebView that sizes itself to fit its HTML content without internal scrolling
struct NonScrollingWebView: NSViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat
    
    init(html: String, contentHeight: Binding<CGFloat>) {
        self.html = html
        self._contentHeight = contentHeight
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        
        // Enable JavaScript for height measurement
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        
        // Use custom WebView that passes scroll events to parent
        let webView = ScrollPassthroughWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        
        // White background
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.white.cgColor
        
        context.coordinator.webView = webView
        context.coordinator.parent = self
        
        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        let styledHTML = buildHTML(html: html)
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }
    
    private func buildHTML(html: String) -> String {
        return """
        <!DOCTYPE html>
        <html style="background-color: white !important;">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body {
                    background-color: white !important;
                    overflow: hidden;
                }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: 14px;
                    line-height: 1.5;
                    padding: 12px;
                    color: #555;
                }
                img { max-width: 100%; height: auto; }
                a { color: #0066cc; }
            </style>
        </head>
        <body style="background-color: white !important;">\(html)</body>
        </html>
        """
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var parent: NonScrollingWebView?
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Measure content height after page loads
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, error in
                if let height = result as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self?.parent?.contentHeight = height
                    }
                }
            }
        }
        
        // Links open in default browser
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
