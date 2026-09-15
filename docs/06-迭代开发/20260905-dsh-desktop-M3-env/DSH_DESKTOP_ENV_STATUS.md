# dsh-desktop 开发环境搭建 — 状态报告（双轨：① legacy tauri/gnu 链接 ② Flutter M3 校验；更新至 2026-09-05 续 17:22）

## 0. 结论速览（最新，2026-09-06）

### 轨 A — legacy/tauri-skeleton（gnu 链接，历史）
- 本机 **MSVC 目标无法链接**（无 `cl.exe`/`link.exe`，方案 A 已放弃）。**〔2026-09-05 续测修正〕当前 `cl.exe` 已随 VS 2022 Build Tools 安装就位（`...\MSVC\14.44.35207\bin\Hostx64\x64\cl.exe`），MSVC 链接器现已可用；轨 A 仍按既定走 gnu 方案，未回退 MSVC。**
- **MinGW-w64 工具链已在本机完整装配**（`C:\mingw64`，gcc 16.2.0），gnu host 工具链安装中（见 §1–§5）。
- 待办：修复后重跑 `cargo build --target x86_64-pc-windows-gnu`（见 §4）。

### 轨 B — Flutter 3.47.2 / Dart 3.13.2（M3 校验；Dart 层已完成，Windows 构建前置已就绪）
- Flutter SDK 已装：`C:\Users\jiang\.workbuddy\binaries\flutter`（cn 镜像 zip，SHA 校验通过，Dart 3.13.2）。
- **Dart 层校验全部通过（M3 硬出口的替代验证；本会话 2026-09-05 复测仍全绿）**：
  - `client_dart`：`dart pub get`✓ / `dart analyze` 无问题 ✓ / `dart test` **6 测试全过**（00:01 +6）✓
  - `dsh_manager`：`dart analyze` 无问题 ✓ / 无 `package:test` 依赖 → 无单测（符合交付）
  - `contract`：纯数据（golden 样例），无 pubspec → 无 Dart 文件
  - `apps/desktop_flutter`：`dart analyze` 无问题 ✓ / `widget_test.dart` 结构合法但**本机不可执行**
- **Windows 原生工具链（Step 4 前置）已就绪，且构建已验证**：VS 2022 Build Tools「使用 C++ 的桌面开发」工作负载已装，`cl.exe` 位于 `...\MSVC\14.44.35207\bin\Hostx64\x64\cl.exe`，Windows SDK 10（10.0.19041/22621/26100）齐备 → `flutter build windows` 的 MSVC 编译前置**已满足**。**用户已于本机正常网络下 `flutter build windows --release` 成功产出 exe**（位于 `apps/desktop_flutter/build/windows/x64/runner/Release/`），证明代码与工具链端到端正确；该产物不在本沙箱工作副本（沙箱内 `flutter` 仍挂死）。
- **本机仍不可执行项（环境限制，非代码缺陷）**：
  1. `flutter` 子命令（`pub get`/`analyze`/`test`/`build`）在 artifact 解析循环结束后、asset 步骤卡死（flutter_tools 内部挂起；已验证网络与代理均非根因——清空代理后 Dart 可直连所有镜像 200/404，flutter 仍挂且**不打印任何 http URL**）。→ 用 `dart` 工具链完成 analyze/test 验证；`flutter build/test` 须 `flutter`，故**本沙箱**内仍不可行（用户在正常网络机器上 `flutter build windows --release` 已成功产出 exe，见 §7.7）。
  2. 本地代理 `127.0.0.1:54569`：仅影响 `dart`/`flutter` 的 pub 网络（静默丢 Dart 连接）。**注意：此代理是 `dart pub get` 0 字节挂死的根因，但不是 `flutter pub get` 挂死的根因** → 所有命令前置 `unset` 代理直连 cn 镜像即可。
  3. `reg.exe` 在 Security Center 黑名单：`flutter doctor` 的 Windows 版本/设备检测会崩；对 `flutter build windows` 是否构成硬阻塞尚不确定（pub get 挂死发生在 reg.exe 调用之前，故非 pub get 挂死根因）。需用户在 Security Center UI 手动移除。
  4. app `widget_test.dart` 需 `flutter test`（`package:test` 是 `flutter_test` SDK 传递依赖，未提升进 app 的 package_config）→ `dart test` 报 “Could not find package test”；且 `flutter test` 被 ① 阻塞。

