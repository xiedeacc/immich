#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="${VERSION:-v3.0.1}"
REPO_DIR="${REPO_DIR:-/opt/software/src/immich}"
APP_DIR="${APP_DIR:-/opt/immich}"
UPLOAD_DIR="${UPLOAD_DIR:-/opt/immich/upload}"
BUILD_ROOT="${BUILD_ROOT:-$REPO_DIR/immich-build}"
TOOL_ROOT="${TOOL_ROOT:-/opt/software/src/tools}"
RUN_USER="${RUN_USER:-tiger}"
RUN_GROUP="${RUN_GROUP:-tiger}"
TOOL_BIN="$TOOL_ROOT/bin"
MISE_DATA_DIR="${MISE_DATA_DIR:-$TOOL_ROOT/mise}"
MISE_CACHE_DIR="${MISE_CACHE_DIR:-$TOOL_ROOT/mise-cache}"
MISE_VERSION="${MISE_VERSION:-v2026.6.10}"
UV_VERSION="${UV_VERSION:-0.8.15}"
UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$TOOL_ROOT/uv-python}"
NODE_HOME="${NODE_HOME:-/opt/software/src/tools/nvm/versions/node/v24.18.0}"
PNPM_BIN="${PNPM_BIN:-$NODE_HOME/bin/pnpm}"
NODE_BIN="${NODE_BIN:-$NODE_HOME/bin/node}"
NPM_BIN="${NPM_BIN:-$NODE_HOME/bin/npm}"
UV_BIN="${UV_BIN:-$TOOL_BIN/uv}"
BUILD_DIR="$BUILD_ROOT/source-$VERSION"
STAGING_DIR="$BUILD_ROOT/staging-$VERSION"
CODE_BACKUP_DIR="$APP_DIR/code-backups/$(date +%Y%m%dT%H%M%S)-from-2.5.6"

log() {
  printf '[%s] %s\n' "$(date +%F\ %T)" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 运行此脚本，因为需要停止/启动 systemd 服务并写入 $APP_DIR"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

detect_uv_target() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x86_64-unknown-linux-gnu' ;;
    aarch64 | arm64) printf 'aarch64-unknown-linux-gnu' ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

install_mise_if_missing() {
  if [ -x "$TOOL_BIN/mise" ]; then
    return
  fi

  local arch url target
  arch="$(detect_arch)"
  url="https://github.com/jdx/mise/releases/download/$MISE_VERSION/mise-$MISE_VERSION-linux-$arch"
  target="$TOOL_BIN/mise"

  log "未找到 mise，安装到 $target"
  mkdir -p "$TOOL_BIN"
  curl -fL "$url" -o "$target"
  chmod 0755 "$target"
}

install_uv_if_missing() {
  if [ -x "$UV_BIN" ]; then
    if "$UV_BIN" --version | grep -q "uv $UV_VERSION"; then
      return
    fi
    log "发现 uv 版本不是 $UV_VERSION，将替换为 Immich 要求的版本"
  fi

  local target archive tmpdir
  target="$(detect_uv_target)"
  archive="uv-$target.tar.gz"
  tmpdir="$(mktemp -d)"

  log "安装 uv $UV_VERSION 到 $TOOL_BIN"
  mkdir -p "$TOOL_BIN"
  curl -fL "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/$archive" -o "$tmpdir/$archive"
  tar -xzf "$tmpdir/$archive" -C "$tmpdir"
  install -m 0755 "$tmpdir/uv-$target/uv" "$TOOL_BIN/uv"
  install -m 0755 "$tmpdir/uv-$target/uvx" "$TOOL_BIN/uvx"
  rm -rf "$tmpdir"
  [ -x "$UV_BIN" ] || die "uv 安装失败：$UV_BIN"
}

ensure_tools() {
  require_command curl
  install_mise_if_missing
  install_uv_if_missing
  export PATH="$TOOL_BIN:$PATH"
}

