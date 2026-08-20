# DSH Mobile — dsh web 服务跑在 iOS（nodejs-mobile + WKWebView）

极薄原生壳：Swift 起 nodejs-mobile 引擎跑 `main.js`，WKWebView 指向 `127.0.0.1:3080`。
点火阶段只验证 dsh boot/core 进程内启动 + WebView 连上。

## 目录结构

```
dsh-iOS/
├── ios-app/
│   ├── project.yml                  # XcodeGen 工程定义（工程源文件）
│   ├── DSHMobile/
│   │   ├── AppDelegate.swift        # 起引擎 + WKWebView
│   │   ├── NodeRunner.swift         # nodejs-mobile 引擎封装（node_start）
│   │   ├── ConsoleTailer.swift      # 把 node-console.log 尾巴打到 NSLog
│   │   ├── WebViewController.swift  # 轮询 127.0.0.1:3080 后 load
│   │   └── Info.plist               # 含 NSAllowsLocalNetworking（本地 HTTP）
│   └── nodejs-project/
│       ├── main.js                  # 入口：console 镜像 + 按 PHASE 分派
│       └── boot-web.js              # 阶段3：boot dsh web profile
├── scripts/
│   ├── build-nodejs-mobile.sh       # 源码编译 Node 22.9 iOS xcframework
│   ├── prepare-dsh-dist.sh          # 组装 nodejs-project 的 dsh 运行载荷
│   └── run-simulator.sh             # 模拟器构建 + 安装 + 启动 + 看日志
└── patches/
    ├── nodejs-mobile-ios.patch      # 对 nodejs-mobile 仓库的完整改动（git diff，构建脚本自动应用）
    ├── ios_framework_prepare.sh.patched
    ├── NodeMobile.pbxproj.patched
    ├── v8.gyp.patched               # 补上 iOS 缺失的 v8 源文件
    └── platform-ios.cc.patched      # jitless 下 SetJitWriteProtected 空实现
```

## 关键结论（已在本机验证）

1. **dsh 需要 Node 22+**（root package.json `engines: ^22.19.0 || >=24.0.0`，代码用
   `Promise.withResolvers`/`findLast`/`toReversed`）。nodejs-mobile 官方预编译最高只有
   Node 18 → 必须从 capawesome 的 `update22-9-0` 分支（Node 22.9.0）源码编译。
2. **dsh 的 web profile 完整 boot 已在 Mac 桌面验证通过**：130+ 插件行全部激活、
   webserver 绑定、前端 HTML 返回 HTTP 200。使用的正是 nodejs-project 里同一份 dsh-dist。
3. **JIT**：构建保留 `--v8-options=--jitless`（nodejs-mobile 默认）。本阶段只验证 jitless 能起来，
   JIT 后续由 StikDebug 挂载（不在本仓库范围内）。

## 复现步骤

### 0. 前置
- Xcode 26.6 + Command Line Tools，`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
- `brew install xcodegen`、`npm i -g pnpm@11.7.0`
- dsh 仓库 clone：`git clone https://github.com/deepseek-ai/deepseek-harness ~/deepseek-harness`

### 1. 编译 nodejs-mobile xcframework（Node 22.9，约 40 分钟，三遍 V8）
```bash
./scripts/build-nodejs-mobile.sh
# 产出 deps/NodeMobile.xcframework（ios-arm64 真机 + ios-arm64-simulator 两个切片）
```
> 注意：构建脚本会 clone capawesome/nodejs-mobile `update22-9-0` 分支并应用 `patches/` 里的改动。
> 补丁解决四件事：
> 1. gyp 把 iOS SDK 泄漏给 host 工具（node_js2c/mksnapshot 被链成 iOS 二进制导致内核 SIGKILL）
> 2. Node 22 新增的 7 个静态库（sqlite/ada/nbytes/simdjson/ncrypto/turboshaft/abseil/initializers_slow）没进 framework 工程
> 3. libbase64 系库在 Node 22.9 不产出需跳过
> 4. iOS 目标缺两个 v8 源文件（`platform-ios.cc` 的 jitless `SetJitWriteProtected`、abseil 的
>    `crc_non_temporal_memcpy.cc`），导致 framework 链接报 3 个 undefined 符号
> 5. （接手注记）补丁基于 `update22-9-0` tip 提交 `106c51f9`，clone 后由构建脚本 `git apply`
>    自动打上；四个 `.patched` 文件是参照副本，构建后自动刷新（首次构建即补齐）。