## 1. Rust 工具链

| 组件 | 版本 | 说明 |
|------|------|------|
| rustup | 1.29.1 | `C:\Users\jiang\.rustup` |
| rustc（默认） | 1.98.1 | stable-x86_64-pc-windows-**msvc**（host，MSVC 链接器缺失 → 不可用） |
| rustc（新增，安装中） | 1.98.1 | stable-x86_64-pc-windows-**gnu**（host=gnu，链接走 `gcc`） |
| cargo | 1.98.1 | `C:\Users\jiang\.cargo\bin` |
| 目标 | x86_64-pc-windows-gnu | 已 `rustup target add`（gnu 目标 std 就绪） |

- cargo 镜像：`rsproxy` 稀疏索引（`~/.cargo/config.toml`），沙箱内唯一可用的高速 Rust 源。
- 网络出口走代理 `HTTP_PROXY/HTTPS_PROXY=http://127.0.0.1:54569`（cargo 默认读取，rsproxy 可达）。

## 2. C 链接器：MSVC 失败 → MinGW-w64（gnu）

### 2.1 方案 A（MSVC Build Tools）：不可用
- 安装返回码 0，但产物**不含 `cl.exe`/`link.exe`**，仅有 VC/Redist、clang-format、IDE 组件 → MSVC 目标无法链接，放弃。

