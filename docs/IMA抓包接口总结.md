# Tencent IMA 私有接口抓包总结



IMA 桌面端和移动端大量功能依赖 `https://ima.qq.com` 下的私有 H5 接口。FileSyncMonitor 当前真正需要的核心链路是：

1. 登录态获取：通过 WebView 扫码登录，从 Cookie 中提取 `IMA-TOKEN`、`IMA-REFRESH-TOKEN`、`IMA-UID`、`IMA-GUID`。
2. 鉴权请求头拼装：用 `IMA-TOKEN` 计算 `x-ima-bkn`，再拼出 `x-ima-cookie`。
3. 知识库列表：拉取用户可用知识库。
4. 知识库目录列表：递归读取知识库文件和文件夹。
5. 文件上传：创建 media，上传 COS，再 add knowledge。
6. 文件下载：读取 knowledge 详情中的下载 URL。
7. 同名处理：上传前调用重名检查；覆盖策略走删除旧 media 后重新上传。
8. 文件夹同步：创建文件夹、删除文件夹、重命名文件夹。
9. 双向同步辅助：云端删除、云端重命名、云端新增/修改均依赖知识库列表和 media ID 对照。

## 鉴权与公共请求头

所有敏感接口基本都需要以下头部：

```http
Host: ima.qq.com
from_browser_ima: 1
x-ima-bkn: <X_IMA_BKN>
x-ima-cookie: PLATFORM=H5; CLIENT-TYPE=256020; WEB-VERSION=4.25.3; IMA-GUID=<IMA_GUID>; IMA-UID=<IMA_UID>; IMA-TOKEN=<IMA_TOKEN>; IMA-REFRESH-TOKEN=<IMA_REFRESH_TOKEN>; UID-TYPE=2; TOKEN-TYPE=14
User-Agent: Mozilla/5.0 (...) IMA/143.0.7499.4456
accept: application/json
content-type: application/json
extension_version: 4.25.3
Origin: chrome-extension://nkohmbngmopdajidckglcoehlaeepeoi
```

移动端抓包中也出现过另一套 Cookie 形态：

```http
x-ima-cookie: IMA-GUID=<IMA_GUID>; APP-VERSION=2.5.1.x; IMA-UID=<IMA_UID>; IMA-TOKEN=<IMA_TOKEN>; IMA-TOKEN-TYPE=idcTokenImatokenBindSocial; CLIENT-TYPE=256002
User-Agent: ima/4638 CFNetwork/... Darwin/...
Origin: https://ima.qq.com
```

当前 macOS 客户端实现建议优先使用桌面 H5 形态。

### x-ima-bkn 算法

`x-ima-bkn` 来自 `IMA-TOKEN` 的 DJB2 变体：

```swift
func calculateBkn(token: String) -> UInt32 {
    var hash: UInt32 = 5381
    for char in token.utf8 {
        hash = hash &+ (hash &<< 5) &+ UInt32(char)
    }
    return hash & 0x7FFFFFFF
}
```

## FileSyncMonitor 重点接口

### 获取知识库列表

`POST /cgi-bin/knowledge_tab_reader/get_knowledge_base_list`

用途：获取当前账号可访问的知识库列表，用于设置页选择同步目标。

请求体：

```json
{
  "params": [
    { "type": 1001, "cursor": "", "limit": 20 },
    { "type": 1002, "cursor": "", "limit": 20 },
    { "type": 1004, "cursor": "", "limit": 20 },
    { "type": 1005, "cursor": "", "limit": 50 }
  ]
}
```

关键响应字段：

- `code`: `0` 表示成功。
- `data.results[].knowledge_base_list[]`: 知识库数组。
- `knowledge_base_id`: 知识库 ID。
- `name`: 知识库名称。
- `type`: 知识库类型。

### 获取知识库内容列表

`POST /cgi-bin/knowledge_tab_reader/get_knowledge_list`

用途：读取知识库根目录或指定文件夹下的文件/文件夹。双向同步拉取云端新增、删除、重命名都依赖它。

请求体：

```json
{
  "sort_type": 9,
  "need_default_cover": true,
  "knowledge_base_id": "<KNOWLEDGE_BASE_ID>",
  "folder_id": "<FOLDER_ID_OPTIONAL>",
  "cursor": "",
  "limit": 50,
  "ext_info": {}
}
```

