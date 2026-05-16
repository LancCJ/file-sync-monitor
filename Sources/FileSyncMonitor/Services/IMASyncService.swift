import Foundation

/// 负责对接 IMA OpenAPI 的服务
final class IMASyncService {
    static let shared = IMASyncService()

    private let baseURL = URL(string: "https://ima.qq.com/openapi/wiki/v1")!

    // 从 Keychain 获取这些信息（实际实现中应调用 Keychain 工具类）
    var clientId: String?
    var apiKey: String?

    private init() {}

    /// 获取知识库列表
    func getKnowledgeBases() async throws -> [KnowledgeBase] {
        let credentials = try normalizedCredentials()

        var request = URLRequest(url: baseURL.appendingPathComponent("get_knowledge_base"))
        applyCredentials(credentials, to: &request)

        let response: IMAResponse<KnowledgeBaseListPayload> = try await send(request)
        try validate(response)

        return response.data?.items ?? []
    }

    /// 导入文档到 IMA
    func importDoc(fileURL: URL, knowledgeBaseId: String) async throws -> String {
        let credentials = try normalizedCredentials()

        let boundary = UUID().uuidString
        var request = URLRequest(url: baseURL.appendingPathComponent("import_doc"))
        request.httpMethod = "POST"
        applyCredentials(credentials, to: &request)
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try createMultipartBody(fileURL: fileURL, knowledgeBaseId: knowledgeBaseId, boundary: boundary)
        let response: IMAResponse<ImportResult> = try await upload(request, body: data)
        try validate(response)

        return response.data?.docId ?? ""
    }

    private func normalizedCredentials() throws -> (clientId: String, apiKey: String) {
        let trimmedClientId = clientId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedApiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !trimmedClientId.isEmpty, !trimmedApiKey.isEmpty else {
            throw IMASyncError.missingCredentials
        }

        return (trimmedClientId, trimmedApiKey)
    }

    private func applyCredentials(_ credentials: (clientId: String, apiKey: String), to request: inout URLRequest) {
        request.addValue(credentials.clientId, forHTTPHeaderField: "ima-openapi-clientid")
        request.addValue(credentials.apiKey, forHTTPHeaderField: "ima-openapi-apikey")
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> IMAResponse<T> {
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        return try decodeIMAResponse(data: data, urlResponse: urlResponse)
    }

    private func upload<T: Decodable>(_ request: URLRequest, body: Data) async throws -> IMAResponse<T> {
        let (data, urlResponse) = try await URLSession.shared.upload(for: request, from: body)
        return try decodeIMAResponse(data: data, urlResponse: urlResponse)
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

    private func createMultipartBody(fileURL: URL, knowledgeBaseId: String, boundary: String) throws -> Data {
        var body = Data()

        // 知识库 ID
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"knowledge_base_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(knowledgeBaseId)\r\n".data(using: .utf8)!)

        // 文件内容
        let filename = fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
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
        for key in ["list", "items", "knowledge_bases", "knowledgeBases"] {
            if let codingKey = DynamicCodingKey(stringValue: key),
               let nestedItems = try? container.decode([KnowledgeBase].self, forKey: codingKey) {
                items = nestedItems
                return
            }
        }

        items = []
    }
}

struct KnowledgeBase: Decodable, Identifiable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case knowledgeBaseId = "knowledge_base_id"
        case name
        case title
        case knowledgeBaseName = "knowledge_base_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id))
            ?? (try? container.decode(String.self, forKey: .knowledgeBaseId))
            ?? ""
        name = (try? container.decode(String.self, forKey: .name))
            ?? (try? container.decode(String.self, forKey: .title))
            ?? (try? container.decode(String.self, forKey: .knowledgeBaseName))
            ?? "未命名知识库"
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
