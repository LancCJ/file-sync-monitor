import Foundation
import CommonCrypto
import WebKit

/// 负责对接 Tencent IMA H5 Web 私有接口的同步服务
final class IMASyncService {
    static let shared = IMASyncService()

    private let baseURL = URL(string: "https://ima.qq.com")!

    #if DEBUG
    var session: URLSession = URLSession.shared
    #else
    private let session = URLSession.shared
    #endif

    private init() {}

    /// 同步文件到指定目标（知识库或笔记）
    @discardableResult
    func syncFile(
        fileURL: URL,
        knowledgeBaseId: String?,
        relativeFolderPath: String? = nil,
        existingRemoteId: String? = nil,
        duplicateStrategy: IMADuplicateFileStrategy = .renameWithTimestamp
    ) async throws -> String {
        await MainActor.run {
            FileMonitorService.shared.updateSyncProgress(status: String(format: "正在上传: %@".appLocalized, fileURL.lastPathComponent))
        }
        if let kbId = knowledgeBaseId, !kbId.isEmpty && kbId != "default" {
            // 如果指定了具体知识库 ID，走 Wiki 上传流
            let folderId = try await resolveFolderIdIfNeeded(knowledgeBaseId: kbId, relativeFolderPath: relativeFolderPath)
            let mediaId = try await uploadToWiki(
                fileURL: fileURL,
                knowledgeBaseId: kbId,
                folderId: folderId,
                existingRemoteId: existingRemoteId,
                duplicateStrategy: duplicateStrategy
            )
            
            // 异步启动流式 SSE 解析进度监听，非阻塞
            Task {
                try? await trackParseProgress(mediaId: mediaId)
            }
            
            return mediaId
        } else {
            throw IMASyncError.apiError("同步目标错误：新版 IMA 不再支持直接导入个人笔记，请选择具体的知识库作为同步目标。")
        }
    }

    /// 获取知识库列表 (私有 H5 接口)
    func getKnowledgeBases() async throws -> [KnowledgeBase] {
        let body: [String: Any] = [
            "params": [
                ["type": 1001, "cursor": "", "limit": 20],
                ["type": 1002, "cursor": "", "limit": 20],
                ["type": 1004, "cursor": "", "limit": 20],
                ["type": 1005, "cursor": "", "limit": 50]
            ]
        ]
        
        let response: IMAResponse<H5KnowledgeBaseListResponse> = try await postJson(
            path: "cgi-bin/knowledge_tab_reader/get_knowledge_base_list",
            body: body
        )
        try validate(response)

        return response.data?.results.flatMap { $0.knowledgeBaseList } ?? []
    }

    /// 获取绑定设备列表 (私有 H5 接口)
    func getTabDevices() async throws -> [H5Device] {
        let response: IMAResponse<H5DeviceListResponse> = try await postJson(
            path: "cgi-bin/user_info/get_device_list",
            body: [:]
        )
        try validate(response)
        return response.data?.devices ?? []
    }

    /// 获取用户微信昵称与头像个人信息 (私有 H5 接口)
    func getUserProfile() async throws -> (avatarUrl: String, nickname: String) {
        let response: IMAResponse<H5UserInfoDetail> = try await postJson(
            path: "cgi-bin/user_info/get_user_info",
            body: [:]
        )
        try validate(response)
        
        guard let openInfo = response.data?.openInfo else {
            throw IMASyncError.apiError("未获取到有效的微信用户信息")
        }
        
        return (openInfo.avatarUrl, openInfo.nickname)
    }

    /// 获取空间配额信息 (私有 H5 接口)
    func getSpaceQuota() async throws -> H5SpaceQuota {
        let response: IMAResponse<H5SpaceQuotaResponse> = try await postJson(
            path: "cgi-bin/space/get_user_space",
            body: [
                "condition": [
                    "need_knowledge": true,
                    "need_note": true,
                    "need_total": true,
                    "need_share": true
                ]
            ]
        )
        try validate(response)
        
        guard let space = response.data?.totalUserSpace else {
            return H5SpaceQuota(totalQuota: 0, usedQuota: 0)
        }
        
        let total = Int64(space.totalSpace) ?? 0
        let used = Int64(space.usedSpace) ?? 0
        return H5SpaceQuota(totalQuota: total, usedQuota: used)
    }

    /// 获取知识库内容列表 (私有 H5 接口)
    func getKnowledgeList(knowledgeBaseId: String, folderId: String? = nil, cursor: String = "") async throws -> (items: [KnowledgeInfo], isEnd: Bool, nextCursor: String) {
        var body: [String: Any] = [
            "sort_type": 9,
            "need_default_cover": true,
            "knowledge_base_id": knowledgeBaseId,
            "cursor": cursor,
            "limit": 50,
            "ext_info": [:]
        ]
        if let folderId, !folderId.isEmpty {
            body["folder_id"] = folderId
        }
        
        let response: IMAResponse<KnowledgeListPayload> = try await postJson(
            path: "cgi-bin/knowledge_tab_reader/get_knowledge_list",
            body: body
        )
        try validate(response)
        
        return (
            items: response.data?.knowledgeList ?? [],
            isEnd: response.data?.isEnd ?? true,
            nextCursor: response.data?.nextCursor ?? ""
        )
    }

