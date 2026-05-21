import SwiftUI
import WebKit

/// 内置微信扫码登录的 WKWebView 封装
struct IMALoginWebView: NSViewRepresentable {
    let onLoginSuccess: () -> Void
    let reloadToken: UUID

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        
        let userContentController = WKUserContentController()
        // 动态注入精细 CSS 样式，强制网页背景透明，隐藏多余头尾信息，隐藏所有溢出滚动条，并让登录容器绝对居中以完美契合小尺寸视口
        let cssSource = """
        var style = document.createElement('style');
        style.innerHTML = `
            html, body, #app, .login-page, .main-container, .login-container, .login-box, .login-card {
                background: transparent !important;
                background-color: transparent !important;
                overflow: hidden !important;
            }
            .header, .footer, .nav-bar, .login-footer, .logo-container {
                display: none !important;
            }
            .login-box, .login-container {
                margin: 0 !important;
                padding: 0 !important;
                position: absolute !important;
                top: 50% !important;
                left: 50% !important;
                transform: translate(-50%, -50%) !important;
            }
        `;
        document.head.appendChild(style);
        """
        let userScript = WKUserScript(source: cssSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        userContentController.addUserScript(userScript)
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        
        // 开启 macOS 平台下 WebKit 的透明背景渲染支持
        webView.setValue(false, forKey: "drawsBackground")
        
        // 禁用 macOS AppKit 级别的滚动条与回弹弹性
        disableScrollbars(in: webView)
        
        // 伪装成标准的 macOS Desktop Chrome User-Agent 以通过微信 OAuth 安全风控
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.loadLoginPage(in: webView, bypassCache: false)
        
        return webView
    }

    private func disableScrollbars(in view: NSView) {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView {
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
                scrollView.horizontalScrollElasticity = .none
                scrollView.verticalScrollElasticity = .none
            }
            disableScrollbars(in: subview)
        }
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastReloadToken != reloadToken else { return }
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.loadLoginPage(in: nsView, bypassCache: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: IMALoginWebView
        weak var webView: WKWebView?
        var lastReloadToken: UUID?
        private var timer: Timer?
        private var isValidating = false

        init(_ parent: IMALoginWebView) {
            self.parent = parent
            super.init()
            startCredentialsPolling()
        }

        deinit {
            timer?.invalidate()
        }

        func loadLoginPage(in webView: WKWebView, bypassCache: Bool) {
            isValidating = false
            webView.stopLoading()

            var components = URLComponents(string: "https://ima.qq.com/login/")!
            if bypassCache {
                let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
                components.queryItems = [URLQueryItem(name: "fs_refresh", value: timestamp)]
            }

            guard let url = components.url else { return }
            var request = URLRequest(url: url)
            if bypassCache {
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            }
            webView.load(request)

            if timer == nil {
                startCredentialsPolling()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                let urlString = url.absoluteString
                print("[IMALoginWebView] Navigating to: \(urlString)")
                
                // 拦截成功登录跳转，触发即时扫描以加速捕获
                if urlString == "https://ima.qq.com/" || urlString.contains("/home") || urlString.contains("/workspace") {
                    print("[IMALoginWebView] Redirect to workspace detected! Scanning credentials.")
                    checkCredentials()
                }
            }
            decisionHandler(.allow)
        }

        /// 开启每秒一次的全维凭证主动扫描（Cookie、JS Cookie、Local/Session Storage）
        private func startCredentialsPolling() {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.checkCredentials()
            }
        }

        private func checkCredentials() {
            guard let webView = webView else { return }
            guard !isValidating else { return }
            
            // 1. 读取 WKHTTPCookieStore（涵盖 HTTPOnly 饼干）
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self = self else { return }
                self.parseCookies(cookies)
            }
            
            // 2. 读取 JS document.cookie
            webView.evaluateJavaScript("document.cookie") { [weak self] result, error in
                guard let self = self, let cookieStr = result as? String, !cookieStr.isEmpty else { return }
                self.parseCookieString(cookieStr)
            }
            