verify_paths() {
  [ -d "$REPO_DIR/.git" ] || die "源码仓库不存在：$REPO_DIR"
  [ -d "$APP_DIR" ] || die "应用目录不存在：$APP_DIR"
  [ -d "$UPLOAD_DIR" ] || die "上传目录不存在：$UPLOAD_DIR"
  [ "$(realpath "$UPLOAD_DIR")" = "$(realpath "$APP_DIR/upload")" ] || die "UPLOAD_DIR 必须指向 $APP_DIR/upload"
  getent passwd "$RUN_USER" >/dev/null || die "运行用户不存在：$RUN_USER"
  getent group "$RUN_GROUP" >/dev/null || die "运行用户组不存在：$RUN_GROUP"
  [ -x "$NODE_BIN" ] || die "Node 不存在或不可执行：$NODE_BIN"
  [ -x "$PNPM_BIN" ] || die "pnpm 不存在或不可执行：$PNPM_BIN"
  [ -x "$NPM_BIN" ] || die "npm 不存在或不可执行：$NPM_BIN"
  [ -n "$UV_BIN" ] && [ -x "$UV_BIN" ] || die "uv 不存在或不可执行"
}

prepare_source() {
  log "获取 $VERSION 源码"
  git -C "$REPO_DIR" fetch --tags origin "$VERSION"
  cleanup_worktree
  rm -rf "$BUILD_DIR" "$STAGING_DIR"
  mkdir -p "$BUILD_ROOT" "$STAGING_DIR"
  git -C "$REPO_DIR" worktree add --detach "$BUILD_DIR" "$VERSION"
}

build_server() {
  log "构建 server"
  export PATH="$NODE_HOME/bin:$PATH"
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  export SHARP_IGNORE_GLOBAL_LIBVIPS=true

  cd "$BUILD_DIR"
  if [ -d "$BUILD_DIR/cli" ]; then
    "$PNPM_BIN" --filter @immich/sdk --filter @immich/plugin-sdk --filter immich --filter @immich/cli install --frozen-lockfile
    "$PNPM_BIN" --filter @immich/sdk --filter @immich/plugin-sdk --filter immich --filter @immich/cli build
  else
    "$PNPM_BIN" --filter @immich/sdk --filter @immich/plugin-sdk --filter immich install --frozen-lockfile
    "$PNPM_BIN" --filter @immich/sdk --filter @immich/plugin-sdk --filter immich build
  fi

  export SHARP_FORCE_GLOBAL_LIBVIPS=true
  "$PNPM_BIN" --filter immich --prod deploy "$STAGING_DIR/server"
  rebuild_sharp_with_system_libvips "$STAGING_DIR/server"
  if [ -d "$BUILD_DIR/cli" ]; then
    log "构建 CLI"
    "$PNPM_BIN" --filter @immich/cli --prod --no-optional deploy "$STAGING_DIR/cli"
    ln -sfn ../../cli/bin/immich "$STAGING_DIR/server/bin/immich"
  else
    log "当前源码不包含 CLI workspace，跳过 CLI"
  fi
  verify_sharp_runtime "$STAGING_DIR/server"
}

