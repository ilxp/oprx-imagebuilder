#!/usr/bin/env bash
# ==============================================================================
# Build —— ImageBuilder 构建主脚本
# 用法: ./build.sh
#   ARCH_OVERRIDE=x86_64  VERSION_OVERRIDE=25.12.6  ./build.sh
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# ========== 日志函数 ==========
log_info()  { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
log_error() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
log_ok()    { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
log_step()  { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

# ========== 展开字符串中的 ${VAR}（避免 eval 注入） ==========
# 只展开 ${VAR} 花括号形式，不碰 $VAR / $(...) / 反引号
# 未定义的变量替换为空
_expand_vars() {
  local s="$1"
  local key val
  while [[ "$s" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
    key="${BASH_REMATCH[1]}"
    val="${!key:-}"
    s="${s//\$\{$key\}/$val}"
  done
  printf '%s' "$s"
}

# 生成短日期 YY.M.D（去前导 0），如 26.11.6
# 参数：YYYYMMDD（可选，默认今天）
ib_short_date() {
  local d="${1:-$(TZ=Asia/Shanghai date +%Y%m%d)}"
  local yy="${d:2:2}"
  local mm=$((10#${d:4:2}))   # 10# 防止 08/09 被当八进制
  local dd=$((10#${d:6:2}))
  printf '%s.%d.%d' "$yy" "$mm" "$dd"
}

# ========== 由 VERSION / IB_CHANNEL 推导 RELEASE_PATH ==========
# 优先级：
#   1. IB_CHANNEL 显式指定（"releases" / "snapshots"）→ 直接返回，VERSION 只用于命名
#   2. 从 VERSION 自动推导（大小写不敏感）
#
# 自动推导：
#   "" / "SNAPSHOT" / "snapshot"          → snapshots
#   "25.12-SNAPSHOT" / "25.12-snapshot"   → releases/25.12-SNAPSHOT  #仅immortalwrt
#   "25.12.6"                             → releases/25.12.6
#
# 用 tr 而非 ${v,,}：兼容 macOS 自带 bash 3.2
ib_release_path() {
  local v="${1:-$VERSION}"

  # ---- ① 显式 channel override（最高优先）----
  # snapshots + 短日期（如 26.11.6）必须走这里，否则 26.11.6 会被当稳定版
  if [[ -n "${IB_CHANNEL:-}" ]]; then
    case "$IB_CHANNEL" in
      snapshots|snapshot)
        printf 'snapshots'
        return
        ;;
      releases|release)
        printf 'releases/%s' "$v"
        return
        ;;
      *)
        log_error "IB_CHANNEL 不合法: $IB_CHANNEL（应为 releases 或 snapshots）"
        exit 1
        ;;
    esac
  fi

  # ---- ② 自动推导 ----
  local lower
  lower=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')

  # 整串 snapshot → 开发快照
  if [[ -z "$v" || "$lower" == "snapshot" ]]; then
    printf 'snapshots'
    return
  fi

  # x.y-snapshot（任意大小写）→ 统一成 x.y-SNAPSHOT
  if [[ "$lower" == *-snapshot ]]; then
    printf 'releases/%s-SNAPSHOT' "${v%-*}"
    return
  fi

  printf 'releases/%s' "$v"
}

# ========== 展开 ImageBuilder 下载 URL ==========
# 依赖变量（由 load_config 先加载）：
#   IMAGEBUILDER_BASE_URL IB_DISTRO IB_PRODUCT IB_URL_OVERRIDE VERSION
#   TARGET SUBTARGET IB_ARCH_TAG IB_HOST_TAG
ib_url() {
  # ---- escape hatch：自建源 ----
  if [[ -n "${IB_URL_OVERRIDE:-}" ]]; then
    local url="$IB_URL_OVERRIDE"
    url="${url//__IB_ARCH_TAG__/$IB_ARCH_TAG}"
    url="${url//__IB_HOST_TAG__/$IB_HOST_TAG}"
    url="${url//__VERSION__/$VERSION}"
    url="${url//__TARGET__/$TARGET}"
    url="${url//__SUBTARGET__/$SUBTARGET}"
    printf '%s' "$url"
    return
  fi

  local base="${IMAGEBUILDER_BASE_URL%/}"

  # ---- 展开 __DISTRO__（域名）----
  base="${base//__DISTRO__/$IB_DISTRO}"

  # ---- 展开 __RELEASE_PATH__（渠道+版本）；兼容旧写法 __VERSION__ ----
  local rel_path
  rel_path="$(ib_release_path)"
  if [[ "$base" == *"__RELEASE_PATH__"* ]]; then
    base="${base//__RELEASE_PATH__/$rel_path}"
  else
    base="${base//__VERSION__/$VERSION}"
  fi

  # ---- product 推导 ----
  local product="${IB_PRODUCT:-}"
  if [[ -z "$product" ]]; then
    if [[ "$base" == *immortalwrt* ]]; then
      product="immortalwrt"
    elif [[ "$base" == *openwrt* ]]; then
      product="openwrt"
    else
      log_error "无法从 IMAGEBUILDER_BASE_URL 推断产品名（openwrt/immortalwrt）："
      log_error "  $base"
      log_error "  请设置 IB_PRODUCT=\"openwrt\" 或 \"immortalwrt\""
      exit 1
    fi
  fi

  # ---- snapshots 无版本段；releases 有 ----
  local out
  if [[ "$base" =~ /snapshots/targets$ ]]; then
    out="${base}/${TARGET}/${SUBTARGET}/${product}-imagebuilder-${IB_ARCH_TAG}.${IB_HOST_TAG}.tar.zst"
  elif [[ "$base" =~ /releases/([^/]+)/targets$ ]]; then
    local ver="${BASH_REMATCH[1]}"
    out="${base}/${TARGET}/${SUBTARGET}/${product}-imagebuilder-${ver}-${IB_ARCH_TAG}.${IB_HOST_TAG}.tar.zst"
  else
    log_error "IMAGEBUILDER_BASE_URL 格式不对（展开后）："
    log_error "  $base"
    log_error "  必须以 /releases/<版本>/targets 或 /snapshots/targets 结尾"
    exit 1
  fi
  printf '%s' "$out"
}

# ========== 1. 加载配置 ==========
load_config() {
  . "$ROOT/config/build.conf"
  ARCH="${ARCH_OVERRIDE:-$DEFAULT_TARGET}"

  # ---- 版本号优先级：override > config VERSION > DEFAULT_VERSION ----
  if [[ -n "${VERSION_OVERRIDE:-}" ]]; then
    local IFS_OLD="$IFS"
    local -a parts
    IFS='/' read -ra parts <<< "$VERSION_OVERRIDE"
    IFS="$IFS_OLD"
    local nparts="${#parts[@]}"

    if [[ "$nparts" -eq 3 ]]; then
      local ov_distro="${parts[0]}" ov_channel="${parts[1]}" ov_version="${parts[2]}"
      [[ "$ov_distro" =~ ^[a-z][a-z0-9_-]*$ ]] || { log_error "发行版名不合法: $ov_distro"; exit 1; }
      [[ "$ov_channel" == "releases" || "$ov_channel" == "snapshots" ]] || { log_error "渠道名不合法: $ov_channel"; exit 1; }
      [[ -n "$ov_version" ]] || { log_error "版本号为空: $VERSION_OVERRIDE"; exit 1; }
      [[ "$ov_distro" != "$IB_DISTRO" ]] && { log_info "发行版: $ov_distro (VERSION_OVERRIDE 覆盖 $IB_DISTRO)"; IB_DISTRO="$ov_distro"; }
      IB_CHANNEL="$ov_channel"
      VERSION="$ov_version"
      log_info "版本: $VERSION，渠道: $IB_CHANNEL (VERSION_OVERRIDE)"

    elif [[ "$nparts" -eq 2 ]]; then
      local ov_distro="${parts[0]}" ov_version="${parts[1]}"
      [[ "$ov_distro" =~ ^[a-z][a-z0-9_-]*$ ]] || { log_error "发行版名不合法: $ov_distro"; exit 1; }
      [[ -n "$ov_version" ]] || { log_error "版本号为空: $VERSION_OVERRIDE"; exit 1; }
      [[ "$ov_distro" != "$IB_DISTRO" ]] && { log_info "发行版: $ov_distro (VERSION_OVERRIDE 覆盖 $IB_DISTRO)"; IB_DISTRO="$ov_distro"; }
      VERSION="$ov_version"
      IB_CHANNEL=""   # 让下面的 snapshot 判断决定，或从 VERSION 推导
      log_info "版本: $VERSION (VERSION_OVERRIDE)"

    elif [[ "$nparts" -eq 1 ]]; then
      VERSION="$VERSION_OVERRIDE"
      log_info "版本: $VERSION (VERSION_OVERRIDE，distro/channel 用 build.conf)"

    else
      log_error "VERSION_OVERRIDE 格式错误: $VERSION_OVERRIDE"
      exit 1
    fi

  elif [[ -n "${VERSION:-}" ]]; then
    log_info "版本: $VERSION (config VERSION)"
  else
    VERSION="$DEFAULT_VERSION"
    log_warn "VERSION 为空，回退 DEFAULT_VERSION: $VERSION"
  fi

  # ---- snapshots 渠道下，VERSION 为空 / snapshot 占位 → 短日期 ----
  local v_lower
  v_lower=$(printf '%s' "${VERSION:-}" | tr '[:upper:]' '[:lower:]')

  # 判定是否开发快照：
  #   ① IB_CHANNEL 显式为 snapshots
  #   ② VERSION 整串是 snapshot（任意大小写）或空
  if [[ "${IB_CHANNEL:-}" == "snapshots" || "${IB_CHANNEL:-}" == "snapshot" ]]; then
    # ① 已显式指定 snapshots，但 VERSION 还是占位符 / 空 → 换成短日期
    if [[ -z "$v_lower" || "$v_lower" == "snapshot" ]]; then
      VERSION="$(ib_short_date)"
      log_info "开发快照，VERSION 自动设为短日期: $VERSION"
    fi
    IB_CHANNEL="snapshots"    # 归一化
  elif [[ -z "$v_lower" || "$v_lower" == "snapshot" ]]; then
    # ② 没显式指定，但 VERSION 是 snapshot 占位 → 强制 snapshots + 短日期
    IB_CHANNEL="snapshots"
    VERSION="$(ib_short_date)"
    log_info "开发快照，VERSION 自动设为短日期: $VERSION"
  fi

  # ---- 兜底检查：VERSION 为空说明三级链全空，配置有误 ----
  if [[ -z "${VERSION:-}" ]]; then
    log_error "版本号为空：VERSION_OVERRIDE / VERSION / DEFAULT_VERSION 三级都为空"
    log_error "  请在 build.conf 里设置 VERSION 或 DEFAULT_VERSION，"
    log_error "  或在 workflow 传 version input（如 openwrt/25.12.6）"
    exit 1
  fi
  
  log_info "发行版: $IB_DISTRO"
  [[ -n "${IB_CHANNEL:-}" ]] && log_info "渠道: $IB_CHANNEL (显式)"
  log_info "渠道路径: $(ib_release_path)"
  
  # ---- 加载 Target 设备配置 ----
  TARGET_CONF="$ROOT/config/targets/${ARCH}.conf"
  [[ -f "$TARGET_CONF" ]] || { log_error "找不到 $TARGET_CONF"; exit 1; }
  . "$TARGET_CONF"
  [[ "${CONF_TARGET:-}" == "$ARCH" ]] || { log_error "$TARGET_CONF 声明与 $ARCH 不符"; exit 1; }

  # ---- 调试：打印最终 IB 地址（此时 TARGET/SUBTARGET/IB_*_TAG 已就绪）----
  log_info "IB URL: $(ib_url)"

  # ---- 自建包清单 ----
  CUSTOM_ASSETS="${CUSTOM_ASSETS:-}"

  if [[ -n "${CUSTOM_ASSETS_FILE:-}" ]]; then
    if [[ -f "$ROOT/$CUSTOM_ASSETS_FILE" ]]; then
      CUSTOM_ASSETS=$(cat "$ROOT/$CUSTOM_ASSETS_FILE")
      local n
      n=$(echo "$CUSTOM_ASSETS" | grep -cE '^[[:space:]]*[^#[:space:]]' || true)
      log_info "自建包清单: $CUSTOM_ASSETS_FILE（${n} 条启用）"
    else
      log_warn "CUSTOM_ASSETS_FILE 指向的文件不存在: $ROOT/$CUSTOM_ASSETS_FILE（回退到 build.conf 的 CUSTOM_ASSETS）"
    fi
  fi

  # ---- 展开 ${VAR} ----
  if [[ -n "$CUSTOM_ASSETS" ]]; then
    CUSTOM_ASSETS="$(_expand_vars "$CUSTOM_ASSETS")"
  fi

  export CUSTOM_ASSETS
}

# ========== 2. 目录 ==========
prepare_dirs() {
  export WORK_DIR="$ROOT/build_workspace/${ARCH}"
  export IB_DIR="$WORK_DIR/imagebuilder"
  export OUTPUT_DIR="$ROOT/output/${ARCH}"
  mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
}


# ========== 3. 下载 ImageBuilder（带 sha256 校验） ==========
download_imagebuilder() {
  if [[ -f "$IB_DIR/Makefile" ]]; then
    log_ok "ImageBuilder 已存在，跳过下载"
    return
  fi

  local url archive base
  url="$(ib_url)"
  archive="${url##*/}"
  base="${url%/*}"

  log_info "下载 $archive"
  log_info "  从 $base"
  wget -q --timeout=60 --tries=3 "$url" -O "$WORK_DIR/$archive" \
    || { log_error "下载失败: $url"; exit 1; }

  log_info "sha256 校验..."
  if wget -q --timeout=30 "$base/sha256sums" -O "$WORK_DIR/sha256sums" 2>/dev/null; then
    local exp act
    exp=$(awk -v f="$archive" '$2==f || $2=="*"f {print $1}' "$WORK_DIR/sha256sums")
    act=$(sha256sum "$WORK_DIR/$archive" | cut -d' ' -f1)
    if [[ -n "$exp" && "$exp" == "$act" ]]; then
      log_ok "sha256: $act"
    else
      log_error "sha256 不匹配 (期望 $exp / 实际 $act)"
      exit 1
    fi
    rm -f "$WORK_DIR/sha256sums"
  else
    log_warn "无法下载 sha256sums，跳过校验"
  fi

  log_info "解压..."
  rm -rf "$IB_DIR"
  tar --zstd -xf "$WORK_DIR/$archive" -C "$WORK_DIR"

  local ex
  ex=$(find "$WORK_DIR" -maxdepth 1 -type d -name "*imagebuilder*" | head -1)
  [[ -n "$ex" ]] || { log_error "解压失败：未找到 imagebuilder 目录"; ls -la "$WORK_DIR"; exit 1; }

  if [[ "$ex" != "$IB_DIR" ]]; then
    mv "$ex" "$IB_DIR"
  fi

  if [[ ! -f "$IB_DIR/.config" ]]; then
    log_error "ImageBuilder 缺少 .config，解压可能不完整"
    ls -la "$IB_DIR" | head -20
    exit 1
  fi
  log_ok "解压完成，已含 .config"

  rm -f "$WORK_DIR/$archive"
}

# ========== 4. 打 ImageBuilder 补丁 ==========
patch_imagebuilder() {
  local mk="$IB_DIR/Makefile"
  [[ -f "$mk" ]] || { log_error "找不到 $mk"; exit 1; }

  if grep -q 'pkg_ver:=)' "$mk" 2>/dev/null; then
    log_ok "补丁已存在"
    return
  fi

  log_info "应用补丁：pkg_ver 复位 + apk --force-overwrite"
  python3 - "$mk" <<'PYEOF'
import sys, io
path = sys.argv[1]
with io.open(path, encoding='utf-8') as f:
    lines = f.readlines()

changed = False

# 补丁 1：pkg_ver 复位（避免版本 pin 泄漏到后续包）
for i, line in enumerate(lines):
    if '$(eval pkg_name:=$(firstword $(subst =, ,$(pkg))))' in line:
        indent = line[:len(line) - len(line.lstrip())]
        if not any('pkg_ver:=)' in l for l in lines[i:i+3]):
            lines.insert(i + 1, indent + '$(eval pkg_ver:=)\n')
            changed = True
        break

# 补丁 2：apk --force-overwrite（包间文件冲突降级为警告）
for i, line in enumerate(lines):
    if '--cache-dir $(DL_DIR)' in line and '--force-overwrite' not in line:
        lines[i] = line.rstrip('\n') + ' --force-overwrite\n'
        changed = True
        break

if changed:
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.writelines(lines)
    print('  已打补丁')
else:
    print('  未找到锚点，跳过')
PYEOF
}

# ========== 5. 准备仓库（构建时 + 刷机后） ==========
prepare_repos() {
  mkdir -p "$IB_DIR/keys"

  local overlay_repo_dir="$ROOT/files/etc/apk/repositories.d"
  local overlay_key_dir="$ROOT/files/etc/apk/keys"
  mkdir -p "$overlay_repo_dir" "$overlay_key_dir"

  # ImageBuilder 25.12 的 repositories 是 apk v3 纯 URL 格式
  local orig_count=0
  [[ -f "$IB_DIR/repositories" ]] && orig_count=$(grep -cE '^https?://' "$IB_DIR/repositories" || true)
  log_info "ImageBuilder 内置 ${orig_count} 个官方仓库（保留）"

  local count=0
  local release_path
  release_path="$(ib_release_path)"          # 只算一次，循环里复用

  while IFS='|' read -r name url key_url enabled; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    [[ "$enabled" == "true" ]] || continue

    # 官方源（downloads.openwrt.org）已经由 ImageBuilder 自带，跳过避免重复
    #if [[ "$url" == *"downloads.openwrt.org"* ]]; then
      #log_info "跳过 ${name}（官方源已内置）"
      #continue
    #fi

    # ---- 占位符展开 ----
	url="${url//__DISTRO__/${IB_DISTRO:-openwrt}}"	
    url="${url//__RELEASE_PATH__/$(ib_release_path)}"   
    url="${url//__VERSION__/$VERSION}"                  # 保留（第三方源可能用）
    url="${url//__ARCH__/$ARCH_PACKAGES}"
    url="${url//__TARGET__/$TARGET}"
    url="${url//__SUBTARGET__/$SUBTARGET}"
    url="${url//__SERIES__/${VERSION%.*}}"

    # ① 构建时：纯 URL 追加（与 IB 自带格式一致）
    echo "$url" >> "$IB_DIR/repositories"

    # ② 刷机后：纯 URL 写入 files/etc/apk/repositories.d/<name>.list
    echo "$url" > "${overlay_repo_dir}/${name}.list"

    # ③ 密钥：两处都要
    if [[ -n "$key_url" && "$key_url" != "(内置)" ]]; then
      local kf_ib="$IB_DIR/keys/${name}.rsa.pub"
      local kf_ov="${overlay_key_dir}/${name}.rsa.pub"
      if [[ ! -f "$kf_ib" ]]; then
        wget -q --timeout=15 --tries=2 "$key_url" -O "$kf_ib" || {
          log_warn "密钥下载失败: $key_url"; continue
        }
      fi
      cp -f "$kf_ib" "$kf_ov"
    fi
    count=$((count + 1))
  done <<< "$REPOS"

  log_ok "追加 ${count} 个第三方仓库（官方 ${orig_count} 个保留）"
}

# ========== 6. 收集预装包 ==========
collect_packages() {
  local pkgs=""
  
  # ① common-pkgs.list（每行一个包名，# 是注释）
  if [[ -f "$ROOT/config/common-pkgs.list" ]]; then
    local common
    # grep -v 无输出时返回 1，加 || true 避免 set -e / pipefail 触发退出
    common=$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/config/common-pkgs.list" || true)
    pkgs+=" $(echo "$common" | tr '\n' ' ')"
  fi

  # ② PACKAGES_ARCH_EXTRA（来自 target conf）
  # ⚠️ 这个变量里如果有中文注释（如 `# ---- 网卡（有线） ----`），shell 词分割后
  #    会把 `----`、`网卡（有线）`、`虚拟机）` 当成"包名"传给 make image。
  #    所以下面要严格过滤：只保留合法包名格式。
  if [[ -n "${PACKAGES_ARCH_EXTRA:-}" ]]; then
    pkgs+=" $PACKAGES_ARCH_EXTRA"
  fi

  # ③ 功能开关
  #if [[ "${ENABLE_ARGON:-false}" == "true" ]]; then
    #pkgs+=" luci-theme-argon"
  #fi
  if [[ "${ENABLE_DOCKER:-false}" == "true" ]]; then
    pkgs+=" docker dockerd docker-compose luci-app-dockerman"
  fi

  # ④ 【关键】严格过滤包名
  #
  #    合法包名 = 字母数字开头，只含 [a-zA-Z0-9._+-]，可带 `-` 前导（排除标记），
  #    可带 `=version` 后缀（版本 pin）。
  #
  #    过滤过程：
  #      1. 把空格/制表/换行都转成换行（每行一个候选）
  #      2. grep 只保留合法包名
  #      3. sort -u 去重
  #      4. 转回空格分隔
  #
  #    这会自动过滤掉：
  #      - `#`（注释符号本身）
  #      - `----`（多个连字符开头，不是合法包名）
  #      - `网卡（有线）`（非 ASCII）
  #      - `PVE`（只是大写字母，但会被保留 —— 实际上 PVE 是包名吗？NO！）
  #
  #    等等，`PVE` 是大写字母，符合 `^[a-zA-Z0-9]` 但...它确实是中文注释里的词。
  #    问题：`PVE` 恰好符合包名格式，无法通过正则排除！
  #
  #    所以光过滤不够，必须同时把 PACKAGES_ARCH_EXTRA 里的中文注释删掉。
  PACKAGES=$(echo "$pkgs" \
    | tr ' \t\n' '\n\n\n' \
    | grep -E '^-?[a-z0-9][a-z0-9._+-]*(=[a-zA-Z0-9._+~-]+)?$' \
    | sort -u \
    | tr '\n' ' ' \
    | xargs)

  # 兜底检查：如果还有非小写的项，说明 PACKAGES_ARCH_EXTRA 里还有中文注释
  local suspicious
  suspicious=$(echo "$PACKAGES" | tr ' ' '\n' | grep -vE '^(-?[a-z0-9][a-z0-9._+-]*(=[a-zA-Z0-9._+~-]+)?)?$' || true)
  if [[ -n "$suspicious" ]]; then
    log_warn "以下项不符合包名格式（可能来自 PACKAGES_ARCH_EXTRA 的注释）："
    echo "$suspicious" | sed 's/^/    /'
    log_warn "建议把 target conf 的 PACKAGES_ARCH_EXTRA 里的中文注释全部删掉"
  fi

  log_ok "预装包数: $(echo "$PACKAGES" | wc -w)"
}

# ========== 6b. 从 GitHub Release 抓自建包 ==========
fetch_custom_packages() {
  # 过滤注释和空行。
  # ⚠️ grep -v 在「全部匹配」（即没有任何输出行）时返回 1，
  #    加上 pipefail + set -e 会让整个脚本静默退出 —— 必须 || true。
  local assets_clean
  assets_clean=$(echo "$CUSTOM_ASSETS" | grep -vE '^[[:space:]]*(#|$)' || true)

  if [[ -z "$assets_clean" ]]; then
    log_info "CUSTOM_ASSETS 为空，跳过自建包抓取"
    return 0
  fi

  # 确保 IB_DIR/packages/ 存在（IB 解压后一般已有，但保险起见）
  mkdir -p "$IB_DIR/packages"

  # CUSTOM_ASSETS 必须显式 export（source 只设 shell 变量不导出）
  export CUSTOM_ASSETS
  export ARCH_PACKAGES
  export GH_TOKEN="${GITHUB_TOKEN:-}"

  local env_file="$WORK_DIR/custom-packages.env"

  if ! python3 "$ROOT/scripts/fetch-custom-packages.py" \
       --dest "$IB_DIR/packages" \
       --out-env "$env_file"; then
    log_error "自建包抓取失败"
    exit 1
  fi

  # 读回 CUSTOM_PKGS 并追加到 PACKAGES
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    . "$env_file"
    if [[ -n "${CUSTOM_PKGS:-}" ]]; then
      # 去掉等号后面的版本号，避免 apk 报 "breaks: world" 的版本冲突错误
      CLEAN_PKGS=""
      for pkg in $CUSTOM_PKGS; do
        CLEAN_PKGS="$CLEAN_PKGS ${pkg%%=*}"
      done
      
      PACKAGES="$PACKAGES $CLEAN_PKGS"
      PACKAGES=$(echo "$PACKAGES" | xargs)
      log_ok "自建包已追加，总计: $(echo "$PACKAGES" | wc -w) 个"
    fi
  fi
}
  
# ========== 7. 准备覆盖层（占位符替换） ==========
stage_overlay() {
  local overlay="$WORK_DIR/overlay"
  rm -rf "$overlay"
  mkdir -p "$overlay"

  [[ -d "$ROOT/files" ]] && cp -a "$ROOT/files/." "$overlay/"

  local build_date distrib_description is_bypass
  build_date=$(TZ=Asia/Shanghai date +%Y.%m.%d)
  
  # 新（与 oprx 一致：oR25.12.6-2026110214）
  local build_date_long
  build_date_long="${BUILD_DATE:-$(TZ=Asia/Shanghai date +%Y%m%d%H)}"
  distrib_description="${FW_TAG:-oR}${VERSION} built by ${AUTHOR}@${build_date_long}"
  
  is_bypass="false"
  [[ "$IS_BYPASS_ROUTER" == "true" ]] && is_bypass="true"

  # 通过环境变量传给 python
  export OV_DIR="$overlay"
  export OV_HOSTNAME="$HOSTNAME"
  export OV_BRAND="$BRAND"
  export OV_VERSION="$VERSION"
  export OV_TIMEZONE="$TIMEZONE"
  export OV_ZONENAME="$ZONENAME"
  export OV_LUCI_LANG="$LUCI_LANG"
  export OV_NTP_SERVERS="$NTP_SERVERS"
  export OV_LAN_IP="$LAN_IP"
  export OV_LAN_NETMASK="$LAN_NETMASK"
  export OV_IS_BYPASS="$is_bypass"
  export OV_GATEWAY_IP="$GATEWAY_IP"
  export OV_DNS_SERVERS="$DNS_SERVERS"
  export OV_ROOT_HASH="$ROOT_PASSWORD_HASH"
  export OV_ROOT_PLAIN="$ROOT_PASSWORD_PLAIN"
  export OV_SSH_PORT="$SSH_PORT"
  export OV_NF_CONNTRACK_MAX="$NF_CONNTRACK_MAX"
  export OV_ENABLE_BBR="$ENABLE_BBR"
  export OV_ENABLE_ZRAM="$ENABLE_ZRAM"
  export OV_ZRAM_PERCENT="$ZRAM_PERCENT"
  export OV_ZRAM_ALGO="$ZRAM_ALGO"
  export OV_INTEL_PSTATE="${ENABLE_INTEL_PSTATE:-false}"
  export OV_CPU_GOVERNOR="${CPU_GOVERNOR:-powersave}"
  export OV_TARGET="$TARGET"
  export OV_SUBTARGET="$SUBTARGET"
  export OV_ARCH="$ARCH_PACKAGES"
  export OV_BUILD_DATE="$build_date"
  export OV_DESCRIPTION="$distrib_description"

  python3 <<'PYEOF'
import os, io

overlay = os.environ['OV_DIR']
vals = {
    '__HOSTNAME__':            os.environ['OV_HOSTNAME'],
    '__BRAND__':               os.environ['OV_BRAND'],
    '__VERSION__':             os.environ['OV_VERSION'],
    '__TIMEZONE__':            os.environ['OV_TIMEZONE'],
    '__ZONENAME__':            os.environ['OV_ZONENAME'],
    '__LUCI_LANG__':           os.environ['OV_LUCI_LANG'],
    '__NTP_SERVERS__':         os.environ['OV_NTP_SERVERS'],
    '__LAN_IP__':              os.environ['OV_LAN_IP'],
    '__LAN_NETMASK__':         os.environ['OV_LAN_NETMASK'],
    '__IS_BYPASS__':           os.environ['OV_IS_BYPASS'],
    '__GATEWAY_IP__':          os.environ['OV_GATEWAY_IP'],
    '__DNS_SERVERS__':         os.environ['OV_DNS_SERVERS'],
    '__ROOT_PASSWORD_HASH__':  os.environ['OV_ROOT_HASH'],
    '__ROOT_PASSWORD_PLAIN__': os.environ['OV_ROOT_PLAIN'],
    '__SSH_PORT__':            os.environ['OV_SSH_PORT'],
    '__NF_CONNTRACK_MAX__':    os.environ['OV_NF_CONNTRACK_MAX'],
    '__ENABLE_BBR__':          os.environ['OV_ENABLE_BBR'],
    '__ENABLE_ZRAM__':         os.environ['OV_ENABLE_ZRAM'],
    '__ZRAM_PERCENT__':        os.environ['OV_ZRAM_PERCENT'],
    '__ZRAM_ALGO__':           os.environ['OV_ZRAM_ALGO'],
    '__ENABLE_INTEL_PSTATE__': os.environ['OV_INTEL_PSTATE'],
    '__CPU_GOVERNOR__':        os.environ['OV_CPU_GOVERNOR'],
    '__TARGET__':              os.environ['OV_TARGET'],
    '__SUBTARGET__':           os.environ['OV_SUBTARGET'],
    '__ARCH_PACKAGES__':       os.environ['OV_ARCH'],
    '__BUILD_DATE__':          os.environ['OV_BUILD_DATE'],
    '__DISTRIB_DESCRIPTION__': os.environ['OV_DESCRIPTION'],
}

n = 0
for root, _, files in os.walk(overlay):
    for f in files:
        path = os.path.join(root, f)
        try:
            with io.open(path, 'r', encoding='utf-8') as fh:
                content = fh.read()
        except (UnicodeDecodeError, IOError):
            continue
        orig = content
        for k, v in vals.items():
            if k in content:
                content = content.replace(k, v)
        if content != orig:
            with io.open(path, 'w', encoding='utf-8') as fh:
                fh.write(content)
            n += 1
print(f'  已替换 {n} 个文件')
PYEOF

  # 未替换检查（跳过注释行）
  #
  # 为什么跳过注释行：
  #   - 静态文件里的注释常会写 "所有 __XXX__ 占位符由 build.sh 替换" 这类说明，
  #     这里的 __XXX__ 是字面量，不是真占位符，应排除。
  #   - 大部分静态文件（shell 脚本、uci 配置文件、crontab、sysctl.d）都用 # 注释，
  #     所以按「行首（可带空白）是 #」来判断，足够覆盖。
  #   - 占位符出现在行中间且前面有 # 的极端情况（如 `foo # __XXX__`）会被漏掉，
  #     这种场景罕见，且 build.sh 的 python 替换阶段仍会处理，这里只是"预警"，
  #     不影响产物正确性。
  #
  # grep -I：忽略二进制文件（overlay 里可能有 .dat、.bin 等）
  local leftover
  leftover=$(grep -rIE '__[A-Z_]+__' "$overlay" 2>/dev/null \
             | grep -vE ':[[:space:]]*#' \
             | head -10 || true)
  if [[ -n "$leftover" ]]; then
    log_error "有未替换的占位符（已排除注释行）："
    echo "$leftover"
    exit 1
  fi

  # uci-defaults 静态守卫（对所有脚本生效）
  #
  # 检查 1：语法必须过。语法错要到设备上才暴露，太晚。
  #
  # 检查 2：不许 `exit <非 0>`。
  #   /etc/init.d/boot 的 uci_apply_defaults 用 `( . file ) && applied=...`
  #   判断脚本是否跑成功；返回非 0 会让脚本留在原地，每次启动重跑。
  #   ⚠️ `exit 0` 是合法的判板早退写法（boot 在子 shell 里 source，
  #   exit 只退出那个子 shell、不牵连调用方），不要一并禁掉。
  #
  # 参考：openwrt-imagebuilder 那边 25.12.x 期间实测该行为（run 39233383588 等）。
  if [[ -d "$overlay/etc/uci-defaults" ]]; then
    local f base
    for f in "$overlay"/etc/uci-defaults/*; do
      [[ -f "$f" ]] || continue
      base=$(basename "$f")

      if ! sh -n "$f" 2>/tmp/uci-syntax.err; then
        log_error "uci-defaults 语法错误: $base"
        cat /tmp/uci-syntax.err
        rm -f /tmp/uci-syntax.err
        exit 1
      fi

      if grep -nE '^[[:space:]]*exit[[:space:]]+[1-9]' "$f" >/tmp/uci-exit.txt 2>&1; then
        log_error "$base 里有 exit <非 0>：脚本不会被删除、每次启动都会重跑"
        cat /tmp/uci-exit.txt
        rm -f /tmp/uci-exit.txt
        exit 1
      fi
      rm -f /tmp/uci-exit.txt

      chmod 0755 "$f"
    done
    rm -f /tmp/uci-syntax.err
  fi

  log_ok "覆盖层准备完成"
}

# ========== 8. 构建（5 轮自愈） ==========
make_image_with_self_heal() {
  local log="$WORK_DIR/build.log"
  local overlay="$WORK_DIR/overlay"
  local bin="$IB_DIR/bin/targets/${TARGET}/${SUBTARGET}"
  local round=0
  local max=5
  local skipped=""
  local protected='^(base-files|libc|busybox|uci|procd|netifd|fstools|firewall4|dropbear|libgcc|kernel)$'

  while :; do
    round=$((round + 1))
    log_info "第 ${round} 轮构建..."

    if make -C "$IB_DIR" image \
         PROFILE="$PROFILE" \
         PACKAGES="$PACKAGES" \
         FILES="$overlay" \
         ROOTFS_PARTSIZE="$ROOTFS_SIZE_MB" \
         EXTRA_IMAGE_NAME="$EXTRA_IMAGE_NAME" \
         #> "$log" 2>&1; then  #静默，不产生详细的构建日志
		 2>&1 | tee "$log"; then  #产生详细的构建日志
      log_ok "构建成功"
      break
    fi

    # 失败但产物已生成？直接成功
    if [[ -d "$bin" ]] && find "$bin" -maxdepth 1 -name "*.img.gz" | grep -q .; then
      log_warn "make 报错但产物已生成，继续"
      break
    fi

    # 提取缺失包
    local missing
    missing=$(
      {
        sed -nE 's/^[[:space:]]*([^ ]+) \(no such package\):[[:space:]]*$/\1/p' "$log" 2>/dev/null
        sed -nE 's/.*Cannot install package ([^ ]+)\.$/\1/p' "$log" 2>/dev/null
        sed -nE "s/.*Unknown package '([^']+)'.*/\1/p" "$log" 2>/dev/null
      } | sort -u | grep -v '^$' || true
    )

    if [[ -z "$missing" ]]; then
      log_error "❌ 构建失败，且未识别到常规的缺失包。正在全面扫描日志提取真正的错误原因..."
      
      # 提取日志中所有包含 error / conflict / fail / abort 的行，并排除无关警告
      local real_errors
      real_errors=$(grep -iE "error|fail|conflict|overwrite|abort" "$log" | grep -viE "WARNING: updating|falling back|No such file|no default route" | tail -n 20 || true)
      
      if [ -n "$real_errors" ]; then
        log_error "================ 🚨 提取到的致命错误 ================"
        echo "$real_errors"
        log_error "===================================================="
      fi
      
      log_error "--- 日志末尾 30 行 ---"
      tail -30 "$log"
      
      log_warn "💡 诊断建议：如果刚刚添加了新的第三方包，请使用二分法将其注释掉重试。"
      exit 1
    fi

    # 保护核心包
    local prot
    prot=$(echo "$missing" | grep -E "$protected" || true)
    if [[ -n "$prot" ]]; then
      log_error "关键包缺失，无法自愈："
      echo "$prot"
      exit 1
    fi

    if [[ "$round" -ge "$max" ]]; then
      log_error "已达自愈上限 ${max} 轮"
      exit 1
    fi

    log_warn "剔除缺失包："
    echo "$missing" | sed 's/^/    /'
    skipped+=" $(echo "$missing" | xargs)"

	# 在 for pkg in $missing 循环里
	for pkg in $missing; do
		if ! echo " $PACKAGES " | grep -qE " ${pkg}(=[0-9][^ ]*)? "; then
			log_error "缺失包 $pkg 不在 PACKAGES 里（是依赖），无法通过剔除自愈"
			log_error "  请检查 build.log 里 'cannot find dependency $pkg for XXX'，找到依赖它的包"
			log_error "  然后从 common-pkgs.list / custom-assets.txt / PACKAGES_ARCH_EXTRA 里移除那个包"
			exit 1
		fi
		PACKAGES=$(echo " $PACKAGES " | sed -E "s| ${pkg}(=[0-9][^ ]*)? | |g" | xargs)
	done
  done

  if [[ -n "$skipped" ]]; then
    echo "$skipped" | tr ' ' '\n' | grep -v '^$' > "$OUTPUT_DIR/skipped-packages.txt" || true
  fi
}

# ========== 9. 验证 ==========
verify_output() {
  local bin="$IB_DIR/bin/targets/${TARGET}/${SUBTARGET}"
  [[ -d "$bin" ]] || { log_error "产物目录不存在: $bin"; exit 1; }

  local manifest
  manifest=$(find "$bin" -maxdepth 1 -name '*.manifest' 2>/dev/null | head -1)
  if [[ -n "$manifest" ]]; then
    local miss=0
    for pkg in $PACKAGES; do
      local name="${pkg%%=*}"
      [[ "$name" == -* ]] && continue
      grep -qE "^${name} " "$manifest" || { log_warn "包不在 manifest: $name"; miss=$((miss + 1)); }
    done
    [[ "$miss" -eq 0 ]] && log_ok "所有预装包都在 manifest 中"
  fi

  [[ -f "$WORK_DIR/overlay/etc/uci-defaults/99-custom" ]] \
    || { log_error "覆盖层 99-custom 不存在"; exit 1; }
}

# ========== 10. 收集产物 ==========
collect_artifacts() {
  local bin="$IB_DIR/bin/targets/${TARGET}/${SUBTARGET}"

  # ---- 根据 GENERATE_* 开关组装要生成的变体列表 ----
  local variants=()

  if [[ "$TARGET" == "x86" ]]; then
    # x86：ext4/squashfs × combined-efi/combined
    if [[ "${GENERATE_EXT4:-false}" == "true" ]]; then
      [[ "${GENERATE_COMBINED_EFI:-false}" == "true" ]] && variants+=("ext4-combined-efi")
      [[ "${GENERATE_COMBINED:-false}" == "true" ]]     && variants+=("ext4-combined")
    fi
    if [[ "${GENERATE_SQUASHFS:-false}" == "true" ]]; then
      [[ "${GENERATE_COMBINED_EFI:-false}" == "true" ]] && variants+=("squashfs-combined-efi")
      [[ "${GENERATE_COMBINED:-false}" == "true" ]]     && variants+=("squashfs-combined")
    fi
  else
    # ARM（rockchip / armsr / bcm27xx 等）：ext4/squashfs × sysupgrade
    if [[ "${GENERATE_SYSUPGRADE:-true}" == "true" ]]; then
      [[ "${GENERATE_EXT4:-false}" == "true" ]]      && variants+=("ext4-sysupgrade")
      [[ "${GENERATE_SQUASHFS:-false}" == "true" ]]  && variants+=("squashfs-sysupgrade")
    fi
  fi

  # ---- 兜底：开关全关时用 RELEASE_VARIANT ----
  if [[ ${#variants[@]} -eq 0 ]]; then
    if [[ -n "${RELEASE_VARIANT:-}" ]]; then
      variants=("$RELEASE_VARIANT")
      log_warn "GENERATE_* 开关组合出空列表，回退到 RELEASE_VARIANT=${RELEASE_VARIANT}"
    else
      log_error "没有任何产物格式可生成：请至少启用 GENERATE_EXT4 / GENERATE_SQUASHFS 之一，"
      log_error "并启用对应的引导方式（GENERATE_COMBINED_EFI / GENERATE_COMBINED / GENERATE_SYSUPGRADE）"
      exit 1
    fi
  fi

  log_info "本次要生成的变体（${#variants[@]} 个）：${variants[*]}"

  local build_date="${BUILD_DATE:-$(TZ=Asia/Shanghai date +%Y%m%d%H)}"
  local brand="${BRAND:-OprX}"
  local fw_tag="${FW_TAG:-oR}"

  local first_out=""
  local variant

  for variant in "${variants[@]}"; do
    log_step "处理变体: $variant"

    local match="*-${variant}.img.gz"
    local hits n_hits
    hits=$(find "$bin" -maxdepth 1 -type f -name "$match" 2>/dev/null)
    n_hits=$(echo "$hits" | grep -c . || true)

    if [[ "$n_hits" -eq 0 ]]; then
      log_warn "  变体 '$variant' 未找到产物（跳过）"
      continue
    fi
    if [[ "$n_hits" -gt 1 ]]; then
      log_error "  变体 '$variant' 匹配到 $n_hits 个产物（应为 1 个）"
      echo "$hits"
      exit 1
    fi

    local img="$hits"
    local fname out
    fname=$(basename "$img")
	
	# 把 variant 里的 efi 替换成 uefi（仅影响文件名）
    local name_variant="${variant//efi/uefi}"

    # 固件名：${BRAND}-${IB_DISTRO}-${FW_TAG}${VERSION}-${BUILD_DATE}-${ARCH}-${NAME_VARIANT}.img.gz
	# 示例（IB_DISTRO="openwrt", FW_TAG="oR", VERSION="25.12.6"）：
	#   OprX-openwrt-oR25.12.6-2026110214-x86_64-squashfs-combined-uefi.img.gz
	# 示例（IB_DISTRO="immortalwrt", FW_TAG="oR", VERSION="25.12.2"）：
	#   OprX-immortalwrt-oR25.12.2-2026110214-x86_64-squashfs-combined-uefi.img.gz
    out="${brand}-${IB_DISTRO}-${fw_tag}${VERSION}-${build_date}-${ARCH}-${name_variant}.img.gz"

    cp -f "$img" "$OUTPUT_DIR/$out"
    ( cd "$OUTPUT_DIR" && sha256sum "$out" > "$out.sha256" )
    log_ok "  产物: $out"
    log_info "    (原: $fname)"

    [[ -z "$first_out" ]] && first_out="$out"

    # ---- gzip 完整性检查（fwtool 感知）----
    local rc=0
    gzip -t "$OUTPUT_DIR/$out" 2>/tmp/gzip-check.err || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      log_ok "  gzip 完整（纯 gzip 流）"
    elif [[ "$rc" -eq 2 ]] && grep -q 'decompression OK' /tmp/gzip-check.err; then
      log_ok "  gzip 完整（尾部 fwtool 元数据）"
      if ! tail -c 8192 "$OUTPUT_DIR/$out" | grep -a 'supported_devices' > /dev/null; then
        log_error "  $out: 尾部缺 supported_devices"
        exit 1
      fi
    else
      log_error "  $out: gzip 检查失败 (rc=$rc)"
      cat /tmp/gzip-check.err
      exit 1
    fi
    rm -f /tmp/gzip-check.err

    # ---- VMDK（受 GENERATE_VMDK 控制，仅 x86）----
    if [[ "${GENERATE_VMDK:-false}" == "true" ]] \
       && [[ "$TARGET" == "x86" ]] \
       && command -v qemu-img >/dev/null 2>&1; then
      log_info "  生成 VMDK..."
      local b tmp
      b=$(basename "$OUTPUT_DIR/$out" .img.gz)
      tmp="/tmp/${b}.img"
      gzip -dc "$OUTPUT_DIR/$out" > "$tmp"
      qemu-img convert -f raw -O vmdk "$tmp" "$OUTPUT_DIR/${b}.vmdk"
      rm -f "$tmp"
      log_ok "  VMDK: ${b}.vmdk"
    fi
  done

  if [[ -z "$first_out" ]]; then
    log_error "所有变体都没有产物，检查 make image 是否成功"
    ls -la "$bin"
    exit 1
  fi

  if [[ "${GENERATE_VMDK:-false}" != "true" ]] && [[ "$TARGET" == "x86" ]]; then
    log_info "GENERATE_VMDK=false，不生成 VMDK"
  fi

  # ---- 生成 onup 在线升级 JSON（文件名跟随 FW_TAG）----
  log_info "生成 ${fw_tag}.json..."
  local gen_script="$ROOT/scripts/gen-onup-json.sh"
  if [[ ! -f "$gen_script" ]]; then
    log_error "找不到 $gen_script —— 请先创建这个脚本"
    exit 1
  fi

  local onup_repo="${ONUP_REPO:-ilxp/oprx-imagebuilder}"
  local onup_tag="${ONUP_JSON_TAG:-firmware}"
  local re_url="https://github.com/${onup_repo}/releases/download/${onup_tag}"

  local logs_arg=()
  [[ -f "$ROOT/CHANGELOG.md" ]] && logs_arg=(--logs "$ROOT/CHANGELOG.md")

  if ! bash "$gen_script" \
    --fw-file    "$OUTPUT_DIR/$first_out" \
    --out        "$OUTPUT_DIR/${fw_tag}.json" \
    --profile    "$ARCH_PACKAGES" \
    --re-url     "$re_url" \
    --build-date "$build_date" \
    "${logs_arg[@]}"; then
    log_error "gen-onup-json.sh 执行失败"
    exit 1
  fi
  log_ok "${fw_tag}.json 已生成: $OUTPUT_DIR/${fw_tag}.json"

  # 输出实际构建的版本号（如 25.12.6）和标签（如oR），供 CI 的 Release 步骤读取并作为 Tag
  echo "${VERSION}" > "$OUTPUT_DIR/version.txt"
  echo "${FLAG:-oR}" > "$OUTPUT_DIR/flag.txt"

  ( cd "$OUTPUT_DIR" && ls -lh )
  log_ok "完成，产物在: $OUTPUT_DIR"
}

# ========== 主流程 ==========
main() {
  # 时间戳锁定一次，全流程共享（镜像文件名、JSON build_date、版本描述）
  export BUILD_DATE="$(TZ=Asia/Shanghai date +%Y%m%d%H)"
  
  log_step "加载配置"
  load_config
  log_info "版本:   $VERSION"
  log_info "目标:   $ARCH ($TARGET/$SUBTARGET)"
  log_info "Profile:$PROFILE"
  # 从 RELEASE_VARIANT 里提取文件系统前缀（squashfs / ext4）
  local fs_hint="${RELEASE_VARIANT%%-*}"
  log_info "分区:   ${ROOTFS_SIZE_MB} MB (${fs_hint})"

  log_step "准备目录";       prepare_dirs
  log_step "下载 IB";        download_imagebuilder
  log_step "打补丁";          patch_imagebuilder
  log_step "准备仓库";       prepare_repos
  log_step "收集预装包";      collect_packages
  log_step "抓取自建包";      fetch_custom_packages
  log_step "准备覆盖层";      stage_overlay
  log_step "构建";            make_image_with_self_heal
  log_step "验证";            verify_output
  log_step "收集产物";        collect_artifacts

  log_ok "全部完成！"
}

main "$@"