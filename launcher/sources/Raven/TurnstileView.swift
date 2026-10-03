import AppKit
import WebKit

@MainActor
final class TurnstileView: DynamicSurfaceView, WKNavigationDelegate {
    static let siteKey = "0x4AAAAAACsMJCI5RCdba9TQ"

    var onToken: ((String) -> Void)?

    private final class ScriptProxy: NSObject, WKScriptMessageHandler {
        weak var view: TurnstileView?

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            view?.didReceive(message)
        }
    }

    private let proxy = ScriptProxy()
    private let controller = WKUserContentController()
    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        return WKWebView(frame: .zero, configuration: configuration)
    }()

    private let timeout = 15.0
    private var timeoutTask: Task<Void, Never>?
    private var delivered = false

    init() {
        super.init(fill: { NSColor.controlBackgroundColor.withAlphaComponent(0.5) },
                   stroke: { NSColor.separatorColor },
                   cornerRadius: 8)

        proxy.view = self
        controller.add(proxy, contentWorld: .page, name: "turnstile")
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: 88),
        ])
        load()
        armTimeout()
    }

    func reload() {
        delivered = false
        load()
        armTimeout()
    }

    private func load() {
        webView.loadHTMLString(Self.replacementHTML(siteKey: Self.siteKey),
                               baseURL: URL(string: LocalProxy.baseURL + "/"))
    }

    private func armTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.timeout ?? 15))
            guard let self, !Task.isCancelled, !self.delivered else { return }
            self.delivered = true
            self.onToken?("")
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fail()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        fail()
    }

    private func fail() {
        guard !delivered else { return }
        delivered = true
        onToken?("")
    }

    func didReceive(_ message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        if text.isEmpty {
            delivered = false
            onToken?("")
            return
        }
        delivered = true
        onToken?(text)
    }

    static func replacementHTML(siteKey: String) -> String {
        html.replacingOccurrences(of: "__SITEKEY__", with: siteKey)
    }
}