    /// 获取媒体信息与下载链接 (私有 H5 /get_knowledge 接口适配)
    func getMediaInfo(mediaId: String, knowledgeBaseId: String) async throws -> MediaInfoPayload {
        let response: IMAResponse<H5GetKnowledgeResponse> = try await postJson(
            path: "cgi-bin/knowledge_tab_reader/get_knowledge",
            body: [
                "media_id": mediaId,
                "knowledge_base_id": knowledgeBaseId,
                "need_default_cover": true
            ]
        )
        try validate(response)
        guard let data = response.data else { throw IMASyncError.apiError("未获取到媒体详情") }
        
        let urlInfo = URLInfo(url: data.knowledge.jumpUrl, headers: nil)
        return MediaInfoPayload(mediaType: data.knowledge.mediaType, urlInfo: urlInfo)
    }

    func downloadFile(mediaId: String, knowledgeBaseId: String, to destinationURL: URL) async throws {
        await MainActor.run {
            FileMonitorService.shared.updateSyncProgress(status: String(format: "正在拉取: %@".appLocalized, destinationURL.lastPathComponent))
        }
        let info = try await getMediaInfo(mediaId: mediaId, knowledgeBaseId: knowledgeBaseId)
        guard let urlInfo = info.urlInfo, let downloadURL = URL(string: urlInfo.url) else {
            throw IMASyncError.apiError("该媒体类型暂不支持导出或无法获取下载链接")
        }
        
        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        
        let logId = IMALogService.shared.logRequest(method: "DOWNLOAD", url: downloadURL.absoluteString, headers: request.allHTTPHeaderFields, body: "Downloading file...")
        let (tempURL, response) = try await self.session.download(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            IMALogService.shared.logResponse(id: logId, code: httpResponse.statusCode, body: "Download Finished", requestId: nil)
            if !(200...299).contains(httpResponse.statusCode) {
                throw IMASyncError.apiError("文件下载失败: HTTP \(httpResponse.statusCode)")
            }
        }
        
        // 移动到目标位置
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }

    /// 知识库模块：上传文件 (私有 H5 接口上传链路)
    @discardableResult
    func uploadToWiki(
        fileURL: URL,
        knowledgeBaseId: String,
        folderId: String? = nil,
        existingRemoteId: String? = nil,
        duplicateStrategy: IMADuplicateFileStrategy = .renameWithTimestamp
    ) async throws -> String {
        let originalFileName = fileURL.lastPathComponent
        
        // 1. 直接将文件数据读入内存，锁定字节流。这既消除了在上传期间被编辑/写入导致的 race condition（Content-Length 与数据不一致），
        //    同时也彻底绕过了 macOS 沙盒环境下，对临时文件夹进行 copyItem 文件系统操作可能遭遇的权限受限风险。
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            let errorMsg = "读取本地文件内容失败（可能尚未写入完成或沙盒受限），已拦截本次同步：\(error.localizedDescription)"
            let logId = IMALogService.shared.logRequest(method: "PREFLIGHT", url: "wiki/v1/upload", headers: nil, body: "File: \(originalFileName)")
            IMALogService.shared.logError(id: logId, code: nil, error: errorMsg, requestId: nil)
            throw IMASyncError.apiError(errorMsg)
        }

        let fileSize = fileData.count
        
        if fileSize == 0 {
            let errorMsg = "检测到文件大小为 0（可能尚未写入完成或沙盒受限），已拦截本次无效同步，防止触发腾讯云端 code 51 参数错误。"
            let logId = IMALogService.shared.logRequest(method: "PREFLIGHT", url: "wiki/v1/upload", headers: nil, body: "File: \(originalFileName)")
            IMALogService.shared.logError(id: logId, code: nil, error: errorMsg, requestId: nil)
            throw IMASyncError.apiError(errorMsg)
        }
        
        let fileExt = fileURL.pathExtension.lowercased()
        
        // 1. Preflight Check (获取 media_type 和 content_type)
        guard let (mediaType, contentType) = IMAMediaType.resolve(extension: fileExt) else {
            let errorMsg = "不支持的文件类型 (.\(fileExt))。IMA 知识库目前不支持以文件形式同步 HTML 或视频。"
            let logId = IMALogService.shared.logRequest(method: "PREFLIGHT", url: "wiki/v1/upload", headers: nil, body: "File: \(originalFileName)")
            IMALogService.shared.logError(id: logId, code: nil, error: errorMsg, requestId: nil)
            throw IMASyncError.apiError(errorMsg)
        }

        let uploadFileName = try await resolvedUploadFileName(
            originalFileName: originalFileName,
            mediaType: mediaType,
            knowledgeBaseId: knowledgeBaseId,
            folderId: folderId,
            existingRemoteId: existingRemoteId,
            duplicateStrategy: duplicateStrategy
        )
        