### 2. 组装 dsh 运行载荷（nodejs-project/）
```bash
./scripts/prepare-dsh-dist.sh ~/deepseek-harness
# 在 dsh 仓库里 pnpm install + pnpm run build，然后 pnpm deploy --prod 抽出
# 自包含 node_modules，写入 ios-app/nodejs-project/
```
> 脚本会做三件关键事：
> - 把 `node-addon-require-builtin` 换成纯 JS shim（`process.getBuiltinModule ?? createRequire`）
> - 把 `node-pty`、`sharp` 换成纯 JS stub（iOS 无 .node；dsh 只在调用时才用它们）
> - 补齐 pnpm deploy 丢掉的 19 个 peer-only workspace 包，并重建顶层 @deepseek-ai 符号链接
>   （`createRequire.resolve.paths` 不 realpath 符号链接，导致 healProfilesModuleFallback 闭包不完整）

### 3. 模拟器验证（阶段1 → 2 → 3）
```bash
# 阶段1：引擎跑起来，Xcode 控制台看到 'node up'
./scripts/run-simulator.sh 1

# 阶段2：import dsh 核心包成功（无模块解析错误）
./scripts/run-simulator.sh 2

# 阶段3：dsh web 起 127.0.0.1:3080，WKWebView 加载出 dsh 界面
./scripts/run-simulator.sh 3
```
阶段号通过 `SIMCTL_CHILD_DSH_IOS_PHASE` 传给引擎（NodeRunner.swift 里默认 1）。

### 4. 真机 ipa（未签名）
```bash
xcodebuild -project ios-app/DSHMobile.xcodeproj \
  -scheme DSHMobile -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/DSHMobile.xcarchive \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  archive

xcodebuild -exportArchive -archivePath build/DSHMobile.xcarchive \
  -exportPath build/ipa -exportOptionsPlist ios-app/ExportOptions.plist
```
> 未签名 ipa 你自己用 Xcode + Apple ID 重签（注册你的 iPhone、7 天有效期）。
> 签名/部署由你负责，本仓库不包含任何签名配置。

## 阶段3 运行时的可写目录

Swift 侧把沙盒可写目录（`Application Support/dsh`）通过 argv 传给 main.js 作为 `DSH_HOME`，
session 持久化、storage、profile 都落在那里，绝不碰只读 bundle 目录。
控制台输出通过 main.js 镜像到 `Application Support/node-console.log`，Swift 的 ConsoleTailer
把它尾随到 NSLog（iOS 无 tty，stdout 默认不可见）。

## 已知留白（点火阶段刻意不做）

- 不接 SSH、不做文件授权、不做 UI 之外的任何功能
- `code-runtime`（worker_threads）在 iOS overlay 里 disabled（nodejs-mobile 不支持 worker 线程）
- JIT 挂载留给 StikDebug
- 真机签名部署由你负责

## 云端构建（GitHub Actions，无需本地 Mac）

本仓库自带了 `.github/workflows/ci.yml`，把三步全部搬到了 GitHub 云端：

| Job | 运行器 | 产物 |
|---|---|---|
| `framework`（arm64 / arm64-simulator 并行） | macOS 14（Apple Silicon） | 两个 xcframework 切片 |
| `payload`（dsh 载荷 + Linux 桌面冒烟测试 HTTP 200） | ubuntu | `dsh-dist.tar.gz` |
| `app`（合成 xcframework → xcodegen → 模拟器跑阶段3 → 出 ipa） | macOS 14 | `DSHMobile.ipa`（未签名）+ 模拟器控制台日志 |

**推送即触发**（push 到 main/master，或仓库 Actions 页面手动 Run workflow）。

> ⚠️ 用量提示：私有仓库 macOS 分钟按 ×10 计费（免费额度 2000 分钟/月 → 约 200 macOS 分钟）。
> 一次完整构建约 90–180 macOS 分钟，私有仓库一个月大概只够跑 1–2 次；**公开仓库不限标准运行器分钟**。
> 仓库内容无密钥/签名信息，如需频繁构建建议直接设成 public。

在 Mac 上跑本地三步的脚本现在也支持 CI 分片：`ARCH_ONLY=arm64 ./scripts/build-nodejs-mobile.sh`、
`ARCH_ONLY=arm64-simulator ...`（合成 xcframework 时手动跑 `xcodebuild -create-xcframework`，见 ci.yml）。
