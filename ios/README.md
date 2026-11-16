# 构建与安装 Argo iOS

App 面向 iOS 26+ 的 iPhone / iPad，使用 Swift 6；产品、target、scheme 和显示名为 `Argo`，Bundle ID 为 `dev.argo.ios`。

## 获取构建产物

[Argo iOS unsigned 工作流](https://github.com/xiayuqin152/argo-ios/actions/workflows/ios-unsigned.yml)使用 GitHub 标准 `macos-26` runner、Xcode 26.6 和 XcodeGen 2.46.0，以 jobs=2 运行 ArgoMobileKit Core 测试、生成工程、执行 Release iPhoneOS archive 并打包 unsigned IPA。Core 测试失败会中止后续构建，其日志与 archive 日志一并上传。定义见 [.github/workflows/ios-unsigned.yml](../.github/workflows/ios-unsigned.yml)。

在 [Argo iOS unsigned 工作流](https://github.com/xiayuqin152/argo-ios/actions/workflows/ios-unsigned.yml) 中选择所需提交对应的成功运行。进入 Artifacts，查看 `Argo-iOS-unsigned-…`，其中包含 unsigned IPA、archive 和日志；当前工作流产物保留 3 天。

**无签名 IPA 不能直接安装。** 真机签名需要 Apple Developer 账号、适用证书、App ID 和描述文件。手机提醒还需启用 Push Notifications capability、匹配的 APNs 环境及主机密钥。签名配置尚待准备，当前没有已签名 IPA、TestFlight 或 App Store 安装渠道。

## 源码构建入口

直接用完整 Xcode 打开 [Argo.xcodeproj](Argo.xcodeproj)，选择 `Argo` scheme。工程事实源为 [project.yml](project.yml)，本地依赖为 [Packages/ArgoMobileKit](Packages/ArgoMobileKit) 与 [ThirdParty/BeautifulUI](ThirdParty/BeautifulUI)。

在具有完整 Xcode 26.6、iOS SDK、XcodeGen 2.46.0 和 Python 3 的 macOS 构建环境，从仓库根目录执行：

```sh
sh ios/scripts/generate.sh
xcodebuild -jobs 2 \
  -project ios/Argo.xcodeproj -scheme Argo \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios \
  -archivePath build/Argo-unsigned.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
  archive
```

这是无签名编译入口。签名构建前，在自己的构建配置中选择 Team 和描述文件，并按[通知签名对应表](../docs/phone-notifications.md#apns-environments)核对 entitlement。不要提交个人 Team、证书、密钥、描述文件或 APNs 配置。

修改源码成员、依赖或构建设置后重新生成工程；保持原 Argo 图标与矢量来源，见[品牌说明](../docs/branding/SOURCES.md)。

<a id="host-compatibility"></a>
## 主机兼容要求

兼容性按主机实际能力判断，目前尚未指定包含这些增量的已发布主机版本，也不提供新的服务端安装命令。

| 能力 | 已核对的契约 |
| --- | --- |
| 网关与接口 | gateway proto=1、HTTP api=1 |
| 会话阅读 | 客户端请求 `GET /api/terminals/{id}/chat?bounded=1`；响应必须声明 `bounded: true` 和 `byteLimit: 1048576`，支持 `recordOffset:blockIndex` 形式的 before/after/around 游标及 fileRefs |
| 会话回复 | 当前已接通的 managed 会话具有可写身份和主机回执；历史、manual 或未接入会话只读 |
| 队列预览与全文 | 新版客户端需要升级 Argo 后端以支持[queue wire v2](../research/queue-wire-v2/queue-wire-v2.md)：队列读取与发送回执请求 `bounded=1`，响应声明 `bounded: true` 和 `byteLimit: 8388608`；按原 item ID 读取 `GET /api/agents/{run}/queue/{id}` 获得完整原文 |
| 手机提醒 | 主机提供以已配对设备凭证认证的 `PUT/DELETE /api/notify/device`，并配置自己的 APNs |

最新 fetch 核对的 Argo 源码主线为 `56b03830908811c8cc1675675bbdd59127303b5f`，已包含独立审查通过的后端组合 `eba473a09100b11b2f6ea0cf77ab5817f50f6608`。两者源码树一致，包含上述聊天、配对与通知能力。

上述旧主线核对记录不包含新版队列契约。队列预览与全文需要相应后端升级；目前没有指定包含该能力的已发布最低版本。

运行服务尚未部署此源码，也尚未指定已发布的最低主机版本号；部署后的真实配对、回复与 APNs 仍待验收。

## 配对、输入与权限

在兼容主机运行 `argo pair`，然后在手机扫描二维码、主动粘贴或手动输入完整 `argo1:` 码。码一次有效，10 分钟过期。扫码申请相机权限；不支持扫描或未授权时，可继续粘贴/输入。连接局域网主机需要本地网络权限。

长文本通过输入框的展开按钮进入全页编辑。Return 默认换行，Settings 的 Return Key Sends（按回车发送）默认关闭；开启后 Return 发送、Shift-Return 换行。Paste Image 通过系统按钮在主动点击时导入图片。附件与发送共用原有会话归属及回执，结果未知时由用户刷新确认。

手机提醒按主机开启，权限与配置见[手机通知](../docs/phone-notifications.md)。实际真机签名、通知权限 UI、APNs 和后台收取尚未验收。

## 核心与结构检查

从仓库根目录执行：

```sh
swift test --package-path ios/Packages/ArgoMobileKit --jobs 2
python3 ios/scripts/check_project.py
```

XcodeGen 一致性检查为在 `ios/` 中运行 `./scripts/generate.sh --check`，要求使用同一生成器版本。

<a id="validation-status"></a>
## 当前验收状态

云构建先执行现有 Core 测试，再生成 Xcode 工程并运行 Release iPhoneOS archive 和 IPA 打包。扫码、全页编辑、Return 发送、主动 PasteButton、会话与通知代码均参与完整 App 编译；每次结果绑定对应提交，以 Actions 检查、产物和日志为准。

真实配对、输入法/系统粘贴、Photos/Quick Look、辅助功能、签名安装及 APNs 后台收取/点击仍需设备验收。本次文档收口仅核对源码、配置、来源链接和补丁，不执行这些功能验收。

许可见根目录 [MIT License](../LICENSE) 与 [UPSTREAM.md](../UPSTREAM.md) 所列的实际 Persona、BeautifulUI、Beautiful UI MIT/NOTICE。