        // 2. Create Media (私有 H5 /create_media 接口获取 COS 凭据)
        // 严格契合抓包规范，不能携带未定义参数如 "file_ext"，否则服务器会报 code 51 / 参数错误
        let step1LogId = IMALogService.shared.logRequest(method: "STEP 1", url: "create_media", headers: nil, body: "开始请求 COS 凭据...")
        let createResp: IMAResponse<CreateMediaPayload> = try await postJson(
            path: "cgi-bin/file_manager/create_media",
            body: [
                "file_name": uploadFileName,
                "file_size": fileSize,
                "content_type": contentType,
                "media_type": mediaType,
                "knowledge_base_id": knowledgeBaseId
            ]
        )
        try validate(createResp)
        guard let payload = createResp.data else { throw IMASyncError.apiError("未获取到 COS 凭据") }
        IMALogService.shared.logResponse(id: step1LogId, code: 200, body: "凭据获取成功", requestId: createResp.requestId)
        
        // 3. Upload to COS
        let step2LogId = IMALogService.shared.logRequest(method: "STEP 2", url: "cos_upload", headers: nil, body: "开始上传文件流到腾讯云 COS...")
        try await uploadToCOS(fileData: fileData, fileName: originalFileName, payload: payload, contentType: contentType, fileSize: fileSize)
        IMALogService.shared.logResponse(id: step2LogId, code: 200, body: "文件流上传完成", requestId: nil)
        
        // 增加 1.0 秒的短暂冷却等待，让云端有足够的时间对刚写入 COS 的文件流进行持久化和元数据就绪
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        // 4. Add Knowledge (私有 H5 /add_knowledge 接口关联知识库)
        // file_info 必须携带 "content_type": "" (空字符串) 以完全符合 H5 私有 API 校验
        let step3LogId = IMALogService.shared.logRequest(method: "STEP 3", url: "add_knowledge", headers: nil, body: "开始将媒体关联 to 知识库...")
        var addKnowledgeBody: [String: Any] = [
            "media_type": mediaType,
            "media_id": payload.mediaId,
            "title": uploadFileName,
            "knowledge_base_id": knowledgeBaseId,
            "need_parse": true,
            "file_info": [
                "cos_key": payload.cosCredential.cosKey,
                "file_size": fileSize,
                "file_name": uploadFileName,
                "content_type": ""
            ]
        ]
        if let folderId, !folderId.isEmpty {
            addKnowledgeBody["folder_id"] = folderId
        }

        let addResp: IMAResponse<EmptyPayload> = try await postJson(
            path: "cgi-bin/knowledge_tab_writer/add_knowledge",
            body: addKnowledgeBody
        )
        try validate(addResp)
        IMALogService.shared.logResponse(id: step3LogId, code: 200, body: "关联成功！同步完成。", requestId: addResp.requestId)
        
