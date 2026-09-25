# DonkeyYY iOS 版

## 功能
- 全屏 WebView 浏览器加载 https://duys.k2sw9ni.live/
- App 内悬浮按钮（可拖动）
- 点击悬浮按钮直接读取当前页面 HTML 源码，提取明文 m3u8 地址
- 自动下载 AES-128 加密的 ts 分片、解密、合并为 MP4
- 带进度条显示
- 转换完成后询问是否保存到相册

---

## 🚀 方法一：GitHub Actions 云编译（无需 Mac，推荐）

利用 GitHub 免费提供的 macOS 服务器自动编译，你只需上传代码、下载成品。

### 步骤

1. **注册 GitHub 账号**（已有可跳过）：https://github.com

2. **创建新仓库**：
   - 点右上角 `+` → `New repository`
   - Repository name: `DonkeyYY-iOS`
   - 选 `Public`（免费额度够用）
   - 点 `Create repository`

3. **上传本项目所有文件**：
   - 在仓库页面点 `uploading an existing file`
   - 把解压后的所有文件和文件夹拖进去（包括 `.github` 文件夹、`DonkeyYY` 文件夹、`project.yml`）
   - 点 `Commit changes`

4. **等待自动编译**：
   - 进入仓库的 `Actions` 标签页
   - 会看到一个名为 `Build iOS IPA` 的任务正在运行
   - 等待约 3-5 分钟，状态变成绿色 ✅

5. **下载 IPA**：
   - 点进那个绿色的任务
   - 页面最下方 `Artifacts` 区域有两个文件：
     - `DonkeyYY.ipa` — 安装包
     - `DonkeyYY.app` — 应用本体（TrollStore 用这个）
   - 点击下载

### 安装到手机

**方式 A：TrollStore（免越狱，推荐）**
- 适用 iOS 14.0 - 16.6.1（部分设备到 17.0）
- 下载 `DonkeyYY.app`，通过 TrollStore 安装即可，无需签名

**方式 B：侧载（需 Apple ID）**
- 用 `AltStore`、`Sideloadly` 或 `爱思助手` 等工具
- 导入 `DonkeyYY.ipa`，用你的 Apple ID 签名后安装
- 免费签名有效期 7 天，到期需重签

**方式 C：越狱设备**
- 直接用 Filza 安装 `DonkeyYY.app` 或 `DonkeyYY.ipa`

---

## 💻 方法二：本地 Mac + Xcode 编译

如果你以后有 Mac：

1. 安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
2. 在项目目录执行：`xcodegen generate`（生成 Xcode 项目）
3. 打开 `DonkeyYY.xcodeproj`
4. 连接 iPhone，选你的设备，`Cmd + R` 运行

---

## 项目结构

```
DonkeyYY-iOS/
├── .github/workflows/build.yml   # GitHub Actions 自动编译配置
├── project.yml                    # XcodeGen 项目配置
├── DonkeyYY/
│   ├── AppDelegate.swift          # 应用入口
│   ├── ViewController.swift       # 主界面：WebView + 悬浮按钮 + m3u8查找
│   ├── M3U8Manager.swift          # 下载、解密、合并、转MP4
│   ├── Info.plist                 # 权限配置
│   └── Assets.xcassets/           # 图标资源
├── logo.png                       # 应用图标
└── README.md
```

## 注意事项

- 下载大视频时保持 App 在前台，iOS 后台限制较多
- 保存到相册需授权，首次会弹窗
- 悬浮按钮可拖动位置，轻点触发查找
- 进入视频页面后，等视频开始加载（出现画面/播放按钮）再点悬浮按钮
- GitHub Actions 免费额度：每月 2000 分钟 macOS 运行时间，编译一次约 3-5 分钟，完全够用
