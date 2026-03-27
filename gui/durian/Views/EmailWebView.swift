//
//  EmailWebView.swift
//  Durian
//
//  WKWebView wrapper for rendering HTML emails with security hardening
//

import SwiftUI
import WebKit

struct EmailWebView: NSViewRepresentable {
    let html: String
    let theme: String           // "light", "dark", "system" (default)
    let loadRemoteImages: Bool  // Security: block tracking pixels by default
    
    init(html: String, theme: String = "system", loadRemoteImages: Bool = false) {
        self.html = html
        self.theme = theme
        self.loadRemoteImages = loadRemoteImages
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        
        // JavaScript is disabled in HTML via CSP (script-src 'none').
        // evaluateJavaScript from Swift bypasses CSP for dark mode transform.
        
        // SECURITY: Disable auto-opening windows
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.parent = self
        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        let styledHTML = buildSecureHTML(html: html, theme: theme, loadRemoteImages: loadRemoteImages)
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }
    
    private func buildSecureHTML(html: String, theme: String, loadRemoteImages: Bool) -> String {
        // Dynamic CSP based on loadRemoteImages setting
        let csp: String
        if loadRemoteImages {
            csp = "default-src 'none'; style-src 'unsafe-inline'; img-src data: cid: https: http:;"
        } else {
            csp = "default-src 'none'; style-src 'unsafe-inline'; img-src data: cid:;"
        }
        
        // Theme CSS with robust dark mode (CSS filter invert)
        let themeCSS: String
        switch theme {
        case "light":
            // No filter, normal display
            themeCSS = """
                body { background-color: #ffffff; color: #000000; }
                a { color: #0066cc; }
            """
        case "dark":
            themeCSS = """
                body { background-color: #2a2a2c; }
            """
        default: // "system" - follow system preference via @media query
            themeCSS = """
                @media (prefers-color-scheme: light) {
                    body { background-color: #ffffff; color: #000000; }
                    a { color: #0066cc; }
                }
                @media (prefers-color-scheme: dark) {
                    body { background-color: #2a2a2c; }
                }
            """
        }
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <meta http-equiv="Content-Security-Policy" content="\(csp)">
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
        var parent: EmailWebView?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let isDark = parent?.theme == "dark" ||
                (parent?.theme == "system" && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            if isDark {
                webView.evaluateJavaScript(DarkModeTransform.js)
            }
        }

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