        return payload.mediaId
    }

    /// 监听流式 SSE 解析进度
    private func trackParseProgress(mediaId: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("cgi-bin/media_center/get_parse_progress"))
        request.httpMethod = "POST"
        try applyPrivateWebHeaders(to: &request)
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["media_ids": [mediaId]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        let logId = IMALogService.shared.logRequest(
            method: "SSE (Progress)",
            url: "cgi-bin/media_center/get_parse_progress",
            headers: nil,
            body: "开始监听解析进度..."
        )
        
        do {
            let (bytes, _) = try await self.session.bytes(for: request)
            for try await line in bytes.lines {
                if line.hasPrefix("data:") {
                    let dataContent = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !dataContent.isEmpty {
                        IMALogService.shared.logResponse(id: logId, code: 200, body: dataContent, requestId: nil)
                    }
                }
            }
        } catch {
            IMALogService.shared.logError(id: logId, code: nil, error: "SSE 进度监听异常中断: \(error.localizedDescription)", requestId: nil)
        }
    }

    private func resolvedUploadFileName(
        originalFileName: String,
        mediaType: Int,
        knowledgeBaseId: String,
        folderId: String?,
        existingRemoteId: String?,
        duplicateStrategy: IMADuplicateFileStrategy
    ) async throws -> String {
        let logId = IMALogService.shared.logRequest(method: "PRECHECK", url: "check_repeated_names", headers: nil, body: "检查同目录同名文件：\(originalFileName)")
        var body: [String: Any] = [
            "params": [
                [
                    "name": originalFileName,
                    "media_type": mediaType
                ]
            ],
            "knowledge_base_id": knowledgeBaseId
        ]

        if let folderId, !folderId.isEmpty {
            body["folder_id"] = folderId
        }

        let response: IMAResponse<CheckRepeatedNamesPayload> = try await postJson(
            path: "cgi-bin/knowledge_tab_reader/check_repeated_names",
            body: body
        )
        try validate(response)

        let isRepeated = response.data?.results.contains { result in
            result.name == originalFileName && result.isRepeated
        } ?? false

        if isRepeated {
            if duplicateStrategy == .experimentalOverwrite {
                let mediaId = existingRemoteId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? existingRemoteId
                    : try await findExistingKnowledgeMediaId(fileName: originalFileName, knowledgeBaseId: knowledgeBaseId, folderId: folderId)

                guard let mediaId, !mediaId.isEmpty else {
                    throw IMASyncError.apiError("IMA 目标目录中已存在同名文件：\(originalFileName)，但未能定位旧文件 media_id，无法执行覆盖上传。")
                }

                try await deleteKnowledgeByWebAPI(mediaIds: [mediaId], knowledgeBaseId: knowledgeBaseId)
                IMALogService.shared.logResponse(
                    id: logId,
                    code: 200,
                    body: "发现同名文件并已删除旧文件，继续使用原文件名上传：\(originalFileName)",
                    requestId: response.requestId
                )
                return originalFileName
            }

            let timestampedName = timestampedFileName(originalFileName)
            IMALogService.shared.logResponse(
                id: logId,
                code: 200,
                body: "发现同名文件，自动改名上传：\(timestampedName)",
                requestId: response.requestId
            )
            return timestampedName
        }

        IMALogService.shared.logResponse(id: logId, code: 200, body: "未发现同名文件，可以继续上传。", requestId: response.requestId)
        return originalFileName
    }

    private func findExistingKnowledgeMediaId(fileName: String, knowledgeBaseId: String, folderId: String?) async throws -> String? {
        let items = try await fetchAllKnowledgeItems(knowledgeBaseId: knowledgeBaseId, folderId: folderId)
        return items.first { !$0.isFolder && $0.displayName == fileName }?.mediaId
    }

    func deleteKnowledgeByWebAPI(mediaIds: [String], knowledgeBaseId: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("cgi-bin/knowledge_tab_writer/del_knowledge"))
        request.httpMethod = "POST"
        try applyPrivateWebHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "knowledge_base_id": knowledgeBaseId,
            "media_ids": mediaIds
        ])

        let mediaIdList = mediaIds.joined(separator: ", ")
        let safeHeaders = request.allHTTPHeaderFields?.filter { header in
            let key = header.key.lowercased()
            return key != "x-ima-cookie" && key != "x-ima-bkn"
        }

        let logId = IMALogService.shared.logRequest(
            method: "DELETE (WEB)",
            url: request.url?.absoluteString ?? "",
            headers: safeHeaders,
            body: "删除旧知识条目：\(mediaIdList)"
        )

        do {
            let (data, urlResponse) = try await self.session.data(for: request)
            let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode
            if let statusCode, !(200..<300).contains(statusCode) {
                let preview = String(data: data, encoding: .utf8)?.prefix(180) ?? ""
                throw IMASyncError.apiError("IMA Web 删除接口 HTTP \(statusCode)：\(preview)")
            }

            let decoded = try JSONDecoder().decode(DeleteKnowledgeWebResponse.self, from: data)
            if decoded.code != 0 {
                throw IMASyncError.apiError("IMA Web 删除接口失败：code \(decoded.code) / \(decoded.msg)")
            }

            let failed = mediaIds.filter { mediaId in
                decoded.results[mediaId]?.retCode != 0
            }
            if !failed.isEmpty {
                let failedList = failed.joined(separator: ", ")
                throw IMASyncError.apiError("IMA Web 删除接口未成功删除旧文件：\(failedList)")
            }

            IMALogService.shared.logResponse(
                id: logId,
                code: (urlResponse as? HTTPURLResponse)?.statusCode ?? 0,
                body: String(data: data, encoding: .utf8),
                requestId: nil
            )
        } catch {
            IMALogService.shared.logError(id: logId, code: nil, error: error.localizedDescription, requestId: nil)
            throw error
        }
    }

    func createFolder(title: String, knowledgeBaseId: String, parentFolderId: String?) async throws -> String {
        let actualFolderId = parentFolderId ?? knowledgeBaseId
        
        let response: IMAResponse<IMACreateFolderResponse> = try await postJson(
            path: "cgi-bin/knowledge_tab_writer/create_folder",
            body: [
                "knowledge_base_id": knowledgeBaseId,
                "folder_id": actualFolderId,
                "title": title
            ]
        )
        
        guard response.code == 0, let data = response.data else {
            throw IMASyncError.apiError(response.displayMessage())
        }
        
        return data.knowledge.mediaId
    }

    /// 重命名知识库中的文档或文件夹
    func renameKnowledge(
        mediaId: String,
        title: String,
        knowledgeBaseId: String,
        folderId: String?
    ) async throws {
        let actualFolderId = folderId ?? knowledgeBaseId
        
        let response: IMAResponse<EmptyPayload> = try await postJson(
            path: "cgi-bin/knowledge_tab_writer/rename_knowledge",
            body: [
                "media_id": mediaId,
                "knowledge_base_id": knowledgeBaseId,
                "folder_id": actualFolderId,
                "title": title
            ]
        )
        
        guard response.code == 0 else {
            throw IMASyncError.apiError(response.displayMessage())
        }
    }

    private func timestampedFileName(_ fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension
        let baseName = ext.isEmpty ? fileName : url.deletingPathExtension().lastPathComponent

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMddHHmmss"

        let timestamp = formatter.string(from: Date())
        if ext.isEmpty {
            return "\(baseName)_\(timestamp)"
        }
        return "\(baseName)_\(timestamp).\(ext)"
    }

    func resolveFolderIdIfNeeded(knowledgeBaseId: String, relativeFolderPath: String?) async throws -> String? {
        guard let relativeFolderPath,
              !relativeFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let segments = relativeFolderPath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !segments.isEmpty else { return nil }

        var parentFolderId: String?
        var traversed: [String] = []

        for segment in segments {
            let children = try await fetchAllKnowledgeItems(knowledgeBaseId: knowledgeBaseId, folderId: parentFolderId)
            if let folder = children.first(where: { $0.isFolder && $0.displayName == segment }) {
                parentFolderId = folder.folderIdentifier
                traversed.append(segment)
                continue
            }

            // Automatically create folder instead of throwing
            do {
                let newFolderId = try await createFolder(
                    title: segment,
                    knowledgeBaseId: knowledgeBaseId,
                    parentFolderId: parentFolderId
                )
                parentFolderId = newFolderId
                traversed.append(segment)
            } catch {
                let currentPath = traversed.isEmpty ? "/" : traversed.joined(separator: "/")
                throw IMASyncError.apiError("自动创建云端文件夹 '\(segment)' 失败（当前位置：\(currentPath)）：\(error.localizedDescription)")
            }
        }

        return parentFolderId
    }

    func fetchAllKnowledgeItems(knowledgeBaseId: String, folderId: String?) async throws -> [KnowledgeInfo] {
        var allItems: [KnowledgeInfo] = []
        var cursor = ""

        while true {
            let page = try await getKnowledgeList(knowledgeBaseId: knowledgeBaseId, folderId: folderId, cursor: cursor)
            allItems.append(contentsOf: page.items)

            if page.isEnd || page.nextCursor.isEmpty {
                break
            }
            cursor = page.nextCursor
        }

        return allItems
    }

    private func uploadToCOS(fileData: Data, fileName: String, payload: CreateMediaPayload, contentType: String, fileSize: Int) async throws {
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
        
        let logId = IMALogService.shared.logRequest(method: "PUT (COS)", url: urlString, headers: request.allHTTPHeaderFields, body: "[Binary Data: \(fileName)]")
        let (_, response) = try await self.session.upload(for: request, from: fileData)
        
        if let httpResponse = response as? HTTPURLResponse {
            IMALogService.shared.logResponse(id: logId, code: httpResponse.statusCode, body: "COS Upload Finished", requestId: nil)
            if !(200...299).contains(httpResponse.statusCode) {
                throw IMASyncError.apiError("COS 上传失败: HTTP \(httpResponse.statusCode)")
            }
        }
    }

    private func postJson<T: Decodable>(path: String, body: [String: Any]) async throws -> IMAResponse<T> {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        try applyPrivateWebHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let response: IMAResponse<T> = try await send(request)
        if response.code == 600001 {
            print("[IMASyncService] Token expired (600001) during POST to \(path). Attempting silent refresh...")
            let refreshSuccess = await refreshCredentialsSilently()
            if refreshSuccess {
                print("[IMASyncService] Silent refresh succeeded! Retrying POST to \(path)...")
                var retriedRequest = URLRequest(url: baseURL.appendingPathComponent(path))
                retriedRequest.httpMethod = "POST"
                try applyPrivateWebHeaders(to: &retriedRequest)
                retriedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                retriedRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
                let retriedResponse: IMAResponse<T> = try await send(retriedRequest)
                return retriedResponse
            } else {
                print("[IMASyncService] Silent refresh failed or WeChat session expired. Clearing credentials and logging out.")
                await MainActor.run {
                    IMACredentialsManager.shared.clear(clearWebView: true)
                }
            }
        }
        return response
    }

    private func applyPrivateWebHeaders(to request: inout URLRequest) throws {
        let creds = IMACredentialsManager.shared
        if !creds.isLoggedIn {
            // Keychain might be locked on system startup, try to load it again
            creds.load()
        }
        guard creds.isLoggedIn else {
            throw IMASyncError.missingCredentials
        }
        
        request.setValue("ima.qq.com", forHTTPHeaderField: "Host")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("macOS", forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue("1", forHTTPHeaderField: "from_browser_ima")
        request.setValue("\"Chromium\";v=\"143\", \"Not A(Brand\";v=\"24\"", forHTTPHeaderField: "sec-ch-ua")
        request.setValue(String(creds.bkn), forHTTPHeaderField: "x-ima-bkn")
        request.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue(creds.getCookieString(), forHTTPHeaderField: "x-ima-cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 IMA/143.0.7499.4456", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("4.25.3", forHTTPHeaderField: "extension_version")
        request.setValue("chrome-extension://nkohmbngmopdajidckglcoehlaeepeoi", forHTTPHeaderField: "Origin")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> IMAResponse<T> {
        let bodyString = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        let logId = IMALogService.shared.logRequest(method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "", headers: request.allHTTPHeaderFields, body: bodyString)
        
        var attempts = 0
        let maxAttempts = 5
        var lastError: Error? = nil
        
        while attempts < maxAttempts {
            attempts += 1
            do {
                let (data, urlResponse) = try await self.session.data(for: request)
                let decoded: IMAResponse<T> = try decodeIMAResponse(data: data, urlResponse: urlResponse)
                
                // Do NOT retry on 600001 (unauthorized) to avoid long UI freezes/spins
                
                IMALogService.shared.logResponse(id: logId, code: (urlResponse as? HTTPURLResponse)?.statusCode ?? 0, body: String(data: data, encoding: .utf8), requestId: decoded.requestId)
                return decoded
            } catch {
                lastError = error
                IMALogService.shared.logError(id: logId, code: nil, error: "Attempt \(attempts) failed: \(error.localizedDescription)", requestId: nil)
                
                if attempts < maxAttempts {
                    let delay = Double(attempts) * 1.5
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
            }
        }
        
        throw lastError ?? IMASyncError.apiError("发送请求失败，已自动尝试 \(maxAttempts) 次")
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

    /// 验证指定的登录凭证是否有效（不改变全局凭证管理器状态）
    func validateCredentials(token: String, refreshToken: String, uid: String, guid: String) async -> Bool {
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("cgi-bin/user_info/get_user_info"))
            request.httpMethod = "POST"
            
            request.setValue("ima.qq.com", forHTTPHeaderField: "Host")
            request.setValue("keep-alive", forHTTPHeaderField: "Connection")
            request.setValue("macOS", forHTTPHeaderField: "sec-ch-ua-platform")
            request.setValue("1", forHTTPHeaderField: "from_browser_ima")
            request.setValue("\"Chromium\";v=\"143\", \"Not A(Brand\";v=\"24\"", forHTTPHeaderField: "sec-ch-ua")
            request.setValue(String(IMACredentialsManager.calculateBkn(token: token)), forHTTPHeaderField: "x-ima-bkn")
            request.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
            
            let cookieStr = IMACredentialsManager.getCookieString(token: token, refreshToken: refreshToken, uid: uid, guid: guid)
            request.setValue(cookieStr, forHTTPHeaderField: "x-ima-cookie")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 IMA/143.0.7499.4456", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "accept")
            request.setValue("4.25.3", forHTTPHeaderField: "extension_version")
            request.setValue("chrome-extension://nkohmbngmopdajidckglcoehlaeepeoi", forHTTPHeaderField: "Origin")
            request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [:])
            
            let (data, _) = try await self.session.data(for: request)
            let response = try JSONDecoder().decode(IMAResponse<H5UserInfoDetail>.self, from: data)
            return response.code == 0
        } catch {
            print("[IMASyncService] validateCredentials failed with error: \(error)")
            return false
        }
    }

    private func validate<T>(_ response: IMAResponse<T>) throws {
        if response.code != 0 {
            if response.code == 600001 {
                DispatchQueue.main.async {
                    IMACredentialsManager.shared.clear(clearWebView: true)
                }
            }
            throw IMASyncError.apiError(response.displayMessage())
        }
    }
    
    /// 静默刷新登录凭证（不影响全局状态，除非成功才更新）
    @MainActor
    func refreshCredentialsSilently() async -> Bool {
        print("[IMASyncService] Starting silent credentials refresh via background WKWebView...")
        
        return await withCheckedContinuation { continuation in
            let refresher = IMASilentTokenRefresher { success in
                continuation.resume(returning: success)
            }
            refresher.start()
        }
    }
}

/// 负责在后台静默刷新 IMA Token 的辅助类，复用现有 Cookie 与微信登录态
@MainActor
final class IMASilentTokenRefresher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var timer: Timer?
    private var completion: (Bool) -> Void
    private var isFinished = false
    private var isValidating = false
    private let oldToken: String
    private var selfRetain: IMASilentTokenRefresher?
    
    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        self.oldToken = IMACredentialsManager.shared.imaToken
        super.init()
    }
    
    func start() {
        selfRetain = self // 保持强引用，防止被 ARC 销毁导致 WebView / 定时器失效
        
        let configuration = WKWebViewConfiguration()
        // 复用默认数据存储，直接读取现存 Cookie
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        
        let request = URLRequest(url: URL(string: "https://ima.qq.com/login/")!)
        webView.load(request)
        
        // 开启每秒一次的凭证轮询扫描
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.checkCredentials()
            }
        }
        
        // 15 秒超时兜底，防止挂起
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                if !self.isFinished {
                    print("[IMASilentTokenRefresher] Silent refresh timed out after 15 seconds.")
                    self.finish(success: false)
                }
            }
        }
    }
    
    private func finish(success: Bool) {
        guard !isFinished else { return }
        isFinished = true
        
        timer?.invalidate()
        timer = nil
        webView?.navigationDelegate = nil
        webView = nil
        
        completion(success)
        
        selfRetain = nil // 释放自身强引用以完成内存销毁
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            let urlString = url.absoluteString
            print("[IMASilentTokenRefresher] Background WebView navigating to: \(urlString)")
        }
        decisionHandler(.allow)
    }
    
    private func getCookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
    
    private func checkCredentials() async {
        guard !isFinished, let webView = webView else { return }
        
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await getCookies(from: store)
        
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
        
        if verifyAndSaveIfValid(token: token, refreshToken: refreshToken, uid: uid, guid: guid) {
            return
        }
        
        // 尝试通过 JS document.cookie 获取
        if let cookieStr = try? await webView.evaluateJavaScript("document.cookie") as? String, !cookieStr.isEmpty {
            if parseAndVerifyCookieString(cookieStr) {
                return
            }
        }
    }
    
    private func parseAndVerifyCookieString(_ str: String) -> Bool {
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
        
        return verifyAndSaveIfValid(token: token, refreshToken: refreshToken, uid: uid, guid: guid)
    }
    
    private func verifyAndSaveIfValid(token: String, refreshToken: String, uid: String, guid: String) -> Bool {
        guard !token.isEmpty && !uid.isEmpty && token != oldToken else { return false }
        guard !isValidating else { return true }
        isValidating = true
        
        let finalGuid = guid.isEmpty ? IMACredentialsManager.fallbackGuid() : guid
        let finalRefreshToken = refreshToken.isEmpty ? token : refreshToken
        
        print("[IMASilentTokenRefresher] Detected new credentials in background WebView. Validating...")
        
        Task { @MainActor in
            let isValid = await IMASyncService.shared.validateCredentials(
                token: token,
                refreshToken: finalRefreshToken,
                uid: uid,
                guid: finalGuid
            )
            
            if isValid {
                print("[IMASilentTokenRefresher] Background refresh validated successfully! Saving to Keychain...")
                IMACredentialsManager.shared.save(
                    token: token,
                    refreshToken: finalRefreshToken,
                    uid: uid,
                    guid: finalGuid
                )
                
                if let profile = try? await IMASyncService.shared.getUserProfile() {
                    IMACredentialsManager.shared.avatarUrl = profile.avatarUrl
                    IMACredentialsManager.shared.nickname = profile.nickname
                }
                
                self.finish(success: true)
            } else {
                print("[IMASilentTokenRefresher] Background credentials validation failed. Continuing search...")
                self.isValidating = false
            }
        }
        
        return true
    }
}

