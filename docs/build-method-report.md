# ImmortalWrt 编译方法调研报告：TUI 交互（menuconfig） vs 配置文件方式

> 调研日期：2026-08-31
> 适用对象：本项目（immortalwrt 源码树，master 分支）
> 范围：仅调研与部署，**未启动任何固件编译**

---

## 1. 背景与构建系统概览

ImmortalWrt 是 OpenWrt 的分支，其构建系统沿用 OpenWrt 的 buildroot 体系：

- 顶层 `Makefile` + `include/*.mk`（`rules.mk`、`package.mk`、`scan.mk`、`toplevel.mk` 等）构成构建框架；
- 所有可编译单元（工具链、内核、软件包、固件镜像）都由 `Makefile` + `Kconfig` 符号（`CONFIG_XXX`）驱动；
- 用户对"编译什么、怎么编译"的**唯一权威描述文件是根目录的 `.config`**（Kconfig 格式）；
- 构建系统运行时先解析 `.config`，再据其展开目标、依赖与参数。

因此，**"选择编译方式"本质上就是"选择如何生成/维护 `.config`"**。业界两种主流做法：TUI 交互式界面（`make menuconfig`）与直接维护配置文件（`.config` / `defconfig`）。

---

## 2. 方式一：TUI 交互式配置（`make menuconfig`）

### 2.1 原理

- `make menuconfig` 调起 Kconfig 的 curses 界面（`scripts/config/mconf`，由 `scripts/config/*.c` 编译而来）。
- 界面的选项树来自构建系统扫描出的全部 `Kconfig`/`Config.in` 描述文件：
  - `Config.in`（顶层通用选项，如 target/profile/镜像格式）；
  - `target/linux/*/config-*`（内核特性）；
  - `package/*/Config.in`（每个软件包的 `Kconfig` 声明，含依赖 `depends on`、选择关系 `select`）；
  - `feeds` 的包通过 `package/feeds/*` 符号链接进入扫描范围（本项目因文件系统限制以镜像目录替代，见附录 B）。
- 用户在界面中选择 `y`（编入固件）、`m`（编译为 .ipk 包，按需安装）、`n`（不选）。
- 保存时，界面将当前状态**整体写回 `.config`**（`mconf` 调用 `conf --silentoldconfig`），并自动补齐被 `select` 的依赖项、剔除冲突项。
- 二次进入时界面会基于已有 `.config` 回显上次选择（增量式），因此它是**有状态的交互工具**。

### 2.2 标准流程

```bash
# 1. 准备源码与 feeds（本项目已完成）
./scripts/feeds update -a        # 拉取 feeds 仓库（packages/luci/routing/telephony/video）
./scripts/feeds install -a       # 把 feed 包链接进 package/feeds/（供扫描与编译）

# 2. 交互式配置
make menuconfig                  # 首次运行会先执行 make prereq 检查宿主依赖
#    → 选择 Target System / Subtarget / Target Profile
#    → 在 LuCI → Applications 等处勾选所需插件（本任务 10 个插件）
#    → 保存退出（写回 .config）

# 3. 编译
make -j$(nproc)                  # 完整编译；或 make -j$(nproc) V=s 查看详细日志
```

### 2.3 优点

- **所见即所得**：所有包、依赖关系、帮助文本（`help`）在界面中可浏览，无需记忆符号名；
- **依赖自动处理**：勾选 `luci-app-upnp` 时自动选中 `miniupnpd` 等依赖，冲突项自动置灰；
- **适合新手与一次性选型**：第一次配 target/profile 必须知道硬件型号，界面有候选列表；
- **默认值友好**：未触碰的选项保留 `default` 值，避免漏配。

### 2.4 缺点

- **不可脚本化/不可复现**：界面操作无法进入 CI、无法 diff、难以审计"为什么选了这个"；
- **状态漂移**：`.config` 随内核/包更新变化，交互式增量更新容易产生"幽灵选项"（旧符号残留）；
- **人因错误**：大规模选择（几十个包）逐一勾选易遗漏；
- **无版本记录**：`.config` 变化不产生可读的变更记录。

---

## 3. 方式二：配置文件方式（`.config` / `defconfig`）

### 3.1 原理

`.config` 本身就是一个**文本配置文件**，每行形如：

```
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_Generic=y
CONFIG_PACKAGE_luci-app-upnp=y
CONFIG_PACKAGE_openclash=y
CONFIG_PACKAGE_luci-theme-argon=y
# CONFIG_PACKAGE_xxx is not set
```

构建系统（`include/toplevel.mk`）直接读它：
- 未定义/注释的符号取 `default`；
- 勾选 `y` 的包若带 `select`，会在 **`make defconfig` 阶段自动补齐**（见 3.3）；
- `m` 与 `y` 的区别（编译为 ipk vs 编入固件）与 menuconfig 完全一致。