关键响应字段：

- `data.knowledge_list[]`: 条目列表。
- `media_id`: 文件 media ID；文件夹有时也可作为 folder 标识。
- `folder_info.folder_id`: 文件夹 ID。
- `title`: 展示名称。
- `media_type`: 媒体类型。
- `jump_url`: 可下载 URL 或访问 URL。
- `is_end` / `next_cursor`: 分页控制。

### 获取知识库条目详情

`POST /cgi-bin/knowledge_tab_reader/get_knowledge`

用途：按 `media_id` 获取文件详情和下载地址。

请求体：

```json
{
  "media_id": "<MEDIA_ID>",
  "knowledge_base_id": "<KNOWLEDGE_BASE_ID>",
  "need_default_cover": true
}
```

关键响应字段：

- `data.knowledge.media_id`
- `data.knowledge.title`
- `data.knowledge.media_type`
- `data.knowledge.jump_url`
- `data.knowledge.raw_file_url`
- `data.knowledge.file_size`
- `data.knowledge.parse_progress`

### 检查同名文件

`POST /cgi-bin/knowledge_tab_reader/check_repeated_names`

用途：上传前判断目标目录是否已有同名文件。该接口只返回是否重复，不直接返回旧文件 `media_id`，因此需要结合 `get_knowledge_list` 查找同名条目。

请求体：

```json
{
  "params": [
    {
      "name": "example.md",
      "media_type": 7
    }
  ],
  "knowledge_base_id": "<KNOWLEDGE_BASE_ID>",
  "folder_id": "<FOLDER_ID_OPTIONAL>"
}
```

关键响应字段：

- `data.results[].name`
- `data.results[].is_repeated`

### 创建媒体对象

`POST /cgi-bin/file_manager/create_media`

用途：上传文件第一步。向 IMA 请求 media ID 和 COS 临时凭据。

请求体：

```json
{
  "media_type": 7,
  "file_size": 6005,
  "file_name": "example.md",
  "knowledge_base_id": "<KNOWLEDGE_BASE_ID>",
  "content_type": "text/markdown"
}
```

关键响应字段：

- `media_id`: 后续 add knowledge 使用。
- `cos_credential.bucket_name`
- `cos_credential.region`
- `cos_credential.cos_key`
- `cos_credential.secret_id`
- `cos_credential.secret_key`
- `cos_credential.token`
- `cos_credential.start_time`
- `cos_credential.expired_time`

注意：COS 凭据是临时凭据，不应写入日志或仓库。

### 上传到 COS

`PUT https://{bucket}.cos.{region}.myqcloud.com/{cos_key}`

用途：上传文件二进制流。该请求不是发给 `ima.qq.com`，而是发给腾讯云 COS。

关键头：

```http
Content-Type: <MIME_TYPE>
Content-Length: <FILE_SIZE>
x-cos-security-token: <COS_SESSION_TOKEN>
Authorization: <COS_SIGNATURE>
Host: <BUCKET>.cos.<REGION>.myqcloud.com
```

签名需要基于 `secret_id`、`secret_key`、`start_time`、`expired_time`、`host`、`content-length` 等字段生成。

### 添加文件到知识库

`POST /cgi-bin/knowledge_tab_writer/add_knowledge`

用途：上传 COS 成功后，将 media 关联到知识库目录中。

请求体：

```json
{
  "media_id": "<MEDIA_ID>",
  "media_type": 7,
  "file_info": {
    "file_size": 6005,
    "cos_key": "<COS_KEY>",
    "file_name": "example.md",
    "content_type": ""
  },
  "knowledge_base_id": "<KNOWLEDGE_BASE_ID>",
  "folder_id": "<FOLDER_ID_OPTIONAL>",
  "title": "example.md",
  "need_parse": true
}
```

关键响应字段：

- `code`
- `msg`
- `media_id`

注意：抓包中 `file_info.content_type` 为 `""`，实际代码保持这个空字符串更贴近客户端行为。

### 文档解析进度

`POST /cgi-bin/media_center/get_parse_progress`

用途：上传后监听解析进度，响应为 SSE。

请求体：

```json
{
  "media_ids": ["<MEDIA_ID>"]
}
```

