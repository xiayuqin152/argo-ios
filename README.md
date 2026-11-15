# Argo for iOS

![Argo](ios/Argo/Resources/Assets.xcassets/ArgoMark.imageset/Argo.png)

Argo 手机伴侣：在 iPhone 和 iPad 浏览主机上的会话、读取状态并回复，采用 Persona 的界面与输入体验。
支持配对、managed 会话消息与问题回复、只读 manual 会话、附件及受管预览。完整 iOS 云构建与设备验收仍待完成。

## 构建

源码保持 `ios/` 布局，包含 ArgoMobileKit 与 BeautifulUI 两个本地包；无需访问私有 loom 仓库。
`.github/workflows/ios-unsigned.yml` 在 main push、PR 和手动触发时使用 GitHub 标准 macOS runner，
生成工程并执行 jobs=2 的无签名 iOS archive，保留日志和 xcresult。GitHub 首跑结果尚未取得。
产生的 unsigned IPA 需要适当重签后才能安装。

Linux 核心检查：

```sh
swift test --package-path ios/Packages/ArgoMobileKit --jobs 2
python3 ios/scripts/check_project.py
```

## 配对与会话

在支持移动端契约的 Argo 主机生成配对码，在 App 添加主机后选择工作区与会话。
managed 会话支持读写，manual 会话保持只读。上传状态未知时保留操作证据并手动复核，不自动重发。
手机提醒能力和最新主线服务端契约尚在整合，当前源码不宣称已具备 APNs 或设备后台提醒验收。

## 来源与许可

Persona/BeautifulUI 来源见 [ios/UPSTREAM.md](ios/UPSTREAM.md)；四份原文许可/notice 位于
[ios/Argo/Resources/Licenses](ios/Argo/Resources/Licenses)。Argo 共享 Foundation 源已成为仓库内普通文件，
来源及 hash 见 `ios/Packages/ArgoMobileKit/shared-sources.json`。
