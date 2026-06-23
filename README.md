# rvoe — RISC-V Secure Boot in openEuler 

基于 QEMU 的 RISC-V UEFI Secure Boot 实验环境，目标系统为 openEuler RISC-V。

**验证链**：`EDK2 (UEFI 固件) → Shim → GRUB → Linux Kernel`

Shim 的验证策略为 **HTTP-first**：优先通过 HTTP 远程验证服务（keyless signature）进行在线签名验证，失败后 fallback 到本地 DB 证书链验证。

## 架构概览

```
┌──────────────────────────────────────────────────┐
│                    QEMU (riscv64)                 │
│  ┌────────────────────────────────────────────┐  │
│  │         EDK2 UEFI Firmware (pflash)        │  │
│  │  SECURE_BOOT_ENABLE=TRUE                   │  │
│  │  Hash2DxeCrypto + TcpDxe + HttpDxe Drivers    │  │
│  │  VARS 已注入 PK/KEK/DB + SecureBoot=ON     │  │
│  └────────────────────────────────────────────┘  │
│                      │                            │
│                      ▼                            │
│  ┌────────────────────────────────────────────┐  │
│  │  Shim (BOOTRISCV64.EFI)                    │  │
│  │  ├─ 1. HTTP Keyless Verify → 10.0.2.2:8080/verify│  │
│  │  ├─ 2. DB CertChain Verify (fallback)             │  │
│  │  └─ 3. Vendor Cert Verify (fallback)          │  │
│  └────────────────────────────────────────────┘  │
│                      │                            │
│                      ▼                            │
│  ┌────────────────────────────────────────────┐  │
│  │  GRUB (grubriscv64.efi) + grub.cfg         │  │
│  │  (RISC-V origin grub2-mkimage built and signed)  │  │
│  └────────────────────────────────────────────┘  │
│                      │                            │
│                      ▼                            │
│  ┌────────────────────────────────────────────┐  │
│  │  Linux Kernel (sbsign signed)              │  │
│  │  + openEuler rootfs (ext4)                  │  │
│  └────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
         │                                ▲
         │  QEMU user-net (10.0.2.2)      │
         └────────────────────────────────┘
              HTTP POST /verify
     ┌────────────────────────────────────┐
     │   Remote Verification Service      │
     │   (Run on Host, Listening 0.0.0.0:8080) │
     └────────────────────────────────────┘
```

**网络驱动加载链**：
```
Shell (startup.nsh)
  └→ load Hash2DxeCrypto.efi  (提供 gEfiHash2ProtocolGuid — TcpDxe 依赖)
     └→ load TcpDxe.efi        (提供 EFI_TCP4_PROTOCOL — HttpDxe 依赖)
        └→ load HttpDxe.efi    (提供 EFI_HTTP_PROTOCOL — Shim HTTP 验证用)
           └→ fs0:\EFI\BOOT\BOOTRISCV64.EFI (Shim)
```

## 目录结构

```
rvoe/
├── rv_boot.sh                  # QEMU 启动脚本
├── script/
│   ├── 0_init_edk/                 # EDK2 初始化
│   │   ├── setup-edk2.sh       #   clone EDK2 + patch 
│   │   ├── edk2-riscv.patch    #   RISC-V Secure Boot patch
│   │   └── edk2-base-commit.txt #  EDK2 基线 commit
│   ├── 1_init_keys/                 # EDK2 初始化
│   │   ├── setup-keys.sh       #   clone EDK2 + patch 
│   ├── sign_all.sh             # 批量签名 EFI 组件
│   ├── fix_reloc.py            # 修复 PE .reloc 段 Page RVA
│   └── images/
│       └── RiscV_OpenEuler_New.sh  # 构建 RiscV openEuler 磁盘镜像
├── shimsrc/                    # Shim 源码 (子模块, 分支 riscv64)
│   └── gnu-efi/               #   gnu-efi (子模块, 分支 osignRV)
├── artifact/                   # 构建产物 (实验用)
│   ├── ovmf/                   #   EDK2 固件 (32MB CODE + 32MB VARS)
│   ├── shim/                   #   Shim EFI 文件 + BOOTRISCV64.CSV
│   ├── drivers/                #   网络驱动 EFI (已签名)
│   ├── keys/                   #   UEFI Secure Boot 密钥 (PK/KEK/DB)
│   ├── images/                 #   磁盘镜像
│   └── oerv_rootfs_backup.tar.gz  # rootfs 离线备份
└── .gitmodules
```

