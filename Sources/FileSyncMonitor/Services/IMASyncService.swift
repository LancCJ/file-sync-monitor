import Foundation
import CommonCrypto

/// 负责对接 IMA OpenAPI 的服务
final class IMASyncService {
    static let shared = IMASyncService()

    private let baseURL = URL(string: "https://ima.qq.com")!

    private init() {}

    /// 同步文件到指定目标（知识库或笔记）
    func syncFile(fileURL: URL, knowledgeBaseId: String?) async throws {
        if let kbId = knowledgeBaseId, !kbId.isEmpty && kbId != "default" {
            // 如果指定了具体知识库 ID，走 Wiki 上传流
            try await uploadToWiki(fileURL: fileURL, knowledgeBaseId: kbId)
        } else {
            // 默认走笔记导入流 (注意：笔记导入暂时保留简单实现)
            _ = try await importDoc(fileURL: fileURL, knowledgeBaseId: "default")
        }
    }

    /// 获取知识库列表
    func getKnowledgeBases() async throws -> [KnowledgeBase] {
        let credentials = try normalizedCredentials()

        var request = URLRequest(url: baseURL.appendingPathComponent("openapi/wiki/v1/search_knowledge_base"))
        request.httpMethod = "POST"
        applyCredentials(credentials, to: &request)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // 根据文档，query 为空字符串时返回所有知识库
        let body: [String: Any] = ["query": "", "cursor": "", "limit": 20]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let response: IMAResponse<KnowledgeBaseListPayload> = try await send(request)
        try validate(response)

        return response.data?.items ?? []
    }

    /// 知识库模块：上传文件 (Wiki Flow)
    func uploadToWiki(fileURL: URL, knowledgeBaseId: String) async throws {
        let fileName = fileURL.lastPathComponent
        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let fileExt = fileURL.pathExtension.lowercased()
        
        // 1. Preflight Check (获取 media_type 和 content_type)
        guard let (mediaType, contentType) = IMAMediaType.resolve(extension: fileExt) else {
            let errorMsg = "不支持的文件类型 (.\(fileExt))。IMA 知识库目前不支持以文件形式同步 HTML 或视频。"
            let logId = IMALogService.shared.logRequest(method: "PREFLIGHT", url: "wiki/v1/upload", headers: nil, body: "File: \(fileName)")
            IMALogService.shared.logError(id: logId, code: nil, error: errorMsg, requestId: nil)
            throw IMASyncError.apiError(errorMsg)
        }
        
        // 2. Create Media (获取 COS 凭据)
        let step1LogId = IMALogService.shared.logRequest(method: "STEP 1", url: "create_media", headers: nil, body: "开始请求 COS 凭据...")
        let createResp: IMAResponse<CreateMediaPayload> = try await postJson(
            path: "openapi/wiki/v1/create_media",
            body: [
                "file_name": fileName,
                "file_size": fileSize,
                "content_type": contentType,
                "media_type": mediaType,
                "knowledge_base_id": knowledgeBaseId,
                "file_ext": fileExt
            ]
        )
        try validate(createResp)
        guard let payload = createResp.data else { throw IMASyncError.apiError("未获取到 COS 凭据") }
        IMALogService.shared.logResponse(id: step1LogId, code: 200, body: "凭据获取成功", requestId: createResp.requestId)
        
        // 3. Upload to COS
        let step2LogId = IMALogService.shared.logRequest(method: "STEP 2", url: "cos_upload", headers: nil, body: "开始上传文件流到腾讯云 COS...")
        try await uploadToCOS(fileURL: fileURL, payload: payload, contentType: contentType, fileSize: fileSize)
        IMALogService.shared.logResponse(id: step2LogId, code: 200, body: "文件流上传完成", requestId: nil)
        
        // 4. Add Knowledge (正式关联)
        let step3LogId = IMALogService.shared.logRequest(method: "STEP 3", url: "add_knowledge", headers: nil, body: "开始将媒体关联到知识库...")
        let addResp: IMAResponse<EmptyPayload> = try await postJson(
            path: "openapi/wiki/v1/add_knowledge",
            body: [
                "media_type": mediaType,
                "media_id": payload.mediaId,
                "title": fileName,
                "knowledge_base_id": knowledgeBaseId,
                "file_info": [
                    "cos_key": payload.cosCredential.cosKey,
                    "file_size": fileSize,
                    "file_name": fileName
                ]
            ]
        )
        try validate(addResp)
        IMALogService.shared.logResponse(id: step3LogId, code: 200, body: "关联成功！同步完成。", requestId: addResp.requestId)
    }