// MARK: - H5 Web Models & Adaptations

struct H5KnowledgeBaseListResponse: Decodable {
    let results: [H5KnowledgeBaseResult]
    
    struct H5KnowledgeBaseResult: Decodable {
        let knowledgeBaseList: [KnowledgeBase]
        
        enum CodingKeys: String, CodingKey {
            case knowledgeBaseList = "knowledge_base_list"
        }
    }
}

struct H5GetKnowledgeResponse: Decodable {
    let knowledge: H5KnowledgeDetail
    
    struct H5KnowledgeDetail: Decodable {
        let jumpUrl: String
        let mediaType: Int
        
        enum CodingKeys: String, CodingKey {
            case jumpUrl = "jump_url"
            case mediaType = "media_type"
        }
    }
}

struct H5DeviceListResponse: Decodable {
    let devices: [H5Device]
    
    enum CodingKeys: String, CodingKey {
        case devices = "device_list"
    }
}

struct H5Device: Decodable, Identifiable {
    var id: String { deviceName + "_" + deviceType }
    let deviceName: String
    let deviceType: String
    
    var isCurrent: Bool {
        deviceType.lowercased().contains("mac")
    }
    
    var osName: String {
        deviceType
    }
    
    enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
        case deviceType = "device_type"
    }
}