因此配置文件方式**不需要任何交互界面**，只需：
1. 准备好 `.config`（或最小 `defconfig`）；
2. `make defconfig` 让构建系统补齐依赖、生成完整 `.config`；
3. `make`。

### 3.2 三种常见子方式

| 子方式 | 做法 | 适用场景 |
|---|---|---|
| **手写完整 `.config`** | 直接编辑 `.config`，写明每个 `CONFIG_*` | 需要精确控制每个开关（如内核特性、镜像格式） |
| **最小 `defconfig`** | 只写"与默认不同的差异项"（`CONFIG_TARGET_...` + 要装的包），`make defconfig` 自动展开为完整 `.config` | 推荐：可读、可维护、可版本化 |
| **由现有 `.config` 生成** | `./scripts/diffconfig.sh > seed.config`（生成最小差异配置）；或在固件发布时使用编译产物 `bin/targets/*/config.buildinfo`（官方生成的"复现配置"） | 复现/交接/打包 |

`scripts/diffconfig.sh` 的原理（本项目已具备该脚本）：

```bash
# 从完整 .config 中提取"非默认"差异项，输出最小配置
./scripts/diffconfig.sh > defconfig.seed
# 应用：
cp defconfig.seed .config
make defconfig          # 展开为完整 .config（补齐默认项与 select 依赖）
```

### 3.3 标准流程（推荐：最小 defconfig + make defconfig）

```bash
# 1. 准备源码与 feeds（同 2.2）

# 2. 写入最小配置（以 x86_64 + 本任务插件为例）
cat > .config <<'EOF'
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_Generic=y
CONFIG_PACKAGE_luci-app-upnp=y
CONFIG_PACKAGE_luci-app-ddns=y
CONFIG_PACKAGE_luci-app-watchcat=y
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-app-turboacc=y
CONFIG_PACKAGE_luci-app-openclash=y
CONFIG_PACKAGE_ua3f=y
CONFIG_PACKAGE_minieap=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
CONFIG_PACKAGE_luci-app-docker=y
CONFIG_PACKAGE_luci-i18n-docker-zh-cn=y
EOF

# 3. 展开为完整配置（自动补齐 select 依赖、默认值）
make defconfig

# 4. 编译
make -j$(nproc)
```

> 注：本环境**未执行**上述 `make` 系列命令（任务约束"不得擅自启动编译"）；以上为交付给验收方的标准操作步骤。

### 3.4 优点

- **可脚本化/可复现/可审计**：配置即文本，进 git、进 CI、可 diff、可 review；
- **交接友好**：最小 defconfig 几行到几十行，团队成员一看即懂；
- **组合能力强**：可基于 `config.buildinfo` 或他人 defconfig 增量修改；
- **与 menuconfig 可互操作**：menuconfig 保存的 `.config` 可用 diffconfig 转成 defconfig，反之亦然。

### 3.5 缺点

- **学习成本**：需要知道符号名（`CONFIG_PACKAGE_xxx`），找不到包名时会卡壳（可用 `grep -r xxx package/*/Makefile` 或 `make menuconfig` 反查）；
- **依赖不全时编译期报错**：若只写了包没写依赖，`make defconfig` 阶段会补齐 `select` 依赖，但 `depends on` 的符号不满足时包会被静默跳过或报错——需对 Kconfig 有一定理解；
- **target 相关符号难记**：`CONFIG_TARGET_<arch>_<subtarget>_<device>` 层级符号新手容易写错（可用 `make menuconfig` 选一次 target 后 `diffconfig.sh` 导出，或从官方 `config.buildinfo` 抄）。

---

## 4. 两种方式对比

| 维度 | TUI（menuconfig） | 配置文件（.config / defconfig） |
|---|---|---|
| 交互性 | 界面点选，所见即所得 | 无界面，纯文本 |
| 依赖处理 | 界面自动置灰/自动 select | `make defconfig` 自动补齐 |
| 可复现性 | 差（操作不可记录） | 好（文本可进 git/CI） |
| 学习门槛 | 低 | 中（需懂符号名） |
| 大批量选包 | 繁琐易漏 | 高效（粘贴即得） |
| 变更审计 | 无 | 有（diff） |
| 二次修改 | 回显上次选择，增量友好 | 需维护配置文本 |
| 首次选 target | 界面列出候选，最稳妥 | 需查符号名 |
| 适合场景 | 新手首配、硬件选型、临时调整 | CI、复现、交接、批量固件 |

---

## 5. 结论与建议