## 宿主机环境要求

| 依赖 | 用途 |
|------|------|
| Ubuntu 22.04+ / Debian 12+ (x86_64) | 宿主机 OS |
| `gcc-riscv64-linux-gnu` | RISC-V 交叉编译工具链 |
| `qemu-system-riscv64` (≥ 9.0) | RISC-V 虚拟机 (需要 `-cpu rva23s64`) |
| `qemu-user-static` | 在 x86 宿主机上运行 RISC-V 原生 grub2-mkimage |
| `sbsigntool` | 签名/验证 EFI PE 文件 |
| `virt-fw-vars` | 向 UEFI 固件 VARS 注入 PK/KEK/DB 密钥 |
| `python3` | 运行 fix_reloc.py 和 SizeOfImage 扩展脚本 |
| `parted`, `dosfstools`, `mtools` | 创建 GPT 磁盘镜像 |
| `iconv` (glibc 自带) | 生成 UCS-2LE 编码的 CSV 文件 |
| Docker (可选) | rootfs 在线安装 (离线模式不需要) |

一键安装：

```bash
sudo apt-get update
sudo apt-get install -y \
    gcc-riscv64-linux-gnu \
    qemu-system-riscv64 \
    qemu-user-static \
    sbsigntool \
    virt-firmware \
    python3 \
    parted dosfstools mtools \
    uuid-runtime \
    build-essential \
    git curl \
    openssl
```

---

## 全新环境完整部署步骤

### 步骤 0：克隆仓库

```bash
git clone --recursive https://code.osssc.ac.cn/digital-signature/secure-boot/rvoe.git
cd rvoe
```

