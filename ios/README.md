# 构建与安装 Argo iOS

本仓库仅提供 iOS 客户端。App 面向 iOS 26+ 的 iPhone / iPad，使用 Swift 6；产品、target、scheme 和显示名为 `Argo`，Bundle ID 为 `dev.argo.ios`。Argo 主机需单独运行。

## 获取构建产物

[Argo iOS unsigned 工作流](https://github.com/xiayuqin152/argo-ios/actions/workflows/ios-unsigned.yml)使用 GitHub 标准 `macos-26` runner、Xcode 26.6 和 XcodeGen 2.46.0，以 jobs=2 运行 ArgoMobileKit Core 测试、生成工程、执行 Release iPhoneOS archive 并打包 unsigned IPA，随后在可用 iOS Simulator 上执行原生 UIKit 输入测试，保留归档和 UIKit 测试各自的 xcresult。Core 测试失败会中止后续构建，其日志、archive 与测试日志一并上传。定义见 [.github/workflows/ios-unsigned.yml](../.github/workflows/ios-unsigned.yml)。本机没有完整 Xcode 时，可使用这条云构建路线。

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

兼容性按主机实际能力判断，目前尚未指定已发布的最低主机版本。配对前请确认主机具备下列能力；本仓库不包含或部署服务端。

| 能力 | 主机要求与手机体验 |
| --- | --- |
| 配对与连接 | 支持 Argo 配对、设备凭证认证，以及手机可访问的主机地址 |
| 会话阅读 | 支持有界会话读取、历史翻页和附件引用；手机发送的消息随主机读回的 Agent 会话记录显示 |
| 会话回复 | 已接通的 managed 会话支持发送和回执；历史、manual 或未接入会话只读 |
| 队列与早先记录 | 支持队列预览、按原消息读取全文和早先交接记录；结果未知时保留回执，不自动重发 |
| 手机提醒 | 支持已配对设备的通知注册，并配置主机自己的 APNs |

当前已核对的后端候选为 [Loom PR#44](https://github.com/xiayuqin152/loom/pull/44) 的 `6d189c72eacdc2688c8fa788b2c6af13e2d38201`。它仍是候选，最终发布前需记录最终已验证的主机来源。运行服务尚未部署此候选；部署后的真实配对、回复和 APNs 仍待验收。iOS 源码候选见 [PR#3](https://github.com/xiayuqin152/argo-ios/pull/3)。

旧主机需升级到具备这些能力的版本。完整能力说明与开发者接口约定见[主机兼容说明](../docs/COMPATIBILITY.md)，队列接口见[queue wire v2](../research/queue-wire-v2/queue-wire-v2.md)。

## 配对、输入与权限

在兼容主机运行 `argo pair`，然后在手机扫描二维码、主动粘贴或手动输入完整 `argo1:` 码。码一次有效，10 分钟过期。扫码申请相机权限；不支持扫描或未授权时，可继续粘贴/输入。连接局域网主机需要本地网络权限。

长文本通过输入框的展开按钮进入全页编辑。Return 默认换行，Settings 的 Return Key Sends（按回车发送）默认关闭；开启后 Return 发送，Shift/Option-Return 换行。Paste Image 通过系统按钮在主动点击时导入图片。附件与发送共用原有会话归属及回执，结果未知时由用户刷新确认。

手机发送内容可在投递回执中查看；主机读回 Agent 会话记录后，消息显示在对应对话中。排队或收到交接回执不表示 Agent 已完成回复，结果未知的回执也不会因出现相同文本而自动变为成功。

手机提醒按主机开启，点击提醒只打开对应主机和会话，不发送消息；已停用或替换的注册所对应的旧提醒会被忽略。权限与配置见[手机通知](../docs/phone-notifications.md)。实际真机签名、通知权限 UI、APNs 和后台收取尚未验收。

## 核心与结构检查

从仓库根目录执行：

```sh
swift test --package-path ios/Packages/ArgoMobileKit --jobs 2
python3 ios/scripts/check_project.py
```

XcodeGen 一致性检查为在 `ios/` 中运行 `./scripts/generate.sh --check`，要求使用同一生成器版本。

<a id="validation-status"></a>
## 当前验收状态

云构建先执行现有 Core 测试，再生成 Xcode 工程并运行 Release iPhoneOS archive 和 IPA 打包，随后在可用 iOS Simulator 上执行原生 UIKit 输入测试，保留归档和 UIKit 测试各自的 xcresult。扫码、全页编辑、Return 发送、主动 PasteButton、会话与通知代码均参与完整 App 编译；每次结果绑定对应提交，以 Actions 检查、产物和日志为准。

已有成功云构建 [43859719631](https://github.com/xiayuqin152/argo-ios/actions/runs/43859719631) 仅对应 iOS 源码 `3d38c9afecc362a1bf549984c9448bfc83e18c1c`。后续源码变更的 SDK 构建、原生 UIKit 测试、归档和 IPA 验包待对应提交的新云结果；下载时请核对运行记录中的源码 SHA。

真实配对、输入法/系统粘贴、Photos/Quick Look、辅助功能、签名安装及 APNs 后台收取/点击仍需设备验收。

许可见根目录 [MIT License](../LICENSE) 与 [UPSTREAM.md](../UPSTREAM.md) 所列的实际 Persona、BeautifulUI、Beautiful UI MIT/NOTICE。