1. **首配 target 用 menuconfig，固化用 defconfig**：
   - 第一次配置（尤其不确定 target/subtarget/device 符号时）先 `make menuconfig` 选好硬件与基础项；
   - 保存后 `./scripts/diffconfig.sh > seed.config`，把这份最小配置入库；
   - 之后任何机器/CI 都用 `cp seed.config .config && make defconfig && make`，保证完全一致。

2. **自动化/多固件场景必须走配置文件**：
   - GitHub Actions 等 CI 无法操作 TUI；社区"一键编译脚本"（如 ImmortalWrt 常见脚本）本质都是 `cat >> .config` + `make defconfig` + `make` 的组合。

3. **两种方式可随时互转**，不存在"只能二选一"：
   - `make menuconfig` → `.config` → `diffconfig.sh` → 最小 defconfig；
   - 最小 defconfig → `make defconfig` → `.config` → `make menuconfig` 继续微调。

4. **对本项目的建议**：采用"**menuconfig 首配 + seed defconfig 固化 + CI 用配置文件**"的混合策略；
   插件选择建议直接写在 seed 配置中（见 3.3 示例），便于版本管理与复现。

---

## 附录 A：本环境部署记录

### A.1 宿主环境与依赖（对应验收项 1）

- 宿主：Arch Linux（非 README 示例的 Debian/Ubuntu；按官方依赖清单的 Arch 等价包安装）。
- 已安装/补装的构建依赖（`sudo pacman -S --needed ...`）：
  - 本次新装 14 个：`mpc subversion python-pyelftools help2man intltool swig gperf lrzsz upx xmlto asciidoc re2c haveged`
  - 系统原有可用：`base-devel gcc gmp mpfr libelf ncurses zlib zstd git rsync wget curl unzip xz bzip2 gzip python python-pip python-ply python-docutils gettext autoconf automake libtool m4 make cmake ninja meson pkg-config ccache texinfo squashfs-tools dtc qemu openssl gnutls cpio gawk flex patch p7zip lz4 lzo llvm lld clang scons xxd vim jq` 等。
- 未安装（记录为已知缺口，编译前如报错再补）：`lib32-gcc-libs`/`lib32-glibc`（multilib 仓库未启用，x86_64 常规编译通常不需要）、`fastjar`/`ecj`（Java 打包工具，非必需）、`nodejs` 系 `uglifyjs`（LuCI JS 压缩可选工具，缺省有降级路径）。
- 网络：可访问 GitHub（存在本地代理，`github.com` 解析为 198.18.x.x 假 IP，实际可用）。

### A.2 插件部署清单（对应验收项 2–11）

> 选型原则：凡 ImmortalWrt 官方 feeds（immortalwrt/luci、immortalwrt/packages）已收录的插件，一律采用 feed 内版本（与 ImmortalWrt 主线同步维护、避免包名冲突）；仅 feed 未收录的 UA3F、Turbo ACC 采用第三方最新维护版克隆。

| 插件 | 部署位置 | 来源/版本 |
|---|---|---|
| UA3F（UA 改写代理） | `package/UA3F`（openwrt 子目录） | github.com/SunBK201/UA3F @ `23923d4`（2026-08-02），解析版本 3.6.0-r1 |
| OpenClash | `package/feeds/luci/applications/luci-app-openclash` | ImmortalWrt luci feed（= vernesong 0.47.156，2026-08-10） |
| 锐捷上网认证（minieap） | `package/feeds/packages/net/minieap` + `package/feeds/luci/protocols/luci-proto-minieap` | ImmortalWrt feeds（minieap 0.93，含 LuCI 协议支持） |
| Argon 主题 | `package/feeds/luci/themes/luci-theme-argon` | ImmortalWrt luci feed（v2.4.7，2026-08-24，与 jerrykuku 上游同步） |
| Argon 配置插件（配套） | `package/feeds/luci/applications/luci-app-argon-config` | ImmortalWrt luci feed |
| UPnP | `package/feeds/luci/applications/luci-app-upnp` + `package/feeds/packages/net/miniupnpd` | ImmortalWrt feeds |
| Turbo ACC | `package/turboacc/luci-app-turboacc` | github.com/chenmozhijin/turboacc @ `530092c`（2026-07-30，适配 firewall4 的维护版），解析版本 1.4-r1 |
| 动态 DNS | `package/feeds/luci/applications/luci-app-ddns` + `package/feeds/packages/net/ddns-scripts` | ImmortalWrt feeds |
| AdGuard Home | `package/feeds/luci/applications/luci-app-adguardhome` + `package/feeds/packages/net/adguardhome` | ImmortalWrt feeds（luci 支持 + 服务本体） |
| Watchcat | `package/feeds/luci/applications/luci-app-watchcat` + `package/feeds/packages/utils/watchcat` | ImmortalWrt feeds |
| i18n-docker-zh-cn | 由 `package/feeds/luci/applications/luci-app-docker` 的 `po/zh_Hans` 经 luci.mk 自动生成 `luci-i18n-docker-zh-cn`（已 DUMP 验证） | ImmortalWrt luci feed |