struct H5SpaceQuota {
    let totalQuota: Int64
    let usedQuota: Int64
}

struct H5SpaceQuotaResponse: Decodable {
    let totalUserSpace: H5SpaceDetail?
    
    enum CodingKeys: String, CodingKey {
        case totalUserSpace = "total_user_space"
    }
}

struct H5SpaceDetail: Decodable {
    let totalSpace: String
    let usedSpace: String
    
    enum CodingKeys: String, CodingKey {
        case totalSpace = "total_space"
        case usedSpace = "used_space"
    }
}

struct H5UserInfoDetail: Decodable {
    let openInfo: H5UserOpenInfo
    
    enum CodingKeys: String, CodingKey {
        case openInfo = "open_info"
    }
}

struct H5UserOpenInfo: Decodable {
    let avatarUrl: String
    let nickname: String
    
    enum CodingKeys: String, CodingKey {
        case avatarUrl = "avatar_url"
        case nickname = "nickname"
    }
}

// MARK: - Standard Models & Errors

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
        case info
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = (try? container.decode(String.self, forKey: .message))
            ?? (try? container.decode(String.self, forKey: .msg))
            ?? "IMA 接口未返回错误说明"
        requestId = try? container.decode(String.self, forKey: .requestId)
        data = (try? container.decodeIfPresent(T.self, forKey: .data))
            ?? (try? container.decodeIfPresent(T.self, forKey: .info))
            ?? (try? T(from: decoder))
    }

    func displayMessage(httpStatus: Int? = nil) -> String {
        var parts: [String] = []
        if let httpStatus {
            parts.append("HTTP \(httpStatus)")
        }
        parts.append("code \(code)")
        if code == 80001 {
            parts.append("权限不足 (可能是由于您切换了微信账号或该同步文件夹绑定的知识库不存在，请在‘设置 -> 常规’中为该文件夹重新选择正确的同步目标知识库)".appLocalized)
        } else {
            parts.append(message)
        }
        if let requestId, !requestId.isEmpty {
            parts.append("request_id \(requestId)")
        }
        return parts.joined(separator: " / ")
    }
}

