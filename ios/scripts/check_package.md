# 云端 unsigned 包检查

在 macOS/Xcode 构建机、仓库根目录运行。输入是已解包的 xcarchive 内
Argo.app 和本次生成的 IPA；脚本从当前生成的 project.pbxproj 与源 plist
读取 Release 声明，不下载产物。

在现有 `Package the unsigned archive and IPA` 步骤之后、Upload 之前调用：

```bash
python3 ios/scripts/check_package.py \
  --archive-app "$RUNNER_TEMP/argo-ios/Argo-iphoneos-unsigned.xcarchive/Products/Applications/Argo.app" \
  --ipa "$RUNNER_TEMP/argo-ios/packages/Argo-unsigned.ipa" \
  --summary "$RUNNER_TEMP/argo-ios/logs/package-check.json"
```

`--summary` 可省略；同一份 JSON 总会输出到 stdout，最多 4096 字节。
成功 exit 0，检查失败或缺少输入/原生工具时非零；不要忽略失败退出码。
检查 ZIP CRC、IPA/archive app 文件一致性、源身份/版本/权限与隐私、
图标资源、arm64 iPhoneOS Mach-O，以及实际签名/描述文件状态。

unsigned 与 ad-hoc 都会明确报告；ad-hoc 不是 Apple 证书签名。
脚本拒绝证书签名或描述文件，不执行签名、安装或 APNs 投递；
production APNs 检查的是 Release 配置和包内 Info，不宣称已验证签名 entitlement。
Linux 可运行 `--help`、语法及标准库负例；真实包必须在 macOS CI 执行。