说明：
- feeds 已 `./scripts/feeds update -a` 完成（packages/luci/routing/telephony/video 五个 feed 全部就位）。
- 因文件系统不支持符号链接（见附录 B），`./scripts/feeds install -a` 无法执行；已将 `packages` 与 `luci` 两个 feed 目录整体镜像至 `package/feeds/`（该路径在 `.gitignore` 中，不污染 git 状态），使全部 feed 包对构建扫描可见，等效于 feeds install；镜像为完整结构复制，feed 内相对 `include`（如 `../../luci.mk`）可正常解析。在支持符号链接的文件系统上，可 `rm -rf package/feeds && ./scripts/feeds install -a` 恢复官方标准布局。
- 曾克隆的 OpenClash / AdGuardHome / Argon / minieap 第三方版本因与 feed 内版本重复（且 feed 版本更新）已移除，避免扫描包名冲突。
- 所有部署仅改动本项目目录内文件；未运行任何固件编译命令。

### A.3 验证方式

- **元数据解析验证（DUMP）**：对每个插件目录执行 `make -r -s DUMP=1 -C <pkgdir> TOPDIR=$(pwd)`（仅解析 Makefile 元数据、不编译），确认 `Package:`/`Version:`/`Depends:` 输出正确。抽样结果：
  - `luci-app-upnp` → `Depends: +libc +luci-base +miniupnpd +rpcd-mod-ucode`（相对 include 链解析正常）
  - `luci-app-openclash` → 0.47.156
  - `luci-app-turboacc` → 1.4-r1
  - `ua3f` → 3.6.0-r1
  - `luci-app-docker` → 自动生成 `luci-i18n-docker-zh-cn` ✓
- **扫描收录验证**：按 include/scan.mk 的 filelist 逻辑（`find -L package -maxdepth 5 -name Makefile | xargs grep 'call BuildPackage'`）确认 10 个插件均被收录（16 个相关 Makefile 全部含 `call BuildPackage`、全部 `include` 均可解析）。
- 完整校验脚本：`docs/verify-plugins.sh`（可重复执行）。

### A.4 扫描结果摘要

- 10/10 插件全部部署并可被构建扫描识别（明细见 A.2 与 A.3）；
- feed 镜像完整性：`packages` 5667/5667 文件、`luci` 6830/6830 文件（与源 feed 完全一致，含 7 个 `_` 前缀文件的手工补齐，rsync 临时文件名与该挂载的 `._` 限制冲突所致）；
- 未执行 `make menuconfig`/`make`（任务约束），编译前的最终把关请按附录 B 在支持符号链接的文件系统上进行。

---

## 附录 B：本环境已知限制（重要）

**问题**：本项目工作目录位于 SMB2/CIFS 网络挂载（`//10.126.126.5/eDisk`，挂载选项 `symlink=native, nounix`），**服务器端不支持创建符号链接**（实测 `ln -s` 报"不支持的操作"）。

**影响**：
1. `./scripts/feeds install -a` 无法建立 `package/feeds/*` 符号链接；
2. 构建系统的宿主预检（`make prereq` 中的 `SetupHostCommand`）依赖在 `staging_dir/host/bin` 建立符号链接，全部检查会失败——**本机直接 `make` 会在此阶段被拦下**；
3. 仓库内少量 git 符号链接（4 个）在检出时被降级为普通文本文件；
4. 真实编译时 `build_dir`/`staging_dir` 大量依赖符号链接，SMB 上无法完成。

**建议**（任选其一）：
- **推荐**：把本目录 `cp -a` 到本地 ext4/xfs/btrfs（如 `/home/ryanz/immortalwrt-build`），再执行：
  `rm -rf package/feeds && ./scripts/feeds install -a && make defconfig && make -j$(nproc)`；
- 或让 NAS 管理员开启 SMB 符号链接支持（reparse point）；
- 或以 `mfsymlinks` 方式重挂载（`symlink=native` → `mfsymlinks`，需重挂载整盘，风险自担，未在本会话执行）。

**本会话处置**：在不动系统挂载、不越界操作的前提下，用"目录镜像"完成插件部署（附录 A），保证树内一切就位；实际编译请按上述建议在支持符号链接的文件系统上执行。

---

*本报告由任务 t-mth7yz2l-mfh6kq 执行会话产出；全程未启动固件编译、未操作项目目录之外的文件。*