    private func uploadToCOS(fileURL: URL, payload: CreateMediaPayload, contentType: String, fileSize: Int) async throws {
        let cos = payload.cosCredential
        let hostname = "\(cos.bucketName).cos.\(cos.region).myqcloud.com"
        let urlString = "https://\(hostname)/\(cos.cosKey)"
        
        guard let url = URL(string: urlString) else {
            throw IMASyncError.apiError("无效的 COS URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.addValue(contentType, forHTTPHeaderField: "Content-Type")
        request.addValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        request.addValue(cos.token, forHTTPHeaderField: "x-cos-security-token")
        request.addValue(hostname, forHTTPHeaderField: "Host")
        
        // 生成 COS 签名
        let signature = COSSigner.sign(
            method: "PUT",
            pathname: "/\(cos.cosKey)",
            secretId: cos.secretId,
            secretKey: cos.secretKey,
            startTime: Int(cos.startTime) ?? Int(Date().timeIntervalSince1970),
            expiredTime: Int(cos.expiredTime) ?? (Int(Date().timeIntervalSince1970) + 3600),
            headers: [
                "host": hostname,
                "content-length": "\(fileSize)"
            ]
        )
        request.setValue(signature, forHTTPHeaderField: "Authorization")
        
        let logId = IMALogService.shared.logRequest(method: "PUT (COS)", url: urlString, headers: request.allHTTPHeaderFields, body: "[Binary Data: \(fileURL.lastPathComponent)]")
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        
        if let httpResponse = response as? HTTPURLResponse {
            IMALogService.shared.logResponse(id: logId, code: httpResponse.statusCode, body: "COS Upload Finished", requestId: nil)
            if !(200...299).contains(httpResponse.statusCode) {
                throw IMASyncError.apiError("COS 上传失败: HTTP \(httpResponse.statusCode)")
            }
        }
    }

    private func postJson<T: Decodable>(path: String, body: [String: Any]) async throws -> IMAResponse<T> {
        let credentials = try normalizedCredentials()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        applyCredentials(credentials, to: &request)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        return try await send(request)
    }

    /// 导入文档到 IMA (笔记流)
    func importDoc(fileURL: URL, knowledgeBaseId: String) async throws -> String {
        let credentials = try normalizedCredentials()
        let boundary = UUID().uuidString
        var request = URLRequest(url: baseURL.appendingPathComponent("openapi/note/v1/import_doc"))
        request.httpMethod = "POST"
        applyCredentials(credentials, to: &request)
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let tempFileURL = try createMultipartFile(fileURL: fileURL, knowledgeBaseId: knowledgeBaseId, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: tempFileURL) }

        let response: IMAResponse<ImportResult> = try await upload(request, fromFile: tempFileURL)
        try validate(response)
        return response.data?.docId ?? ""
    }

    private func normalizedCredentials() throws -> (clientId: String, apiKey: String) {
        let clientId = UserDefaults.standard.string(forKey: "imaClientId")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let apiKey = UserDefaults.standard.string(forKey: "imaApiKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !clientId.isEmpty, !apiKey.isEmpty else {
            throw IMASyncError.missingCredentials
        }

        return (clientId, apiKey)
    }

    private func applyCredentials(_ credentials: (clientId: String, apiKey: String), to request: inout URLRequest) {
        request.addValue(credentials.clientId, forHTTPHeaderField: "ima-openapi-clientid")
        request.addValue(credentials.apiKey, forHTTPHeaderField: "ima-openapi-apikey")
        request.addValue("skill_version=1.1.7", forHTTPHeaderField: "ima-openapi-ctx")
        request.addValue("FileSyncMonitor/1.0", forHTTPHeaderField: "User-Agent")
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> IMAResponse<T> {
        let bodyString = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        let logId = IMALogService.shared.logRequest(method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "", headers: request.allHTTPHeaderFields, body: bodyString)
        
        do {
            let (data, urlResponse) = try await URLSession.shared.data(for: request)
            let decoded: IMAResponse<T> = try decodeIMAResponse(data: data, urlResponse: urlResponse)
            IMALogService.shared.logResponse(id: logId, code: (urlResponse as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8), requestId: decoded.requestId)
            return decoded
        } catch {
            IMALogService.shared.logError(id: logId, code: nil, error: error.localizedDescription, requestId: nil)
            throw error
        }
    }

    private func upload<T: Decodable>(_ request: URLRequest, fromFile fileURL: URL) async throws -> IMAResponse<T> {
        let logId = IMALogService.shared.logRequest(method: "UPLOAD", url: request.url?.absoluteString ?? "", headers: request.allHTTPHeaderFields, body: "[Multipart Data: \(fileURL.lastPathComponent)]")
        
        do {
            let (data, urlResponse) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
            let decoded: IMAResponse<T> = try decodeIMAResponse(data: data, urlResponse: urlResponse)
            IMALogService.shared.logResponse(id: logId, code: (urlResponse as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8), requestId: decoded.requestId)
            return decoded
        } catch {
            IMALogService.shared.logError(id: logId, code: nil, error: error.localizedDescription, requestId: nil)
            throw error
        }
    }

    private func decodeIMAResponse<T: Decodable>(data: Data, urlResponse: URLResponse) throws -> IMAResponse<T> {
        let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode

        do {
            let response = try JSONDecoder().decode(IMAResponse<T>.self, from: data)
            if let statusCode, !(200..<300).contains(statusCode) {
                throw IMASyncError.apiError(response.displayMessage(httpStatus: statusCode))
            }
            return response
        } catch let error as IMASyncError {
            throw error
        } catch {
            let preview = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(180) ?? ""
            if let statusCode, !(200..<300).contains(statusCode) {
                throw IMASyncError.apiError("HTTP \(statusCode)：\(preview)")
            }
            throw IMASyncError.invalidResponse(preview.isEmpty ? error.localizedDescription : String(preview))
        }
    }

    private func validate<T>(_ response: IMAResponse<T>) throws {
        if response.code != 0 {
            throw IMASyncError.apiError(response.displayMessage())
        }
    }

    private func createMultipartFile(fileURL: URL, knowledgeBaseId: String, boundary: String) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        // 知识库 ID
        handle.write("--\(boundary)\r\n".data(using: .utf8)!)
        handle.write("Content-Disposition: form-data; name=\"kbId\"\r\n\r\n".data(using: .utf8)!)
        handle.write("\(knowledgeBaseId)\r\n".data(using: .utf8)!)

        // 文件名
        let filename = fileURL.lastPathComponent
        handle.write("--\(boundary)\r\n".data(using: .utf8)!)
        handle.write("Content-Disposition: form-data; name=\"fileName\"\r\n\r\n".data(using: .utf8)!)
        handle.write("\(filename)\r\n".data(using: .utf8)!)
        handle.write("--\(boundary)\r\n".data(using: .utf8)!)
        handle.write("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        handle.write("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        
        // 分块读取原文件并写入临时文件，避免一次性读入大文件内存
        let sourceHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? sourceHandle.close() }
        
        while let chunk = try sourceHandle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            handle.write(chunk)
        }
        
        handle.write("\r\n".data(using: .utf8)!)
        handle.write("--\(boundary)--\r\n".data(using: .utf8)!)
        
        return tempURL
    }
}