enum IMADuplicateFileStrategy: String {
    case renameWithTimestamp
    case experimentalOverwrite
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
        case basicInfo = "basic_info"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let rawId = (try? container.decode(String.self, forKey: .kbId))
            ?? (try? container.decode(String.self, forKey: .id))
            ?? (try? container.decode(String.self, forKey: .knowledgeBaseId))
        self.id = rawId ?? ""
        
        var rawName: String? = nil
        if let basicInfoContainer = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .basicInfo) {
            if let kbNameKey = DynamicCodingKey(stringValue: "name") {
                rawName = try? basicInfoContainer.decode(String.self, forKey: kbNameKey)
            }
        }
        
        if rawName == nil {
            rawName = (try? container.decode(String.self, forKey: .kbName))
                ?? (try? container.decode(String.self, forKey: .name))
                ?? (try? container.decode(String.self, forKey: .title))
                ?? (try? container.decode(String.self, forKey: .knowledgeBaseName))
        }
        
        self.name = rawName ?? "未命名知识库"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
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

struct KnowledgeListPayload: Decodable {
    let knowledgeList: [KnowledgeInfo]
    let isEnd: Bool
    let nextCursor: String
    
    enum CodingKeys: String, CodingKey {
        case knowledgeList = "knowledge_list"
        case folderList = "folder_list"
        case infoList = "info_list"
        case list
        case items
        case isEnd = "is_end"
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        var items: [KnowledgeInfo] = []
        items.append(contentsOf: (try? container.decode([KnowledgeInfo].self, forKey: .knowledgeList)) ?? [])
        items.append(contentsOf: (try? container.decode([KnowledgeInfo].self, forKey: .folderList)) ?? [])