            // 3. 读取 LocalStorage 与 SessionStorage 并打包回传
            let jsGetStorage = """
            (function() {
                var res = {};
                for (var i = 0; i < localStorage.length; i++) {
                    var k = localStorage.key(i);
                    res[k] = localStorage.getItem(k);
                }
                for (var j = 0; j < sessionStorage.length; j++) {
                    var sk = sessionStorage.key(j);
                    res[sk] = sessionStorage.getItem(sk);
                }
                return JSON.stringify(res);
            })()
            """
            webView.evaluateJavaScript(jsGetStorage) { [weak self] result, error in
                guard let self = self, let jsonStr = result as? String, !jsonStr.isEmpty else { return }
                self.parseStorageJson(jsonStr)
            }
        }

        private func parseCookies(_ cookies: [HTTPCookie]) {
            var token = ""
            var refreshToken = ""
            var uid = ""
            var guid = ""

            for cookie in cookies {
                let name = cookie.name.uppercased()
                let value = cookie.value.removingPercentEncoding ?? cookie.value
                if name == "IMA-TOKEN" {
                    token = value
                } else if name == "TOKEN" && (token.isEmpty || token == "guest") {
                    token = value
                } else if name == "IMA-REFRESH-TOKEN" {
                    refreshToken = value
                } else if name == "REFRESH-TOKEN" && refreshToken.isEmpty {
                    refreshToken = value
                } else if name == "IMA-UID" {
                    uid = value
                } else if (name == "UID" || name == "USER_ID") && uid.isEmpty {
                    uid = value
                } else if name == "IMA-GUID" {
                    guid = value
                } else if name == "GUID" && guid.isEmpty {
                    guid = value
                }
            }

            saveIfValid(token: token, refreshToken: refreshToken, uid: uid, guid: guid)
        }

        private func parseCookieString(_ str: String) {
            let pairs = str.components(separatedBy: ";")
            var token = ""
            var refreshToken = ""
            var uid = ""
            var guid = ""
            
            for pair in pairs {
                let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    let name = parts[0].uppercased()
                    let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                    
                    if name == "IMA-TOKEN" {
                        token = value
                    } else if name == "TOKEN" && (token.isEmpty || token == "guest") {
                        token = value
                    } else if name == "IMA-REFRESH-TOKEN" {
                        refreshToken = value
                    } else if name == "REFRESH-TOKEN" && refreshToken.isEmpty {
                        refreshToken = value
                    } else if name == "IMA-UID" {
                        uid = value
                    } else if (name == "UID" || name == "USER_ID") && uid.isEmpty {
                        uid = value
                    } else if name == "IMA-GUID" {
                        guid = value
                    } else if name == "GUID" && guid.isEmpty {
                        guid = value
                    }
                }
            }
            
            saveIfValid(token: token, refreshToken: refreshToken, uid: uid, guid: guid)
        }

        private func parseStorageJson(_ jsonStr: String) {
            guard let data = jsonStr.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            
            var token = ""
            var refreshToken = ""
            var uid = ""
            var guid = ""
            
            // 递归扫描任何嵌套的字典/数组或序列化的 JSON 字符串
            func scan(_ anyObj: Any) {
                if let stringVal = anyObj as? String {
                    let trimmed = stringVal.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("{") && trimmed.hasSuffix("}"),
                       let innerData = trimmed.data(using: .utf8),
                       let innerJson = try? JSONSerialization.jsonObject(with: innerData) {
                        scan(innerJson)
                    }
                    return
                }
                
                if let arrayVal = anyObj as? [Any] {
                    for item in arrayVal {
                        scan(item)
                    }
                    return
                }
                
                if let dictVal = anyObj as? [String: Any] {
                    for (k, v) in dictVal {
                        let upperK = k.uppercased()
                        if let s = v as? String, !s.isEmpty {
                            let value = s.removingPercentEncoding ?? s
                            if upperK == "IMA-TOKEN" || upperK == "IMA_TOKEN" {
                                token = value
                            } else if (upperK == "TOKEN" || upperK.contains("TOKEN")) && (token.isEmpty || token == "guest") {
                                token = value
                            } else if upperK == "IMA-REFRESH-TOKEN" || upperK == "IMA_REFRESH_TOKEN" {
                                refreshToken = value
                            } else if (upperK == "REFRESH_TOKEN" || upperK == "REFRESH-TOKEN" || upperK.contains("REFRESH")) && refreshToken.isEmpty {
                                refreshToken = value
                            } else if upperK == "IMA-UID" || upperK == "IMA_UID" {
                                uid = value
                            } else if (upperK == "USER_ID" || upperK == "UID" || upperK == "USERID") && uid.isEmpty {
                                uid = value
                            } else if upperK == "IMA-GUID" || upperK == "IMA_GUID" {
                                guid = value
                            } else if upperK == "GUID" && guid.isEmpty {
                                guid = value
                            }
                        }
                        // 递归扫描其值（可能包含嵌套字典或嵌套序列化字符串）
                        scan(v)
                    }
                }
            }
            
            scan(dict)
            
            saveIfValid(token: token, refreshToken: refreshToken, uid: uid, guid: guid)
        }

        private func saveIfValid(token: String, refreshToken: String, uid: String, guid: String) {
            guard !token.isEmpty && !uid.isEmpty else { return }
            guard !isValidating else { return }
            
            let finalGuid = guid.isEmpty ? IMACredentialsManager.fallbackGuid() : guid
            let finalRefreshToken = refreshToken.isEmpty ? token : refreshToken

            isValidating = true
            
            Task {
                print("[IMALoginWebView] Testing captured token for validation...")
                let isValid = await IMASyncService.shared.validateCredentials(
                    token: token,
                    refreshToken: finalRefreshToken,
                    uid: uid,
                    guid: finalGuid
                )
                
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if isValid {
                        print("[IMALoginWebView] Captured Session Credentials Validated Successfully!")
                        
                        // 验证成功，停止轮询定时器
                        self.timer?.invalidate()
                        self.timer = nil
                        
                        IMACredentialsManager.shared.save(
                            token: token,
                            refreshToken: finalRefreshToken,
                            uid: uid,
                            guid: finalGuid
                        )
                        
                        // 异步获取微信头像和昵称
                        Task {
                            if let profile = try? await IMASyncService.shared.getUserProfile() {
                                await MainActor.run {
                                    IMACredentialsManager.shared.avatarUrl = profile.avatarUrl
                                    IMACredentialsManager.shared.nickname = profile.nickname
                                }
                            }
                        }
                        
                        self.parent.onLoginSuccess()
                    } else {
                        print("[IMALoginWebView] Temporary or invalid credentials detected, skipping and continuing polling...")
                        self.isValidating = false
                    }
                }
            }
        }
    }
}

