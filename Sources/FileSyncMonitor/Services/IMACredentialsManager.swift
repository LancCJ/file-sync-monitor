import Foundation
import Observation
import WebKit

/// 管理 IMA 登录凭证（Cookie/Token）的安全存储与计算
@Observable
final class IMACredentialsManager {
    static let shared = IMACredentialsManager()
    
    // 内存缓存以驱动 SwiftUI 视图流式更新
    var imaToken: String = ""
    var imaRefreshToken: String = ""
    var imaUid: String = ""
    var imaGuid: String = ""
    
    // 微信个人头像与昵称（响应式存储）
    var avatarUrl: String = UserDefaults.standard.string(forKey: "ima_avatar_url") ?? "" {
        didSet { UserDefaults.standard.set(avatarUrl, forKey: "ima_avatar_url") }
    }
    var nickname: String = UserDefaults.standard.string(forKey: "ima_nickname") ?? "" {
        didSet { UserDefaults.standard.set(nickname, forKey: "ima_nickname") }
    }
    
    private struct CachedCredentials: Codable {
        let token: String
        let refreshToken: String
        let uid: String
        let guid: String
    }
    
    private let serviceName = "com.tencent.imamac.credentials"
    private let singleCredentialsKey = "ima_combined_credentials"
    
    // 旧版的分离 Key（用于平滑迁移）
    private let tokenKey = "ima_token"
    private let refreshTokenKey = "ima_refresh_token"
    private let uidKey = "ima_uid"
    private let guidKey = "ima_guid"
    
    var isLoggedIn: Bool {
        return !imaToken.isEmpty && !imaUid.isEmpty
    }
    
    var bkn: UInt32 {
        guard !imaToken.isEmpty else { return 0 }
        return calculateBkn(token: imaToken)
    }
    
    private init() {
        load()
    }
    
    /// 从系统安全 KeyChain 加载凭证到内存 (支持单主 Key 加载与旧 Key 迁移)
    func load() {
        // 1. 优先尝试从合并的主 Key 载入（只需 1 次钥匙串弹窗授权）
        if let jsonString = KeychainHelper.shared.read(service: serviceName, account: singleCredentialsKey),
           let data = jsonString.data(using: .utf8),
           let creds = try? JSONDecoder().decode(CachedCredentials.self, from: data) {
            self.imaToken = creds.token
            self.imaRefreshToken = creds.refreshToken
            self.imaUid = creds.uid
            self.imaGuid = creds.guid
            return
        }
        
        // 2. 如果没有合并主 Key，则尝试读取旧版的分离 Key（向下兼容平滑升级）
        let legacyToken = KeychainHelper.shared.read(service: serviceName, account: tokenKey) ?? ""
        let legacyRefreshToken = KeychainHelper.shared.read(service: serviceName, account: refreshTokenKey) ?? ""
        let legacyUid = KeychainHelper.shared.read(service: serviceName, account: uidKey) ?? ""
        let legacyGuid = KeychainHelper.shared.read(service: serviceName, account: guidKey) ?? ""
        
        if !legacyToken.isEmpty {
            self.imaToken = legacyToken
            self.imaRefreshToken = legacyRefreshToken
            self.imaUid = legacyUid
            self.imaGuid = legacyGuid
            
            // 自动升级为合并的单 Key 存储，并删除旧版 Key 以防后续再次弹窗
            let creds = CachedCredentials(token: legacyToken, refreshToken: legacyRefreshToken, uid: legacyUid, guid: legacyGuid)
            if let data = try? JSONEncoder().encode(creds),
               let jsonString = String(data: data, encoding: .utf8) {
                KeychainHelper.shared.save(jsonString, service: serviceName, account: singleCredentialsKey)
                
                // 异步在后台静默删除旧版 Key
                DispatchQueue.global(qos: .utility).async {
                    KeychainHelper.shared.delete(service: self.serviceName, account: self.tokenKey)
                    KeychainHelper.shared.delete(service: self.serviceName, account: self.refreshTokenKey)
                    KeychainHelper.shared.delete(service: self.serviceName, account: self.uidKey)
                    KeychainHelper.shared.delete(service: self.serviceName, account: self.guidKey)
                }
            }
        }
    }
    
    /// 保存从 WebView 或 CookieStore 截获的鉴权凭证
    func save(token: String, refreshToken: String, uid: String, guid: String) {
        let creds = CachedCredentials(token: token, refreshToken: refreshToken, uid: uid, guid: guid)
        if let data = try? JSONEncoder().encode(creds),
           let jsonString = String(data: data, encoding: .utf8) {
            // 合并存储为一个 Key，大幅降低钥匙串系统弹窗次数
            KeychainHelper.shared.save(jsonString, service: serviceName, account: singleCredentialsKey)
        }
        
        // 更新内存状态触发 UI 响应
        self.imaToken = token
        self.imaRefreshToken = refreshToken
        self.imaUid = uid
        self.imaGuid = guid
    }
    
    /// 退出登录，清空凭证
    func clear(clearWebView: Bool = false) {
        // 清理合并 Key
        KeychainHelper.shared.delete(service: serviceName, account: singleCredentialsKey)
        
        // 顺便清理旧版 Key（防止残留）
        KeychainHelper.shared.delete(service: serviceName, account: tokenKey)
        KeychainHelper.shared.delete(service: serviceName, account: refreshTokenKey)
        KeychainHelper.shared.delete(service: serviceName, account: uidKey)
        KeychainHelper.shared.delete(service: serviceName, account: guidKey)
        
        self.imaToken = ""
        self.imaRefreshToken = ""
        self.imaUid = ""
        self.imaGuid = ""
        self.avatarUrl = ""
        self.nickname = ""
        
        if clearWebView {
            DispatchQueue.main.async {
                let store = WKWebsiteDataStore.default()
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: Date.distantPast) {
                    print("[IMACredentialsManager] WebView session and cookies cleared successfully.")
                }
            }
        }
    }
    
    /// 动态装配 x-ima-cookie 请求头的值
    func getCookieString() -> String {
        return "PLATFORM=H5; CLIENT-TYPE=256020; WEB-VERSION=4.25.3; " +
               "IMA-GUID=\(imaGuid); " +
               "IMA-Q36=e749267b48b3622b592f9d2d200018c19311; " +
               "IMA-IUA=PR=IMA&PP=com.tencent.imamac&PPVN=2.5.1&PL=MAC&COVC=143.0.7499.4456&RL=3024*1964&MO=Mac OS X&OS=15.7.7&SYSARCH=Arm&DN=&BC=release&BN=4262&BT=1778318655445&CH=9caac41887&DC=10000074&EV=; " +
               "IMA-UID=\(imaUid); " +
               "IMA-TOKEN=\(imaToken); " +
               "IMA-REFRESH-TOKEN=\(imaRefreshToken); " +
               "UID-TYPE=2; TOKEN-TYPE=14"
    }
    
    /// 腾讯经典的 DJB2 哈希指纹算法，将 Token 转化为 32 位无符号防 CSRF 整数
    private func calculateBkn(token: String) -> UInt32 {
        var hash: UInt32 = 5381
        for char in token.utf8 {
            hash = hash &+ (hash &<< 5) &+ UInt32(char)
        }
        return hash & 0x7FFFFFFF
    }
}
