# **SBENV** — RISC-V & x86_64 UEFI Secure Boot 实验环境

基于 QEMU 的多架构 UEFI Secure Boot 开发与测试环境。一份代码、一套密钥，同时支撑 **RISC-V 64** 和 **x86_64** 双架构的 Secure Boot 实验。

---

## 支持的实验环境

| # | 架构 | 操作系统 | 启动命令 |
|---|------|----------|----------|
| 1 | RISC-V 64 | openEuler 24.03 LTS | `sudo ./boot.sh --arch rv --os openEuler` |
| 2 | x86_64 | openEuler 24.03 LTS | `sudo ./boot.sh --arch x86 --os openEuler` |
| 3 | x86_64 | Ubuntu 22.04 (jammy) | `sudo ./boot.sh --arch x86 --os ubuntu` |

**验证链**:

```
EDK2 (OVMF 固件) → Shim → GRUB → Linux Kernel
```

---

## 架构概览

### RISC-V 实验环境

```
┌───────────────────────────────┐
│                   QEMU (riscv64)                             │
│  ┌───────────────────────────┐  │
│  │        EDK2 UEFI Firmware (pflash, 32MB)             │  │
│  │  SECURE_BOOT_ENABLE=TRUE                             │  │
│  │  NETWORK_HTTP_BOOT_ENABLE=TRUE                       │  │
│  │  Hash2DxeCrypto + TcpDxe + HttpDxe compiled in ovmf  │  │
│  │  VARS 已注入 PK/KEK/DB + SecureBoot=ON               │  │
│  └───────────────────────────┘  │
│                      │                                      │
│                      ▼                                      │
│  ┌───────────────────────────┐  │
│  │  UEFI Shell → startup.nsh                           │  │
│  │  ├─ load Hash2DxeCrypto.efi                        │  │
│  │  ├─ load TcpDxe.efi                                │  │
│  │  └─ load HttpDxe.efi                               │  │
│  └───────────────────────────┘  │
│                      │                                      │
│                      ▼                                      │
│  ┌───────────────────────────┐  │
│  │  Shim (BOOTRISCV64.EFI)                              │  │
│  │  ├─ 1. HTTP verify → 10.0.2.2:8080/verify         │  │
│  │  ├─ 2. DB Certchain verify (fallback)              │  │
│  │  └─ 3. Vendor Cert Verify (fallback)               │  │
│  └───────────────────────────┘  │
│                      │                                      │
│                      ▼                                      │
│  ┌───────────────────────────┐  │
│  │  GRUB (grubriscv64.efi, qemu-user built and signed   │  │
│  │  + grub.cfg                                          │  │
│  └───────────────────────────┘  │
│                      │                                      │
│                      ▼                                      │
│  ┌───────────────────────────┐  │
│  │  Linux Kernel (vmlinuz-*, sbsign signed)             │  │
│  │  + openEuler RISC-V rootfs (ext4)                    │  │
│  └───────────────────────────┘  │
└───────────────────────────────┘
         │
         │       HTTP POST /verify          ▲
         └─────────────────┘
            QEMU user-net (10.0.2.2 → Host)
```

### x86_64 实验环境

```
┌──────────────────────────────────┐
│                         QEMU (x86_64)                              │
│    ┌────────────────────────────┐    │
│    │        EDK2 OVMF Firmware (pflash, ~3.5MB)             │    │
│    │  SECURE_BOOT_ENABLE=TRUE                               │    │
│    │  VARS Inject PK/KEK/DB + SecureBoot=ON                 │    │
│    │  Already have network drivers, don't need startup.nsh  │    │
│    └────────────────────────────┘    │
│                      │                                            │
│                      ▼                                            │
│  ┌─────────────────────────────┐    │
│  │  Shim (BOOTX64.EFI / shimx64.efi)                        │    │
│  │  └─DB Certchain local verify(Standard UEFI Secure Boot)│    │
│  └─────────────────────────────┘    │
│                      │                                            │
│                      ▼                                            │
│  ┌─────────────────────────────┐    │
│  │  GRUB (grubx64.efi built and signed by host)             │    │
│  │  + grub.cfg                                              │    │
│  └─────────────────────────────┘    │
│                      │                                            │
│                      ▼                                            │
│  ┌─────────────────────────────┐    │
│  │  Linux Kernel (vmlinuz-* signed by sbsign)               │    │
│  │  + openEuler / Ubuntu rootfs (ext4)                      │    │
│  └─────────────────────────────┘    │
└──────────────────────────────────┘
```

