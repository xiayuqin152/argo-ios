# Argo iOS

<p align="center">
  <img src="docs/branding/argo-logo.png" alt="Argo" width="144" height="144">
</p>

Argo 的 iPhone / iPad 手机伴侣：在手机上跟进编程会话、阅读进展、发送回复，采用 Persona 的相关界面、输入与配对体验。

[English](README.md) · [构建与主机要求](ios/README.md) · [手机通知](docs/phone-notifications.md)

## 会话与输入

- 浏览已配对主机、工作区、消息、工具进展和会话历史。
- 已接通的 **managed 会话支持读写**，可正常回复和回答支持的问题；历史、manual 或未接入的会话保持只读。
- 查看工作中、等待回复、完成和错误状态。发送后展示主机的投递/排队回执；结果未知时先刷新确认，再决定是否另发。
- 展开输入框编辑长文本。Return 默认换行；在**设置 → 按回车发送**中开启后，Return 发送、Shift-Return 换行。
- 附加照片或文件，并打开受管预览；主动点击系统 **Paste Image / 粘贴图片**按钮导入图片。

## 配对

在满足移动端契约的 Argo 主机执行：

```sh
argo pair
```

在 App 中扫描二维码、点击**粘贴配对码**，或手动输入完整的 `argo1:` 码。配对码有效期为 10 分钟，只能使用一次。扫码需相机权限和受支持设备；粘贴与手动输入持续可用。手机须能访问该主机，连接局域网时按提示允许本地网络访问。

主机须支持有界 1 MiB 聊天契约，手机提醒还需要 `PUT/DELETE /api/notify/device`。已核对的 Argo 源码主线 `56b03830908811c8cc1675675bbdd59127303b5f` 已包含后端组合 `eba473a09100b11b2f6ea0cf77ab5817f50f6608`。运行服务尚未部署此源码。准确状态见[主机兼容要求](ios/README.md#host-compatibility)。本仓库提供手机客户端。

## 手机提醒

候选源码已包含按主机注册通知和点击定位会话的实现。配对后选择主机，在**设置 → 通知 → 在此 iPhone 接收 Agent 提醒**中开启。提醒正文仅包含状态；需要正确签名的 App、iOS 通知权限及主机自己的 APNs 配置，详见[配置与权限说明](docs/phone-notifications.md)。

签名、真实 APNs 送达和设备后台收取仍待验收。前台会话由 App 读取，重新打开后恢复连接。

## 构建与安装

App 面向 iOS 26 及更新系统，使用 [ios/Argo.xcodeproj](ios/Argo.xcodeproj) 的 `Argo` scheme。[GitHub Actions](https://github.com/xiayuqin152/argo-ios/actions/workflows/ios-unsigned.yml) 使用所选 Xcode 执行 Core 测试，再生成 Release iPhoneOS archive 和 unsigned IPA。进入成功运行可查看对应提交、产物和日志。

工作流产生的 **unsigned IPA 不能直接安装**。真机安装需要 Apple Developer 账号、适用证书和描述文件；当前未配置已签名 IPA、TestFlight 或 App Store 渠道。构建入口和验收状态见[构建说明](ios/README.md)。

## 来源与许可

Argo 新增部分采用根目录 [MIT License](LICENSE)，© 2026 Argo contributors。

相关界面、输入和配对组件改写自 [Persona](https://github.com/nwverse/persona)，© 2026 nwverse，保留其 [MIT License](ios/ThirdParty/Persona/LICENSE)。[BeautifulUI](ios/ThirdParty/BeautifulUI)，© 2026 ChrisPan，保留 [MIT License](ios/ThirdParty/BeautifulUI/LICENSE)；基础设计来自 [Beautiful UI](https://www.beautifului.dev/)，© 2026 Shane Levine，原版 [MIT 许可](ios/ThirdParty/BeautifulUI/LICENSE-beautifului)和 [NOTICE](ios/ThirdParty/BeautifulUI/NOTICE)均保留。逐文件来源见 [UPSTREAM.md](UPSTREAM.md)。

Logo 与 AppIcon 沿用所有者既有的 Argo 品牌，原图和重建方式继续见[品牌来源](docs/branding/SOURCES.md)。
