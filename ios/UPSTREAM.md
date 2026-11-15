# Persona → Argo iOS 移植来源

固定来源：[nwverse/persona](https://github.com/nwverse/persona/tree/3002eb387c65fe471a75b03586e89bd49e20f4a3)，commit `3002eb387c65fe471a75b03586e89bd49e20f4a3`。没有追踪更新。下表 blob SHA 是该 commit 中原文件的 Git blob SHA；界面移植条目已逐项与原仓 commit tree 核对。完整逐文件映射见 [upstream-files.json](Argo/Verification/upstream-files.json)。

## 实际采用的界面

实际页面采用 Persona iOS Liquid Glass 的手机揭开式侧栏、iPad 分栏、头像状态会话行、搜索及滚动筛选胶囊、蓝色用户消息泡、开放回复列、可展开思考/工具内容、单编辑器增长输入框、代码复制及横滚。Shared/Design 的字号、行高、4pt 间距、圆角、状态色和 Shell 表面直接保留。BeautifulUI 的 ToolChipRow 在消息页实际使用。

Argo 的 AppModel、配对页、问题回答卡、数据投影及生命周期协调为 Argo 新增。网络、TLS、Keychain、配对码、API、分页合并仅调用 `import ArgoMobileKit` 公共接口，UI 不重写网络。入口是 `@main ArgoApp`；工程负责人设置 iOS 26 deployment target，并以同仓相对路径引用 ArgoMobileKit 与 BeautifulUI。

## 移植文件

| Argo 文件 | Persona 原路径与 blob SHA | 改造点 |
|---|---|---|
| `ios/Argo/Design/Theme.swift` | `apple/Shared/Design/Theme.swift`<br>`6de7dde5ccdcccd1894cb0f1bcedac164a027ead`<br>`apple/Shared/Design/Styles/Glass.swift`<br>`3664c89801ace74704a2f3b49c8028ad4162328f` | 保留 Liquid Glass 字号、行高、间距、圆角、角色色及 Shell 表面；固定原版蓝色主题，品牌用 Argo。 |
| `ios/Argo/Design/Palette.swift` | `apple/Shared/Design/Palette.swift`<br>`a613af6be0d2c6161a56f9f6229fa87dc67e68e7` | 保留系统色；Persona coral 未用于品牌。 |
| `ios/Argo/Design/StatusPalette.swift` | `apple/Shared/StatusPalette.swift`<br>`2cc188140e94e5a71c8ca0adb56a99b193699efc` | 保留 dot/text/tint 状态色及明暗色 helper。 |
| `ios/Argo/Design/Icons.swift` | `apple/Shared/Design/Icons.swift`<br>`652bc6ad03dc64c98f91e19e00bca4db013740cc` | 保留实际使用的 SF Symbols，含 Persona 原版 interrupt=stop.fill；移除 Persona 品牌与无关平台图标。 |
| `ios/Argo/DesignSystem/AgentMark.swift` | `apple/Persona/DesignSystem/AgentMark.swift`<br>`7f58bc6729f3e2cea2f89fc9e70ef5834fe37efb` | 保留字母方块和 CLI 角标；名称取自 Argo 卡片。 |
| `ios/Argo/DesignSystem/BesideOrUnder.swift` | `apple/Persona/DesignSystem/BesideOrUnder.swift`<br>`801839b5dcc0fe841ac1397c69d3d82437400321` | 原始 Layout 算法；长标题、大字体的时间自动换行。 |
| `ios/Argo/DesignSystem/CapsuleFilterBar.swift` | `apple/Persona/DesignSystem/CapsuleFilterBar.swift`<br>`947c35fc200bdceb8f44a2747d8b9f81b09080e1` | 保留滚动胶囊、状态色、数量及固定末端按钮；清理旧定位式翻译 key。 |
| `ios/Argo/DesignSystem/Components.swift` | `apple/Persona/DesignSystem/Components.swift`<br>`f664aeb7a70690038e49960663865d03f3b8581e`<br>`apple/Persona/Views/Chats/ChatsView.swift`<br>`e93c1e3163567c773c25600c80237f9de8a4a7e5` | 提取 StatusDot、Working 环、Chip、TimeBesideOrUnder；以系统动效替换 Persona 可见性动画桥。 |
| `ios/Argo/DesignSystem/ComposerButtons.swift` | `apple/Persona/DesignSystem/ComposerButtons.swift`<br>`8eee80dc2d5cd6a15ec954c3012882fce8a89485` | 保留原版 ink 圆形按钮、44pt 命中区域与按压曲线；停止当前轮次使用同款 stop.fill 与 busy spinner，不引入音频能力。 |
| `ios/Argo/DesignSystem/Notice.swift` | `apple/Persona/DesignSystem/Notice.swift`<br>`76260d17d4ead8ad125958bffd610a77c07d336d` | 保留提示布局及 tone，固定原生 thinMaterial 表面。 |
| `ios/Argo/DesignSystem/ReadingSize.swift` | `apple/Persona/DesignSystem/ReadingSize.swift`<br>`35c08b01778c562302ea715081e39331583ad787` | 保留界面字体上限与正文独立 Dynamic Type。 |
| `ios/Argo/DesignSystem/TextSize.swift` | `apple/Persona/DesignSystem/TextSize.swift`<br>`ece5b30f7cd98bfb09cc209d6f91b70877f6948c` | 保留 scaledFrame、命中区域及行距；以 ScaledMetric 适配 iOS。 |
| `ios/Argo/DesignSystem/ThemedIcon.swift` | `apple/Persona/DesignSystem/ThemedIcon.swift`<br>`cd5d0c53929f98122742fe9b871a0319bb5046ff` | 保留 SF Symbol 入口，固定 Liquid Glass 原生字重。 |
| `ios/Argo/DesignSystem/TypedText.swift` | `apple/Persona/DesignSystem/TypedText.swift`<br>`e8880a7f3aca19ea03c1b8691af3e3b46bf2e47a`<br>`apple/Persona/DesignSystem/TextViewScroll.swift`<br>`95d08bc8ac845885e045796081050a3c1eb06d16` | 保留发送前 unmarkText 及 UITextInput 全文同步；仅读取有焦点的目标框，selector 用 Argo 前缀。 |
| `ios/Argo/Views/RootView.swift` | `apple/Persona/Views/SplitNavigation.swift`<br>`8afbbc12fff44892b6c583f819c3255b847fc044`<br>`apple/Persona/Views/Chats/ChatsView.swift`<br>`e93c1e3163567c773c25600c80237f9de8a4a7e5` | 保留 iPad 分栏及 340/400/480 列宽；仅保留 Argo Agent 路由。 |
| `ios/Argo/Views/Shell/DrawerLayout.swift` | `apple/Persona/Views/Assistant/AssistantSidebar.swift`<br>`aa2a7d9982fe0ee76e9318b19b47d550039c5613` | 保留固定侧栏、整页平移、0.82/380pt 侧栏宽、55pt 页角和 0.32s spring；单页 SwiftUI 状态替代 Hub/pager/UIKit 监测，打开手势限定列表左缘。 |
| `ios/Argo/Views/Connection/HostWorkspaceView.swift` | `apple/Persona/Views/Shell/UnifiedSidebar.swift`<br>`1b4ee81a8b3086105b7860aa75f91a97475db3ea` | 沿用侧栏层级及近白/近黑底色，内容接入真实主机、项目、工作区。 |
| `ios/Argo/Views/Chats/AgentRowStyles.swift` | `apple/Persona/Views/Chats/AgentRowStyles.swift`<br>`665853624c98ee15a8ff04072dac9c8e165d0902` | 移植默认 avatarRow、头像状态角标、标题/时间自适应、两行预览与状态元信息；改用 AgentSession 薄投影。 |
| `ios/Argo/Views/Chats/ChatsView.swift` | `apple/Persona/Views/Chats/ChatsView.swift`<br>`e93c1e3163567c773c25600c80237f9de8a4a7e5` | 保留列表、搜索、筛选胶囊与 split 选择，接入 Argo 卡片及真实排队数量。 |
| `ios/Argo/Views/Chat/ChatView.swift` | `apple/Persona/Views/Chat/ChatView.swift`<br>`10cb94ec74daea1afec3942cc5f8cf740bc7717b` | 沿用 Persona 原生会话页面与工具栏中 active/canInterrupt 条件入口；映射为 Argo managed working 身份、当前主机连接和 busy/未知结果约束；接入 managed Claude 模型错误恢复；停止结果单独提示并刷新实际状态与队列。 |
| `ios/Argo/Views/Chat/ModelRecoveryCard.swift` | `apple/Persona/Views/Chat/APIErrorCard.swift`<br>`5c349efee2992f977d05b3eec87fdd673218d3ed`<br>`apple/Persona/Views/Chat/AssistantModelSheet.swift`<br>`e26357f15b47e1bdd53d746462ce5ff145322698` | 保留错误卡警示、表面、可读详情与手输模型行；仅接入 managed Claude 模型错误的换模型并续跑，不接入 PersonaHub 模型目录。 |
| `ios/Argo/Views/Chat/MessageViews.swift` | `apple/Persona/Views/Chat/MessageViews.swift`<br>`1cb9c7346299f7e77af0547a968a09acfc0f97ed` | 移植右侧蓝色消息泡、开放正文列、思考折叠及待发送形态；原生消息与发送回执分开，任意类型统一显示截断提示。 |
| `ios/Argo/Views/Chat/PromptComposer.swift` | `apple/Persona/Views/Chat/PromptComposer.swift`<br>`765531484fb6377474fd7a2101996de2fb186496`<br>`apple/Persona/DesignSystem/ShellComposerBar.swift`<br>`4a15714c28f361c67cbc7b4efec815aa1fe4523d` | 保留单一 TextField 与三子视图布局；恢复 Persona 空草稿时以 stop 圆形键替代 send 的行为，停止期间展示 busy，不清空草稿；合入真实附件入口，只有空文本且没有附件时以 stop 替换 send，Cmd-Return 仅在编辑器聚焦时生效。 |
| `ios/Argo/Views/Chat/ComposerParts.swift` | `apple/Persona/Views/Chat/ComposerParts.swift`<br>`9b20cb30afdf99b68c0b39f163db390d6696a224`<br>`apple/Persona/DesignSystem/ShellComposerBar.swift`<br>`4a15714c28f361c67cbc7b4efec815aa1fe4523d` | 保留原 ComposerBoxLayout 三视图测量算法及 ComposerSurface，不创建第二个编辑器。 |
| `ios/Argo/Views/Chat/ReplyBlocks.swift` | `apple/Persona/Views/Chat/ReplyBlocks.swift`<br>`1b6dc95e6e04acabf789c1afaea677ce86e10a03` | 移植代码标题、复制、横滚及色板；Foundation Markdown 替代 MarkdownUI/PersonaKit。 |
| `ios/Argo/Views/Chat/ToolViews.swift` | `apple/Persona/Views/Chat/ToolViews.swift`<br>`1c1da3730e08dcd33534b116b29050c705b1269a` | 实际使用 BeautifulUI ToolChipRow；工具输入/输出/diff、计划、任务和步骤均读 Argo 核心模型。 |

## 第三方文件与许可

`ios/ThirdParty/Persona/LICENSE` 为原版 MIT 许可。BeautifulUI 延续前任已有副本，所有源码及许可逐字节匹配固定 Persona commit 的 `apple/Packages/BeautifulUI/`，含 `LICENSE`、`LICENSE-beautifului`、`NOTICE`、`VENDORED.md`。仅保留前任的 Package.swift 改动：删除未拷入的 BeautifulUITests target。VENDORED.md 记录 BeautifulUI 自有来源 `d22da54`；本轮未重新抓取或修改第三方库。

| 保留文件 | Persona 原路径 | blob SHA | 差异 |
|---|---|---|---|
| `ios/ThirdParty/BeautifulUI/LICENSE` | `apple/Packages/BeautifulUI/LICENSE` | `424b798f648076e6639ae057de98c98d55a57a3d` | 原样 |
| `ios/ThirdParty/BeautifulUI/LICENSE-beautifului` | `apple/Packages/BeautifulUI/LICENSE-beautifului` | `6635631aded86516cec8cab103c1a6f27b026c42` | 原样 |
| `ios/ThirdParty/BeautifulUI/NOTICE` | `apple/Packages/BeautifulUI/NOTICE` | `1ecef9aa93012ed02e9bdb21a73cebb30e20b4a1` | 原样 |
| `ios/ThirdParty/BeautifulUI/Package.swift` | `apple/Packages/BeautifulUI/Package.swift` | `74287f6dc18b7cd67ebd41ae9c0d4d4d1633d50c` | 删除未拷入的 test target（前任已有） |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/AgentScreen.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/AgentScreen.swift` | `87a2e9efe8eba562b89952969cf9e6f9a281d85c` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/ApprovalCard.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/ApprovalCard.swift` | `aaeb017e114e349cc97a8ce1e9a634c0905f9c2a` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/ChatPanel.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/ChatPanel.swift` | `59927e484064cf31c3c9bafafda1340403abb636` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/CodeBlock.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/CodeBlock.swift` | `7f2faa2397116f43a8b85b55f07a02596366a4b4` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/ContextCards.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/ContextCards.swift` | `856a80e70aa7558274e4592e86c262938b6b0655` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/DeliberateTap.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/DeliberateTap.swift` | `8f5580762cc84c5806ee9116a57a927ec8f3ae36` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/DiffTable.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/DiffTable.swift` | `371803f7fe7eba0bec1f16bffb482854eabaae59` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/FilterChips.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/FilterChips.swift` | `5399ebb659a696ccb587e24440b999e87a28e53a` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/FilterTable.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/FilterTable.swift` | `d3b05d6a40308fa7b183e8e76b39097e84a03f21` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/FineTuneCard.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/FineTuneCard.swift` | `432d21af0f1d5eae290fe8f9b5ad5880c2a39d2b` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/Flowchart.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/Flowchart.swift` | `1ddc102b4c57f0f0475e0eed967011d92ff1d9d9` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/InsightCards.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/InsightCards.swift` | `013c0705df1499accc8a6886f80e9ab056c7aec9` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/ListRows.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/ListRows.swift` | `b9995f2eb4ca2855b39d821ac000f0f89b706a4c` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/LoadingState.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/LoadingState.swift` | `e70a2f57a713d726e6ed3ec00b23d9d2236c1109` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/PromptBar.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/PromptBar.swift` | `648abb1c6b3b80665d2a9137b1632dfbb21a29e8` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/RecommendationCard.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/RecommendationCard.swift` | `48e13257af0bf36bb9fae978d8488ca6c102500f` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/RecordsTable.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/RecordsTable.swift` | `f882666623be0ff6c46fb79fc0af8e120bee367d` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/SearchList.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/SearchList.swift` | `796f67d2760fab7a4fc40c29f65701c0ceaedbba` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/SelectionActions.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/SelectionActions.swift` | `5a3b7302e4dc79add8172dbfad2034d5c2b0e10a` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/SidebarNav.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/SidebarNav.swift` | `18e97a4b82307fdd2c15326b16147c6d720f4db8` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/SidebarPieces.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/SidebarPieces.swift` | `2453f7118a89a0b123495460303b2434a70db69d` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/StreamingText.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/StreamingText.swift` | `9ead36b3739446b984f69aa56a5bd370831d0307` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/TaskRows.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/TaskRows.swift` | `e5b9bd20365b472ecd941cba85778c5738fc27e4` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/ThinkingState.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/ThinkingState.swift` | `a92aa12eadb41c027efde1ac56ce772ee30cf79c` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/ToolChipGroup.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/ToolChipGroup.swift` | `1311a68e5b179cb1879cfdbb786346e9d70a3cea` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Components/ToolChips.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Components/ToolChips.swift` | `5fc4f3cfec88860949ae7671fb454387137d08b4` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Support/Avatar.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Support/Avatar.swift` | `2c3a84dedf80331e98aa2d85ca760f5d6990819a` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Support/Buttons.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Support/Buttons.swift` | `e05523651c0c3173bf64287f309fd8e675adf626` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Support/FlowLayout.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Support/FlowLayout.swift` | `a6295d5b178375385f6d460f8c42161bcf976985` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Support/Glyphs.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Support/Glyphs.swift` | `9af9a0c2d79f6408050ae2b70fa6dffc3554bf3d` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Support/InlineSpans.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Support/InlineSpans.swift` | `a2e9dae6d215a490f2b85cbe9cdae7e0f95bcee5` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Support/ProportionalColumns.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Support/ProportionalColumns.swift` | `bceb67b52ffe1cf71e35b42d2ac8b48602178407` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Support/Reveal.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Support/Reveal.swift` | `3dad724321092b77fefc2da42a5133c8d8321ad9` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Support/SVGPath.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Support/SVGPath.swift` | `447f067e1752c8389939ec221b4b98ceda722903` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Support/Shimmer.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Support/Shimmer.swift` | `5baf9ef907364a3ce5bead58772d8162560cb478` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Support/SpinningArc.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Support/SpinningArc.swift` | `aa1fddaab7c73cb7cbcbd650f9dde7ac7aca7f7e` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Tokens/BUIColors.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Tokens/BUIColors.swift` | `3566acee0597344ab7d82fd0ac3473122f1cdb84` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Tokens/BUIElevation.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Tokens/BUIElevation.swift` | `3160f3f37eea145697c53c06ed03066e1e7dd81a` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Tokens/BUILayout.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Tokens/BUILayout.swift` | `e666d91289b4ea96f4d7b685cae7dd27c9ec639e` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Tokens/BUIMotion.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Tokens/BUIMotion.swift` | `8cbf1ef7196a3fc9da3879a45d5cc84dcbd572be` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Tokens/BUITheme.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Tokens/BUITheme.swift` | `a3a8e07088b7485908f05796fdb86f02066f2ade` | 原样 |
| `ios/ThirdParty/BeautifulUI/Sources/BeautifulUI/Tokens/BUITypography.swift` | `apple/Packages/BeautifulUI/Sources/BeautifulUI/Tokens/BUITypography.swift` | `291ec19027ad41e0f19a69a577e3ea615d71f8f6` | 原样 |
| `ios/ThirdParty/BeautifulUI/VENDORED.md` | `apple/Packages/BeautifulUI/VENDORED.md` | `0ebb8e07edfb6d052df3948f9d6f95c2c84a3c78` | 原样 |
| `ios/ThirdParty/Persona/LICENSE` | `LICENSE` | `c8265a71fae6d6ec59b9a296b2dd2d990779212d` | 原样 |

## 独立手机设置

`Argo/Views/Settings/SettingsView.swift` 沿用同一固定 Persona `apple/Persona/Views/Settings/SettingsView.swift`（blob `893610c2e96e60848c513c359eab0bc5d93212d5`）的系统 Label/LabeledContent 行和设备、连接分组。Argo 仅保留本地外观、现有主机/工作区入口、应用版本和许可查看，不接入 Persona Hub 或未支持的开关。外观通过 AppStorage 在应用根生效，系统语言选择继续由 iOS 管理。

`Argo/Resources/Licenses/` 四份文件逐字节来自现有 `ThirdParty/Persona/LICENSE`、`ThirdParty/BeautifulUI/LICENSE`、`LICENSE-beautifului` 和 `NOTICE`，仅为 Bundle 中避免重名而命名；正文、版权与授权不变。完整来源及 unchanged 标记见逐文件清单。

## Argo 品牌与资源

图标沿用本仓 `mac/Resources/AppIcon.svg` 的绿色立方体（blob `1bf3d7317163198af10271d1f6936e712fcd1fc6`），按原矢量几何生成 1024×1024 RGB iOS 图标及 ArgoMark；iOS 图标无透明度，方形底由系统裁圆角。未拷入 Persona 名称、coral 品牌图标或头像资源。界面字符串位于 `Argo/Resources/en.lproj`、`zh-Hans.lproj`；服务端文本原样显示。

## 生命周期与范围

草稿和发送回执保存在按主机 UUID、工作区、run、terminal 索引的内存状态；导航、视图重建、前后台及重连不丢失或跨会话使用。进程退出后的草稿持久化未实现。发送捕获原生 identity 与 attempt，只由用户点击触发。确定未发出的消息可手动重试并保留 attempt；未知送达（写后取消、HTTP 5xx 等）仅提供刷新与复制。

读取使用核心 1 MiB 有界 block 协议及默认 600 块/4 MiB 保留窗口。浏览历史暂停自动向前合并，可显式载入更新或回到最新；过期读取、原生 identity 更换、409、任意内容块截断分别处理。选择变化、离开会话和前后台切换取消旧任务，退后台或切主机关闭旧连接；结果只更新捕获的目的地。

移除 PersonaHub、PersonaModels、PersonaKit、PersonaWire、Rust、跨平台窗口桥以及助手/飞书/音频/录制等本次范围外功能。Argo 服务端已有文件上传与受限的 Claude 模型恢复接口；手机模型恢复仅使用 `POST /api/agents/{run}/model`：managed Claude 模型错误时输入模型 ID 并显式执行一次换模型并续跑；不移植 Persona 模型目录。新建 Agent 的模型与思考强度沿用所选 CLI 设置。Markdown 使用 Foundation 的标题、段落、列表、引用、内联格式及代码解析；原版 HTML/复杂图文卡和表格专属布局未纳入；附件通过本机副本或原主机受管下载查看，HTML/SVG 只展示有界纯文本。

## 验证层次

源及资源核查：`python3 ios/Argo/Verification/verify_sources.py --swiftc <swiftc> --persona <固定来源解压目录>`。生命周期 fixture：`python3 ios/Argo/Verification/run_lifecycle_checks.py --swiftc <swiftc>`；默认使用同仓 `ios/Packages/ArgoMobileKit`，集成前可传 `--core` 指向只读核心工作树。详细结果见 [UI-REPORT.md](Argo/Verification/UI-REPORT.md)。

Catalyst 仅作辅助类型检查。当前没有 iOS SDK，完整 iOS 编译、模拟器布局、VoiceOver 交互、真机输入法及配对验收留给 L0 集成与独立评审；辅助检查不替代这些验收。

## 新建 Agent 的增量移植

| Argo 文件 | Persona 来源 / blob | 改造 |
|---|---|---|
| `ios/Argo/Views/NewChat/NewChatView.swift` | `apple/Persona/Views/NewChat/NewChatView.swift` / `2e9c5b1b998db8e96d548063a123819c0e7eee0f` @ `3002eb387c65fe471a75b03586e89bd49e20f4a3` | 保留 NavigationStack + Form、主机横向卡片、推入工作区/目录/启动配置选择、权限行、首条消息、底部 Start 及相邻错误。适配 Argo 已有 profiles/create/terminals；不移接 PersonaHub、虚构模型目录或附件/语音。 |

首条非空 prompt 随创建只提交一次，普通 Agent `leader=false`，权限 full 默认明确显示且保留 CLI 原有限制；固定权限原因原样展示，不自动调整权限。底部按钮沿用本仓 TypedText 处理中文组合输入。创建意图由独立 `NewSessionModel` 持有，busy 在 Task 前同步设置。

pending 本地元数据只含原 host/workspace/profile/engine/cwd/permission/context/时间与已知 terminal/run/生命周期位；prompt、token、标题和 native history 不落盘。首次保存失败无 POST。未知创建按精确 context 与归属回查；0/多结果不猜测、不自动重建；多结果仅接受用户明确选择。真实回执支持首轮列表缺席时的启动导航；迟到结果归原主机与工作区。首消息原文留在进程内的创建说明，永不作为伪造的 native 消息或 delivery receipt。

新建验收入口：`python3 ios/Argo/Verification/run_lifecycle_checks.py --new-session --wire <真实 Go handler JSON 目录> --swiftc <swiftc>`。源/资源、生产 model 与辅助 SwiftUI 类型检查结果及未覆盖范围见 [本次报告](../research/new-session-result.md)。18 个共享 symlink、Mac 目标及 BeautifulUI vendor 保留原 dirty 基线。

## 照片与文件附件

`AttachSheet.swift`、`TurnAttachments.swift` 与 `Attachments/AttachmentSources.swift` 继续改编自同一 Persona 固定版本的 AttachSheet/PhotoAttach/FileAttach/TurnAttachments，逐个来源 blob 见 `Argo/Verification/upstream-files.json`。保留半屏/全屏 sheet、Recents 三列、Photos/Files、caption、附件行/卡片/照片条；不复制视频、相机、录音、编辑器或 Persona 的 base64/Hub 协议。Argo 使用真实 multipart upload、文件路径文本引用与受管 download，发送回执仍由现有 queue 管理。
