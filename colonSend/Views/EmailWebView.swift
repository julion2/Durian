//
//  EmailWebView.swift
//  colonSend
//
//  WKWebView wrapper for rendering HTML emails with security hardening
//

import SwiftUI
import WebKit

struct EmailWebView: NSViewRepresentable {
    let html: String
    let theme: String  // "light", "dark", "system" (default)
    
    init(html: String, theme: String = "system") {
        self.html = html
        self.theme = theme
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        
        // SECURITY: Disable JavaScript completely
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        
        // SECURITY: Disable auto-opening windows
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        let styledHTML = buildSecureHTML(html: html, theme: theme)
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }
    
    private func buildSecureHTML(html: String, theme: String) -> String {
        // CSS for theme (system uses @media query)
        let themeCSS: String
        switch theme {
        case "dark":
            themeCSS = """
                body { background-color: #1e1e1e; color: #e0e0e0; }
                a { color: #6db3f2; }
            """
        case "light":
            themeCSS = """
                body { background-color: #ffffff; color: #000000; }
                a { color: #0066cc; }
            """
        default: // "system" or "auto" - follow system preference
            themeCSS = """
                @media (prefers-color-scheme: dark) {
                    body { background-color: #1e1e1e; color: #e0e0e0; }
                    a { color: #6db3f2; }
                }
                @media (prefers-color-scheme: light) {
                    body { background-color: #ffffff; color: #000000; }
                    a { color: #0066cc; }
                }
            """
        }
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <!-- SECURITY: Block all external resources -->
            <meta http-equiv="Content-Security-Policy" 
                  content="default-src 'none'; style-src 'unsafe-inline'; img-src data: cid:;">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: 14px;
                    line-height: 1.5;
                    padding: 8px;
                    margin: 0;
                    color-scheme: light dark;
                }
                img { max-width: 100%; height: auto; }
                \(themeCSS)
            </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        // Links open in default browser (not in WebView)
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