/// 精致极简的扫码登录页容器视图 (超紧凑布局)
struct IMALoginView: View {
    let onLoginSuccess: () -> Void
    @State private var isAnimating = false
    @State private var reloadToken = UUID()
    @State private var isReloadingQRCode = false

    var body: some View {
        VStack(spacing: 0) {
            // 极简 Header Bar
            HStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.title3)
                    .foregroundColor(.appMint)
                    .symbolEffect(.pulse, options: .repeating)
                
                Text("微信扫码登录")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                
                Spacer()

                Button {
                    reloadToken = UUID()
                    isReloadingQRCode = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(900))
                        isReloadingQRCode = false
                    }
                } label: {
                    Label("刷新二维码", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(QuietButtonStyle())
                .rotationEffect(.degrees(isReloadingQRCode ? 360 : 0))
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isReloadingQRCode)
                .help("网络不稳定或二维码未显示时，点击重新加载登录二维码")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            
            Divider()
                .opacity(0.12)
            
            // WebView 容器 - 极简 320x320 刚好契合二维码尺寸
            ZStack {
                IMALoginWebView(onLoginSuccess: onLoginSuccess, reloadToken: reloadToken)
                    .frame(width: 320, height: 320)
            }
            .padding(.vertical, 8)
            
            Divider()
                .opacity(0.12)
            
            // 极简安全 Footer Bar
            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.appMint)
                Text("微信凭证已加密托管至系统原生 Keychain")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 350, height: 410)
        // 极致的磨砂玻璃背景
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 25, x: 0, y: 12)
        .opacity(isAnimating ? 1.0 : 0.0)
        .scaleEffect(isAnimating ? 1.0 : 0.97)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                isAnimating = true
            }
        }
    }
}
