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
        guard let clientId = clientId, let apiKey = apiKey else {
            throw IMASyncError.missingCredentials
        }
        
        var request = URLRequest(url: baseURL.appendingPathComponent("get_knowledge_base"))
        request.addValue(clientId, forHTTPHeaderField: "ima-openapi-clientid")
        request.addValue(apiKey, forHTTPHeaderField: "ima-openapi-apikey")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(IMAResponse<[KnowledgeBase]>.self, from: data)
        
        if response.code != 0 {
            throw IMASyncError.apiError(response.message)
        }
        
        return response.data ?? []
    }
    
    /// 导入文档到 IMA
    func importDoc(fileURL: URL, knowledgeBaseId: String) async throws -> String {
        guard let clientId = clientId, let apiKey = apiKey else {
            throw IMASyncError.missingCredentials
        }
        
        let boundary = UUID().uuidString
        var request = URLRequest(url: baseURL.appendingPathComponent("import_doc"))
        request.httpMethod = "POST"
        request.addValue(clientId, forHTTPHeaderField: "ima-openapi-clientid")
        request.addValue(apiKey, forHTTPHeaderField: "ima-openapi-apikey")
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let data = try createMultipartBody(fileURL: fileURL, knowledgeBaseId: knowledgeBaseId, boundary: boundary)
        let (responseData, _) = try await URLSession.shared.upload(for: request, from: data)
        
        let response = try JSONDecoder().decode(IMAResponse<ImportResult>.self, from: responseData)
        if response.code != 0 {
            throw IMASyncError.apiError(response.message)
        }
        
        return response.data?.docId ?? ""
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

struct IMAResponse<T: Codable>: Codable {
    let code: Int
    let message: String
    let data: T?
}

struct KnowledgeBase: Codable, Identifiable {
    let id: String
    let name: String
}

struct ImportResult: Codable {
    let docId: String
}

enum IMASyncError: Error {
    case missingCredentials
    case apiError(String)
}