> `--recursive` 自动拉取 `shimsrc`（[tearizz/shimsrc](https://github.com/tearizz/shimsrc)，`riscv64` 分支）及其子模块 `gnu-efi`（`osignRV` 分支）。

如果已克隆但未拉取子模块：

```bash
git submodule update --init --recursive
```

---

### 步骤 1：构建 EDK2 固件

#### 1.1 克隆 EDK2 并打补丁

```bash
./script/0_init_edk/setup-edk2.sh
```

此脚本会：
- 克隆 [tianocore/edk2](https://github.com/tianocore/edk2) 到 `artifact/edk2-riscv/`
- 检出基线 commit（记录在 `script/0_init_edk/edk2-base-commit.txt`）
- 应用 `script/0_init_edk/edk2-riscv.patch`，修改内容：

| 修改项 | 文件 | 说明 |
|--------|------|------|
| `SECURE_BOOT_ENABLE = TRUE` | `RiscVVirtQemu.dsc` | 启用 Secure Boot（**必须**，默认 FALSE 则固件不编译 SecurityStubDxe 等驱动） |
| `NETWORK_HTTP_BOOT_ENABLE = TRUE` | `RiscVVirtQemu.dsc` | 启用 HttpDxe（**必须**，默认 FALSE 则 Shim 找不到 `EFI_HTTP_PROTOCOL`） |
| `Hash2DxeCrypto.inf` | `RiscVVirtQemu.dsc` + `.fdf` | TcpDxe 的 Depex 依赖此驱动，缺失则 TcpDxe 报 `Not Found` |

#### 1.2 编译 EDK2

```bash
cd artifact/edk2-riscv
export WORKSPACE=$PWD
export EDK_TOOLS_PATH=$WORKSPACE/BaseTools
export GCC_RISCV64_PREFIX=riscv64-linux-gnu-
export PATH=$EDK_TOOLS_PATH/BinWrappers/PosixLike:$PATH

make -C BaseTools -j$(nproc)
source edksetup.sh

# Method1
python3 BaseTools/Source/Python/build/build.py \
    -p OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc \
    -a RISCV64 -t GCC -b RELEASE
# If method1 failed, try:
export PYTHON_COMMAND=python3
BaseTools/BinWrappers/PosixLike/build \
      -p OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc \
      -a RISCV64 -t GCC -b RELEASE

cd ../..
```

输出产物：
- `Build/RiscVVirtQemu/RELEASE_GCC/FV/RISCV_VIRT_CODE.fd` — 固件代码
- `Build/RiscVVirtQemu/RELEASE_GCC/FV/RISCV_VIRT_VARS.fd` — 固件变量模板

#### 1.3 部署固件 + 填充到 32MB

```bash
cd artifact/edk2-riscv

# 复制到 artifact/ovmf/
cp Build/RiscVVirtQemu/RELEASE_GCC/FV/RISCV_VIRT_CODE.fd ../ovmf/
cp Build/RiscVVirtQemu/RELEASE_GCC/FV/RISCV_VIRT_VARS.fd ../ovmf/

cd ../ovmf

# 创建备份
cp RISCV_VIRT_CODE rv_code_32m.fd
cp RISCV_VIRT_VARS rv_vars_32m.fd

# QEMU pflash 要求 32MB 对齐，填充
truncate -s 32M rv_code_32m.fd
truncate -s 32M rv_vars_32m.fd

cd ../..
```

#### 1.4 注入 PK/KEK/DB 密钥到固件 VARS（**关键步骤**）

EDK2 构建产出的 VARS 文件 **不含任何密钥**，必须手动注入：

```bash
bash script/1_init_keys/setup-keys.sh
```

> `--secure-boot` 标志会创建 PK/KEK/db/dbx 变量并设置 `SecureBootEnable=ON`。

> **注意**：仓库中已提供的 `artifact/ovmf/` 固件已经注入密钥，可直接使用。如果重新编译了 EDK2，必须执行此步骤。

---

### 步骤 2：构建 gnu-efi（RISC-V）

gnu-efi 的 Make 系统存在几个坑，需要特别注意：

```bash
cd shimsrc/gnu-efi

# ⚠️ 不要只用默认的 `make ARCH=riscv64` — 会构建 apps 子目录并失败
# 原因1: Make.defaults 第71行 LD := $(CROSS_COMPILE)ld，使用裸 ld
#        传 LD=gcc 会导致 gcc 不理解 ld 的 flags
# 原因2: apps 子目录的 Makefile 会追加 --defsym=EFI_SUBSYSTEM=...，加剧问题
#
# 正确做法：只构建 lib, gnuefi, inc 三个子目录

make ARCH=riscv64 \
    CC=riscv64-linux-gnu-gcc \
    HOSTCC=gcc \
    TOPDIR=$(pwd) \
    -f $(pwd)/Makefile \
    lib gnuefi inc

# 验证输出
ls riscv64/lib/libefi.a
ls riscv64/gnuefi/libgnuefi.a
ls riscv64/gnuefi/crt0-efi-riscv64.o
```

#### 2.1 修改 gnu-efi 编译制品（**关键**）

Shim 的 Makefile 在链接时需要 `crt0-efi-riscv64-local.o`（即 crt0 的 local 变体）。
gnu-efi 默认只生成 `crt0-efi-riscv64.o`，需要手动复制：

```bash
cp riscv64/gnuefi/crt0-efi-riscv64.o \
   riscv64/gnuefi/crt0-efi-riscv64-local.o

cd ../..
```

---

### 步骤 3：构建 Shim

本仓库的 shimsrc 已包含所有必要的 RISC-V Secure Boot 修改：

| 修改位置 | 内容 |
|----------|------|
| `keyless-sign.c:657` | 远程验证 URL → `http://10.0.2.2:8080/verify` |
| `shim.c:704-726` | HTTP-first 验证顺序（先 HTTP 远程验证，失败后 fallback DB） |
| `http-request.c:167` | `load_network_drivers()` — 从 ESP 加载网络驱动 |
| `http-request.c:256-271` | HTTP binding 30 秒等待循环（确保网络栈就绪） |

```bash
cd shimsrc

# 将 DB 证书放入 shim 源码目录（构建时需要嵌入 Vendor Cert）
cp ../artifact/keys/DB.cer .

# 编译
make -j$(nproc) \
    ARCH=riscv64 \
    CROSS_COMPILE=riscv64-linux-gnu- \
    COMPILER=gcc \
    EFIDIR=openEuler \
    VENDOR_CERT_FILE=DB.cer \
    ENABLE_SHIM_CERT=y

cd ..
```

#### 3.1 安装 Shim 产物到 artifact

```bash
mkdir -p artifact/shim

# 复制主文件
cp shimsrc/shimriscv64.efi artifact/shim/
cp shimsrc/mmriscv64.efi  artifact/shim/
# fbriscv64.efi (fallback) 可选
cp shimsrc/fbriscv64.efi artifact/shim/ 2>/dev/null || true

# 生成 BOOTRISCV64.CSV （⚠️ 必须用 UCS-2LE 编码！）
echo "shimriscv64.efi,openEuler,,This is the boot entry for openEuler" \
    | iconv -t UCS-2LE > artifact/shim/BOOTRISCV64.CSV
```

> CSV 格式：`<shim名称>,<OS标签>,,<描述>`，UCS-2LE 编码是 UEFI 规范要求。

---

### 步骤 4：提取网络驱动

即使固件已编译 Hash2DxeCrypto + TcpDxe + HttpDxe，仍然建议在 ESP 上放置已签名驱动作为双保险。
驱动必须从**同一 EDK2 版本**提取并签名：

```bash
mkdir -p artifact/drivers

EDK2_BUILD="artifact/edk2-riscv/Build/RiscVVirtQemu/RELEASE_GCC"

# 按依赖顺序：Hash2DxeCrypto → TcpDxe → HttpDxe
for drv in Hash2DxeCrypto TcpDxe HttpDxe; do
    find "$EDK2_BUILD" -name "${drv}.efi" -exec cp {} artifact/drivers/ \;
done
```

> 仓库 `artifact/drivers/` 中已提供预提取并签名的驱动文件，可直接使用。

---

### 步骤 5：签名所有 EFI 组件

```bash
./script/sign_all.sh
```

每个 EFI 文件的签名流程为：

```
sbattach --remove    (先移除已有签名)
  → fix_reloc        (修复 PE .reloc 段 Page RVA)
  → expand SizeOfImage (预扩展，为签名证书留空间)
  → sbsign           (用 DB.key 签名)
  → sbverify         (验证签名)
```

> **顺序至关重要**：`fix_reloc` 修改 PE 文件会破坏已有签名，所以必须先移除旧签名，再 fix_reloc，最后重新签名。

**必须签名的文件**：

| 文件 | 来源 | 说明 |
|------|------|------|
| `artifact/shim/shimriscv64.efi` | Shim 构建 | 主 Shim |
| `artifact/shim/mmriscv64.efi` | Shim 构建 | MokManager |
| `artifact/shim/fbriscv64.efi` | Shim 构建 | Fallback (可选) |
| `artifact/drivers/Hash2DxeCrypto.efi` | EDK2 Build | Hash2 服务 (TcpDxe 依赖) |
| `artifact/drivers/TcpDxe.efi` | EDK2 Build | TCP4 协议 (HttpDxe 依赖) |
| `artifact/drivers/HttpDxe.efi` | EDK2 Build | HTTP 协议 (Shim 远程验证用) |
| `artifact/images 中的 grubriscv64.efi` | 镜像构建时生成 | GRUB (脚本自动签名) |
| `rootfs 中的 vmlinuz-*` | Docker/离线 rootfs | Linux 内核 (脚本自动签名) |

**不需要签名的文件**：`initramfs-*.img` 是 cpio 归档，不是 PE 格式，`sbsign` 会报 `Invalid DOS header magic`。GRUB 不验证 initramfs 的签名。

---

### 步骤 6：准备 rootfs + 构建磁盘镜像

rootfs 有三种获取方式，镜像构建脚本按优先级自动选择：

| 优先级 | 方式 | 说明 |
|--------|------|------|
| 1 | 离线备份 | `artifact/oerv_rootfs_backup.tar.gz` 已存在则直接使用 |
| 2 | GitLab Package Registry | 设置环境变量自动下载 |
| 3 | Docker 在线安装 | `--docker` 参数触发 (约 10-20 分钟，需网络) |

```bash
# 方式 1（推荐）：放置 rootfs 备份
cp /path/to/oerv_rootfs_backup.tar.gz artifact/

# 方式 2：GitLab 下载
export GITLAB_PROJECT="<project_id>"
export GITLAB_TOKEN="<personal_access_token>"

# 方式 3：Docker 在线安装
# sudo ./script/images/RiscV_OpenEuler_New.sh --docker
```

然后构建磁盘镜像：

```bash
sudo ./script/images/RiscV_OpenEuler_New.sh
```

此脚本自动完成：
1. 创建 12GB GPT 磁盘（ESP 512MB FAT32 + rootfs ext4）
2. 部署 Shim + MokManager + CSV + 网络驱动 + startup.nsh 到 ESP
3. 安装 rootfs（离线解压或 Docker 在线安装）
4. 通过 `qemu-riscv64-static` 运行 RISC-V 原生 `grub2-mkimage` 构建 GRUB
5. 生成 QEMU virt DTB 并放入 `/boot/`
6. 创建 `grub.cfg`（**不含 `devicetree` 命令** — Secure Boot 下 GRUB lockdown 会阻止它，内核自动从 UEFI Configuration Table 读取 DTB）
7. 签名 GRUB + Linux 内核

输出：`artifact/images/RiscV_OpenEuler.img`

---

### 步骤 7：启动远程验证服务

Shim 的 HTTP-first 验证策略会优先向 `http://10.0.2.2:8080/verify` 发送 POST 请求（`10.0.2.2` 是 QEMU user-mode 网络下宿主机的固定地址）。

**接口规范**：

请求（POST `/verify`, Content-Type: `application/json`）：
```json
{
    "certificate": "<base64 DER 证书>",
    "payload": "<base64 Authenticode 哈希>",
    "signature": "<base64 PKCS#7 签名>"
}
```

响应：HTTP 200 = 验证通过，非 200 = 验证失败（Shim fallback 到 DB 本地验证）。

**最小可用服务器**（供测试）：

```bash
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{\"result\":\"yes\"}')
HTTPServer(('0.0.0.0', 8080), H).serve_forever()
" &
```

> ⚠️ 远程验证服务的完整实现不在本仓库中，以上是测试用桩。如需修改验证服务器地址，编辑 `shimsrc/keyless-sign.c:657` 后重新编译 Shim。

---

### 步骤 8：启动 QEMU

```bash
sudo ./rv_boot.sh --arch rv --kernel openEuler --secureboot
```

参数说明：

| 参数 | 可选值 | 说明 |
|------|--------|------|
| `-a, --arch` | `rv`, `x86` | 虚拟机架构 |
| `-k, --kernel` | `openEuler`, `ubuntu` | 启动的系统内核 |
| `--secureboot` | — | 启用安全启动 |
| `--unsecureboot` | — | 关闭安全启动 |

QEMU 以 `-nographic` 模式启动，串口输出直接连接到终端。按 `Ctrl+A X` 退出。

**默认 SSH 端口转发**：宿主机 `12055` → 虚拟机 `22`。

**预期启动日志**：
```
=== RISC-V Secure Boot: Loading Network Drivers ===
Image 'fs0:\EFI\BOOT\Hash2DxeCrypto.efi' loaded at XXX - Success
Image 'fs0:\EFI\BOOT\TcpDxe.efi' loaded at XXX - Success
Image 'fs0:\EFI\BOOT\HttpDxe.efi' loaded at XXX - Success
=== Starting Shim ===
Get http response body: {"result":"yes"}
GNU GRUB version 2.12
  Booting `openEuler RISC-V'
EFI stub: Booting Linux Kernel...
openEuler 24.03 (LTS)
openeuler-riscv login:
```

**VM 内验证 Secure Boot 已启用**：
```bash
mokutil --sb-state            # 应输出: SecureBoot enabled
# 或
cat /sys/firmware/efi/efivars/SecureBoot-* | hexdump -C | head -1
# 最后一个字节应为 01
```

---

## 一键流程总结

```bash
# 0. 克隆
git clone --recursive git@github.com:tearizz/rvoe.git && cd rvoe

# 1. 安装依赖
sudo apt-get update
sudo apt-get install -y gcc-riscv64-linux-gnu qemu-system-riscv64 \
    qemu-user-static sbsigntool virt-firmware python3 \
    parted dosfstools mtools uuid-runtime build-essential git curl openssl

# 2. 构建 EDK2（或使用 artifact/ovmf 中预编译的固件）
bash script/0_init_edk/setup-edk2.sh
cd artifact/edk2-riscv
export WORKSPACE=$PWD EDK_TOOLS_PATH=$WORKSPACE/BaseTools
export GCC_RISCV64_PREFIX=riscv64-linux-gnu-
export PATH=$EDK_TOOLS_PATH/BinWrappers/PosixLike:$PATH
make -C BaseTools -j$(nproc) && source edksetup.sh
python3 BaseTools/Source/Python/build/build.py \
    -p OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc -a RISCV64 -t GCC -b RELEASE
cd ../..
# 部署固件 + 填充 32MB + 注入密钥
bash script/1_init_keys/setup-keys.sh

# 3. 构建 gnu-efi（只构建 lib gnuefi inc）
cd shimsrc/gnu-efi
make ARCH=riscv64 CC=riscv64-linux-gnu-gcc HOSTCC=gcc \
    TOPDIR=$(pwd) -f $(pwd)/Makefile lib gnuefi inc
cp riscv64/gnuefi/crt0-efi-riscv64.o \
   riscv64/gnuefi/crt0-efi-riscv64-local.o
cd ../..

# 4. 构建 Shim（或使用 artifact/shim 中预编译的 EFI）
cd shimsrc
cp ../artifact/keys/DB.cer .
make -j$(nproc) ARCH=riscv64 CROSS_COMPILE=riscv64-linux-gnu- \
    COMPILER=gcc EFIDIR=openEuler VENDOR_CERT_FILE=DB.cer ENABLE_SHIM_CERT=y
cd ..
# 复制产物到 artifact/shim（见步骤 3.1）

# 5. 提取驱动 + 签名
mkdir -p artifact/drivers
find artifact/edk2-riscv/Build -name 'Hash2DxeCrypto.efi' -exec cp {} artifact/drivers/ \;
find artifact/edk2-riscv/Build -name 'TcpDxe.efi' -exec cp {} artifact/drivers/ \;
find artifact/edk2-riscv/Build -name 'HttpDxe.efi' -exec cp {} artifact/drivers/ \;
./script/sign_all.sh

# 6. 构建磁盘镜像
# 确保 artifact/oerv_rootfs_backup.tar.gz 已就位
sudo ./script/images/RiscV_OpenEuler_New.sh

# 7. 终端 1 — 启动远程验证服务
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.end_headers()
        self.wfile.write(b'{\"result\":\"yes\"}')
HTTPServer(('0.0.0.0', 8080), H).serve_forever()
" &

# 8. 终端 2 — 启动 QEMU
sudo ./rv_boot.sh --arch rv --kernel openEuler --secureboot
```

---

## QEMU 关键参数

| 参数 | 作用 |
|------|------|
| `-cpu rva23s64,sv39=on,zkr=true` | Zkr 扩展必须启用 (TcpDxe 的 RNG 依赖) |
| `-smp 1 -m 4G` | SMP=1 避免 GRUB relocation overflow；内存 >8G 也会触发 overflow |
| `pflash0` (read-only) | 固件 CODE (32MB, 含 OpenSBI) |
| `pflash1` (read-write) | 固件 VARS (32MB, 含 PK/KEK/DB 密钥) |
| `-netdev user` | QEMU 用户态网络 (Guest DHCP→10.0.2.15, Host→10.0.2.2) |

---

## 重要注意事项

### fix_reloc 问题

gnu-efi CRT0 通过 `dummy - label1` 计算 `.reloc` 段 Page RVA。当 `.data` VMA < `.reloc` VMA 时（RISC-V 链接脚本常见情况），结果为负值（`>= 0x80000000` 的无符号表示）。UEFI PE 加载器拒绝此类映像，报 `Command Error Status: Unsupported`。

`script/fix_reloc.py` 检测负值并将其修正为 `0x1000`。**必须对以下所有 EFI 执行 fix_reloc**：shimriscv64.efi, mmriscv64.efi, fbriscv64.efi, grubriscv64.efi。

`sign_all.sh` 已自动处理此步骤。

### GRUB 构建注意事项

- **必须用 RISC-V 原生 grub2-mkimage**：x86_64 宿主的 `grub-mkimage` 会产生 relocation overflow。镜像构建脚本通过 `qemu-riscv64-static` 运行 rootfs 中的原生 grub2-mkimage。
- **grub.cfg 不能包含 `devicetree`**：Secure Boot 下 GRUB lockdown 会阻止此命令。UEFI 固件会自动将 DTB 放入 Configuration Table，内核可直接读取。
- **initramfs 不签名**：`initramfs-*.img` 是 cpio 归档，`sbsign` 只处理 PE/COFF 格式。

### 安全启动签名链

```
UEFI 固件 ──[DB 证书]──→ 验证 Shim (BOOTRISCV64.EFI)
    │ 固件从 VARS 读取 DB，验证 Shim 的 PKCS#7 签名
    ▼
Shim ──[Vendor Cert + DB]──→ 验证 GRUB (grubriscv64.efi)
    │ HTTP 远程验证优先，失败 fallback DB 本地验证
    ▼
GRUB ──[shim_verify()]──→ 验证 Kernel (vmlinuz)
    │ 内核必须用 sbsign + DB.key 签名
    ▼
Linux Kernel → systemd → Login
```

**每一个环节的签名必须有效**，否则整条 Secure Boot 链断裂。

### sudo 权限

`RiscV_OpenEuler_New.sh` 需要 root（loopback 设备、mkfs、mount）。`rv_boot.sh` 用 `sudo -S` 执行 QEMU（pflash 需要 CAP_SYS_ADMIN）。建议配置免密码 sudo 或手动输入。

---

## 相关仓库

- [tearizz/rvoe](https://github.com/tearizz/rvoe) — 本项目（实验环境 + 构建脚本）
- [tearizz/shimsrc](https://github.com/tearizz/shimsrc) (分支 `riscv64`) — 修改后的 Shim 源码（HTTP-first 验证 + RISC-V 支持）
- [gnu-efi](https://git.code.sf.net/p/gnu-efi/code) (分支 `osignRV`) — RISC-V 签名支持的 EFI 开发工具链
- [tianocore/edk2](https://github.com/tianocore/edk2) — UEFI 固件参考实现