// MARK: - Models & Errors

struct IMAResponse<T: Decodable>: Decodable {
    let code: Int
    let message: String
    let requestId: String?
    let data: T?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case msg
        case requestId = "request_id"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = (try? container.decode(String.self, forKey: .message))
            ?? (try? container.decode(String.self, forKey: .msg))
            ?? "IMA 接口未返回错误说明"
        requestId = try? container.decode(String.self, forKey: .requestId)
        data = try? container.decodeIfPresent(T.self, forKey: .data)
    }

    func displayMessage(httpStatus: Int? = nil) -> String {
        var parts: [String] = []
        if let httpStatus {
            parts.append("HTTP \(httpStatus)")
        }
        parts.append("code \(code)")
        parts.append(message)
        if let requestId, !requestId.isEmpty {
            parts.append("request_id \(requestId)")
        }
        return parts.joined(separator: " / ")
    }
}

struct KnowledgeBaseListPayload: Decodable {
    let items: [KnowledgeBase]

    init(from decoder: Decoder) throws {
        if let directItems = try? [KnowledgeBase](from: decoder) {
            items = directItems
            return
        }

        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        for key in ["list", "items", "knowledge_bases", "knowledgeBases", "kb_list", "info_list"] {
            if let codingKey = DynamicCodingKey(stringValue: key),
               let nestedItems = try? container.decode([KnowledgeBase].self, forKey: codingKey) {
                items = nestedItems
                return
            }
        }

        items = []
    }
}

struct KnowledgeBase: Codable, Identifiable, Hashable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case knowledgeBaseId = "knowledge_base_id"
        case kbId = "kb_id"
        case name
        case title
        case knowledgeBaseName = "knowledge_base_name"
        case kbName = "kb_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // 优先尝试官方最新字段
        let rawId = (try? container.decode(String.self, forKey: .kbId))
            ?? (try? container.decode(String.self, forKey: .id))
            ?? (try? container.decode(String.self, forKey: .knowledgeBaseId))
        self.id = rawId ?? ""
        
        // 优先尝试官方名称字段
        let rawName = (try? container.decode(String.self, forKey: .kbName))
            ?? (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .title))
            ?? (try? container.decode(String.self, forKey: .knowledgeBaseName))
        self.name = rawName ?? "未命名知识库"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
    }
}

struct ImportResult: Decodable {
    let docId: String