rebuild_sharp_with_system_libvips() {
  local server_dir="$1"

  log "重编译 sharp，使其链接系统 libvips 并支持 HEIC"
  require_command pkg-config
  pkg-config --atleast-version=8.17.3 vips-cpp || die "系统 libvips 版本不足，sharp 需要 vips-cpp >= 8.17.3"

  # pnpm's isolated layout can leave node-gyp's relative lookup one directory
  # above the deployed server tree. Expose that package at the expected path.
  node_gyp_pkg="$(find "$server_dir/node_modules/.pnpm" -maxdepth 1 -type d -name 'node-gyp@*' 2>/dev/null | head -1)"
  if [ -n "$node_gyp_pkg" ]; then
    node_gyp_base="$(basename "$node_gyp_pkg")"
    node_gyp_link="$STAGING_DIR/$node_gyp_base"
    if [ ! -e "$node_gyp_link" ]; then
      ln -s "server/node_modules/.pnpm/$node_gyp_base" "$node_gyp_link"
    fi
  fi

  cd "$server_dir/node_modules/sharp"
  env -u SHARP_IGNORE_GLOBAL_LIBVIPS \
    PATH="$server_dir/node_modules/sharp/node_modules/.bin:$NODE_HOME/bin:$PATH" \
    SHARP_FORCE_GLOBAL_LIBVIPS=true \
    npm_config_build_from_source=true \
    "$NODE_BIN" install/build.js

  "$NODE_BIN" - <<NODE
const sharp = require('$server_dir/node_modules/sharp');
const suffixes = sharp.format.heif?.input?.fileSuffix || [];
if (!suffixes.includes('.heic') || !suffixes.includes('.heif')) {
  throw new Error('sharp HEIC support missing: ' + suffixes.join(','));
}
NODE
}

verify_sharp_runtime() {
  local server_dir="$1"

  if "$NODE_BIN" -e "require('$server_dir/node_modules/sharp')" >/dev/null 2>&1; then
    return
  fi

  die "sharp 运行时依赖缺失，请检查 pnpm deploy 是否安装了当前 Linux 平台的 optional dependencies"
}

build_web() {
  log "构建 web"
  export PATH="$NODE_HOME/bin:$PATH"
  export SHARP_IGNORE_GLOBAL_LIBVIPS=true

  cd "$BUILD_DIR"
  "$PNPM_BIN" --filter @immich/sdk --filter immich-web install --frozen-lockfile --force
  "$PNPM_BIN" --filter @immich/sdk --filter immich-web build

  mkdir -p "$STAGING_DIR/web"
  rsync -a --delete "$BUILD_DIR/web/build/" "$STAGING_DIR/web/build/"
}

build_plugins() {
  log "构建 core plugin"
  export PATH="$TOOL_BIN:$NODE_HOME/bin:$PATH"
  export MISE_DATA_DIR
  export MISE_CACHE_DIR

  cd "$BUILD_DIR"
  MISE_TRUSTED_CONFIG_PATHS="$REPO_DIR/mise.toml:$BUILD_DIR/mise.toml" MISE_DISABLE_TOOLS=flutter "$TOOL_BIN/mise" //:plugins

  install -d "$STAGING_DIR/plugins/immich-plugin-core"
  rsync -a --delete "$BUILD_DIR/packages/plugin-core/dist/" "$STAGING_DIR/plugins/immich-plugin-core/dist/"
  install -m 0644 "$BUILD_DIR/packages/plugin-core/manifest.json" "$STAGING_DIR/plugins/immich-plugin-core/manifest.json"
}

build_machine_learning() {
  log "准备 machine-learning"
  rsync -a \
    --exclude '.cache/' \
    --exclude '__pycache__/' \
    "$BUILD_DIR/machine-learning/" "$STAGING_DIR/machine-learning/"

  cd "$STAGING_DIR/machine-learning"
  UV_PYTHON_INSTALL_DIR="$UV_PYTHON_INSTALL_DIR" UV_LINK_MODE=copy "$UV_BIN" sync --extra cpu --no-dev --compile-bytecode
}

copy_static_assets() {
  log "准备 geodata、i18n 和根配置文件"
  if [ -d "$BUILD_DIR/geodata" ]; then
    rsync -a --delete "$BUILD_DIR/geodata/" "$STAGING_DIR/geodata/"
  elif geodata_complete "$APP_DIR/geodata"; then
    log "复用现有 geodata"
    rsync -a --delete "$APP_DIR/geodata/" "$STAGING_DIR/geodata/"
  else
    download_geodata "$STAGING_DIR/geodata"
  fi
  rsync -a --delete "$BUILD_DIR/i18n/" "$STAGING_DIR/i18n/"
  install -m 0644 "$BUILD_DIR/package.json" "$STAGING_DIR/package.json"
  install -m 0644 "$BUILD_DIR/pnpm-lock.yaml" "$STAGING_DIR/pnpm-lock.yaml"
  install -m 0644 "$BUILD_DIR/pnpm-workspace.yaml" "$STAGING_DIR/pnpm-workspace.yaml"
  install -m 0644 "$BUILD_DIR/.pnpmfile.cjs" "$STAGING_DIR/.pnpmfile.cjs"
  install -m 0644 "$BUILD_DIR/LICENSE" "$STAGING_DIR/LICENSE"
}