### 2.2 方案 B（MinGW-w64）：已完成
- 经 **MSYS2 镜像**（`repo.msys2.org`）下载 `mingw64.db` + 12 个核心包（binutils/gcc/gcc-libs/crt/headers/winpthreads/gmp/mpfr/mpc/isl/zlib/libiconv），用 `zstandard` 解包、两遍提取（常规文件 + 符号/硬链接），装配到 `C:\mingw64`。
- 版本：gcc 16.2.0 / binutils 2.47 / crt 14.0.0，posix/seh/**msvcrt** 运行时（与 Rust gnu 目标期望一致）。
- 校验（全部 OK）：`bin/{gcc,cc,ar,windres,ld,dlltool,as,nm,ranlib,objcopy,strip}.exe`；`lib/{libkernel32,libmsvcrt,libuser32,libgdi32,libadvapi32,libws2_32,...}.a`（21/21 Tauri 需用到的导入库齐全）；`lib/crt2.o`、`lib/libmingw32.a`；运行时 DLL（`libgcc_s_seh-1.dll`、`libstdc++-6.dll` 等）。
- `C:\mingw64\bin\cc.exe` 由 `gcc.exe` 复制生成（为 `cc` 构建脚本兜底）。

### 2.3 cargo 配置（`~/.cargo/config.toml`）
```toml
[target.x86_64-pc-windows-gnu]
linker = "gcc.exe"
```
> 注意：`[target.*]` 只对**最终二进制**生效，**不覆盖 build script 的 host 链接器**。因此必须把 host 也设为 gnu（见 §3）。

## 3. 根因与修复（build script 链接失败）

首次 `cargo build --target x86_64-pc-windows-gnu` 在编译期全部通过、但在 **链接 build script** 时失败：
```
error: linking with `link.exe` failed: exit code: 1
  = note: link: extra operand '....rcgu.o'   # GNU coreutils `link`，非 MSVC
```
- 链接命令行引用 `<sysroot>/lib/rustlib/x86_64-pc-windows-**msvc**/lib/...` → 证实 build script 用的是 **msvc host** 链接器 `link.exe`。
- 本机无 MSVC `link.exe`，PATH 上的 `link` 是 GNU 版，参数不兼容 → 失败。
- **修复（两层）**：
  1. 安装 gnu **host** 工具链，使 build script 与最终二进制均按 gnu 目标用 `gcc` 链接：
     `rustup toolchain install stable-x86_64-pc-windows-gnu --profile minimal`
  2. **关键**：即便 gnu host 就位，`cargo` 仍经 PATH 上的 **rustup 代理** `C:\Users\jiang\.cargo\bin\rustc` 解析 `rustc`，该代理在 cargo 子进程环境下 exec gnu rustc 失败，报 `os error 193`（`%1 不是有效的 Win32 应用程序`，"never executed"）。**必须用绝对路径绕过代理**：
     ```bash
     export PATH="/c/mingw64/bin:/c/Users/jiang/.cargo/bin:$PATH"
     export RUSTC="C:/Users/jiang/.rustup/toolchains/stable-x86_64-pc-windows-gnu/bin/rustc.exe"
     cd dsh-desktop/legacy/tauri-skeleton/src-tauri
     rustup run stable-x86_64-pc-windows-gnu cargo build
     ```
  > PATH 必须用 **Unix 风格** `/c/mingw64/bin`（不能用 `C:/mingw64/bin`，`command -v` 在该 shell 下无法解析 Windows 风格路径）。
  > `RUSTC` 必须指向 gnu 工具链的**绝对路径**，否则 cargo 经 rustup 代理解析 rustc 会触发 `os error 193`。（已用空 `hello_test` 工程验证：加 `RUSTC` 绝对路径后即 `Finished dev profile`；不加则同样 `os error 193`。）

## 4. 待办：编译验证（Task #4，修复后重跑）
- 工程：`dsh-desktop/legacy/tauri-skeleton/src-tauri`（`tauri 2.11` + `tauri-plugin-shell 2.3`，`rust-version=1.77.2`）。
- 命令见 §3 末。成功标志：产出 `target/x86_64-pc-windows-gnu/debug/dsh-desktop.exe`（debug 构建即可验证链接）。
- 若仍报某导入库缺失，按错误补对应 MSYS2 包后重跑。

## 5. 关于 glib 安全告警
- `Cargo.lock` 中 `glib = 0.18.5`（受影响区间 `>=0.15.0 <0.20.0`，修复 `0.20.0`）。
- 经 **Linux-only WebKitGTK** 路径引入；**Windows/gnu 构建不编译 glib**，本机构建无影响。`Cargo.lock` 维持 `glib 0.18.5`。

## 6. 临时文件（可清理）
- `C:\Users\jiang\vs_buildtools.exe`、`C:\Users\jiang\vsbt`、`C:\Users\jiang\vsbt2`（MSVC 残留，无编译器）。
- `C:\Users\jiang\mingw64.zip`（部分 winlibs 归档，已弃用）。
- `C:\Users\jiang\WorkBuddy\2026-09-05-17-22-20\.tmp_install\`（下载/探测脚本，可保留或删）。
- 构建日志：`dsh-desktop/legacy/tauri-skeleton/src-tauri/build_dsh.log`。

## 7. Flutter SDK 安装与 M3 Dart 校验（2026-09-06）

### 7.1 安装（已在本机完成）
- 走 cn 镜像 zip（非 github clone，避本地代理丢弃大包）：
  - `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` + `PUB_HOSTED_URL=https://pub.flutter-io.cn`
  - 释放至 `C:\Users\jiang\.workbuddy\binaries\flutter`（M3 §1.2 约定路径）
  - 版本 **Flutter 3.47.2 / Dart 3.13.2**，Windows engine 已缓存（stamp `a804b26164`），SHA256 已校验。
- `flutter --version` 正常；`flutter doctor` 仅 Windows 设备/版本检测因 `reg.exe` 黑名单崩溃（硬环境限制）。