    enum CodingKeys: String, CodingKey {
        case docId
        case docID = "doc_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        docId = (try? container.decode(String.self, forKey: .docId))
            ?? (try? container.decode(String.self, forKey: .docID))
            ?? ""
    }
}

struct CreateMediaPayload: Decodable {
    let mediaId: String
    let cosCredential: COSCredential
    
    enum CodingKeys: String, CodingKey {
        case mediaId = "media_id"
        case cosCredential = "cos_credential"
    }
}

struct COSCredential: Decodable {
    let bucketName: String
    let region: String
    let cosKey: String
    let secretId: String
    let secretKey: String
    let token: String
    let startTime: String
    let expiredTime: String
    
    enum CodingKeys: String, CodingKey {
        case bucketName = "bucket_name"
        case region
        case cosKey = "cos_key"
        case secretId = "secret_id"
        case secretKey = "secret_key"
        case token
        case startTime = "start_time"
        case expiredTime = "expired_time"
    }
}

struct EmptyPayload: Decodable {}

struct IMAMediaType {
    static func resolve(extension ext: String) -> (Int, String)? {
        let map: [String: (Int, String)] = [
            "pdf": (1, "application/pdf"),
            "doc": (3, "application/msword"),
            "docx": (3, "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
            "ppt": (4, "application/vnd.ms-powerpoint"),
            "pptx": (4, "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
            "xls": (5, "application/vnd.ms-excel"),
            "xlsx": (5, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
            "csv": (5, "text/csv"),
            "md": (7, "text/markdown"),
            "markdown": (7, "text/markdown"),
            "png": (9, "image/png"),
            "jpg": (9, "image/jpeg"),
            "jpeg": (9, "image/jpeg"),
            "webp": (9, "image/webp"),
            "txt": (13, "text/plain"),
            "xmind": (14, "application/x-xmind"),
            "mp3": (15, "audio/mpeg"),
            "m4a": (15, "audio/x-m4a"),
            "wav": (15, "audio/wav"),
            "aac": (15, "audio/aac")
        ]
        return map[ext.lowercased()]
    }
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

enum IMASyncError: LocalizedError {
    case missingCredentials
    case apiError(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "请先填写 IMA Client ID 和 API Key"
        case .apiError(let message):
            return message
        case .invalidResponse(let message):
            return "IMA 响应无法解析：\(message)"
        }
    }
}

// MARK: - COS Signature Helper
struct COSSigner {
    static func sign(
        method: String,
        pathname: String,
        secretId: String,
        secretKey: String,
        startTime: Int,
        expiredTime: Int,
        headers: [String: String]
    ) -> String {
        let keyTime = "\(startTime);\(expiredTime)"
        
        // 1. SignKey = HMAC-SHA1(SecretKey, KeyTime)
        let signKey = hmacSha1(key: secretKey, data: keyTime)
        
        // 2. HttpString = method\npathname\nparams\nheaders\n
        let sortedHeaders = headers.keys.sorted()
        let httpHeaders = sortedHeaders.map { "\($0.lowercased())=\(headers[$0]!.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")
        let httpString = "\(method.lowercased())\n\(pathname)\n\n\(httpHeaders)\n"
        
        // 3. StringToSign = sha1\nKeyTime\nSHA1(HttpString)\n
        let stringToSign = "sha1\n\(keyTime)\n\(sha1(httpString))\n"
        
        // 4. Signature = HMAC-SHA1(SignKey, StringToSign)
        let signature = hmacSha1(key: signKey, data: stringToSign)
        
        // 5. Build Authorization
        let headerList = sortedHeaders.map { $0.lowercased() }.joined(separator: ";")
        return [
            "q-sign-algorithm=sha1",
            "q-ak=\(secretId)",
            "q-sign-time=\(keyTime)",
            "q-key-time=\(keyTime)",
            "q-header-list=\(headerList)",
            "q-url-param-list=",
            "q-signature=\(signature)"
        ].joined(separator: "&")
    }
    
    private static func hmacSha1(key: String, data: String) -> String {
        let keyData = key.data(using: .utf8)!
        let dataToSign = data.data(using: .utf8)!
        var result = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        
        keyData.withUnsafeBytes { keyBytes in
            dataToSign.withUnsafeBytes { dataBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), keyBytes.baseAddress, keyData.count, dataBytes.baseAddress, dataToSign.count, &result)
            }
        }
        return result.map { String(format: "%02x", $0) }.joined()
    }
    
    private static func sha1(_ data: String) -> String {
        let data = data.data(using: .utf8)!
        var result = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { dataBytes in
            CC_SHA1(dataBytes.baseAddress, CC_LONG(data.count), &result)
        }
        return result.map { String(format: "%02x", $0) }.joined()
    }
}