响应事件：

```text
event:PROGRESS
data:{"Msgs":[{"MediaID":"<MEDIA_ID>","Percent":0.61}]}

event:PARSESTATE
data:{"Msgs":[{"MediaID":"<MEDIA_ID>","State":2}]}

event:COMPLETE
data:{"Code":0,"Msg":"success"}
```

### 创建文件夹

`POST /cgi-bin/knowledge_tab_writer/create_folder`

用途：本地存在子目录但云端缺少对应目录时，自动创建云端文件夹。

请求体：

```json
{
  "knowledge_base_id": "<KNOWLEDGE_BASE_ID>",
  "folder_id": "<PARENT_FOLDER_ID_OR_KNOWLEDGE_BASE_ID>",
  "title": "子文件夹"
}
```

关键响应字段：

- `data.knowledge.media_id`
- `data.knowledge.folder_info.folder_id`
- `data.knowledge.title`

### 删除知识库条目

`POST /cgi-bin/knowledge_tab_writer/del_knowledge`

用途：删除云端文件或文件夹。本地删除同步到云端、覆盖上传前删除旧文件都依赖它。

请求体：

```json
{
  "knowledge_base_id": "<KNOWLEDGE_BASE_ID>",
  "media_ids": ["<MEDIA_ID_OR_FOLDER_ID>"]
}
```

关键响应字段：

```json
{
  "code": 0,
  "msg": "ok",
  "results": {
    "<MEDIA_ID_OR_FOLDER_ID>": {
      "media_id": "<MEDIA_ID_OR_FOLDER_ID>",
      "ret_code": 0
    }
  }
}
```

### 重命名知识库条目

`POST /cgi-bin/knowledge_tab_writer/rename_knowledge`

用途：本地文件/文件夹重命名同步到云端，或云端重命名后做本地反向同步。

请求体：

```json
{
  "media_id": "<MEDIA_ID_OR_FOLDER_ID>",
  "knowledge_base_id": "<KNOWLEDGE_BASE_ID>",
  "title": "new-name.txt",
  "folder_id": "<PARENT_FOLDER_ID_OR_KNOWLEDGE_BASE_ID>"
}
```

关键响应字段：

- `code`
- `msg`
- `knowledge.media_id`
- `knowledge.title`
- `knowledge.parent_folder_id`

## 登录、用户与设备接口

### Web 登录页

`GET /login/`

用途：打开 IMA 登录页，由 WebView 扫码登录并接收 Cookie。

### 登录接口

`POST /auth/login_login`

用途：微信登录授权后换取 token。抓包里包含真实 `code`、`token`、`refresh_token`、`user_id`，文档中必须全部脱敏。

典型响应字段：

- `code`
- `msg`
- `token`
- `refresh_token`
- `token_valid_time`
- `refresh_token_valid_time`
- `user_id`
- `user_info.open_info.avatar_url`
- `user_info.open_info.nickname`
- `user_info.open_info.guid`

### 退出登录

`POST /auth/login_logout`

用途：退出当前登录态。

请求体：

```json
{
  "fresh_token": "<IMA_REFRESH_TOKEN>",
  "token_type": 14,
  "user_id": "<IMA_UID>"
}
```

### 获取用户资料

`POST /cgi-bin/user_info_get_user_info`

用途：获取头像、昵称、uid、guid 等账号信息。

### 获取用户基础信息

`POST /cgi-bin/user_info_get`

用途：获取用户基础资料，和 `get_user_info` 有重叠。

### 获取设备列表

`POST /cgi-bin/user_info_get_device_list`

用途：展示当前账号登录过的设备。

关键响应字段：

- `device_list[].device_name`
- `device_list[].device_type`
- `device_list[].session_id`
- `device_list[].update_ts`

### 获取空间配额

抓包中出现两种路径：

- `POST /cgi-bin/space_get_user_space`
- `POST /cgi-bin/knowledge_tab_reader_get_user_space`

用途：获取总空间、已用空间、知识库空间等配额信息。当前代码使用 `space_get_user_space` 形态。

## 笔记相关接口

这些接口用于 IMA 个人笔记或网页笔记，不是 FileSyncMonitor 当前主同步链路，但可作为未来扩展参考。

### 新增笔记

