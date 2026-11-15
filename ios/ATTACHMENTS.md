# 照片与文件附件 / Attachments

在已配对主机的受管 Agent 会话中，输入框加号打开 Persona 的半屏/全屏附件 sheet。Recents 只展示照片，按打开时的 full/limited/denied 权限处理；All Photos 使用系统 PhotosPicker，Files 使用系统文件选择器。关闭/滑落保留选择，Send 才启动发送；不提供相机、视频、录音或照片编辑入口。

每条最多 **4 项**，每项上传/下载最多 **10 MiB**。照片经后台 ImageIO 转为长边最多 **1600 px、JPEG 0.75**。文件通过 security scope 和 NSFileCoordinator 复制到应用私有目录，拒绝目录、package 和软链。处理前与实际复制后检查大小；副本由草稿/回执/查看器共同持有，最后一个句柄释放时删除其独立目录。尚未准备完成就被取消的项保留名称和错误，需要重新选择。

同一个 ArgoConnection 逐项 multipart 上传到 `/api/upload`，校验单项 `{path,name,size}`。caption、选择顺序与原 host/workspace/run/terminal/native identity 固定；全部 readyRemote 后才创建一次 queue attempt。引用沿用网页的 `文件引用：` / `请用图片查看工具查看图片：` 和完整 JSON 引号路径，供 Agent 工具读取，并供 bounded chat 的 `fileRefs` 投影。上传成功只代表文件已在主机，queue 的 queued/delivered/pasted/unknown 回执继续独立显示。

notSent 的 Retry 从当前回执取权，使用同一 path/text/target/attempt，不再上传。unknown 不自动重发。切主机、工作区、会话、原生 identity、退后台或取消会结束旧事务，保留原草稿；晚到的系统 picker 选择在原草稿显示需重新选择，不后台读取或发送到新会话。文件上传无服务端幂等键；上传回执丢失时明确显示“上传状态未知，消息尚未发送”，再次上传只由用户显式触发。

历史 `fileRefs`（`origin:"text-reference"`，最多 20 项/item，绝对路径、无控制符、≤4096 UTF-8 bytes）与正文 file link 共用受管查看器，从原 host/workspace/terminal 下载。1 MiB page、4 MiB transcript 保留预算包含引用路径/名称/origin 和数组元素。每次远端查看重新请求；403/404/超限展示真实状态，不使用本机旧副本代替远端结果。外部 HTTP(S) 链接交系统处理且不附 gateway/bearer，开发机 file:// 从不直接交系统打开。

本机草稿和回执有明确的 Local copy 预览。图片使用 ImageIO 下采样，普通文档使用只接收私有 URL 的 Quick Look；HTML/SVG 展示最多 256 KiB 纯文本并标示截断。没有 WebView 或向远端页面传 bearer 的通路。上传保留和 download 的 workspace/terminal 授权沿用服务端；历史引用不保证文件仍存在或读取授权仍有效。

The app keeps Persona's attachment sheet, photo strip, file rows and document cards. Up to four private staged files are uploaded serially, at most 10 MiB each; photos become 1600-pixel JPEGs at quality 0.75. Sending freezes the original destination and caption, waits for every upload receipt, and uses the existing text queue. A notSent retry keeps its exact attempt and remote paths; unknown delivery is never resent automatically. Historical references are fresh scoped downloads, while receipt previews are explicitly local copies.

验证命令见 `Argo/Verification/run_lifecycle_checks.py --attachments`、`--localization` 与 Core package tests。本次还有真实 Go wire fixture、合成 MIME、Mac ImageIO/coordinator 和 Catalyst 辅助类型证据，详见交付 `research/result.md`。完整 iOS build、设备配对、真实 Photos/iCloud/security scope、Quick Look/VoiceOver/中文输入法及 upload→真实 Agent 工具读取仍需在具备 iOS SDK/设备的授权环境验收；未在工具执行中读取真实相册或用户文件。
