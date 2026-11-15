# Argo 手机通知：配置与权限

候选源码已包含按主机注册/注销通知、APNs 发送和点击定位会话。启用前需同时准备可签名的 Apple Developer App ID、APNs 密钥，以及包含设备注册接口的 Argo 主机。签名、真实 APNs 送达和手机后台收取/点击尚待验收。

## 手机上开启

1. 配对并选择兼容主机。
2. 打开 **Settings → Notifications → Agent Alerts on This iPhone**，允许 iOS 的提醒和声音权限。尚未开启此开关时，App 不主动请求通知授权。
3. 若系统权限已拒绝，使用页面的 **Open iOS Settings** 调整；配置或网络错误会显示在页面，可用 **Retry Notifications** 重试。

每个主机单独开启。关闭提醒或忘记主机时，App 先向该主机注销通知；离线或失败时保留凭据，供重连后重试。通知点击定位已配对主机的会话，只读取状态和记录，不自动发送回复。

提醒覆盖待回复、错误、完成、疑似卡住和预算状态，遵守会话已有通知级别。正文仅包含状态，不包含聊天、问题或文件路径。手机目录之外、没有对应可打开会话的事件不发送手机推送。

## 主机配置

主机需要 `PUT/DELETE /api/notify/device`，使用已配对设备凭证注册/注销。兼容状态见[主机要求](../ios/README.md#host-compatibility)；当前公开手机仓库不提供服务端安装器。

主机启动时读取其配置目录中的 `apns.json`。现有 Linux 默认位置为 `~/.config/loom/apns.json`；设置 `XDG_CONFIG_HOME` 时为该目录下的 `loom/apns.json`。这是既有配置目录名。

由主机维护者填写自己的值，以下尖括号内容为待替换的占位符：

```json
{
  "keyID": "<APNS_KEY_ID>",
  "teamID": "<APPLE_TEAM_ID>",
  "keyFile": "keys/AuthKey.p8",
  "topic": "dev.argo.ios",
  "environment": "sandbox"
}
```

`apns.json` 和 `.p8` 私钥使用 0600 权限，目录建议 0700；相对 `keyFile` 从配置文件所在目录解析。密钥仅留在主机本地，不提交到仓库、不通过 App 上传。缺少配置时 APNs 关闭，配置错误会阻止主机启动。

每台主机当前使用一个 topic/environment。`topic` 必须等于已签名 App 的 Bundle ID，环境必须与 App 注册值和描述文件一致；不匹配会拒绝注册。

<a id="apns-environments"></a>
## 签名与 APNs 环境

在 Apple Developer 为自己的 App ID 启用 **Push Notifications**，准备适用的证书、描述文件与 APNs signing key。`ArgoAPNSEnvironment` 是 App 注册到主机的环境值；Apple 的 `aps-environment` entitlement 使用另一组取值：

| 构建用途 | 主机 environment / App 注册值 | 签名 aps-environment |
| --- | --- | --- |
| 开发调试 | `sandbox` | `development` |
| 分发 | `production` | `production` |

取值依据 [Apple APS Environment 文档](https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment)。当前候选已将两种环境分开：`ARGO_APNS_ENVIRONMENT` 只用于 Info.plist 的 `ArgoAPNSEnvironment`，`ARGO_APNS_ENTITLEMENT` 只用于签名的 `aps-environment`。默认 Debug 为 `sandbox` / `development`，Release 为 `production` / `production`；该映射修复已落地。自定义构建配置须显式设置两个变量，并与实际描述文件匹配。真实签名验收仍待完成。

无签名云 IPA 用于编译检查，不能直接安装或用于 APNs 真机验收。真实送达需要 iOS 通知权限、上述签名和主机配置同时就绪。当前尚未交付可安装的签名包或完成真实后台推送测试。