---

## 目录结构

```
rvoe/
├── README.md
├── boot.sh                           # Unify QEMU Boot Entry
├── .gitmodules / .gitignore
│
├── shimsrc/                           # Shim Source (submodule)
│   └── gnu-efi/                      # gnu-efi  (submodule)
│   └── ...                           # shim code(main)
│
├── script/
│   ├── setup-edk2.sh                 # clone EDK2 + apply rv + x86 双 patch
│   ├── setup-keys.sh                 # generate PK/KEK/DB + inject rv & x86  VARS
│   ├── sign-rv.sh                    # risc-v EFI sign (fix_reloc)
│   ├── sign-x86.sh                   # x86_64 EFI sign
│   ├── image/
│   │   ├── build-rvoe.sh             # RISC-V + openEuler disk image
│   │   ├── build-x86oe.sh            # x86_64 + openEuler disk image
│   │   └── build-x86ubuntu.sh        # x86_64 + Ubuntu disk image
│   └── resources/
│       ├── edk2-riscv.patch          # RiscVVirtQemu: SB + HTTP + Hash2DxeCrypto
│       ├── edk2-x64.patch            # OvmfPkgX64: SB enable
│       ├── edk2-base-commit.txt      # make sure EDK2 base commit
│       └── fix_reloc.py              # RV PE .reloc Page RVA fix
│
└── artifact/                         # built artifact (tracked in git)
    ├── ovmf/                         # UEFI OVMF
    │   ├── rvcode.fd                   # RV CODE (OpenSBI)
    │   ├── rvvars.fd                   # RV VARS (PK/KEK/DB)
    │   ├── x86code.fd                  # x86 CODE
    │   └── x86vars.fd                  # x86 VARS (PK/KEK/DB)
    ├── shim/                         # shim .efi binary
    │   ├── shimriscv64.efi / mmriscv64.efi / fbriscv64.efi
    │   ├── shimx64.efi / mmx64.efi
    │   ├── BOOTRISCV64.CSV / BOOTX64.CSV
    ├── drivers/                      # riscv network drivers (x86 OVMF already contained)
    │   ├── Hash2DxeCrypto.efi / TcpDxe.efi / HttpDxe.efi
    ├── keys/                         # PK/KEK/DB keys
    │   └── PK/KEK/DB.{key,crt,cer}
    ├── images/                       # built disk image
    │   ├── RiscV_OpenEuler.img
    │   ├── x86_openEuler.img
    │   └── x86_ubuntu.img
    └── ..._rootfs_backup.tar.gz      # rootfs offline backup
```

---

## 宿主机环境要求

| 依赖 | 用途 | 最低版本 |
|------|------|----------|
| Ubuntu 22.04+ / Debian 12+ (x86_64) | 宿主机 OS | — |
| `gcc` + `build-essential` | x86_64 原生编译 (Shim, gnu-efi) | GCC 11+ |
| `gcc-riscv64-linux-gnu` | RISC-V 交叉编译工具链 | GCC 12+ |
| `qemu-system-riscv64` | RISC-V 虚拟机 | ≥ 9.0 (需 `-cpu rva23s64`) |
| `qemu-system-x86_64` | x86_64 虚拟机 | ≥ 6.0 (需 KVM 支持) |
| `qemu-user-static` | 在 x86 宿主机上运行 RISC-V 原生 grub2-mkimage | — |
| `sbsigntool` | 签名/验证 EFI PE 文件 (`sbsign`, `sbverify`, `sbattach`) | — |
| `virt-fw-vars` (virt-firmware) | 向 UEFI 固件 VARS 注入 PK/KEK/DB 密钥 | — |
| `python3` | 运行 fix_reloc.py 和 SizeOfImage 扩展脚本 | 3.8+ |
| `parted`, `dosfstools`, `mtools` | 创建 GPT 磁盘镜像 + FAT32 格式化 | — |
| `uuid-runtime` | `uuidgen` 生成密钥 GUID | — |
| `iconv` (glibc 自带) | 生成 UCS-2LE 编码的 CSV 文件 | — |
| `openssl` | 生成 RSA 密钥对 | — |
| `debootstrap` | x86 Ubuntu rootfs 在线安装 | — |
| `qemu-utils` | `qemu-img` 创建磁盘镜像 | — |
| Docker (可选) | openEuler rootfs 在线安装 (离线备份模式无需) | — |