`POST /cgi-bin/notebook_logic_add_doc`

用途：创建一篇新笔记。

### 读取笔记

`POST /cgi-bin/notebook_logic_get_doc`

请求体包含：

```json
{
  "docid": "<DOC_ID>",
  "op": {
    "op_basic": true,
    "op_content": true,
    "op_resource": true,
    "op_attach": true,
    "disable_cover": false,
    "op_attach_detail": true
  }
}
```

### 修改笔记

`POST /cgi-bin/notebook_logic_set_doc`

用途：更新笔记内容。该接口可用于“追加或覆盖笔记内容”，但不等价于知识库文件覆盖。

### 获取笔记版本

`POST /cgi-bin/notebook_logic_get_doc_version`

用途：笔记编辑器频繁轮询版本，是抓包数量最多的接口。对当前文件同步价值较低。

### 获取文档签名

`POST /cgi-bin/notebook_logic_get_doc_sig`

用途：笔记协同编辑、资源访问签名相关。

### 文件夹与分享

- `POST /cgi-bin/notebook_tab_list_note_folder`
- `POST /cgi-bin/notebook_tab_locate_notes_in_folder`
- `POST /cgi-bin/notebook_tab_get_visitor_num`
- `POST /cgi-bin/notebook_right_get_share_right`
- `POST /cgi-bin/notebook_right_do_share`

## 其他观察到的接口

| 接口 | 用途判断 | 当前项目是否需要 |
| --- | --- | --- |
| `/cgi-bin/ping` | 心跳 | 暂不需要 |
| `/cgi-bin/reddot_mget_dot` | 红点/通知角标 | 暂不需要 |
| `/cgi-bin/history_get_history_list` | 历史记录 | 暂不需要 |
| `/cgi-bin/history_get_web_history` | Web 历史 | 暂不需要 |
| `/message-center-v2` | 消息中心 | 暂不需要 |
| `/cgi-bin/activity_center_query_activity` | 活动中心预检/查询 | 暂不需要 |
| `/cgi-bin/activity_center_report_activity` | 活动上报 | 暂不需要 |
| `/cgi-bin/activity_tab_get_available_activities` | 活动入口 | 暂不需要 |
| `/cgi-bin/activity_tab_query_available_activities` | 活动入口 | 暂不需要 |
| `/cgi-bin/report_svr_report` | 行为上报 | 暂不需要 |
| `/cgi-bin/intelligent_assistant_http_nl_get_models` | AI 模型列表 | 暂不需要 |
| `/cgi-bin/intelligent_assistant_http_get_qa_permissions` | QA 权限 | 暂不需要 |
| `/cgi-bin/task_assistant_nl_get_homepage` | 任务助手首页 | 暂不需要 |
| `/cgi-bin/task_assistant_nl_get_podcast_config` | 播客配置 | 暂不需要 |
| `/cgi-bin/task_assistant_get_remaining_task_count` | 剩余任务数 | 暂不需要 |
| `/cgi-bin/task_center_get_assist_detail` | 任务详情 | 暂不需要 |
| `/cgi-bin/im_sdk_gen_user_sig` | IM SDK 签名 | 暂不需要 |
| `/cgi-bin/session_logic_init_session` | 会话初始化 | 暂不需要 |
| `/cgi-bin/bookmark_api_client_to_server` | 收藏/书签同步 | 暂不需要 |
| `/cgi-bin/knowledge_comment_reader_get_comment_count` | 评论数 | 暂不需要 |
| `/cgi-bin/knowledge_comment_reader_get_comment_list` | 评论列表 | 暂不需要 |
| `/cgi-bin/knowledge_member_get_member_list` | 知识库成员 | 暂不需要 |
| `/cgi-bin/knowledge_member_get_apply_list` | 成员申请 | 暂不需要 |
| `/cgi-bin/knowledge_tab_reader_search_tags` | 标签搜索 | 暂不需要 |
| `/cgi-bin/knowledge_tab_reader_get_knowledge_summary` | 知识摘要 | 可选 |
| `/cgi-bin/knowledge_tab_reader_check_content_status_in_knowledge_base` | 内容状态检查 | 可选 |
| `/cgi-bin/knowledge_tab_reader_get_home_page_data` | 首页数据 | 可选 |
| `/cgi-bin/knowledge_tab_reader_get_knowledge_base_home_page` | 知识库首页 | 可选 |
| `/cgi-bin/knowledge_tab_reader_get_addable_knowledge_base_list` | 可添加知识库列表 | 可选 |
| `/cgi-bin/s_file_manager_get_media` | 移动端加密媒体读取 | 暂不建议使用 |