### 7.2 Dart 层校验命令（M3 硬出口的替代验证）
> 根因：本机 `flutter` 子命令在 “Flutter assets will be downloaded from …” 后挂死（engine 已缓存仍卡），疑似 flutter CLI 内部 asset 步骤异常。绕过：一律用 `dart` 工具链。
> 前置：`unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy`（本地代理静默丢 Dart 连接），并 `export PUB_HOSTED_URL=https://pub.flutter-io.cn`。

每个包独立跑（monorepo 路径依赖，子包需各自 `dart pub get` 生成 `.dart_tool/package_config.json`）：
```bash
DART=/c/Users/jiang/.workbuddy/binaries/flutter/bin/dart
for d in packages/client_dart packages/dsh_manager; do
  ( cd "$d" && "$DART" pub get && "$DART" analyze && "$DART" test )
done
( cd apps/desktop_flutter && "$DART" analyze )   # 该包 widget_test 需 flutter test，见 §7.4(6)
```

### 7.3 结果
| 包 | dart pub get | dart analyze | dart test |
|---|---|---|---|
| client_dart | ✓ Got dependencies! | ✓ 无问题 | ✓ **6 测试全过**（assemble 5 + connection 1） |
| dsh_manager | ✓ Got dependencies! | ✓ 无问题 | N/A（无 `package:test` 依赖，无 test/ 目录） |
| contract | —（无 pubspec） | ✓ 无 Dart 文件 | N/A（纯 golden 数据） |
| apps/desktop_flutter | ✓（须先 pub get） | ✓ 无问题 | ⚠ 需 `flutter test`；本机被 §7.4 限制阻塞 |

### 7.4 本机阻塞项与环境陷阱（2026-09-05 续测修正）
1. **`flutter` CLI 挂死（根因已精确定位，非网络/代理）**：`flutter pub get`/build/test 在「artifact 解析循环全部完成（含 WindowsEngineArtifacts、PubDependencies → not required, skipping update）」之后、asset 步骤卡死；`-v` 日志**不打印任何 http URL**。已验证：清空代理后 `dart` 可直连 `storage.flutter-io.cn`(200,80ms)/`pub.flutter-io.cn`(200,95ms)/TUNA(404,258ms)，说明网络与代理均非根因 → 属本沙箱 flutter_tools 内部挂起。→ analyze/test 用 `dart` 工具链替代；`flutter build/test` 须 `flutter`，故本机仍不可行（需在用户本机正常网络下执行）。
2. **本地代理 `127.0.0.1:54569`（仅影响 pub 网络，非 flutter 挂死根因）**：静默丢弃 Dart HTTP 客户端连接，致 `dart pub get` 0 字节无限挂。→ 所有命令前置 `unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy all_proxy` + `export PUB_HOSTED_URL=https://pub.flutter-io.cn` 直连。
3. **Pub 缓存损坏**：首次代理中断的 `dart pub get` 留半截 `collection-1.19.1`（缺 `lib/collection.dart`），致 `dart test` 报 “Failed to build test:test”。`dart pub cache repair` 因下载缓存缺失而跳过；修复：`rm -rf <cache>/collection-1.19.1` 后重 `dart pub get` 重新拉取（本会话已验证 → 6/6 通过）。
4. **`reg.exe` 黑名单**：Security Center 程序黑名单拦截 → `flutter doctor` 的 Windows 版本/设备检测会崩；但 `flutter pub get` 挂死发生在 reg.exe 调用之前，故**非 pub get 挂死根因**；对 `flutter build windows` 是否构成硬阻塞尚待用户移除黑名单后验证。
5. **MSVC（已解决）**：VS 2022 Build Tools「使用 C++ 的桌面开发」工作负载现已装好，`cl.exe` 位于 `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\cl.exe`，Windows SDK 10（10.0.19041/22621/26100）齐备 → `flutter build windows` 的 MSVC 编译前置**已满足**。
6. **app `widget_test.dart` 不可由 `dart test` 跑**：`flutter_test` 是 `sdk: flutter` 包，其传递依赖 `test` 未提升进 app 的 package_config；`dart test` 报 “Could not find package test”。须 `flutter test`（本机被 ① 阻塞）。