### 一键安装

```bash
sudo apt-get update && sudo apt-get install -y \
    build-essential gcc-riscv64-linux-gnu \
    qemu-system-riscv64 qemu-system-x86_64 qemu-utils qemu-user-static \
    sbsigntool virt-firmware python3 \
    parted dosfstools mtools uuid-runtime git curl openssl \
    debootstrap
```

---

# 完整部署步骤

仓库 `artifact/` 中已提供预构建产物 (OVMF 固件、Shim EFI、密钥、驱动)。若使用预构建产物，可跳到 **步骤 5** (构建磁盘镜像) 或 **步骤 6** (启动)。

## 步骤 0：克隆仓库

```bash
git clone --recursive git@github.com:tearizz/rvoe.git
cd rvoe
```

`--recursive` 自动拉取 `shimsrc` 及其子模块 `gnu-efi`。

如果已克隆但未拉取子模块：

```bash
git submodule update --init --recursive
```

---

## 步骤 1：构建 EDK2 固件

> `artifact/ovmf/` 已提供预编译并注入密钥的固件，可直接使用。

### 1.1 克隆 EDK2 并打补丁

```bash
./script/setup-edk2.sh
```

此脚本会：
- 克隆 [tianocore/edk2](https://github.com/tianocore/edk2) 到 `artifact/edk2/`
- 检出基线 commit (记录在 `script/resources/edk2-base-commit.txt`)
- **同时 apply 两个 patch**（两个 patch 修改不同平台文件，互不冲突）：

| Patch | 修改文件 | 变更内容 |
|-------|----------|----------|
| `edk2-riscv.patch` | `RiscVVirtQemu.dsc` + `.fdf` | `SECURE_BOOT_ENABLE=TRUE`, `NETWORK_HTTP_BOOT_ENABLE=TRUE`, 添加 `Hash2DxeCrypto.inf` |
| `edk2-x64.patch` | `OvmfPkgX64.dsc` | `SECURE_BOOT_ENABLE=TRUE`, `NETWORK_HTTP_BOOT_ENABLE=TRUE` |

> **为什么 RV 需要 Hash2DxeCrypto?** TcpDxe 的 `[Depex]` 依赖 `gEfiHash2ServiceBindingProtocolGuid`，该协议由 `Hash2DxeCrypto.inf` 提供。RISC-V 平台默认未编译此驱动，必须显式添加。x86 OVMF 默认已包含。

### 1.2 编译 EDK2

```bash
cd artifact/edk2
export WORKSPACE=$PWD
export EDK_TOOLS_PATH=$WORKSPACE/BaseTools
export GCC_RISCV64_PREFIX=riscv64-linux-gnu-
export PATH=$EDK_TOOLS_PATH/BinWrappers/PosixLike:$PATH

# 编译 BaseTools (两个架构共用，只做一次)
make -C BaseTools -j$(nproc)
source edksetup.sh

# 编译 RISC-V 固件
build -p OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc -a RISCV64 -t GCC -b RELEASE

# 编译 x86_64 固件
build -p OvmfPkg/OvmfPkgX64.dsc -a X64 -t GCC -b RELEASE

cd ../..
```

输出产物：

| 文件 | 说明 |
|------|------|
| `Build/RiscVVirtQemu/RELEASE_GCC/FV/RISCV_VIRT_CODE.fd` | RV 固件代码 |
| `Build/RiscVVirtQemu/RELEASE_GCC/FV/RISCV_VIRT_VARS.fd` | RV 变量模板 |
| `Build/OvmfX64/RELEASE_GCC/FV/OVMF_CODE.fd` | x86 固件代码 |
| `Build/OvmfX64/RELEASE_GCC/FV/OVMF_VARS.fd` | x86 变量模板 |

### 1.3 部署固件

```bash
# RISC-V: QEMU pflash 要求 32MB 对齐，需 truncate 填充
cp artifact/edk2/Build/RiscVVirtQemu/RELEASE_GCC/FV/RISCV_VIRT_CODE.fd artifact/ovmf/rvcode.fd
cp artifact/edk2/Build/RiscVVirtQemu/RELEASE_GCC/FV/RISCV_VIRT_VARS.fd artifact/ovmf/rvvars.fd
truncate -s 32M artifact/ovmf/rvcode.fd

# x86_64: 不需要 truncate
cp artifact/edk2/Build/OvmfX64/RELEASE_GCC/FV/OVMF_CODE.fd artifact/ovmf/x86code.fd
cp artifact/edk2/Build/OvmfX64/RELEASE_GCC/FV/OVMF_VARS.fd artifact/ovmf/x86vars.fd
```

> **大小说明**：RV 固件原始约 8MB，QEMU pflash 对 RISC-V 强制要求 32MB 对齐。x86 OVMF 约 3.5MB，无此要求。

---

## 步骤 2：生成密钥 + 注入固件

```bash
# RISC-V
bash ./script/setup-keys.sh riscv64

# x86_64
bash ./script/setup-keys.sh x86_64

# 或一次执行两个 (默认 riscv64)
bash ./script/setup-keys.sh riscv64 && bash ./script/setup-keys.sh x86_64
```

此脚本自动完成：
1. 生成三对 RSA-2048 密钥：PK、KEK、DB
2. 转换 DER 格式（`virt-fw-vars` 需要 `.cer`）
3. 注入 VARS：写入 PK/KEK/DB，启用 Secure Boot

> 仓库预置的 `artifact/ovmf/*.fd` 已完成密钥注入。

---

## 步骤 3：构建 gnu-efi

gnu-efi 是 Shim 的构建依赖，需要为 RISC-V 和 x86_64 各编译一次。

```bash
cd shimsrc/gnu-efi

# ===== RISC-V: 交叉编译 =====
# ⚠️ 不要使用默认的 `make ARCH=riscv64` — 会尝试构建 apps 子目录并失败
make ARCH=riscv64 \
    CC=riscv64-linux-gnu-gcc HOSTCC=gcc \
    TOPDIR=$(pwd) -f $(pwd)/Makefile lib gnuefi inc

# 验证
ls riscv64/lib/libefi.a riscv64/gnuefi/libgnuefi.a

# ⚠️ 关键: Shim Makefile 需要 crt0-efi-riscv64-local.o
cp riscv64/gnuefi/crt0-efi-riscv64.o \
   riscv64/gnuefi/crt0-efi-riscv64-local.o

# ===== x86_64: 原生编译 =====
make ARCH=x86_64 \
    CC=gcc HOSTCC=gcc \
    TOPDIR=$(pwd) -f $(pwd)/Makefile lib gnuefi inc

cp x86_64/gnuefi/crt0-efi-x86_64.o \
   x86_64/gnuefi/crt0-efi-x86_64-local.o

cd ../..
```

---

## 步骤 4：构建 Shim

```bash
cd shimsrc

# 将 DB 证书放入源码目录 (构建时嵌入 Vendor Cert)
cp ../artifact/keys/DB.cer .

# ===== RISC-V Shim =====
make -j$(nproc) \
    ARCH=riscv64 CROSS_COMPILE=riscv64-linux-gnu- COMPILER=gcc \
    EFIDIR=openEuler VENDOR_CERT_FILE=DB.cer ENABLE_SHIM_CERT=y

# ===== x86_64 Shim =====
make -j$(nproc) \
    ARCH=x86_64 COMPILER=gcc \
    EFIDIR=openEuler VENDOR_CERT_FILE=DB.cer ENABLE_SHIM_CERT=y

cd ..
```

### 4.1 安装 Shim 产物

```bash
mkdir -p artifact/shim

# RV
cp shimsrc/shimriscv64.efi artifact/shim/
cp shimsrc/mmriscv64.efi  artifact/shim/
cp shimsrc/fbriscv64.efi  artifact/shim/ 2>/dev/null || true

# x86
cp shimsrc/shimx64.efi    artifact/shim/
cp shimsrc/mmx64.efi      artifact/shim/

# 生成 BOOT CSV (⚠️ 必须 UCS-2LE 编码)
echo "shimriscv64.efi,openEuler,,This is the boot entry for openEuler" \
    | iconv -t UCS-2LE > artifact/shim/BOOTRISCV64.CSV
echo "shimx64.efi,openEuler,,This is the boot entry for openEuler" \
    | iconv -t UCS-2LE > artifact/shim/BOOTX64.CSV
```

---

## 步骤 5：提取网络驱动 (RISC-V)

```bash
mkdir -p artifact/drivers

EDK2_BUILD="artifact/edk2/Build/RiscVVirtQemu/RELEASE_GCC"

for drv in Hash2DxeCrypto TcpDxe HttpDxe; do
    find "$EDK2_BUILD" -name "${drv}.efi" -exec cp {} artifact/drivers/ \;
done
```

> x86_64 OVMF 固件已内置完整网络驱动栈，无需此步骤。

---

## 步骤 6：签名所有 EFI 组件

```bash
# RISC-V (含 fix_reloc)
./script/sign-rv.sh

# x86_64
./script/sign-x86.sh
```

每个 EFI 文件签名流程：

```
sbattach --remove       ← 移除已有签名
  → fix_reloc.py        ← 修复 PE .reloc Page RVA (仅 RV)
  → expand SizeOfImage  ← 预扩展 PE 头，为签名证书留空间
  → sbsign (DB.key)     ← 用 DB 私钥签名
  → sbverify (DB.crt)   ← 验证签名
```

**签名范围**：

| 文件 | 架构 | 说明 |
|------|:---:|------|
| `artifact/shim/shimriscv64.efi` | RV | 主 Shim |
| `artifact/shim/mmriscv64.efi` | RV | MokManager |
| `artifact/shim/shimx64.efi` | x86 | 主 Shim |
| `artifact/shim/mmx64.efi` | x86 | MokManager |
| `artifact/drivers/Hash2DxeCrypto.efi` | RV | Hash2 服务 (必须) |
| `artifact/drivers/TcpDxe.efi` | RV | TCP4 协议 (必须) |
| `artifact/drivers/HttpDxe.efi` | RV | HTTP 协议 (必须) |

签名前自动备份到 `artifact/backup/<timestamp>/`。

> **为什么 RV 需要 fix_reloc？** gnu-efi CRT0 在 RISC-V 上使用 `-O binary` 输出 (objcopy 不支持 `efi-app-riscv64`)，手工构造 PE 头时 `.reloc` Page RVA 可能为负值。`fix_reloc.py` 检测负值并修正为 `0x1000`。x86_64 使用 `--target efi-app-x86_64`，objcopy 自动生成正确的 PE 头，不存在此问题。

---

## 步骤 7：构建磁盘镜像

### rootfs 获取优先级

所有镜像脚本共享同一套 rootfs 获取策略：

| 优先级 | 方式 | 说明 |
|:---:|------|------|
| **1** | 本地离线备份 `artifact/*_rootfs_backup.tar.gz` | 文件已存在时直接使用 (秒级) |
| **2** | 在线安装 (Docker / debootstrap) | 兜底，需要网络 (数分钟) |

首次 Docker/debootstrap 运行后，可从生成的镜像中提取 rootfs 备份：

```bash
# 示例：提取 x86_openEuler rootfs 备份
sudo losetup -f -P artifact/images/x86_openEuler.img --show
sudo mount /dev/loopNp2 /mnt
sudo tar -czf artifact/oex86_rootfs_backup.tar.gz -C /mnt .
sudo umount /mnt && sudo losetup -d /dev/loopN
```

### 7a. RISC-V + openEuler

```bash
sudo ./script/image/build-rvoe.sh
```

构建流程：创建 GPT 磁盘 → 部署 Shim + 驱动 + startup.nsh → rootfs 安装 → GRUB 构建 (qemu-user) → DTB + grub.cfg → 签名 GRUB + 内核 → 输出

输出：`artifact/images/RiscV_OpenEuler.img` (12GB)

> **GRUB 构建**：必须通过 `qemu-riscv64-static` 运行 RISC-V 原生 `grub2-mkimage`。宿主机 x86_64 版本会产生 relocation overflow (RISC-V GRUB 模块用 `-mcmodel=medlow` 编译)。

### 7b. x86_64 + openEuler

```bash
sudo ./script/image/build-x86oe.sh
```

与 RV 版本主要差异：
- 无需 startup.nsh 和网络驱动 (OVMF 内置)
- 宿主机原生 `grub2-mkimage -O x86_64-efi`
- 无需 DTB 生成
- 离线模式自动重建 initramfs (`dracut -f --no-hostonly`)

输出：`artifact/images/x86_openEuler.img` (12GB)

### 7c. x86_64 + Ubuntu

```bash
sudo ./script/image/build-x86ubuntu.sh
```

与 x86 openEuler 主要差异：
- rootfs 通过 `debootstrap --arch amd64 jammy` 安装
- 内核需预置于 `artifact/kernel/vmlinuz-*` 和 `artifact/kernel/initrd.img-*`
- ESP 布局使用 `EFI/ubuntu/` (非 `EFI/openEuler/`)

输出：`artifact/images/x86_ubuntu.img` (12GB)

---

## 步骤 8：启动 QEMU

```bash
# 实验 1: RISC-V + openEuler
sudo ./boot.sh --arch rv --os openEuler

# 实验 2: x86_64 + openEuler
sudo ./boot.sh --arch x86 --os openEuler

# 实验 3: x86_64 + Ubuntu
sudo ./boot.sh --arch x86 --os ubuntu
```

### 启动参数

| 参数 | 可选值 | 说明 |
|------|--------|------|
| `-a, --arch` | `rv`, `x86` | 虚拟机架构 |
| `-k, --os` | `openEuler`, `ubuntu` | 操作系统 (RV 仅支持 openEuler) |

所有固件默认启用 Secure Boot，无需额外参数。

### 登录

- 凭据：`root` / `password`
- SSH：`ssh -p 12055 root@localhost` (宿主机 12055 → VM 22)
- 退出 QEMU：`Ctrl+A X`

---

## 步骤 9：验证 Secure Boot

```bash
mokutil --sb-state              # 预期: SecureBoot enabled

# 或直接读 EFI 变量
cat /sys/firmware/efi/efivars/SecureBoot-* | hexdump -C | head -1
# 最后一个字节应为 01 (enabled)
```

---

## QEMU 关键参数

### RISC-V

| 参数 | 作用 |
|------|------|
| `-cpu rva23s64,sv39=on,zkr=true` | Zkr 扩展必须启用 (TcpDxe 的 RNG 依赖) |
| `-smp 1 -m 4G` | SMP=1 避免 GRUB relocation overflow |
| `pflash0` (read-only) | 固件 CODE (32MB, 含 OpenSBI) |
| `pflash1` (read-write) | 固件 VARS (已注入密钥) |
| `-netdev user` | Guest DHCP → 10.0.2.15, Host → 10.0.2.2 |

### x86_64

| 参数 | 作用 |
|------|------|
| `-machine q35,smm=on` | Q35 芯片组 + SMM (Secure Boot 必须) |
| `-cpu host --enable-kvm` | KVM 硬件加速 |
| `-smp 4 -m 4G` | 4 核 + 4GB |
| `pflash0` (read-only) | OVMF CODE (~3.5MB) |
| `pflash1` (read-write) | OVMF VARS (~540KB, 已注入密钥) |

---

## 一键流程

```bash
# 0. 克隆
git clone --recursive git@github.com:tearizz/rvoe.git && cd rvoe

# 1. 安装依赖
sudo apt-get update && sudo apt-get install -y \
    build-essential gcc-riscv64-linux-gnu \
    qemu-system-riscv64 qemu-system-x86_64 qemu-user-static \
    sbsigntool virt-firmware python3 parted dosfstools mtools \
    uuid-runtime git curl openssl debootstrap

# 2. 构建 EDK2 (或使用 artifact/ovmf 预编译固件)
./script/setup-edk2.sh
cd artifact/edk2
export WORKSPACE=$PWD EDK_TOOLS_PATH=$WORKSPACE/BaseTools
export GCC_RISCV64_PREFIX=riscv64-linux-gnu-
export PATH=$EDK_TOOLS_PATH/BinWrappers/PosixLike:$PATH
make -C BaseTools -j$(nproc) && source edksetup.sh
build -p OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc -a RISCV64 -t GCC -b RELEASE
build -p OvmfPkg/OvmfPkgX64.dsc -a X64 -t GCC -b RELEASE
cd ../..
# 部署固件 (见步骤 1.3)

# 3. 密钥 + 注入
bash ./script/setup-keys.sh riscv64 && bash ./script/setup-keys.sh x86_64

# 4. gnu-efi + Shim (见步骤 3-4)
# ...

# 5. 提取驱动 (RV) + 签名
./script/sign-rv.sh
./script/sign-x86.sh

# 6. 构建磁盘镜像
sudo ./script/image/build-rvoe.sh
sudo ./script/image/build-x86oe.sh
sudo ./script/image/build-x86ubuntu.sh

# 7. 启动
sudo ./boot.sh --arch rv --os openEuler
sudo ./boot.sh --arch x86 --os openEuler
sudo ./boot.sh --arch x86 --os ubuntu
```

---

## 架构差异速查

| | RISC-V | x86_64 |
|---|---|---|
| **QEMU machine** | `virt,acpi=off` | `q35,smm=on` |
| **QEMU CPU** | `rva23s64,sv39=on,zkr=true` | `host --enable-kvm` |
| **SMP / Memory** | 1 核 / 4GB | 4 核 / 4GB |
| **OVMF 大小** | 8MB (需 truncate 到 32MB) | ~3.5MB (无需填充) |
| **启动方式** | UEFI Shell → startup.nsh → 加载驱动 → Shim | UEFI 固件直接启动 Shim |
| **网络驱动** | 需部署到 ESP | OVMF 内置 |
| **GRUB 构建** | `qemu-riscv64-static` 模拟 | 宿主机原生 |
| **fix_reloc** | **需要** | **不需要** |
| **DTB 生成** | 需要 | 不需要 |
| **交叉编译器** | `gcc-riscv64-linux-gnu` | 不需要 |
| **磁盘接口** | virtio-blk | IDE |
| **EDK2 平台** | `RiscVVirtQemu.dsc` | `OvmfPkgX64.dsc` |
| **rootfs 安装** | Docker `openeuler:24.03-lts-sp1` | Docker `openeuler:24.03-lts` 或 `debootstrap` |

---

## 重要注意事项

### fix_reloc 问题 (RISC-V)

gnu-efi CRT0 通过 `dummy - label1` 计算 `.reloc` 段 Page RVA。当 `.data` VMA < `.reloc` VMA 时 (RISC-V 链接脚本常见情况)，结果为负值 (`>= 0x80000000` 的无符号表示)。UEFI PE 加载器拒绝此类映像，报 `Command Error Status: Unsupported`。

`script/resources/fix_reloc.py` 检测负值并修正为 `0x1000`。**必须对以下 EFI 执行**：shimriscv64.efi、mmriscv64.efi、fbriscv64.efi、grubriscv64.efi。`sign-rv.sh` 已自动处理。

### GRUB 构建注意事项 (RISC-V)

- **必须用 RISC-V 原生 grub2-mkimage**：宿主机 x86_64 版本产生 relocation overflow
- **grub.cfg 不能包含 `devicetree` 命令**：Secure Boot 下 GRUB lockdown 会阻止
- **initramfs 不签名**：cpio 归档非 PE/COFF 格式

### 安全启动签名链

```
UEFI 固件 ──[DB 证书]──→ 验证 Shim
    │ 固件从 VARS 读取 DB，验证 Shim 的 PKCS#7 签名
    ▼
Shim ──[Vendor Cert + DB]──→ 验证 GRUB
    │ RV: HTTP 远程验证优先，失败 fallback DB
    │ x86: 标准 DB 证书链本地验证
    ▼
GRUB ──[shim_verify()]──→ 验证 Kernel
    │ 内核必须用 sbsign + DB.key 签名
    ▼
Linux Kernel → systemd → Login
```

**每一个环节的签名必须有效**，否则整条 Secure Boot 链断裂。

### sudo 权限

镜像构建脚本需要 root (loopback 设备、mkfs、mount)。`boot.sh` 用 `sudo -S` 执行 QEMU (pflash 需要 CAP_SYS_ADMIN)。

---

## 相关仓库

- [tearizz/rvoe](https://github.com/tearizz/rvoe) — 本项目
- [tearizz/shimsrc](https://github.com/tearizz/shimsrc) (分支 `main`) — 修改后的 Shim 源码
- [gnu-efi](https://git.code.sf.net/p/gnu-efi/code) — UEFI 开发工具链
- [tianocore/edk2](https://github.com/tianocore/edk2) — UEFI 固件参考实现