## 抓包接口全集

| 接口 | 抓包文件数 | 备注 |
| --- | ---: | --- |
| `/auth/login_login` | 2 | 登录换 token |
| `/auth/login_logout` | 2 | 退出登录 |
| `/cgi-bin/activity_center_query_activity` | 24 | 活动查询/预检 |
| `/cgi-bin/activity_center_report_activity` | 16 | 活动上报 |
| `/cgi-bin/activity_tab_get_available_activities` | 10 | 活动入口 |
| `/cgi-bin/activity_tab_query_available_activities` | 4 | 活动入口 |
| `/cgi-bin/bookmark_api_client_to_server` | 2 | 书签/收藏 |
| `/cgi-bin/file_manager_create_media` | 2 | 创建 media，拿 COS 凭据 |
| `/cgi-bin/history_get_history_list` | 18 | 历史记录 |
| `/cgi-bin/history_get_web_history` | 2 | Web 历史 |
| `/cgi-bin/im_sdk_gen_user_sig` | 2 | IM SDK 签名 |
| `/cgi-bin/intelligent_assistant_http_get_qa_permissions` | 4 | QA 权限 |
| `/cgi-bin/intelligent_assistant_http_nl_get_models` | 12 | 模型列表 |
| `/cgi-bin/knowledge_comment_reader_get_comment_count` | 8 | 评论数 |
| `/cgi-bin/knowledge_comment_reader_get_comment_list` | 4 | 评论列表 |
| `/cgi-bin/knowledge_member_get_apply_list` | 8 | 成员申请 |
| `/cgi-bin/knowledge_member_get_member_list` | 4 | 成员列表 |
| `/cgi-bin/knowledge_tab_reader_check_content_status_in_knowledge_base` | 2 | 内容状态 |
| `/cgi-bin/knowledge_tab_reader_check_repeated_names` | 2 | 同名检测 |
| `/cgi-bin/knowledge_tab_reader_get_addable_knowledge_base_list` | 8 | 可添加知识库 |
| `/cgi-bin/knowledge_tab_reader_get_home_page_data` | 2 | 首页数据 |
| `/cgi-bin/knowledge_tab_reader_get_knowledge` | 10 | 知识条目详情 |
| `/cgi-bin/knowledge_tab_reader_get_knowledge_base` | 14 | 知识库详情 |
| `/cgi-bin/knowledge_tab_reader_get_knowledge_base_home_page` | 12 | 知识库首页 |
| `/cgi-bin/knowledge_tab_reader_get_knowledge_base_list` | 10 | 知识库列表 |
| `/cgi-bin/knowledge_tab_reader_get_knowledge_list` | 28 | 知识库文件列表 |
| `/cgi-bin/knowledge_tab_reader_get_knowledge_summary` | 4 | 知识摘要 |
| `/cgi-bin/knowledge_tab_reader_get_user_space` | 2 | 用户空间 |
| `/cgi-bin/knowledge_tab_reader_search_tags` | 14 | 标签搜索 |
| `/cgi-bin/knowledge_tab_writer_add_knowledge` | 2 | 添加知识 |
| `/cgi-bin/knowledge_tab_writer_create_folder` | 8 | 创建文件夹 |
| `/cgi-bin/knowledge_tab_writer_del_knowledge` | 6 | 删除知识 |
| `/cgi-bin/knowledge_tab_writer_rename_knowledge` | 4 | 重命名知识 |
| `/cgi-bin/media_center_get_parse_progress` | 2 | 解析进度 SSE |
| `/cgi-bin/notebook_logic_add_doc` | 2 | 新增笔记 |
| `/cgi-bin/notebook_logic_get_doc` | 2 | 读取笔记 |
| `/cgi-bin/notebook_logic_get_doc_sig` | 10 | 笔记签名 |
| `/cgi-bin/notebook_logic_get_doc_version` | 166 | 笔记版本轮询 |
| `/cgi-bin/notebook_logic_set_doc` | 4 | 修改笔记 |
| `/cgi-bin/notebook_right_do_share` | 2 | 分享 |
| `/cgi-bin/notebook_right_get_share_right` | 2 | 分享权限 |
| `/cgi-bin/notebook_tab_get_visitor_num` | 6 | 访问人数 |
| `/cgi-bin/notebook_tab_list_note_folder` | 6 | 笔记文件夹 |
| `/cgi-bin/notebook_tab_locate_notes_in_folder` | 2 | 定位笔记 |
| `/cgi-bin/ping` | 32 | 心跳 |
| `/cgi-bin/reddot_mget_dot` | 20 | 红点 |
| `/cgi-bin/report_svr_report` | 8 | 行为上报 |
| `/cgi-bin/s_file_manager_get_media` | 2 | 移动端媒体读取 |
| `/cgi-bin/session_logic_init_session` | 2 | 会话初始化 |
| `/cgi-bin/space_get_user_space` | 2 | 用户空间 |
| `/cgi-bin/task_assistant_get_remaining_task_count` | 6 | 剩余任务数 |
| `/cgi-bin/task_assistant_nl_get_homepage` | 10 | 任务助手首页 |
| `/cgi-bin/task_assistant_nl_get_podcast_config` | 18 | 播客配置 |
| `/cgi-bin/task_center_get_assist_detail` | 2 | 任务详情 |
| `/cgi-bin/user_info_get` | 8 | 用户信息 |
| `/cgi-bin/user_info_get_device_list` | 12 | 设备列表 |
| `/cgi-bin/user_info_get_user_info` | 4 | 用户资料 |
| `/login/` | 4 | 登录页 |
| `/message-center-v2` | 4 | 消息中心 |