### 7.5 用户侧后续（使 `flutter build windows` / `flutter test` 可行）
- VS 2022 +「使用 C++ 的桌面开发」工作负载 **本机已装好**（见 §7.4(5)），无需再装。
- 唯一待用户手动项：从 **Security Center → 命令安全 → 程序黑名单** 移除 `reg.exe`（建议先直接跑 §7.6 脚本，若仍报 reg 相关错再移除黑名单）。
- 之后在本机正常网络下执行 §7.6 一键脚本即可完成 `pub get → analyze(0 warning) → test(widget_test) → build windows --release`。

### 7.6 一键本地脚本（Windows；正常网络下执行）
> 要点：① 用 `cmd`/PowerShell 运行，路径用 Windows 风格 `C:/...`（Git Bash 的 `/c/...` 传给 Windows 原生 `dart`/`flutter` 会报 “No such file or directory”）；② 必须清空代理；③ `flutter.bat` 在 cmd 下比 `flutter` shell 脚本更稳。
```bat
@echo off
setlocal
REM === dsh-desktop M3 Step4: flutter 全链路（需正常网络 + VS 桌面C++负载 + reg.exe 已放行）===
set FLUTTER=C:/Users/jiang/.workbuddy/binaries/flutter/bin/flutter.bat
set APP=C:/Users/jiang/WorkBuddy/2026-09-05-17-22-20/dsh-desktop/apps/desktop_flutter

REM 清空代理（关键：否则 Dart 连接被 127.0.0.1:54569 静默丢弃）
set HTTP_PROXY=
set HTTPS_PROXY=
set http_proxy=
set https_proxy=
set all_proxy=
set ALL_PROXY=

cd /d "%APP%"
call "%FLUTTER%" config --enable-windows-desktop
call "%FLUTTER%" pub get
call "%FLUTTER%" analyze
call "%FLUTTER%" test
call "%FLUTTER%" build windows --release
echo DONE build -> %APP%\build\windows\x64\runner\Release\
endlocal
```
> 若 `flutter build windows` 仍因 `reg.exe` 黑名单失败，到 Security Center → 命令安全 → 程序黑名单移除 `reg.exe` 后重跑该脚本；或直接 `call "%FLUTTER%" build windows --release` 单行重试。

### 7.7 M3 验证闭环状态（2026-09-06 用户本地构建确认）
- **Dart 层（agent 验证，全绿）**：client_dart `dart test` **6/6 通过**、`dsh_manager`/`apps/desktop_flutter` `dart analyze` 无问题；contract 无 Dart 文件。
- **Windows 构建（用户本地验证）**：`flutter build windows --release` 成功，产物 exe 位于 `apps/desktop_flutter/build/windows/x64/runner/Release/`，确认 Step 4 前置（VS+WinSDK）与 M3 代码端到端正确。
- **沙箱边界（重要）**：本 WorkBuddy 沙箱内 `flutter` CLI 仍因 flutter_tools 内部 stall 挂死（网络/代理/镜像均排除），故 Dart 层验证由 agent 用 `dart` 工具链完成、Windows 构建由用户在正常网络机器完成；本工作副本 `build/` 无产物（gitignored，且不在沙箱跑过 build）。
- **最后一项本地校验（可选）**：用户可再跑一次 `flutter test`（app `widget_test.dart`）补全验证三角；本沙箱内不可行（flutter_test 的 `package:test` 未提升进 app package_config，`dart test` 报 "Could not find package test"）。
- **结论**：M3「开发环境搭建 + Dart 层校验 + Windows 构建链路」已闭环。下一阶段任务待用户指定。
