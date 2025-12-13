//
//  EmailWebView.swift
//  colonSend
//
//  WKWebView wrapper for rendering HTML emails
//

import SwiftUI
import WebKit

struct EmailWebView: NSViewRepresentable {
    let html: String
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        print("WEBVIEW: Loading HTML with length: \(html.count)")
        
        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: 14px;
                    line-height: 1.5;
                    padding: 8px;
                    margin: 0;
                    background-color: white;
                }
                a { color: #0066cc; }
                img { max-width: 100%; height: auto; }
            </style>
        </head>
        <body>\(html)</body>
        </html>
        """
        webView.loadHTMLString(styledHTML, baseURL: URL(string: "about:blank"))
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("WEBVIEW: Finished loading")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("WEBVIEW: Failed with error: \(error)")
        }
        
        // Links im Standard-Browser öffnen (nicht in WebView navigieren)
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