## 当前项目实现映射

| 项目功能 | 主要代码 | 依赖接口 |
| --- | --- | --- |
| WebView 扫码登录 | `IMALoginWebView.swift`、`IMACredentialsManager.swift` | `/login/`、CookieStore |
| 静默刷新登录态 | `IMASyncService.swift` | `/login/`、`/cgi-bin/user_info_get_user_info` |
| 获取知识库 | `IMASyncService.getKnowledgeBases()` | `/cgi-bin/knowledge_tab_reader_get_knowledge_base_list` |
| 获取设备 | `IMASyncService.getTabDevices()` | `/cgi-bin/user_info_get_device_list` |
| 获取空间 | `IMASyncService.getSpaceQuota()` | `/cgi-bin/space_get_user_space` |
| 获取知识库文件 | `IMASyncService.getKnowledgeList()` | `/cgi-bin/knowledge_tab_reader_get_knowledge_list` |
| 下载文件 | `IMASyncService.getMediaInfo()`、`downloadFile()` | `/cgi-bin/knowledge_tab_reader_get_knowledge` |
| 上传文件 | `uploadToWiki()` | `check_repeated_names`、`create_media`、COS PUT、`add_knowledge` |
| 删除云端文件 | `deleteKnowledgeByWebAPI()` | `/cgi-bin/knowledge_tab_writer_del_knowledge` |
| 创建云端文件夹 | `createFolder()` | `/cgi-bin/knowledge_tab_writer_create_folder` |
| 重命名云端文件/文件夹 | `renameKnowledge()` | `/cgi-bin/knowledge_tab_writer_rename_knowledge` |
| 解析进度 | `trackParseProgress()` | `/cgi-bin/media_center_get_parse_progress` |

## 风险与维护建议

- 这些接口均为非官方私有接口，路径、字段、鉴权规则、客户端版本号可能随时变化。
- 不应提交原始抓包文本、真实 token、真实 cookie、真实 COS 临时凭据。
- `x-ima-cookie`、`x-ima-bkn`、COS `secret_key`、COS `token` 必须从日志中脱敏。
- 如果接口返回 `600001`，通常代表登录态失效，当前项目应触发静默刷新或重新登录。
- 上传前应保留 `check_repeated_names`，否则同目录同名文件可能被重复添加。
- 删除接口支持文件和文件夹，但删除文件夹时应谨慎，云端可能级联删除子内容。
- 移动端接口中出现 `x-ima-ckey` 和加密 body，不建议作为桌面端主链路。

