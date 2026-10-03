import AppKit
import SwiftUI
import WebKit

@MainActor
@Observable
final class TurnstileController {
    static let siteKey = "0x4AAAAAACsMJCI5RCdba9TQ"

    private(set) var token = ""

    private var webView: WKWebView?
    private var delivered = false
    private var timeoutTask: Task<Void, Never>?
    private let timeout = 15.0
    private var isArmed = false

    func attach(_ webView: WKWebView) {
        guard !isArmed else { return }
        isArmed = true
        self.webView = webView
        let proxy = ScriptProxy()
        proxy.controller = self
        webView.configuration.userContentController.add(proxy, contentWorld: .page, name: "turnstile")
        load()
        armTimeout()
    }

    func reload() {
        delivered = false
        token = ""
        load()
        armTimeout()
    }

    fileprivate func receive(_ text: String) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if text.isEmpty {
            delivered = false
            token = ""
            return
        }
        delivered = true
        token = text
    }

    fileprivate func expire() {
        guard !delivered else { return }
        delivered = true
        token = ""
    }

    private func load() {
        webView?.loadHTMLString(Self.replacementHTML(siteKey: Self.siteKey),
                                baseURL: URL(string: LocalProxy.baseURL + "/"))
    }

    private func armTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.timeout ?? 15))
            guard let self, !Task.isCancelled else { return }
            self.expire()
        }
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}#c{display:flex;justify-content:center;align-items:center;height:76px}</style>
    <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"></script>
    </head><body><div id="c"></div><script>
    function post(t){window.webkit.messageHandlers.turnstile.postMessage(t)}
    function render(){
      if(!window.turnstile){post("");return}
      try{
        window.turnstile.render("#c",{sitekey:"__SITEKEY__",
          callback:function(t){post(t)},
          "expired-callback":function(){post("")},
          "error-callback":function(){post("")}});
      }catch(e){post("")}
    }
    if(document.readyState==="complete")render();
    else window.addEventListener("load",render);
    </script></body></html>
    """

    static func replacementHTML(siteKey: String) -> String {
        html.replacingOccurrences(of: "__SITEKEY__", with: siteKey)
    }

    private final class ScriptProxy: NSObject, WKScriptMessageHandler {
        weak var controller: TurnstileController?

        nonisolated func userContentController(_ userContentController: WKUserContentController,
                                               didReceive message: WKScriptMessage) {
            let body = message.body as? String
            MainActor.assumeIsolated {
                guard let body else { return }
                controller?.receive(body)
            }
        }
    }
}

struct TurnstileWebView: NSViewRepresentable {
    let controller: TurnstileController

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        controller.attach(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