geodata_complete() {
  local dir="$1"
  [ -s "$dir/admin1CodesASCII.txt" ] &&
    [ -s "$dir/admin2Codes.txt" ] &&
    [ -s "$dir/cities500.txt" ] &&
    [ -s "$dir/geodata-date.txt" ] &&
    [ -s "$dir/ne_10m_admin_0_countries.geojson" ]
}

download_geodata() {
  local dir="$1"
  local geonames=https://download.geonames.org/export/dump
  local natural_earth=https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson

  require_command unzip
  log "下载 Immich geodata"
  rm -rf "$dir"
  mkdir -p "$dir"
  curl -fL --retry 4 --retry-all-errors "$geonames/cities500.zip" -o "$dir/cities500.zip"
  curl -fL --retry 4 --retry-all-errors "$geonames/admin1CodesASCII.txt" -o "$dir/admin1CodesASCII.txt"
  curl -fL --retry 4 --retry-all-errors "$geonames/admin2Codes.txt" -o "$dir/admin2Codes.txt"
  curl -fL --retry 4 --retry-all-errors "$natural_earth" -o "$dir/ne_10m_admin_0_countries.geojson"
  unzip -oq "$dir/cities500.zip" -d "$dir"
  rm -f "$dir/cities500.zip"
  date --iso-8601=seconds | tr -d '\n' > "$dir/geodata-date.txt"
  chmod 0444 "$dir"/*
}

backup_code_only() {
  log "备份当前代码目录，不备份 $UPLOAD_DIR"
  mkdir -p "$CODE_BACKUP_DIR"
  rsync -a \
    --exclude '/upload/' \
    --exclude '/code-backups/' \
    "$APP_DIR/" "$CODE_BACKUP_DIR/"
}

deploy_staging() {
  log "停止 Immich 服务"
  systemctl stop immich.service immich-ml.service

  backup_code_only

  log "同步新版本代码到 $APP_DIR，明确排除 $UPLOAD_DIR"
  rsync -a --delete "$STAGING_DIR/server/" "$APP_DIR/server/"
  rsync -a --delete "$STAGING_DIR/web/build/" "$APP_DIR/web/build/"
  if [ -e "$APP_DIR/www" ] && [ ! -L "$APP_DIR/www" ]; then
    mv "$APP_DIR/www" "$APP_DIR/www.before-v3-symlink.$(date +%Y%m%dT%H%M%S)"
  fi
  ln -sfn "$APP_DIR/web/build" "$APP_DIR/www"
  rsync -a --delete "$STAGING_DIR/machine-learning/" "$APP_DIR/machine-learning/"
  rsync -a --delete "$STAGING_DIR/plugins/" "$APP_DIR/plugins/"
  if [ -d "$STAGING_DIR/geodata" ]; then
    rsync -a --delete "$STAGING_DIR/geodata/" "$APP_DIR/geodata/"
  else
    log "staging 中没有 geodata 目录，保留现有 $APP_DIR/geodata"
  fi
  rsync -a --delete "$STAGING_DIR/i18n/" "$APP_DIR/i18n/"
  if [ -d "$STAGING_DIR/cli" ]; then
    rsync -a --delete "$STAGING_DIR/cli/" "$APP_DIR/cli/"
  else
    rm -rf "$APP_DIR/cli"
  fi
  install -m 0644 "$STAGING_DIR/package.json" "$APP_DIR/package.json"
  install -m 0644 "$STAGING_DIR/pnpm-lock.yaml" "$APP_DIR/pnpm-lock.yaml"
  install -m 0644 "$STAGING_DIR/pnpm-workspace.yaml" "$APP_DIR/pnpm-workspace.yaml"
  install -m 0644 "$STAGING_DIR/.pnpmfile.cjs" "$APP_DIR/.pnpmfile.cjs"
  install -m 0644 "$STAGING_DIR/LICENSE" "$APP_DIR/LICENSE"

  code_paths=("$APP_DIR/server" "$APP_DIR/web" "$APP_DIR/www" "$APP_DIR/machine-learning" "$APP_DIR/plugins" "$APP_DIR/i18n" "$APP_DIR/package.json" "$APP_DIR/pnpm-lock.yaml" "$APP_DIR/pnpm-workspace.yaml" "$APP_DIR/.pnpmfile.cjs" "$APP_DIR/LICENSE")
  if [ -d "$APP_DIR/geodata" ]; then
    code_paths+=("$APP_DIR/geodata")
  fi
  if [ -d "$APP_DIR/cli" ]; then
    code_paths+=("$APP_DIR/cli")
  fi
  chown -R "$RUN_USER:$RUN_GROUP" "${code_paths[@]}"
  fix_code_permissions

  log "启动 Immich 服务"
  systemctl start immich-ml.service
  systemctl start immich.service
}

fix_code_permissions() {
  log "修正代码目录权限，保证 Nginx 和 systemd 服务可读"
  code_dirs=("$APP_DIR/server" "$APP_DIR/web" "$APP_DIR/machine-learning" "$APP_DIR/plugins" "$APP_DIR/i18n")
  if [ -d "$APP_DIR/geodata" ]; then
    code_dirs+=("$APP_DIR/geodata")
  fi
  if [ -d "$APP_DIR/cli" ]; then
    code_dirs+=("$APP_DIR/cli")
  fi
  find "${code_dirs[@]}" -type d -exec chmod 0755 {} +
  find "${code_dirs[@]}" -type f -exec chmod 0644 {} +
  executable_dirs=("$APP_DIR/server/node_modules" "$APP_DIR/machine-learning/.venv/bin")
  if [ -d "$APP_DIR/cli/bin" ]; then
    executable_dirs+=("$APP_DIR/cli/bin")
  fi
  find "${executable_dirs[@]}" -type f -perm /111 -exec chmod 0755 {} + 2>/dev/null || true
  find "$APP_DIR/server/node_modules/.bin" -xtype f -exec chmod 0755 {} + 2>/dev/null || true
  find "$APP_DIR/server/node_modules/.pnpm" -path '*/node_modules/*/bin/*' -type f -exec chmod 0755 {} + 2>/dev/null || true
  find "$APP_DIR/server/node_modules/.pnpm" -path '*/node_modules/.bin/*' -xtype f -exec chmod 0755 {} + 2>/dev/null || true
}

health_check() {
  log "执行健康检查"
  for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:3003/ping >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  curl -fsS http://127.0.0.1:3003/ping

  for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:2283/api/server/ping >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  curl -fsS http://127.0.0.1:2283/api/server/ping
  curl -fsS http://127.0.0.1:2283/api/server/version
  echo
}

cleanup_worktree() {
  if git -C "$REPO_DIR" worktree list --porcelain | grep -Fxq "worktree $BUILD_DIR"; then
    git -C "$REPO_DIR" worktree remove --force "$BUILD_DIR" >/dev/null 2>&1 || true
  fi
}

main() {
  require_root
  require_command git
  require_command rsync
  require_command curl
  ensure_tools
  verify_paths

  trap cleanup_worktree EXIT

  prepare_source
  build_server
  build_web
  build_plugins
  build_machine_learning
  copy_static_assets
  deploy_staging
  health_check

  log "部署完成：$VERSION"
  log "代码备份目录：$CODE_BACKUP_DIR"
  log "未触碰上传目录：$UPLOAD_DIR"
}

main "$@"