        if items.isEmpty {
            items = (try? container.decode([KnowledgeInfo].self, forKey: .infoList))
                ?? (try? container.decode([KnowledgeInfo].self, forKey: .list))
                ?? (try? container.decode([KnowledgeInfo].self, forKey: .items))
                ?? []
        }

        knowledgeList = items
        isEnd = (try? container.decode(Bool.self, forKey: .isEnd)) ?? true
        nextCursor = (try? container.decode(String.self, forKey: .nextCursor)) ?? ""
    }
}

struct KnowledgeInfo: Codable, Identifiable, Hashable {
    var id: String { folderIdentifier ?? mediaId }
    let mediaId: String
    let title: String
    let parentFolderId: String?
    let folderId: String?
    let name: String?

    var displayName: String {
        name?.isEmpty == false ? name! : title
    }

    var folderIdentifier: String? {
        if let folderId, !folderId.isEmpty {
            return folderId
        }
        if mediaId.hasPrefix("folder_") {
            return mediaId
        }
        return nil
    }

    var isFolder: Bool {
        folderIdentifier != nil
    }
    
    enum CodingKeys: String, CodingKey {
        case mediaId = "media_id"
        case folderId = "folder_id"
        case title
        case name
        case parentFolderId = "parent_folder_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folderId = try? container.decode(String.self, forKey: .folderId)
        mediaId = (try? container.decode(String.self, forKey: .mediaId)) ?? folderId ?? ""
        title = (try? container.decode(String.self, forKey: .title))
            ?? (try? container.decode(String.self, forKey: .name))
            ?? ""
        name = try? container.decode(String.self, forKey: .name)
        parentFolderId = try? container.decode(String.self, forKey: .parentFolderId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mediaId, forKey: .mediaId)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(parentFolderId, forKey: .parentFolderId)
        try container.encodeIfPresent(folderId, forKey: .folderId)
        try container.encodeIfPresent(name, forKey: .name)
    }
}

struct MediaInfoPayload: Decodable {
    let mediaType: Int
    let urlInfo: URLInfo?
    
    enum CodingKeys: String, CodingKey {
        case mediaType = "media_type"
        case urlInfo = "url_info"
    }
}

struct URLInfo: Decodable {
    let url: String
    let headers: [String: String]?
}

struct EmptyPayload: Decodable {}

struct IMAMediaType {
    static func resolve(extension ext: String) -> (Int, String)? {
        let map: [String: (Int, String)] = [
            "pdf": (1, "application/pdf"),
            "doc": (3, "application/msword"),
            "docx": (3, "application/msword"), // 统一使用短 MIME 类型突破接口 50 字符限制防 code 51
            "ppt": (4, "application/vnd.ms-powerpoint"),
            "pptx": (4, "application/vnd.ms-powerpoint"), // 统一使用短 MIME 类型突破限制
            "xls": (5, "application/vnd.ms-excel"),
            "xlsx": (5, "application/vnd.ms-excel"), // 统一使用短 MIME 类型突破限制
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
            return "请先使用微信扫码登录 IMA 账号"
        case .apiError(let message):
            return message
        case .invalidResponse(let message):
            return "IMA 响应无法解析：\(message)"
        }
    }
}

struct CheckRepeatedNamesPayload: Decodable {
    let results: [CheckRepeatedNameResult]
}

struct CheckRepeatedNameResult: Decodable {
    let name: String
    let isRepeated: Bool
    
    enum CodingKeys: String, CodingKey {
        case name
        case isRepeated = "is_repeated"
    }
}

struct DeleteKnowledgeWebResponse: Decodable {
    let code: Int
    let msg: String
    let results: [String: DeleteKnowledgeResult]
}

struct DeleteKnowledgeResult: Decodable {
    let mediaId: String
    let retCode: Int
    
    enum CodingKeys: String, CodingKey {
        case mediaId = "media_id"
        case retCode = "ret_code"
    }
}


struct IMACreateFolderResponse: Decodable {
    let knowledge: IMAFolderKnowledge
}

struct IMAFolderKnowledge: Decodable {
    let mediaId: String
    
    enum CodingKeys: String, CodingKey {
        case mediaId = "media_id"
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
