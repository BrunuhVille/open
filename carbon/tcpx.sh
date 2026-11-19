#!/usr/bin/env bash

# 命令搜索路径必须是固定的 root 目录集合：不要追加 ~/bin，
# 因为 ~ 由调用方的 HOME 展开，sudo 保留 HOME 时本地用户可借此投毒 root 执行的命令。
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# =================================================
#  全局配置区 (Configuration as Data)
# =================================================
readonly SH_VER="100.0.6.16"
readonly TCPX_CN_EDITION="cn1"
readonly GITHUB_RAW_URL="https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master"
# 内核二进制 (bbr/bbrplus/lotserver) 已从仓库迁移到 Release，按目录整包托管，避免仓库臃肿。
readonly KERNEL_RELEASE_BASE="https://github.com/ylx2016/Linux-NetSpeed/releases/download/kernels"
readonly CLOUD_STATE_FILE="/etc/tcpx_cloud_lastver"                        # installcloud 记忆上次探测到的最高可安装 Cloud 内核
readonly CLOUD_HDR_POOL_UPSTREAM="https://deb.debian.org/debian/pool/main/l/linux/" # Cloud 内核 headers 默认上游 pool
readonly MIRROR_CONF_FILE="/etc/tcpx_mirror.conf"                          # 国内全链路加速与代理持久化配置

# 自安装：把脚本落地到 /usr/local/bin/tcpx，安装后可直接输入 tcpx 运行。
# 以 bash <(curl -fsSL <URL>) 这类管道方式运行时本地没有文件副本，只能从下面的地址重新下载。
# 默认使用与 Update_Shell 相同的权威地址 (在 check_cn_status 之后会自动走镜像加速下载)；
# 也可用环境变量 TCPX_URL 临时覆盖 (支持镜像前缀或自托管 HTTPS 地址)：
#   TCPX_URL=<地址> bash <(curl -fsSL <地址>)
readonly TCPX_URL_DEFAULT="${GITHUB_RAW_URL}/tcpx.sh"
resolve_self_url() {
	local url="${1:-}"
	if [[ -n "$url" && "$url" =~ ^https://[a-zA-Z0-9._~:/?#\[\]@!$&()*+,;=%-]+$ ]]; then
		printf '%s' "$url"; echo
		return 0
	fi
	[[ -n "$url" ]] && echo -e "已忽略不受支持的 TCPX_URL (仅允许合法的 https:// 地址)，改用默认地址(自动匹配加速镜像)。" >&2
	printf '%s' "$TCPX_URL_DEFAULT"; echo
}
readonly TCPX_SELF_URL="$(resolve_self_url "${TCPX_URL:-}")"
readonly TCPX_INSTALL_PATH="/usr/local/bin/tcpx"

# 颜色变量定义
readonly GREEN_FONT_PREFIX="\033[32m"
readonly RED_FONT_PREFIX="\033[31m"
readonly YELLOW_FONT_PREFIX="\033[33m"
readonly CYAN_FONT_PREFIX="\033[36m"
readonly FONT_COLOR_SUFFIX="\033[0m"
readonly INFO="${GREEN_FONT_PREFIX}[信息]${FONT_COLOR_SUFFIX}"
readonly ERROR="${RED_FONT_PREFIX}[错误]${FONT_COLOR_SUFFIX}"
readonly TIP="${YELLOW_FONT_PREFIX}[注意]${FONT_COLOR_SUFFIX}"

# 系统信息全局变量 (初始化)
OS_TYPE=""
OS_ID=""
OS_VERSION_ID=""
OS_ARCH=""

# 加速配置全局变量 (支持环境变量传入或从 /etc/tcpx_mirror.conf 读取，环境变量优先)
GH_PROXY="${GH_PROXY:-${GITHUB_PROXY:-}}"
GH_API_PROXY="${GH_API_PROXY:-${GITHUB_API_PROXY:-}}"
TCPX_HTTP_PROXY="${TCPX_HTTP_PROXY:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TCPX_FORCE_CN="${TCPX_FORCE_CN:-auto}"             # auto | 1 (强制国内加速) | 0 (强制直连)
TCPX_STRICT_DIGEST="${TCPX_STRICT_DIGEST:-0}"      # 0=有摘要必验、无摘要允许镜像+文件头校验；1=无独立摘要强制仅直连
TCPX_TRUST_CUSTOM_PROXY_TOKEN="${TCPX_TRUST_CUSTOM_PROXY_TOKEN:-0}" # 1=允许向自定义 GH_API_PROXY 发送 GITHUB_TOKEN
TCPX_UPDATE_URL="${TCPX_UPDATE_URL:-}"             # 可选：自定义升级脚本源地址

# 检查当前用户是否为 root
if [ "$EUID" -ne 0 ]; then
	echo -e "${ERROR} 请使用 root 用户身份运行此脚本"
	exit 1
fi

# =================================================
#  持久化加速配置读写模块 (/etc/tcpx_mirror.conf)
# =================================================

# 规范化镜像前缀：非空时必须为 https:// 开头且以 / 结尾
normalize_mirror_prefix() {
	local p="${1:-}"
	p="${p#"${p%%[![:space:]]*}"}"
	p="${p%"${p##*[![:space:]]}"}"
	[[ -z "$p" ]] && return 0
	[[ "$p" =~ ^https://[a-zA-Z0-9._~:/?#\[\]@!$&()*+,;=%-]+$ ]] || return 1
	[[ "$p" == */ ]] || p="${p}/"
	printf '%s' "$p"
}

# 应用或清理 HTTP/SOCKS5 代理环境变量
TCPX_PROXY_APPLIED=0
apply_http_proxy_env() {
	if [[ -n "${TCPX_HTTP_PROXY:-}" ]]; then
		export http_proxy="$TCPX_HTTP_PROXY"
		export https_proxy="$TCPX_HTTP_PROXY"
		export HTTP_PROXY="$TCPX_HTTP_PROXY"
		export HTTPS_PROXY="$TCPX_HTTP_PROXY"
		export ALL_PROXY="$TCPX_HTTP_PROXY"
		TCPX_PROXY_APPLIED=1
	elif [[ "$TCPX_PROXY_APPLIED" == "1" ]]; then
		unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
		TCPX_PROXY_APPLIED=0
	fi
}

# 安全解析 /etc/tcpx_mirror.conf (绝不使用 source/eval，防止配置文件注入；调用环境显式变量优先)
load_mirror_conf() {
	[[ -f "$MIRROR_CONF_FILE" && ! -L "$MIRROR_CONF_FILE" ]] || {
		apply_http_proxy_env
		return 0
	}
	local meta uid
	meta=$(stat -c '%u' -- "$MIRROR_CONF_FILE" 2>/dev/null) || return 0
	uid="${meta%% *}"
	[[ "$uid" == "0" ]] || {
		echo -e "${TIP} ${MIRROR_CONF_FILE} 非 root 拥有，已忽略该配置文件。" >&2
		return 0
	}

	local line key val
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line//$'\r'/}"
		[[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
		[[ "$line" == *=* ]] || continue
		key="${line%%=*}"
		val="${line#*=}"
		key="${key#"${key%%[![:space:]]*}"}"
		key="${key%"${key##*[![:space:]]}"}"
		# 剥离外层成对单/双引号
		if [[ "$val" =~ ^\"(.*)\"$ ]]; then
			val="${BASH_REMATCH[1]}"
		elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
			val="${BASH_REMATCH[1]}"
		fi
		case "$key" in
		GH_PROXY) [[ -z "${GH_PROXY:-}" ]] && GH_PROXY="$val" ;;
		GH_API_PROXY) [[ -z "${GH_API_PROXY:-}" ]] && GH_API_PROXY="$val" ;;
		TCPX_HTTP_PROXY) [[ -z "${TCPX_HTTP_PROXY:-}" ]] && TCPX_HTTP_PROXY="$val" ;;
		GITHUB_TOKEN) [[ -z "${GITHUB_TOKEN:-}" ]] && GITHUB_TOKEN="$val" ;;
		TCPX_FORCE_CN) [[ "${TCPX_FORCE_CN:-auto}" == "auto" && -n "$val" ]] && TCPX_FORCE_CN="$val" ;;
		TCPX_STRICT_DIGEST) [[ "${TCPX_STRICT_DIGEST:-0}" == "0" && -n "$val" ]] && TCPX_STRICT_DIGEST="$val" ;;
		TCPX_TRUST_CUSTOM_PROXY_TOKEN) [[ "${TCPX_TRUST_CUSTOM_PROXY_TOKEN:-0}" == "0" && -n "$val" ]] && TCPX_TRUST_CUSTOM_PROXY_TOKEN="$val" ;;
		TCPX_UPDATE_URL) [[ -z "${TCPX_UPDATE_URL:-}" ]] && TCPX_UPDATE_URL="$val" ;;
		esac
	done <"$MIRROR_CONF_FILE"

	if [[ -n "$GH_PROXY" ]]; then
		GH_PROXY=$(normalize_mirror_prefix "$GH_PROXY") || {
			echo -e "${TIP} GH_PROXY 格式无效 (需 https:// 开头)，已忽略。" >&2
			GH_PROXY=""
		}
	fi
	if [[ -n "$GH_API_PROXY" ]]; then
		GH_API_PROXY=$(normalize_mirror_prefix "$GH_API_PROXY") || {
			echo -e "${TIP} GH_API_PROXY 格式无效 (需 https:// 开头)，已忽略。" >&2
			GH_API_PROXY=""
		}
	fi
	apply_http_proxy_env
}

save_mirror_conf() {
	local tmp
	umask 077
	tmp=$(mktemp "${MIRROR_CONF_FILE}.XXXXXX") || {
		echo -e "${ERROR} 无法写入配置文件 ${MIRROR_CONF_FILE}" >&2
		return 1
	}
	cat >"$tmp" <<EOF
# tcpx 国内全链路加速配置文件 (权限 0600，仅 root 可读写)
GH_PROXY="${GH_PROXY}"
GH_API_PROXY="${GH_API_PROXY}"
TCPX_HTTP_PROXY="${TCPX_HTTP_PROXY}"
GITHUB_TOKEN="${GITHUB_TOKEN}"
TCPX_FORCE_CN="${TCPX_FORCE_CN}"
TCPX_STRICT_DIGEST="${TCPX_STRICT_DIGEST}"
TCPX_TRUST_CUSTOM_PROXY_TOKEN="${TCPX_TRUST_CUSTOM_PROXY_TOKEN}"
TCPX_UPDATE_URL="${TCPX_UPDATE_URL}"
EOF
	chown root:root "$tmp" 2>/dev/null
	chmod 600 "$tmp" 2>/dev/null
	mv -f "$tmp" "$MIRROR_CONF_FILE"
}

# =================================================
#  系统检测模块
# =================================================
check_sys() {
	# 1. 检测架构 (使用最通用的 uname)
	OS_ARCH=$(uname -m)

	# 2. 现代化系统信息获取
	if [[ -f /etc/os-release ]]; then
		. /etc/os-release
		OS_ID="${ID:-unknown}"
		OS_VERSION_ID="${VERSION_ID:-}"
		OS_ID_LIKE="${ID_LIKE:-}"
		if [[ -z "$OS_VERSION_ID" && "$OS_ID" == "debian" && -f /etc/debian_version ]]; then
			OS_VERSION_ID=$(grep -oE '^[0-9]+' /etc/debian_version | head -n 1)
			[[ -z "$OS_VERSION_ID" ]] && OS_VERSION_ID=$(awk -F'/' '{print $1}' /etc/debian_version)
		fi
		[[ -z "$OS_VERSION_ID" ]] && OS_VERSION_ID="unknown"
	elif [[ -f /etc/redhat-release || -f /etc/centos-release ]]; then
		OS_ID="centos"
		OS_VERSION_ID=$(grep -oE '[0-9.]+' /etc/redhat-release | awk -F'.' '{print $1}')
	else
		echo -e "${ERROR} 无法检测到受支持的系统版本。此脚本仅支持现代 Debian/Ubuntu/CentOS/Alma/Rocky 系统。"
		exit 1
	fi

	# 3. 规范化 OS_TYPE
	if [[ "$OS_ID" =~ ^(centos|rhel|almalinux|rocky|oracle|fedora)$ ]] || [[ "$OS_ID_LIKE" =~ (rhel|centos|fedora) ]]; then
		OS_TYPE="CentOS"
		OS_VERSION_ID=$(echo "$OS_VERSION_ID" | awk -F'.' '{print $1}')
	elif [[ "$OS_ID" =~ ^(debian|ubuntu|pop|kali|linuxmint|deepin|elementary|zorin|armbian)$ ]] || [[ "$OS_ID_LIKE" =~ (debian|ubuntu) ]]; then
		OS_TYPE="Debian"
	else
		echo -e "${ERROR} 不支持的系统分支: ${OS_ID} (ID_LIKE: ${OS_ID_LIKE})"
		exit 1
	fi

	echo -e "${INFO} 检测到系统: ${OS_TYPE} (${OS_ID} ${OS_VERSION_ID}) - 架构: ${OS_ARCH}"

	# 4. 必需依赖检查 + 尽力安装 jq (无 jq 时亦有 python3 / awk 摘要提取兜底)
	local required_cmds=("curl" "wget" "awk")

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		for cmd in "${required_cmds[@]}"; do
			if ! command -v "$cmd" >/dev/null 2>&1; then
				echo -e "${INFO} 正在安装缺失依赖: $cmd ..."
				yum install -y "$cmd" >/dev/null 2>&1
			fi
		done
		command -v jq >/dev/null 2>&1 || yum install -y jq >/dev/null 2>&1 || true
		if ! rpm -q ca-certificates >/dev/null 2>&1; then
			yum install ca-certificates -y >/dev/null 2>&1
			update-ca-trust force-enable
		fi
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		local need_update=0
		for cmd in "${required_cmds[@]}"; do
			if ! command -v "$cmd" >/dev/null 2>&1; then
				if [[ $need_update -eq 0 ]]; then
					apt-get update >/dev/null 2>&1
					need_update=1
				fi
				echo -e "${INFO} 正在安装缺失依赖: $cmd ..."
				apt-get install -y "$cmd" >/dev/null 2>&1
			fi
		done
		if ! command -v jq >/dev/null 2>&1; then
			[[ $need_update -eq 0 ]] && { apt-get update >/dev/null 2>&1; need_update=1; }
			apt-get install -y jq >/dev/null 2>&1 || true
		fi
		if ! dpkg-query -W ca-certificates >/dev/null 2>&1; then
			[[ $need_update -eq 0 ]] && apt-get update >/dev/null 2>&1
			apt-get install ca-certificates -y >/dev/null 2>&1
			update-ca-certificates >/dev/null 2>&1
		fi
	fi

	# 4.1 依赖复检
	local missing_cmds=()
	for cmd in "${required_cmds[@]}"; do
		command -v "$cmd" >/dev/null 2>&1 || missing_cmds+=("$cmd")
	done
	if [[ ${#missing_cmds[@]} -gt 0 ]]; then
		echo -e "${ERROR} 以下必需依赖安装失败，脚本无法继续运行:"
		for cmd in "${missing_cmds[@]}"; do
			echo -e "  - ${RED_FONT_PREFIX}${cmd}${FONT_COLOR_SUFFIX}"
		done
		echo -e "${TIP} 请先手动安装后重试，例如:"
		if [[ "${OS_TYPE}" == "CentOS" ]]; then
			echo -e "  yum install -y ${missing_cmds[*]}"
		else
			echo -e "  apt-get update && apt-get install -y ${missing_cmds[*]}"
		fi
		exit 1
	fi

	# 5. 补充底层内核模块管理依赖
	if ! command -v lsmod >/dev/null 2>&1; then
		echo -e "${INFO} 正在补齐系统核心依赖: kmod (提供 lsmod/rmmod 命令) ..."
		if [[ "${OS_TYPE}" == "CentOS" ]]; then
			yum install -y kmod >/dev/null 2>&1
		elif [[ "${OS_TYPE}" == "Debian" ]]; then
			apt-get install -y kmod >/dev/null 2>&1
		fi
	fi
}

# =================================================
#  安装前置守卫 (容器环境 / /boot 空间)
# =================================================

check_container() {
	local virt=""
	if command -v systemd-detect-virt >/dev/null 2>&1; then
		virt=$(systemd-detect-virt 2>/dev/null)
	elif command -v virt-what >/dev/null 2>&1; then
		virt=$(virt-what 2>/dev/null | head -n 1)
	fi

	case "$virt" in
	lxc | lxc-libvirt | openvz | docker | podman | rkt | wsl | systemd-nspawn)
		echo -e "${ERROR} 检测到当前为容器环境 (${virt})，容器共用宿主机内核，无法安装内核！"
		return 1
		;;
	esac

	if [[ -d /proc/vz && ! -d /proc/bc ]]; then
		echo -e "${ERROR} 检测到 OpenVZ 容器环境，无法安装内核！"
		return 1
	fi
	if grep -qaE '(lxc|docker|containerd)' /proc/1/cgroup 2>/dev/null; then
		echo -e "${ERROR} 检测到容器环境 (cgroup 特征)，无法安装内核！"
		return 1
	fi
	return 0
}

check_boot_space() {
	local need_mb="${1:-300}"
	local avail_mb
	avail_mb=$(df -Pm /boot 2>/dev/null | awk 'NR==2 {print $4}')

	if [[ -z "$avail_mb" ]]; then
		echo -e "${TIP} 无法获取 /boot 剩余空间，跳过检查。"
		return 0
	fi

	if [[ "$avail_mb" -lt "$need_mb" ]]; then
		echo -e "${ERROR} /boot 剩余空间不足: 当前 ${avail_mb}MB，建议至少 ${need_mb}MB。"
		echo -e "${TIP} 内核安装极可能在生成 initramfs 时中途失败，导致系统无法引导！"
		echo -e "${TIP} 请先使用菜单 [52] 删除不再使用的旧内核后重试。"
		read -rp "确认无视风险并继续？(请输入大写 YES 确认): " force_go
		[[ "$force_go" != "YES" ]] && {
			echo -e "${INFO} 已取消安装。"
			return 1
		}
	else
		echo -e "${INFO} /boot 剩余空间检查通过: ${avail_mb}MB 可用。"
	fi
	return 0
}

pre_install_check() {
	check_container || return 1
	check_boot_space 300 || return 1
	return 0
}

# =================================================
#  国内全链路加速通信与下载引擎 (Raw / Release / API / CDN / 子脚本)
# =================================================

# 全局变量：节点网络归属。0=海外 (仅直连，除非用户自定义 GH_PROXY)，1=中国大陆，2=无法判定 (按国内优先镜像处理)
IS_CN=0

# 全局最优镜像缓存
BEST_MIRROR=""
BEST_API_MIRROR=""
BEST_DEBIAN_MIRROR=""

# 实测可用的 GitHub 文件/Raw/Release/Archive 加速镜像池 (剔除失效节点，支持完整 URL 拼接)
DEFAULT_GITHUB_MIRRORS=(
	"https://edgeone.gh-proxy.org/"
	"https://gh-proxy.com/"
	"https://cdn.gh-proxy.org/"
	"https://gh-proxy.org/"
	"https://ghfast.top/"
	"https://ghproxy.net/"
	"https://wget.la/"
	"https://fastgit.cc/"
	"https://v6.gh-proxy.org/"
)

# 实测支持 api.github.com JSON 透传的加速镜像池 (已排除对 API 返回 403/404 的纯文件镜像)
DEFAULT_GITHUB_API_MIRRORS=(
	"https://edgeone.gh-proxy.org/"
	"https://cdn.gh-proxy.org/"
	"https://gh-proxy.com/"
	"https://gh-proxy.org/"
	"https://wget.la/"
	"https://v6.gh-proxy.org/"
)

# 针对 raw.githubusercontent.com / github.com/.../raw/... 的 jsDelivr 国内友好 CDN 兜底池
DEFAULT_JSDELIVR_CDNS=(
	"https://testingcf.jsdelivr.net/gh/"
	"https://gcore.jsdelivr.net/gh/"
	"https://fastly.jsdelivr.net/gh/"
)

# 针对 deb.debian.org/debian (Cloud 内核与 Headers pool / backports) 的国内高速源池
DEFAULT_DEBIAN_MIRRORS=(
	"https://mirrors.ustc.edu.cn/debian"
	"https://mirrors.tuna.tsinghua.edu.cn/debian"
	"https://mirrors.cloud.tencent.com/debian"
	"https://mirrors.aliyun.com/debian"
)

# 判断当前是否应启用国内加速策略
should_use_cn_accel() {
	[[ "${TCPX_FORCE_CN:-auto}" == "1" ]] && return 0
	[[ "${TCPX_FORCE_CN:-auto}" == "0" && -z "${GH_PROXY:-}" && -z "${GH_API_PROXY:-}" ]] && return 1
	[[ $IS_CN -ne 0 || -n "${GH_PROXY:-}" || -n "${GH_API_PROXY:-}" ]]
}

# 还原可能已包裹了镜像前缀的 GitHub URL 为规范的 https:// 原始链接，防止二次重复拼接
unwrap_github_url() {
	local url="$1"
	if [[ "$url" =~ ^https?://[^/]+/(https?://(www\.)?(github\.com|api\.github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com|codeload\.github\.com|gist\.github\.com|gist\.githubusercontent\.com|media\.githubusercontent\.com)/.+)$ ]]; then
		local inner="${BASH_REMATCH[1]}"
		printf '%s\n' "${inner/#http:\/\//https://}"
		return 0
	fi
	if [[ "$url" =~ ^https?://[^/]+/((www\.)?(github\.com|api\.github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com|codeload\.github\.com|gist\.github\.com|gist\.githubusercontent\.com|media\.githubusercontent\.com)/.+)$ ]]; then
		printf 'https://%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	printf '%s\n' "$url"
}

# 判断 URL 是否为 GitHub 文件/Raw/Release/Archive 系资源
is_github_url() {
	local url
	url=$(unwrap_github_url "$1")
	[[ "$url" =~ ^https?://(www\.)?(github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com|codeload\.github\.com|gist\.github\.com|gist\.githubusercontent\.com|media\.githubusercontent\.com)/ ]]
}

# 判断 URL 是否为 GitHub REST API
is_github_api_url() {
	local url
	url=$(unwrap_github_url "$1")
	[[ "$url" =~ ^https?://api\.github\.com/ ]]
}

# 判断 URL 是否为 Debian 官方源
is_debian_official_url() {
	[[ "$1" =~ ^https?://deb\.debian\.org/debian/ ]]
}

# 统一的镜像 URL 组装规则：
#   alt_mode=0 (默认首选): 前缀 + 完整 https:// 原始地址 (现代 gh-proxy / ghfast / fastgit 全兼容)
#   alt_mode=1 (兼容回退): 前缀 + 去协议头地址 (仅在默认形式返回 400/404 时自动尝试)
build_mirror_url() {
	local prefix="$1"
	local raw_url="$2"
	local alt_mode="${3:-0}"
	local url
	url=$(unwrap_github_url "$raw_url")
	if [[ -z "$prefix" ]]; then
		echo "$url"
	elif [[ "$alt_mode" == "1" ]]; then
		echo "${prefix}$(echo "$url" | sed 's|^https\?://||')"
	else
		echo "${prefix}${url}"
	fi
}

# 将 GitHub Raw 文件链接转换为多个 jsDelivr CDN 候选链接 (适用于中小体积脚本/源码兜底)
raw_to_jsdelivr_urls() {
	local url owner="" repo="" ref="" filepath=""
	url=$(unwrap_github_url "$1")
	if [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/refs/(heads|tags)/([^/]+)/(.+)$ ]]; then
		owner="${BASH_REMATCH[1]}"
		repo="${BASH_REMATCH[2]}"
		ref="${BASH_REMATCH[4]}"
		filepath="${BASH_REMATCH[5]}"
	elif [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$ ]]; then
		owner="${BASH_REMATCH[1]}"
		repo="${BASH_REMATCH[2]}"
		ref="${BASH_REMATCH[3]}"
		filepath="${BASH_REMATCH[4]}"
	elif [[ "$url" =~ ^https://(www\.)?github\.com/([^/]+)/([^/]+)/raw/refs/(heads|tags)/([^/]+)/(.+)$ ]]; then
		owner="${BASH_REMATCH[2]}"
		repo="${BASH_REMATCH[3]}"
		ref="${BASH_REMATCH[5]}"
		filepath="${BASH_REMATCH[6]}"
	elif [[ "$url" =~ ^https://(www\.)?github\.com/([^/]+)/([^/]+)/raw/([^/]+)/(.+)$ ]]; then
		owner="${BASH_REMATCH[2]}"
		repo="${BASH_REMATCH[3]}"
		ref="${BASH_REMATCH[4]}"
		filepath="${BASH_REMATCH[5]}"
	else
		return 1
	fi
	local cdn
	for cdn in "${DEFAULT_JSDELIVR_CDNS[@]}"; do
		printf '%s%s/%s@%s/%s\n' "$cdn" "$owner" "$repo" "$ref" "$filepath"
	done
}

# 生成当前有序的 GitHub 文件加速镜像列表 (每行一个前缀，末尾空行代表直连兜底)
get_ordered_file_mirrors() {
	if ! should_use_cn_accel; then
		printf '\n'
		return 0
	fi
	local seen="|" m
	for m in "${GH_PROXY:-}" "${BEST_MIRROR:-}" "${DEFAULT_GITHUB_MIRRORS[@]}"; do
		[[ -z "$m" || "$m" == "poll" ]] && continue
		if [[ "$seen" != *"|${m}|"* ]]; then
			seen="${seen}${m}|"
			printf '%s\n' "$m"
		fi
	done
	printf '\n'
}

# 生成当前有序的 GitHub API 加速镜像列表 (每行一个前缀，末尾空行代表直连兜底)
get_ordered_api_mirrors() {
	if ! should_use_cn_accel; then
		printf '\n'
		return 0
	fi
	local seen="|" m
	for m in "${GH_API_PROXY:-}" "${GH_PROXY:-}" "${BEST_API_MIRROR:-}" "${DEFAULT_GITHUB_API_MIRRORS[@]}"; do
		[[ -z "$m" || "$m" == "poll" ]] && continue
		if [[ "$seen" != *"|${m}|"* ]]; then
			seen="${seen}${m}|"
			printf '%s\n' "$m"
		fi
	done
	printf '\n'
}

# 获取当前最优 Debian 官方包镜像基址 (不带末尾斜杠)
active_debian_mirror_base() {
	if should_use_cn_accel && [[ -n "${BEST_DEBIAN_MIRROR:-}" ]]; then
		printf '%s' "$BEST_DEBIAN_MIRROR"
	else
		printf 'https://deb.debian.org/debian'
	fi
}

# 探测单个镜像并写入 PROBE_HTTP / PROBE_TIME / PROBE_OK
mirror_probe() {
	local prefix="$1"
	local url="$2"
	local max_time="${3:-2}"
	local range_limit="${4:-255}"

	local probe http_code time_cost alt_mode=0
	local range_args=()
	[[ "$range_limit" -gt 0 ]] && range_args=(-r "0-${range_limit}")

	probe=$(curl -sL -m "$max_time" "${range_args[@]}" -o /dev/null \
		-w "%{http_code} %{time_total}" \
		"$(build_mirror_url "$prefix" "$url" 0)" 2>/dev/null)
	http_code=${probe%% *}
	if [[ -n "$prefix" && ( "$http_code" == "404" || "$http_code" == "400" ) ]]; then
		alt_mode=1
		probe=$(curl -sL -m "$max_time" "${range_args[@]}" -o /dev/null \
			-w "%{http_code} %{time_total}" \
			"$(build_mirror_url "$prefix" "$url" 1)" 2>/dev/null)
		http_code=${probe%% *}
	fi

	time_cost=${probe#* }
	[[ "$time_cost" == "$probe" ]] && time_cost=""
	PROBE_HTTP="$http_code"
	PROBE_TIME="$time_cost"
	PROBE_ALT_MODE="$alt_mode"
	if [[ "$http_code" =~ ^(200|206)$ && -n "$time_cost" ]]; then
		PROBE_OK=1
		return 0
	fi
	PROBE_OK=0
	return 1
}

wget_http_code() {
	local log_file="$1"
	local code=''
	[[ -f "$log_file" ]] && code=$(grep -oE 'HTTP/[0-9.]+ [0-9]{3}' "$log_file" 2>/dev/null | tail -n 1 | awk '{print $2}')
	[[ "$code" =~ ^[0-9]{3}$ ]] && echo "$code"
}

curl_secure_args() {
	if [[ -z "${TCPX_CURL_STRICT:-}" ]]; then
		if curl -q --proto '=https' --proto-redir '=https' --version >/dev/null 2>&1; then
			TCPX_CURL_STRICT=1
		else
			TCPX_CURL_STRICT=0
		fi
	fi
	if [[ "$TCPX_CURL_STRICT" == "1" ]]; then
		printf '%s\n' -q -fsSL --proto =https --proto-redir =https
	else
		printf '%s\n' -q -fsSL --proto =https
	fi
}

# 校验下载产物的二进制文件头魔数，防止镜像站将 HTML 拦截页/错误页伪装成 200 OK 返回
verify_downloaded_artifact() {
	local file="$1"
	local url="${2:-}"
	[[ -s "$file" ]] || return 1

	local check_name="${file##*/} ${url##*/}"
	if [[ "$check_name" =~ \.(deb|rpm|tar\.gz|tgz|ko)([[:space:]?#]|$) ]]; then
		# 拦截伪装为 200 的 HTML 错误/验证页面
		if head -c 256 "$file" 2>/dev/null | grep -qiE '^[[:space:]]*(<!doctype|<html|<head|<script)'; then
			echo -e "${TIP} 节点返回了 HTML 错误页而非二进制文件，已自动丢弃并切换节点。" >&2
			return 1
		fi
	fi

	if [[ "$file" == *.deb || "$url" == *.deb ]]; then
		if ! head -c 8 "$file" 2>/dev/null | grep -q '!<arch>'; then
			echo -e "${TIP} .deb 归档文件头校验未通过 (非标准 ar 归档)，已丢弃。" >&2
			return 1
		fi
	elif [[ "$file" == *.rpm || "$url" == *.rpm ]]; then
		if command -v od >/dev/null 2>&1; then
			local rpm_magic
			rpm_magic=$(od -An -tx1 -N4 "$file" 2>/dev/null | tr -d ' \t\r\n')
			if [[ "$rpm_magic" != "edabeedb" ]]; then
				echo -e "${TIP} .rpm 文件头魔数校验未通过 (${rpm_magic:-empty})，已丢弃。" >&2
				return 1
			fi
		fi
	elif [[ "$file" == *.tar.gz || "$file" == *.tgz || "$url" == *.tar.gz || "$url" == *.tgz ]]; then
		if command -v od >/dev/null 2>&1; then
			local gz_magic
			gz_magic=$(od -An -tx1 -N2 "$file" 2>/dev/null | tr -d ' \t\r\n')
			if [[ "$gz_magic" != "1f8b" ]]; then
				echo -e "${TIP} .tar.gz gzip 文件头魔数校验未通过 (${gz_magic:-empty})，已丢弃。" >&2
				return 1
			fi
		fi
	fi
	return 0
}

# 单次下载尝试：支持直接传完整 target_url (当 prefix="__DIRECT_URL__" 时) 或经 build_mirror_url 拼接
download_once() {
	local prefix="$1"
	local url="$2"
	local dest="$3"
	local alt_mode="${4:-0}"
	local timeout="${5:-15}"
	local expected_sha256="${6:-}"
	local label_override="${7:-}"
	local target_url http_log http_code downloaded=0
	DOWNLOAD_HTTP=""

	if [[ "$prefix" == "__DIRECT_URL__" ]]; then
		target_url="$url"
		prefix=""
	else
		target_url=$(build_mirror_url "$prefix" "$url" "$alt_mode")
	fi

	[[ "$target_url" == https://* ]] || {
		echo -e "${ERROR} 下载地址必须使用 HTTPS: ${target_url}" >&2
		return 1
	}

	if [[ -n "$expected_sha256" ]]; then
		if [[ ! "$expected_sha256" =~ ^[a-fA-F0-9]{64}$ ]] || ! command -v sha256sum >/dev/null 2>&1; then
			echo -e "${ERROR} 摘要格式无效或缺少 sha256sum，拒绝跳过制品校验。" >&2
			DOWNLOAD_HTTP="digest-unavailable"
			return 1
		fi
		expected_sha256="${expected_sha256,,}"
	elif [[ "${TCPX_STRICT_DIGEST:-0}" == "1" && ( -n "$prefix" || -n "$label_override" ) ]]; then
		echo -e "${ERROR} TCPX_STRICT_DIGEST=1 严格模式：无独立摘要时禁止使用镜像。" >&2
		DOWNLOAD_HTTP="unauthenticated-source"
		return 1
	fi

	if [[ -n "$label_override" ]]; then
		echo -e "${INFO} 正在请求: ${dest} (${label_override}) ..."
	elif [[ -z "$prefix" ]]; then
		echo -e "${INFO} 正在请求: ${dest} (直连${TCPX_HTTP_PROXY:+/代理}) ..."
	else
		echo -e "${INFO} 正在请求: ${dest} (镜像: ${prefix}) ..."
	fi

	http_log=$(mktemp) || return 1

	# 统一优先使用 curl (严控协议 + 连接超时 + 低速防卡死)，curl 失败时对大文件再用 wget 兜底
	local curl_args=() curl_arg
	while IFS= read -r curl_arg; do
		[[ -n "$curl_arg" ]] && curl_args+=("$curl_arg")
	done < <(curl_secure_args)
	if [[ "${TCPX_TLS_INSECURE:-0}" == "1" && -n "$expected_sha256" ]]; then
		curl_args+=(-k)
		echo -e "${TIP} 已按 TCPX_TLS_INSECURE=1 关闭证书校验；仍强制核验 SHA-256。" >&2
	fi

	if http_code=$(curl "${curl_args[@]}" \
		--connect-timeout "$timeout" --speed-time "$timeout" --speed-limit 1024 --retry 1 \
		-o "$dest" -w '%{http_code} %{url_effective}' "$target_url" 2>"$http_log"); then
		local effective="${http_code#* }"
		http_code="${http_code%% *}"
		if [[ "$effective" != https://* ]]; then
			echo -e "${ERROR} 下载最终落点不是 HTTPS (${effective})，已拒绝该内容。" >&2
			DOWNLOAD_HTTP="insecure-redirect"
			rm -f "$http_log" "$dest"
			return 1
		fi
		downloaded=1
		DOWNLOAD_HTTP="$http_code"
	else
		DOWNLOAD_HTTP="${http_code%% *}"
		if [[ -z "$DOWNLOAD_HTTP" || "$DOWNLOAD_HTTP" == "000" ]]; then
			# 尝试从 wget 获取更明确的 HTTP 状态或完成下载
			local wget_tls_args=(--check-certificate)
			[[ "${TCPX_TLS_INSECURE:-0}" == "1" && -n "$expected_sha256" ]] && wget_tls_args=(--no-check-certificate)
			if wget "${wget_tls_args[@]}" -q -S -T "$timeout" -t 1 -O "$dest" "$target_url" 2>"$http_log"; then
				downloaded=1
			fi
			DOWNLOAD_HTTP=$(wget_http_code "$http_log")
		fi
	fi

	if [[ "$downloaded" == "1" && -s "$dest" ]]; then
		if ! verify_downloaded_artifact "$dest" "$url"; then
			rm -f "$http_log" "$dest"
			DOWNLOAD_HTTP="invalid-artifact"
			return 1
		fi
		if [[ -n "$expected_sha256" ]]; then
			local actual_sha256
			if ! actual_sha256=$(sha256sum -- "$dest" 2>/dev/null); then
				rm -f "$http_log" "$dest"
				DOWNLOAD_HTTP="digest-error"
				return 1
			fi
			actual_sha256="${actual_sha256%% *}"
			if [[ "$actual_sha256" != "$expected_sha256" ]]; then
				echo -e "${ERROR} ${dest} SHA-256 校验和不匹配，已丢弃该节点返回的内容！" >&2
				rm -f "$http_log" "$dest"
				DOWNLOAD_HTTP="digest-mismatch"
				return 1
			fi
		fi
		DOWNLOAD_HTTP=200
		rm -f "$http_log"
		echo -e "${INFO} ${dest} 下载成功！"
		return 0
	fi

	rm -f "$http_log" "$dest"
	return 1
}

# 归属地检测端点：国内低延迟节点排在最前，避免启动时在被阻断的海外端点上白等超时
CN_STATUS_ENDPOINTS=(
	"cn|https://myip.ipip.net"
	"cf|https://www.qualcomm.cn/cdn-cgi/trace"
	"cf|https://cloudflare.com/cdn-cgi/trace"
	"code|https://ipinfo.io/country"
)
CN_STATUS_TIMEOUT=2

parse_geo_country() {
	local kind="$1" body="${2//$'\r'/}" line
	case "$kind" in
	cf)
		line=$(printf '%s\n' "$body" | grep -m1 -E '^loc=[A-Z]{2}$') || return 0
		printf '%s' "${line#loc=}"
		;;
	code)
		line=$(printf '%s' "$body" | tr -d '[:space:]')
		[[ "$line" =~ ^[A-Z]{2}$ ]] && printf '%s' "$line"
		;;
	cn)
		line=$(printf '%s\n' "$body" | grep -m1 -E '来自于：中国') || return 0
		case "$line" in
		*香港*) printf 'HK' ;;
		*澳门*) printf 'MO' ;;
		*台湾*) printf 'TW' ;;
		*) printf 'CN' ;;
		esac
		;;
	esac
}

detect_geo_country() {
	local family="$1" entry kind url body country
	for entry in "${CN_STATUS_ENDPOINTS[@]}"; do
		kind=${entry%%|*}
		url=${entry#*|}
		body=$(curl "-${family}" -fsL --max-time "$CN_STATUS_TIMEOUT" "$url" 2>/dev/null) || continue
		country=$(parse_geo_country "$kind" "$body")
		[[ -n "$country" ]] && { printf '%s' "$country"; return 0; }
	done
	return 1
}

# 执行镜像池测速 (供启动初始化和菜单 [90] 手动重测复用)
probe_github_mirrors() {
	echo -e "${INFO} 正在测速优选 GitHub 文件/Raw/Release 镜像与 API 镜像..."

	local test_raw_url="${GITHUB_RAW_URL}/tcpx.sh"
	local best_time=9999
	local failed_mirrors=()
	BEST_MIRROR=""
	BEST_API_MIRROR=""

	# 若用户配置了自定义 GH_PROXY，优先检测其可用性
	local candidates=()
	[[ -n "${GH_PROXY:-}" ]] && candidates+=("$GH_PROXY")
	local m
	for m in "${DEFAULT_GITHUB_MIRRORS[@]}"; do
		[[ "$m" != "${GH_PROXY:-}" ]] && candidates+=("$m")
	done

	local prefix
	for prefix in "${candidates[@]}"; do
		if ! mirror_probe "$prefix" "$test_raw_url" 2 255; then
			failed_mirrors+=("$prefix")
			continue
		fi
		if awk "BEGIN {exit !($PROBE_TIME < $best_time)}"; then
			best_time=$PROBE_TIME
			BEST_MIRROR=$prefix
		fi
	done

	if [[ "$best_time" == "9999" ]]; then
		echo -e "${TIP} 候选文件镜像测速均超时，下载时将依次轮询全部镜像 + jsDelivr CDN。"
		BEST_MIRROR="poll"
	else
		echo -e "${INFO} 最优文件/Raw/Release 镜像: ${GREEN_FONT_PREFIX}${BEST_MIRROR}${FONT_COLOR_SUFFIX} (${best_time}s)"
	fi

	# 优选 API 镜像：若用户设置了 GH_API_PROXY 则优先验证；若 BEST_MIRROR 本身在 API 支持池内且通过 JSON 探测则直接复用
	local api_test_url="https://api.github.com/rate_limit" # /rate_limit 不消耗 GitHub 60次/小时配额
	local api_candidates=()
	[[ -n "${GH_API_PROXY:-}" ]] && api_candidates+=("$GH_API_PROXY")
	[[ -n "${GH_PROXY:-}" && "${GH_PROXY}" != "${GH_API_PROXY:-}" ]] && api_candidates+=("$GH_PROXY")
	if [[ -n "$BEST_MIRROR" && "$BEST_MIRROR" != "poll" ]]; then
		for m in "${DEFAULT_GITHUB_API_MIRRORS[@]}"; do
			[[ "$m" == "$BEST_MIRROR" ]] && api_candidates+=("$BEST_MIRROR")
		done
	fi
	for m in "${DEFAULT_GITHUB_API_MIRRORS[@]}"; do
		local exists=0 c
		for c in "${api_candidates[@]}"; do [[ "$c" == "$m" ]] && exists=1; done
		[[ $exists -eq 0 ]] && api_candidates+=("$m")
	done

	local api_best_time=9999 api_body
	for prefix in "${api_candidates[@]}"; do
		local t0 probe_out code cost
		probe_out=$(curl -sL -m 3 -w "\n%{http_code} %{time_total}" "$(build_mirror_url "$prefix" "$api_test_url" 0)" 2>/dev/null) || continue
		local last_line="${probe_out##*$'\n'}"
		api_body="${probe_out%$'\n'*}"
		code="${last_line%% *}"
		cost="${last_line#* }"
		if [[ "$code" == "200" ]] && printf '%s' "$api_body" | grep -q '"resources"'; then
			if awk "BEGIN {exit !($cost < $api_best_time)}"; then
				api_best_time=$cost
				BEST_API_MIRROR=$prefix
				# 若已命中首个高速可用节点 (<0.8s)，无需遍历全部 API 节点以加快启动速度
				if awk "BEGIN {exit !($cost < 0.8)}"; then
					break
				fi
			fi
		fi
	done

	if [[ -n "$BEST_API_MIRROR" ]]; then
		echo -e "${INFO} 最优 GitHub API 镜像:     ${GREEN_FONT_PREFIX}${BEST_API_MIRROR}${FONT_COLOR_SUFFIX} (${api_best_time}s)"
	else
		BEST_API_MIRROR="poll"
		echo -e "${TIP} 未探测到低延迟 API 镜像，API 请求时将轮询备用池并兜底直连。"
	fi

	# Debian 系顺带探测国内软件池镜像 (用于 Cloud 内核列表与 Headers 高速下载)
	if [[ "${OS_TYPE}" == "Debian" ]]; then
		BEST_DEBIAN_MIRROR=""
		local deb_m deb_best=9999
		for deb_m in "${DEFAULT_DEBIAN_MIRRORS[@]}"; do
			local deb_probe d_code d_time
			deb_probe=$(curl -sI -m 2 -o /dev/null -w "%{http_code} %{time_total}" "${deb_m}/dists/stable/Release" 2>/dev/null) || continue
			d_code="${deb_probe%% *}"
			d_time="${deb_probe#* }"
			if [[ "$d_code" =~ ^(200|301|302)$ && -n "$d_time" ]]; then
				if awk "BEGIN {exit !($d_time < $deb_best)}"; then
					deb_best=$d_time
					BEST_DEBIAN_MIRROR="$deb_m"
					if awk "BEGIN {exit !($d_time < 0.5)}"; then
						break
					fi
				fi
			fi
		done
		[[ -n "$BEST_DEBIAN_MIRROR" ]] && echo -e "${INFO} 最优 Debian 官方包镜像:   ${GREEN_FONT_PREFIX}${BEST_DEBIAN_MIRROR}${FONT_COLOR_SUFFIX} (${deb_best}s)"
	fi

	if [[ ${#failed_mirrors[@]} -gt 0 ]]; then
		echo -e "${TIP} 本次测速不可达镜像已自动后置/剔除 (${#failed_mirrors[@]} 个)。"
	fi
}

# 1. CN 节点检测与镜像测速入口
check_cn_status() {
	if [[ "${TCPX_FORCE_CN:-auto}" == "1" ]]; then
		IS_CN=1
		echo -e "${INFO} 已强制开启国内全链路加速模式 (TCPX_FORCE_CN=1)。"
		probe_github_mirrors
		return 0
	elif [[ "${TCPX_FORCE_CN:-auto}" == "0" ]]; then
		IS_CN=0
		if [[ -n "${GH_PROXY:-}" || -n "${GH_API_PROXY:-}" ]]; then
			echo -e "${INFO} 已设为直连模式，但检测到自定义反代配置，仍优先使用自定义反代。"
			probe_github_mirrors
		else
			echo -e "${INFO} 已强制设为海外直连模式 (TCPX_FORCE_CN=0)。"
		fi
		return 0
	fi

	local country="" ip_version
	for ip_version in 4 6; do
		country=$(detect_geo_country "$ip_version") || country=""
		[[ -n "$country" ]] && break
	done

	if [[ "$country" == "CN" ]]; then
		IS_CN=1
		echo -e "${INFO} 检测到当前节点位于中国大陆 (CN)，自动启用 GitHub 全链路加速..."
		probe_github_mirrors
	elif [[ -n "$country" ]]; then
		IS_CN=0
		if [[ -n "${GH_PROXY:-}" || -n "${GH_API_PROXY:-}" ]]; then
			echo -e "${INFO} 当前节点出口位于 ${country}，已按自定义配置启用指定 GitHub 反代。"
			probe_github_mirrors
		else
			echo -e "${INFO} 当前节点出口位于海外 (${country})，使用直连网络 (如需强制国内镜像可在菜单 [90] 开启)。"
		fi
	else
		IS_CN=2
		echo -e "${TIP} 归属地探测超时，自动按国内网络处理：启用全链路镜像加速 + 直连兜底。"
		probe_github_mirrors
	fi
}

# 2. 安全可靠的多通道下载函数 (GitHub 镜像池 -> jsDelivr Raw CDN -> Debian 国内源 -> 直连兜底)
safe_wget() {
	local raw_url="$1"
	local dest="$2"
	local expected_sha256="${3:-}"
	local timeout=15
	local url
	url=$(unwrap_github_url "$raw_url")

	# 分支 A：Debian 官方池资源 (deb.debian.org/debian/...) 国内高速镜像切换
	if is_debian_official_url "$url" && should_use_cn_accel; then
		local rel_path="${url#https://deb.debian.org/debian}"
		rel_path="${rel_path#http://deb.debian.org/debian}"
		local deb_candidates=() dm
		[[ -n "${BEST_DEBIAN_MIRROR:-}" ]] && deb_candidates+=("$BEST_DEBIAN_MIRROR")
		for dm in "${DEFAULT_DEBIAN_MIRRORS[@]}"; do
			[[ "$dm" != "${BEST_DEBIAN_MIRROR:-}" ]] && deb_candidates+=("$dm")
		done
		deb_candidates+=("https://deb.debian.org/debian")

		for dm in "${deb_candidates[@]}"; do
			download_once "__DIRECT_URL__" "${dm}${rel_path}" "$dest" 0 "$timeout" "$expected_sha256" "Debian源: ${dm}" && return 0
			echo -e "${TIP} Debian 镜像 ${dm} 下载失败，正在切换下一节点..."
		done
		echo -e "${ERROR} 文件 ${dest} 所有 Debian 镜像及官方源均下载失败！"
		return 1
	fi

	# 分支 B：非 GitHub 普通资源 (或海外直连模式)
	if ! is_github_url "$url" || ! should_use_cn_accel || [[ "${TCPX_STRICT_DIGEST:-0}" == "1" && -z "$expected_sha256" ]]; then
		if [[ "${TCPX_STRICT_DIGEST:-0}" == "1" && -z "$expected_sha256" ]] && is_github_url "$url" && should_use_cn_accel; then
			echo -e "${TIP} 当前启用了 TCPX_STRICT_DIGEST=1 且上游无独立摘要，仅尝试上游 HTTPS 直连。" >&2
		fi
		download_once "" "$url" "$dest" 0 "$timeout" "$expected_sha256" && return 0
		echo -e "${ERROR} 文件 ${dest} 直连下载失败！"
		return 1
	fi

	# 分支 C：GitHub 文件 / Raw / Release / Archive 多级加速通道
	local mirrors=() m
	while IFS= read -r m; do
		mirrors+=("$m")
	done < <(get_ordered_file_mirrors)

	# 预先收集 jsDelivr CDN 候选 (仅针对 raw 链接，放在 gh-proxy 池之后、直连之前作为异构 CDN 兜底)
	local jsd_urls=() jurl
	while IFS= read -r jurl; do
		[[ -n "$jurl" ]] && jsd_urls+=("$jurl")
	done < <(raw_to_jsdelivr_urls "$url" 2>/dev/null || true)

	local prefix
	for prefix in "${mirrors[@]}"; do
		# 在进入最后的空前缀 (直连 GitHub) 之前，若存在 jsDelivr CDN 候选则优先走 CDN
		if [[ -z "$prefix" && ${#jsd_urls[@]} -gt 0 ]]; then
			for jurl in "${jsd_urls[@]}"; do
				download_once "__DIRECT_URL__" "$jurl" "$dest" 0 "$timeout" "$expected_sha256" "CDN: ${jurl%%/gh/*}" && return 0
			done
		fi

		local alt_mode=0
		while :; do
			download_once "$prefix" "$url" "$dest" "$alt_mode" "$timeout" "$expected_sha256" && return 0
			if [[ -n "$prefix" && "$alt_mode" == "0" && ( "$DOWNLOAD_HTTP" == "404" || "$DOWNLOAD_HTTP" == "400" ) ]]; then
				echo -e "${TIP} ${prefix} 对完整 URL 返回 ${DOWNLOAD_HTTP}，改用去协议头形式重试..."
				alt_mode=1
				continue
			fi
			break
		done

		[[ -n "$prefix" ]] && echo -e "${TIP} 节点 ${prefix} 下载未完成，无缝切换下一备用节点..."
	done

	echo -e "${ERROR} 文件 ${dest} 所有加速镜像、CDN 及直连均失败，请通过菜单 [90] 检查网络或配置自定义代理！"
	return 1
}

# 3. GitHub REST API 多通道加速请求函数 (自动跳过 403 限流节点与非 JSON 响应，保护 Token 不外泄)
fetch_github_api() {
	local raw_api_url="$1"
	local timeout="${2:-12}"
	local api_url
	api_url=$(unwrap_github_url "$raw_api_url")

	local curl_base=() curl_arg
	while IFS= read -r curl_arg; do
		[[ -n "$curl_arg" ]] && curl_base+=("$curl_arg")
	done < <(curl_secure_args)

	local api_mirrors=() m
	while IFS= read -r m; do
		api_mirrors+=("$m")
	done < <(get_ordered_api_mirrors)

	local prefix alt_mode target resp first_nonspace
	for prefix in "${api_mirrors[@]}"; do
		for alt_mode in 0 1; do
			# 直连时无需跑两遍 alt_mode
			[[ -z "$prefix" && "$alt_mode" == "1" ]] && break
			target=$(build_mirror_url "$prefix" "$api_url" "$alt_mode")

			local auth_args=()
			# 安全红线：GITHUB_TOKEN 仅允许发往官方直连 api.github.com，或用户显式信任的私有反代
			if [[ -n "${GITHUB_TOKEN:-}" ]]; then
				if [[ -z "$prefix" ]] || [[ -n "${GH_API_PROXY:-}" && "$prefix" == "$GH_API_PROXY" && "${TCPX_TRUST_CUSTOM_PROXY_TOKEN:-0}" == "1" ]]; then
					auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
				fi
			fi

			if resp=$(curl "${curl_base[@]}" "${auth_args[@]}" \
				-H "Accept: application/vnd.github+json" \
				--connect-timeout "$timeout" --max-time "$((timeout + 8))" \
				"$target" 2>/dev/null) && [[ -n "$resp" ]]; then

				if printf '%s' "$resp" | grep -q "API rate limit exceeded"; then
					echo -e "${TIP} API 节点 ${prefix:-直连} 触发 GitHub 频率限制，自动切换下一节点..." >&2
					break
				fi

				# 严格验证返回体是合法 JSON 数组或对象，拒绝 HTML 验证页/报错页
				first_nonspace=$(printf '%s' "$resp" | tr -d '[:space:]' | head -c 1)
				if [[ "$first_nonspace" == "[" || "$first_nonspace" == "{" ]]; then
					printf '%s' "$resp"
					return 0
				fi
			fi

			# 仅在非连接超时的快速失败下尝试 alt_mode=1，否则直接换下一个镜像
			[[ -z "$prefix" ]] && break
			break
		done
	done

	return 1
}

# 4. 子脚本透明全链路加速沙箱 (拦截子脚本内部的 curl / wget / git 对 GitHub 及 API 的请求并自动多源故障转移)
run_with_github_accel() {
	if ! should_use_cn_accel; then
		"$@"
		return $?
	fi

	local real_curl real_wget shim_dir
	real_curl=$(type -P curl 2>/dev/null) || real_curl="/usr/bin/curl"
	real_wget=$(type -P wget 2>/dev/null) || real_wget="/usr/bin/wget"

	shim_dir=$(mktemp -d /tmp/tcpx_accel_shim.XXXXXX) || {
		"$@"
		return $?
	}
	chmod 700 "$shim_dir"

	local file_mirrors_str api_mirrors_str primary_mirror=""
	file_mirrors_str=$(get_ordered_file_mirrors)
	api_mirrors_str=$(get_ordered_api_mirrors)
	primary_mirror=$(printf '%s\n' "$file_mirrors_str" | head -n 1)

	# 生成透明加速 curl 包装器
	cat >"${shim_dir}/curl" <<'SHIM_CURL_EOF'
#!/usr/bin/env bash
REAL_CURL="${TCPX_SHIM_REAL_CURL:-/usr/bin/curl}"
gh_idx=-1
gh_kind=""
gh_orig=""
has_out_file=0
has_location=0
has_fail=0

args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	a="${args[$i]}"
	case "$a" in
	-o | --output | -O | --remote-name) has_out_file=1 ;;
	-o*) [[ ${#a} -gt 2 ]] && has_out_file=1 ;;
	esac
	[[ "$a" =~ ^-[a-zA-Z]*L ]] || [[ "$a" == "--location" ]] && has_location=1
	[[ "$a" =~ ^-[a-zA-Z]*f ]] || [[ "$a" == "--fail" ]] && has_fail=1

	if [[ "$a" =~ ^https://api\.github\.com/ ]]; then
		gh_idx=$i
		gh_kind="api"
		gh_orig="$a"
	elif [[ "$a" =~ ^https://(www\.)?(github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com|codeload\.github\.com|gist\.github\.com|gist\.githubusercontent\.com|media\.githubusercontent\.com)/ ]]; then
		gh_idx=$i
		gh_kind="file"
		gh_orig="$a"
	fi
done

# 非 GitHub 请求原样放行
if [[ $gh_idx -lt 0 ]]; then
	exec "$REAL_CURL" "$@"
fi

extra_flags=()
[[ $has_location -eq 0 ]] && extra_flags+=(-L)
[[ $has_fail -eq 0 ]] && extra_flags+=(-f)

if [[ "$gh_kind" == "api" ]]; then
	while IFS= read -r prefix || [[ -n "$prefix" ]]; do
		try_args=("${args[@]}")
		try_args[$gh_idx]="${prefix}${gh_orig}"
		if [[ $has_out_file -eq 0 ]]; then
			tmp_api=$(mktemp /tmp/tcpx_shim_api.XXXXXX) || continue
			if "$REAL_CURL" "${extra_flags[@]}" --connect-timeout 10 "${try_args[@]}" >"$tmp_api" 2>/dev/null && [[ -s "$tmp_api" ]]; then
				if ! grep -q "API rate limit exceeded" "$tmp_api" 2>/dev/null; then
					first_ch=$(tr -d '[:space:]' <"$tmp_api" | head -c 1)
					if [[ "$first_ch" == "[" || "$first_ch" == "{" ]]; then
						cat "$tmp_api"
						rm -f "$tmp_api"
						exit 0
					fi
				fi
			fi
			rm -f "$tmp_api"
		else
			if "$REAL_CURL" "${extra_flags[@]}" --connect-timeout 10 "${try_args[@]}"; then
				exit 0
			fi
		fi
	done <<<"${TCPX_SHIM_API_MIRRORS}"
	exit 1
else
	while IFS= read -r prefix || [[ -n "$prefix" ]]; do
		try_args=("${args[@]}")
		try_args[$gh_idx]="${prefix}${gh_orig}"
		if "$REAL_CURL" "${extra_flags[@]}" --connect-timeout 12 "${try_args[@]}"; then
			exit 0
		fi
	done <<<"${TCPX_SHIM_FILE_MIRRORS}"
	exit 1
fi
SHIM_CURL_EOF

	# 生成透明加速 wget 包装器
	cat >"${shim_dir}/wget" <<'SHIM_WGET_EOF'
#!/usr/bin/env bash
REAL_WGET="${TCPX_SHIM_REAL_WGET:-/usr/bin/wget}"
gh_idx=-1
gh_kind=""
gh_orig=""
out_file=""

args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	a="${args[$i]}"
	if [[ "$a" == "-O" && $((i + 1)) -lt ${#args[@]} ]]; then
		out_file="${args[$((i + 1))]}"
	elif [[ "$a" =~ ^-[a-zA-Z]*O$ && $((i + 1)) -lt ${#args[@]} ]]; then
		out_file="${args[$((i + 1))]}"
	elif [[ "$a" =~ ^-O(.+)$ ]]; then
		out_file="${BASH_REMATCH[1]}"
	fi

	if [[ "$a" =~ ^https://api\.github\.com/ ]]; then
		gh_idx=$i
		gh_kind="api"
		gh_orig="$a"
	elif [[ "$a" =~ ^https://(www\.)?(github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com|codeload\.github\.com|gist\.github\.com|gist\.githubusercontent\.com|media\.githubusercontent\.com)/ ]]; then
		gh_idx=$i
		gh_kind="file"
		gh_orig="$a"
	fi
done

if [[ $gh_idx -lt 0 ]]; then
	exec "$REAL_WGET" "$@"
fi

pool="${TCPX_SHIM_FILE_MIRRORS}"
[[ "$gh_kind" == "api" ]] && pool="${TCPX_SHIM_API_MIRRORS}"

while IFS= read -r prefix || [[ -n "$prefix" ]]; do
	try_args=("${args[@]}")
	try_args[$gh_idx]="${prefix}${gh_orig}"
	if "$REAL_WGET" -T 15 -t 1 "${try_args[@]}"; then
		if [[ -z "$out_file" || "$out_file" == "-" || -s "$out_file" ]]; then
			exit 0
		fi
	fi
	[[ -n "$out_file" && "$out_file" != "-" && ! -s "$out_file" ]] && rm -f "$out_file"
done <<<"$pool"
exit 1
SHIM_WGET_EOF

	chmod 700 "${shim_dir}/curl" "${shim_dir}/wget"

	local rc=0
	if [[ -n "$primary_mirror" ]]; then
		PATH="${shim_dir}:${PATH}" \
			TCPX_SHIM_REAL_CURL="$real_curl" \
			TCPX_SHIM_REAL_WGET="$real_wget" \
			TCPX_SHIM_FILE_MIRRORS="$file_mirrors_str" \
			TCPX_SHIM_API_MIRRORS="$api_mirrors_str" \
			GIT_CONFIG_COUNT=2 \
			GIT_CONFIG_KEY_0="url.${primary_mirror}https://github.com/.insteadOf" \
			GIT_CONFIG_VALUE_0="https://github.com/" \
			GIT_CONFIG_KEY_1="url.${primary_mirror}https://gist.github.com/.insteadOf" \
			GIT_CONFIG_VALUE_1="https://gist.github.com/" \
			"$@" || rc=$?
	else
		PATH="${shim_dir}:${PATH}" \
			TCPX_SHIM_REAL_CURL="$real_curl" \
			TCPX_SHIM_REAL_WGET="$real_wget" \
			TCPX_SHIM_FILE_MIRRORS="$file_mirrors_str" \
			TCPX_SHIM_API_MIRRORS="$api_mirrors_str" \
			"$@" || rc=$?
	fi

	rm -rf "$shim_dir"
	return $rc
}

# 5. 从候选链接中按版本号挑出最高版本 (优先取文件名中的 N.N.N，文件名不含版本时从 Tag 路径提取)
pick_latest_asset() {
	local url base ver
	local unversioned=""
	local versioned=()
	while IFS= read -r url; do
		[[ -z "$url" ]] && continue
		base="${url##*/}"
		ver=$(printf '%s\n' "$base" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
		[[ -z "$ver" ]] && ver=$(printf '%s\n' "$url" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1)
		if [[ -z "$ver" ]]; then
			[[ -z "$unversioned" ]] && unversioned="$url"
			continue
		fi
		versioned+=("${ver} ${url}")
	done

	if [[ ${#versioned[@]} -eq 0 ]]; then
		printf '%s\n' "$unversioned"
		return 0
	fi
	printf '%s\n' "${versioned[@]}" | sort -V -k1,1 | tail -n 1 | sed 's/^[^ ]* //'
}

# 6. 从 GitHub Releases JSON 精确关联指定 asset URL 的 SHA-256 摘要 (支持 jq -> python3 -> 纯 awk 三级降级解析)
asset_digest_for_url() {
	local response="$1"
	local url="$2"
	local digest=""

	if command -v jq >/dev/null 2>&1; then
		if ! digest=$(printf '%s' "$response" | jq -er --arg url "$url" '
			if type != "array" then error("invalid releases response") else . end |
			[.[] | .assets[]? | select(.browser_download_url == $url)] as $assets |
			if ($assets | length) != 1 then error("asset URL is missing or ambiguous")
			elif $assets[0].digest == null then ""
			else $assets[0].digest |
				if type != "string" then error("invalid asset digest")
				elif test("^sha256:[0-9a-fA-F]{64}$") then ltrimstr("sha256:")
				else "" end
			end' 2>/dev/null); then
			return 1
		fi
		printf '%s' "${digest,,}"
		return 0
	fi

	if command -v python3 >/dev/null 2>&1; then
		if digest=$(printf '%s' "$response" | python3 -c '
import json, sys, re
target = sys.argv[1]
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(1)
matches = [a for r in data if isinstance(r, dict) for a in (r.get("assets") or []) if isinstance(a, dict) and a.get("browser_download_url") == target]
if len(matches) != 1:
    sys.exit(1)
d = matches[0].get("digest") or ""
if isinstance(d, str) and re.match(r"^sha256:[0-9a-fA-F]{64}$", d):
    print(d[7:].lower(), end="")
' "$url" 2>/dev/null); then
			printf '%s' "$digest"
			return 0
		fi
	fi

	# 纯 awk 兜底：剥离 asset 内唯一的嵌套子对象 uploader 后按大括号切分匹配
	digest=$(printf '%s' "$response" | awk -v target="$url" '
	BEGIN { RS=""; ORS="" }
	{
		s = $0
		gsub(/"uploader"[[:space:]]*:[[:space:]]*\{[^}]*\}/, "", s)
		n = split(s, blocks, /[{}]/)
		for (i = 1; i <= n; i++) {
			b = blocks[i]
			if (index(b, "\"browser_download_url\"") && index(b, "\"" target "\"")) {
				if (match(b, /"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-fA-F]{64}"/)) {
					m = substr(b, RSTART, RLENGTH)
					sub(/^.*sha256:/, "", m)
					sub(/".*$/, "", m)
					print tolower(m)
					exit 0
				}
				exit 0
			}
		}
	}')
	printf '%s' "$digest"
	return 0
}

# 7. 稳健的 GitHub Release 资源获取函数 (经由 fetch_github_api 多镜像加速)
# 用法: get_github_asset <仓库名> <Tag关键词> <文件名关键词> [架构关键词]
get_github_asset() {
	local repo="$1"
	local tag_kw="$2"
	local ast_kw="$3"
	local arch_kw="${4:-}"
	local api_url="https://api.github.com/repos/${repo}/releases?per_page=100"

	local response
	if ! response=$(fetch_github_api "$api_url" 12); then
		echo -e "${ERROR} GitHub API (${repo}) 所有加速镜像及直连均请求失败！" >&2
		echo -e "${TIP} 可在主菜单输入 [90] 配置自定义 GitHub 反代、HTTP 代理或 GITHUB_TOKEN。" >&2
		return 1
	fi

	local all_urls
	if command -v jq >/dev/null 2>&1; then
		all_urls=$(printf '%s' "$response" | jq -er '
			if type != "array" then error("invalid releases response") else . end |
			.[] | .assets[]? | .browser_download_url |
			select(type == "string") | select(startswith("https://"))' 2>/dev/null) || return 1
	else
		all_urls=$(printf '%s\n' "$response" | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' | grep -oE 'https://[^"]+')
	fi
	if [[ -z "$all_urls" ]]; then
		echo -e "${ERROR} 无法从 ${repo} 提取有效的资源下载列表！" >&2
		return 1
	fi

	local result
	result=$(echo "$all_urls" | grep -iE "$tag_kw" | grep -iE "$ast_kw")
	[[ -n "$arch_kw" ]] && result=$(echo "$result" | grep -iE "$arch_kw")
	result=$(echo "$result" | grep -viE 'dbg|debug|unsigned')

	if [[ "$arch_kw" != *"arm64"* && "$tag_kw" != *"arm64"* && "$OS_ARCH" != "aarch64" ]]; then
		result=$(echo "$result" | grep -viE "arm64|aarch64")
	fi

	local asset_url
	asset_url=$(echo "$result" | pick_latest_asset)

	if [[ -z "$asset_url" ]]; then
		echo -e "${ERROR} 无法在 ${repo} 中解析到匹配关键字 (${tag_kw} -> ${ast_kw} -> ${arch_kw}) 的文件！" >&2
		return 1
	fi

	local digest=""
	digest=$(asset_digest_for_url "$response" "$asset_url") || digest=""
	printf '%s\t%s\n' "$asset_url" "$digest"
}

# =================================================
#  内核安装核心引擎
# =================================================

remove_old_headers() {
	echo -e "${INFO} 正在清理旧的内核 Headers 防止冲突..."
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		local current_ker=$(uname -r)
		rpm -qa | grep -E 'kernel(-ml|-lt|-uek|-rt|-plus)?-headers' | grep -v "$current_ker" | xargs -r rpm -e --nodeps >/dev/null 2>&1
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		dpkg -l | grep -E '(linux|proxmox|pve|raspberrypi)-headers' | awk '{print $2}' | grep -v "$(uname -r)" | xargs -r apt-get purge -y >/dev/null 2>&1
		apt-get autoremove -y >/dev/null 2>&1
	fi
}

install_kernel_generic() {
	local kernel_desc="$1"
	local head_url="$2"
	local img_url="$3"
	local kernel_version="$4"
	local head_sha256="${5:-}"
	local img_sha256="${6:-}"

	echo -e "${INFO} ================================================"
	if [[ -n "$kernel_version" ]]; then
		echo -e "${INFO} 开始安装: ${kernel_desc} (版本: \033[32m${kernel_version}\033[0m)"
	else
		echo -e "${INFO} 开始安装: ${kernel_desc}"
	fi
	echo -e "${INFO} ================================================"

	if [[ -z "$img_url" ]]; then
		echo -e "${ERROR} 传入的镜像文件下载链接为空，可能是 API 解析失败或上游移除了文件！"
		return 1
	fi

	local work_dir
	work_dir=$(mktemp -d /tmp/kernel_install.XXXXXX) || {
		echo -e "${ERROR} 无法创建临时目录！"
		return 1
	}
	chmod 755 "$work_dir"
	trap 'cd /tmp; rm -rf "$work_dir"; trap - RETURN' RETURN
	cd "$work_dir" || {
		echo -e "${ERROR} 无法进入临时目录 ${work_dir}！"
		return 1
	}

	local vmlinuz_before=$(ls -1 /boot/vmlinuz-* 2>/dev/null | wc -l)

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		local head_file="kernel-headers.rpm"
		local img_file="kernel-image.rpm"

		[[ -n "$head_url" ]] && { safe_wget "$head_url" "$head_file" "$head_sha256" || return 1; }
		safe_wget "$img_url" "$img_file" "$img_sha256" || return 1

		remove_old_headers

		echo -e "${INFO} 正在执行 YUM 安装..."
		if [[ -n "$head_url" ]]; then
			yum install -y "./$img_file" "./$head_file" || {
				echo -e "${ERROR} 内核包安装失败，请检查上方 yum 输出！"
				return 1
			}
		else
			yum install -y "./$img_file" || {
				echo -e "${ERROR} 内核包安装失败，请检查上方 yum 输出！"
				return 1
			}
		fi

	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		local head_file="linux-headers.deb"
		local img_file="linux-image.deb"
		local deb_list=()

		[[ -n "$head_url" ]] && { safe_wget "$head_url" "$head_file" "$head_sha256" || return 1; }
		safe_wget "$img_url" "$img_file" "$img_sha256" || return 1

		remove_old_headers

		deb_list+=("./$img_file")
		[[ -n "$head_url" && -s "$head_file" ]] && deb_list+=("./$head_file")

		echo -e "${INFO} 正在执行 APT 安装 (自动解析依赖)..."
		if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${deb_list[@]}"; then
			echo -e "${ERROR} 内核包安装失败，依赖无法满足或包不兼容当前系统！"
			echo -e "${TIP} 系统未被改动，可尝试菜单 [4] 中的 'a' 自动探测可安装版本。"
			return 1
		fi
	fi

	local vmlinuz_after=$(ls -1 /boot/vmlinuz-* 2>/dev/null | wc -l)
	if [[ "$vmlinuz_after" -lt "$vmlinuz_before" ]]; then
		echo -e "${ERROR} /boot 中的内核镜像不增反减，安装可能被回滚 (依赖冲突)！"
		echo -e "${TIP} 请勿重启，先用菜单 [51] 确认当前内核状态。"
		return 1
	fi
	[[ "$vmlinuz_after" -eq "$vmlinuz_before" ]] && echo -e "${INFO} 目标内核镜像已存在 (无需重复安装)，继续处理配套组件..."

	echo -e "${INFO} ${kernel_desc} 内核包安装完成，正在更新系统引导..."
	BBR_grub
}

# 安装 BBR 原版内核 (调用引擎)
installbbr() {
	pre_install_check || return 1
	local head_url=""
	local img_url=""
	local tag_kw=""
	local arch_kw=""
	local img_kw=""

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		tag_kw="CentOS_Kernel_Cloud"
		arch_kw="x86_64"
		img_kw="kernel-[0-9]"
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		tag_kw="Debian_Kernel_Cloud"
		arch_kw="amd64"
		img_kw="image"
		if [[ "$OS_ARCH" == "aarch64" ]]; then
			tag_kw="Debian_Kernel_Cloud_arm64"
			arch_kw="arm64"
		fi
	fi

	echo -e "${INFO} 正在通过加速通道向 Github/ylx2016 请求最新 ${tag_kw} 内核数据..."

	local head_meta img_meta head_sha="" img_sha=""
	head_meta=$(get_github_asset "ylx2016/kernel" "${tag_kw}" "headers" "${arch_kw}") || return 1
	img_meta=$(get_github_asset "ylx2016/kernel" "${tag_kw}" "${img_kw}" "${arch_kw}") || return 1
	head_url="${head_meta%%$'	'*}"
	img_url="${img_meta%%$'	'*}"
	[[ "$head_meta" == *$'	'* ]] && head_sha="${head_meta#*$'	'}"
	[[ "$img_meta" == *$'	'* ]] && img_sha="${img_meta#*$'	'}"

	local kernel_version=$(echo "${img_url##*/}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)

	if [[ -n "$kernel_version" ]]; then
		echo -e "${INFO} 解析成功！获取到的最新云端内核版本为: \033[32m${kernel_version}\033[0m"
	else
		echo -e "${INFO} 解析成功！已获取到下载链接，但未能匹配出纯净版本号。"
	fi

	install_kernel_generic "BBR Cloud 优化内核" "$head_url" "$img_url" "$kernel_version" "$head_sha" "$img_sha"
}

# 安装 BBRplus 新版内核 (调用引擎)
installbbrplusnew() {
	pre_install_check || return 1
	local head_url=""
	local img_url=""
	local tag_kw="bbrplus-6."
	local ext="deb"
	local arch_kw="amd64"
	local img_kw="image"

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		ext="rpm"
		arch_kw="x86_64"
		img_kw="kernel-[0-9]"
		[[ "$OS_ARCH" == "aarch64" ]] && arch_kw="aarch64"
	else
		[[ "$OS_ARCH" == "aarch64" ]] && arch_kw="arm64"
	fi

	echo -e "${INFO} 正在通过加速通道向 UJX6N/bbrplus-6.x_stable 请求数据..."
	local head_meta img_meta head_sha="" img_sha=""
	head_meta=$(get_github_asset "UJX6N/bbrplus-6.x_stable" "${tag_kw}" "headers" "${arch_kw}.*${ext}") || return 1
	img_meta=$(get_github_asset "UJX6N/bbrplus-6.x_stable" "${tag_kw}" "${img_kw}" "${arch_kw}.*${ext}") || return 1
	head_url="${head_meta%%$'	'*}"
	img_url="${img_meta%%$'	'*}"
	[[ "$head_meta" == *$'	'* ]] && head_sha="${head_meta#*$'	'}"
	[[ "$img_meta" == *$'	'* ]] && img_sha="${img_meta#*$'	'}"

	local kernel_version=$(echo "${img_url##*/}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
	install_kernel_generic "BBRplus(UJX6N)新版内核" "$head_url" "$img_url" "$kernel_version" "$head_sha" "$img_sha"
}

# 安装 BBRplus 内核 4.14.129 (cx9208版)
installbbrplus() {
	pre_install_check || return 1
	local head_url=""
	local img_url=""

	if [[ "${OS_TYPE}" == "CentOS" && "${OS_VERSION_ID}" == "7" ]]; then
		head_url="https://github.com/cx9208/Linux-NetSpeed/raw/master/bbrplus/centos/7/kernel-headers-4.14.129-bbrplus.rpm"
		img_url="https://github.com/cx9208/Linux-NetSpeed/raw/master/bbrplus/centos/7/kernel-4.14.129-bbrplus.rpm"
	elif [[ "${OS_TYPE}" == "Debian" && "${OS_ARCH}" == "x86_64" ]]; then
		head_url="https://github.com/cx9208/Linux-NetSpeed/raw/master/bbrplus/debian-ubuntu/x64/linux-headers-4.14.129-bbrplus.deb"
		img_url="https://github.com/cx9208/Linux-NetSpeed/raw/master/bbrplus/debian-ubuntu/x64/linux-image-4.14.129-bbrplus.deb"
	else
		echo -e "${ERROR} BBRplus 4.14.129 仅支持 CentOS 7 或 Debian x86_64！"
		return 1
	fi

	install_kernel_generic "BBRplus 4.14.129" "$head_url" "$img_url"
}

# =================================================
#  自动探测 Cloud 内核最高可安装版本 (支持国内 Debian 镜像池加速)
# =================================================

# 抓取 Debian pool 目录清单 (自动走国内镜像 + 官方源回退)
fetch_debian_pool_html() {
	local subpath="$1" # 例如 /pool/main/l/linux/
	local candidates=() dm
	if should_use_cn_accel; then
		[[ -n "${BEST_DEBIAN_MIRROR:-}" ]] && candidates+=("$BEST_DEBIAN_MIRROR")
		for dm in "${DEFAULT_DEBIAN_MIRRORS[@]}"; do
			[[ "$dm" != "${BEST_DEBIAN_MIRROR:-}" ]] && candidates+=("$dm")
		done
	fi
	candidates+=("https://deb.debian.org/debian")

	local html
	for dm in "${candidates[@]}"; do
		html=$(curl -fsSL --connect-timeout 8 --max-time 20 "${dm}${subpath}" 2>/dev/null)
		if [[ -n "$html" ]] && printf '%s' "$html" | grep -q '\.deb'; then
			printf '%s' "$html"
			return 0
		fi
	done
	return 1
}

fetch_cloud_pool_listing() {
	fetch_debian_pool_html "/pool/main/l/linux/" | grep -oE '(linux-headers|linux-kbuild)-[^"]+\.deb'
}

resolve_cloud_header_debs() {
	local img_file="$1" debarch="$2" listing="$3"
	local abi base
	abi=$(echo "$img_file" | sed -nE "s/^linux-image-(.*-cloud-${debarch})_.*/\1/p")
	[[ -z "$abi" ]] && return 1
	base="${abi%-cloud-${debarch}}"

	local arch_hdr ver
	arch_hdr=$(printf '%s\n' "$listing" | while read -r f; do
		case "$f" in "linux-headers-${abi}_"*"_${debarch}.deb") echo "$f" ;; esac
	done | sort -V | tail -n 1)
	[[ -z "$arch_hdr" ]] && return 1
	ver="${arch_hdr#linux-headers-${abi}_}"
	ver="${ver%_${debarch}.deb}"

	echo "$arch_hdr"
	local common_hdr="linux-headers-${base}-common_${ver}_all.deb"
	local kbuild="linux-kbuild-${base}_${ver}_${debarch}.deb"
	printf '%s\n' "$listing" | grep -qxF "$common_hdr" && echo "$common_hdr"
	printf '%s\n' "$listing" | grep -qxF "$kbuild" && echo "$kbuild"
	return 0
}

check_cloud_headers_installable() {
	local img_file="$1" debarch="$2" listing="$3" scan_dir="$4"
	local hdr_files
	hdr_files=$(resolve_cloud_header_debs "$img_file" "$debarch" "$listing") || return 1
	[[ -z "$hdr_files" ]] && return 1

	local debs=() hf
	while read -r hf; do
		[[ -z "$hf" ]] && continue
		safe_wget "${CLOUD_HDR_POOL_UPSTREAM}${hf}" "${scan_dir}/${hf}" >/dev/null 2>&1 || return 1
		debs+=("${scan_dir}/${hf}")
	done <<<"$hdr_files"
	[[ ${#debs[@]} -eq 0 ]] && return 1

	local log
	log=$(LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get install -s --no-install-recommends "${debs[@]}" 2>&1)
	rm -f "${debs[@]}"
	echo "$log" | grep -qiE "unmet dependencies|broken packages|E: " && return 1
	echo "$log" | grep -q "will be REMOVED" && return 1
	if echo "$log" | grep -q "will be upgraded"; then
		local upgraded=$(echo "$log" | sed -n '/will be upgraded/,/^[^ ]/p' | tail -n +2)
		echo "$upgraded" | grep -qwE "libc6|base-files|dpkg|systemd|systemd-sysv|bash|login|tzdata" && return 1
	fi
	return 0
}

CLOUD_MAX_IDX=-1
CLOUD_MAX_FILE=""
detect_cloud_max() {
	local img_url_base="$1"
	local need_headers="$2"
	local debarch="$3"
	shift 3
	local versions_array=("$@")
	CLOUD_MAX_IDX=-1
	CLOUD_MAX_FILE=""

	local scan_work
	scan_work=$(mktemp -d /tmp/cloud_kernel_scan.XXXXXX) || return 1
	trap 'cd /tmp; rm -rf "$scan_work"; trap - RETURN' RETURN
	cd "$scan_work" || return 1

	local hdr_listing=""
	[[ "$need_headers" == "1" ]] && hdr_listing=$(fetch_cloud_pool_listing)

	local host_deb=""
	if [[ "$need_headers" == "1" && "${OS_ID}" == "debian" ]]; then
		host_deb="${OS_VERSION_ID%%.*}"
		[[ "$host_deb" =~ ^[0-9]+$ ]] || host_deb=""
	fi

	for ((i = ${#versions_array[@]} - 1; i >= 0; i--)); do
		local f="${versions_array[$i]}"
		if [[ -n "$host_deb" ]]; then
			local cand_deb=$(echo "$f" | grep -oE '\+deb[0-9]+' | grep -oE '[0-9]+')
			if [[ -n "$cand_deb" && "$cand_deb" -gt "$host_deb" ]]; then
				echo -e "${TIP}  ✗ ${f} 面向 Debian ${cand_deb} (高于当前 Debian ${host_deb})，Headers 依赖更新工具链，快速跳过"
				continue
			fi
		fi
		echo -e "${INFO} 正在探测候选内核: ${f} ..."
		if ! safe_wget "${img_url_base}${f}" "probe.deb" >/dev/null 2>&1; then
			continue
		fi
		if ! head -c 8 probe.deb | grep -q "!<arch>"; then
			rm -f probe.deb
			continue
		fi

		local scan_log=$(LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get install -s --no-install-recommends "./probe.deb" 2>&1)
		rm -f probe.deb

		local ok=1
		if echo "$scan_log" | grep -qiE "unmet dependencies|broken packages|E: "; then
			ok=0
		fi
		if echo "$scan_log" | grep -q "will be REMOVED"; then
			ok=0
		fi
		if echo "$scan_log" | grep -q "will be upgraded"; then
			local upgraded=$(echo "$scan_log" | sed -n '/will be upgraded/,/^[^ ]/p' | tail -n +2)
			if echo "$upgraded" | grep -qwE "libc6|base-files|dpkg|systemd|systemd-sysv|bash|login|tzdata"; then
				ok=0
			fi
		fi

		if [[ $ok -eq 1 ]]; then
			if [[ "$need_headers" == "1" ]]; then
				echo -e "${GREEN_FONT_PREFIX}  ✓ 镜像依赖可满足${FONT_COLOR_SUFFIX}，继续校验配套 Headers 依赖..."
				if check_cloud_headers_installable "$f" "$debarch" "$hdr_listing" "$scan_work"; then
					CLOUD_MAX_IDX=$i
					CLOUD_MAX_FILE="$f"
					echo -e "${GREEN_FONT_PREFIX}  ✓ 镜像 + Headers 依赖均可干净满足${FONT_COLOR_SUFFIX}"
					break
				else
					echo -e "${TIP}  ✗ 该版本 Headers 依赖不满足 (多为跨发行版内核)，继续找更旧版本"
				fi
			else
				CLOUD_MAX_IDX=$i
				CLOUD_MAX_FILE="$f"
				echo -e "${GREEN_FONT_PREFIX}  ✓ 该版本依赖可干净满足${FONT_COLOR_SUFFIX}"
				break
			fi
		else
			echo -e "${TIP}  ✗ 该版本依赖冲突，已跳过"
		fi
	done
}

ensure_cloud_headers() {
	local img_file="$1"
	local debarch="$2"

	local abi
	abi=$(echo "$img_file" | sed -nE "s/^linux-image-(.*-cloud-${debarch})_.*/\1/p")
	[[ -z "$abi" ]] && return 0

	if [[ -d "/lib/modules/${abi}/build" || -d "/usr/src/linux-headers-${abi}" ]]; then
		echo -e "${INFO} 内核 ${abi} 的配套 Headers 已就绪，可直接编译内核模块。"
		return 0
	fi

	echo -e "${INFO} 正在为内核 ${abi} 补齐配套 Headers (arch + -common + kbuild)..."
	local listing hdr_files
	listing=$(fetch_cloud_pool_listing)
	hdr_files=$(resolve_cloud_header_debs "$img_file" "$debarch" "$listing")
	if [[ -z "$hdr_files" ]]; then
		echo -e "${TIP} pool 中未找到 ${abi} 的 headers，已跳过 (内核镜像不受影响，仅暂无法编译模块)。"
		return 0
	fi

	local work_dir debs=() f
	work_dir=$(mktemp -d /tmp/cloud_hdr.XXXXXX) || {
		echo -e "${TIP} 无法创建临时目录，已跳过 headers。"
		return 0
	}
	chmod 755 "$work_dir"
	while read -r f; do
		[[ -z "$f" ]] && continue
		safe_wget "${CLOUD_HDR_POOL_UPSTREAM}${f}" "${work_dir}/${f}" && debs+=("${work_dir}/${f}")
	done <<<"$hdr_files"

	local apt_out rc=1
	if [[ ${#debs[@]} -gt 0 ]]; then
		apt_out=$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${debs[@]}" 2>&1)
		rc=$?
	fi
	if [[ $rc -eq 0 ]]; then
		echo -e "${INFO} 配套 Headers 已装好，可正常编译 LotSpeed / brutal 等内核模块。"
	elif printf '%s' "$apt_out" | grep -qE 'libc6 \(>= 2\.(3[89]|[4-9])|t64 |gcc-[0-9]+-for-host'; then
		echo -e "${TIP} Headers 无法安装：内核 ${abi} 是较新发行版的 backports 版，其 Headers 依赖更新的 glibc/工具链，"
		echo -e "${TIP}       与当前系统 (Debian $(cat /etc/debian_version 2>/dev/null)) 不兼容。内核镜像不受影响。"
		echo -e "${TIP} 建议：仅用 BBR 无需 Headers，重启进新内核即可；若要编译模块，请改装与本系统同发行版的 Cloud 内核"
		echo -e "${TIP}       (菜单里选不带 +debN 的版本，或输入 'h' 走 apt 装配套 headers)。"
	else
		echo -e "${TIP} Headers 安装未完成 (下载失败或依赖冲突)，内核镜像不受影响；如需编译请重启后手动安装。"
	fi
	rm -rf "$work_dir"
}

installcloud() {
	pre_install_check || return 1

	[[ "${OS_TYPE}" != "Debian" ]] && {
		echo -e "${ERROR} Cloud 内核仅支持 Debian 系系统"
		return 1
	}

	if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "pop" || "${OS_ID_LIKE}" == *"ubuntu"* ]]; then
		echo -e "${INFO} 检测到 Ubuntu/衍生系：Cloud 内核对应 apt 元包 linux-image-virtual (随发行版滚动更新)。"
		local u_ans u_hdr=""
		read -e -p "是否同时安装配套 Headers？(编译内核模块才需要) [y/N]: " u_ans
		[[ "$u_ans" =~ ^[yY]$ ]] && u_hdr="linux-headers-virtual"
		apt-get update >/dev/null 2>&1
		if apt-get install -y linux-image-virtual $u_hdr; then
			echo -e "${INFO} Ubuntu 云内核 (linux-image-virtual${u_hdr:+ + linux-headers-virtual}) 安装完成。"
			BBR_grub
		else
			echo -e "${ERROR} apt 安装 linux-image-virtual 失败，请检查网络与 apt 源。"
			return 1
		fi
		return 0
	fi

	local debarch
	if [[ "$OS_ARCH" == "x86_64" ]]; then
		debarch="amd64"
	elif [[ "$OS_ARCH" == "aarch64" ]]; then
		debarch="arm64"
	else
		echo -e "${ERROR} 不支持的架构：$OS_ARCH"
		return 1
	fi

	# 仍使用标准 deb.debian.org 作为逻辑 URL，safe_wget 与 fetch_debian_pool_html 内部会自动走国内镜像池并兜底官方源
	local img_url_base="https://deb.debian.org/debian/pool/main/l/linux-signed-${debarch}/"
	local img_pattern='linux-image-[^" ]+cloud-'"${debarch}"'_[^" ]+_'"${debarch}"'\.deb'

	echo -e "${INFO} 正在获取 Debian Cloud 内核列表 (自动优选国内高速镜像)..."
	local deb_files
	deb_files=$(fetch_debian_pool_html "/pool/main/l/linux-signed-${debarch}/" | grep -oE "$img_pattern" | sort -V | uniq)
	if [[ -z "$deb_files" ]]; then
		echo -e "${ERROR} 未找到可用的 Cloud 内核版本，请检查网络！"
		return 1
	fi
	mapfile -t versions_array <<<"$deb_files"

	local remembered=""
	[[ -f "$CLOUD_STATE_FILE" ]] && remembered=$(cat "$CLOUD_STATE_FILE" 2>/dev/null)
	local remembered_idx=-1
	if [[ -n "$remembered" ]]; then
		for i in "${!versions_array[@]}"; do
			[[ "${versions_array[$i]}" == "$remembered" ]] && {
				remembered_idx=$i
				break
			}
		done
	fi

	echo -e "${INFO} 检测到以下 Cloud 内核版本 (pool 全部候选)："
	for i in "${!versions_array[@]}"; do
		local v_show=$(echo "${versions_array[$i]}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+')
		if [[ $i -eq $remembered_idx ]]; then
			echo -e "  ${GREEN_FONT_PREFIX}$i) [$v_show]${FONT_COLOR_SUFFIX} ${RED_FONT_PREFIX}← 上次最高可安装版本${FONT_COLOR_SUFFIX} -> ${versions_array[$i]}"
		else
			echo "  $i) [$v_show] -> ${versions_array[$i]}"
		fi
	done
	echo -e "  ${GREEN_FONT_PREFIX}a) 自动逐个探测并判断最高可安装版本${FONT_COLOR_SUFFIX}   ${YELLOW_FONT_PREFIX}h) 使用 apt 安装${FONT_COLOR_SUFFIX}"

	local last_idx=$((${#versions_array[@]} - 1))
	local default_idx=$last_idx
	[[ $remembered_idx -ge 0 ]] && default_idx=$remembered_idx

	local def_label="$default_idx"
	[[ $remembered_idx -ge 0 ]] && def_label="${default_idx} (上次记忆)"
	echo -e "${TIP} 输入 'a' 自动判断最高可安装版本，输入 'h' 使用 apt 安装："
	if ! read -t 60 -rp "输入选项 [0-${last_idx} / a / h / q 取消，回车默认 ${def_label}]: " choice; then
		echo ""
		echo -e "${TIP} 等待超时，出于安全考虑已自动取消操作 (未做任何更改)。"
		return 0
	fi

	if [[ "$choice" =~ ^[qQ]$ ]]; then
		echo -e "${INFO} 已取消操作。"
		return 0
	fi

	if [[ "$choice" =~ ^[aA]$ ]]; then
		local need_headers=0 ans
		echo -e "${INFO} 是否需要安装内核 Headers？(编译 LotSpeed / brutal 等内核模块才需要；只用 BBR 不需要)"
		read -e -p "需要 Headers 请输 y，只装内核直接回车 [y/N]: " ans
		[[ "$ans" =~ ^[yY]$ ]] && need_headers=1

		if [[ $need_headers -eq 1 ]]; then
			echo -e "${INFO} 开始自动探测：要求 内核镜像 + 配套 Headers 依赖同时可满足（从新到旧逐个校验，稍慢）..."
		else
			echo -e "${INFO} 开始自动探测最高可安装的 Cloud 内核版本（仅校验内核镜像依赖）..."
		fi
		detect_cloud_max "$img_url_base" "$need_headers" "$debarch" "${versions_array[@]}"
		if [[ $CLOUD_MAX_IDX -lt 0 || -z "$CLOUD_MAX_FILE" ]]; then
			echo -e "${TIP} 未找到可干净安装的 pool 版本，已回退到 apt 官方源安装 (最稳妥)。"
			apt-get update >/dev/null 2>&1
			if [[ $need_headers -eq 1 ]]; then
				echo -e "${INFO} 正在使用 apt 安装 Cloud 内核及 Headers..."
				apt-get install -y "linux-image-cloud-${debarch}" "linux-headers-cloud-${debarch}"
			else
				echo -e "${INFO} 正在使用 apt 安装 Cloud 内核..."
				apt-get install -y "linux-image-cloud-${debarch}"
			fi
			BBR_grub
			return 0
		fi
		echo "$CLOUD_MAX_FILE" >"$CLOUD_STATE_FILE"
		echo -e "${INFO} 探测完成！当前系统最高可安装版本: ${GREEN_FONT_PREFIX}${CLOUD_MAX_FILE}${FONT_COLOR_SUFFIX}，开始安装..."
		if install_kernel_generic "Debian 官方 Cloud" "" "${img_url_base}${CLOUD_MAX_FILE}"; then
			[[ $need_headers -eq 1 ]] && ensure_cloud_headers "$CLOUD_MAX_FILE" "$debarch"
		fi
		return 0
	fi

	if [[ "$choice" =~ ^[hH]$ ]]; then
		echo -e "${INFO} 正在使用 apt 安装 Cloud 内核及 Headers..."
		apt-get update >/dev/null 2>&1
		apt-get install -y "linux-image-cloud-${debarch}" "linux-headers-cloud-${debarch}"
		BBR_grub
		return 0
	fi

	choice=${choice:-$default_idx}
	if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -gt "$last_idx" ]; then
		echo -e "${TIP} 无效选项，默认安装 ${default_idx} 号版本..."
		choice=$default_idx
	fi

	local selected_file="${versions_array[$choice]}"
	if install_kernel_generic "Debian 官方 Cloud" "" "${img_url_base}${selected_file}"; then
		ensure_cloud_headers "$selected_file" "$debarch"
	fi
}

# 从 Release (kernels) 拉取指定内核二进制整包并解压到目标目录 (现可通过镜像高速下载 + SHA256/gzip魔数双重保护)
fetch_kernel_archive() {
	local name="$1"
	local dest="$2"
	local tarball="${dest}/${name}.tar.gz"
	local target_url="${KERNEL_RELEASE_BASE}/${name}.tar.gz"
	local sha=""

	# 尝试通过 API 获取该整包的官方 SHA-256 摘要 (若上游有提供则绑定校验，获取失败不阻断下载)
	local meta
	if meta=$(get_github_asset "ylx2016/Linux-NetSpeed" "kernels" "${name}\\.tar\\.gz" 2>/dev/null); then
		[[ "$meta" == *$'	'* ]] && sha="${meta#*$'	'}"
	fi

	echo -e "${INFO} 正在通过加速镜像下载 ${name} 内核整包 (体积较大，请耐心等待)..."
	if ! safe_wget "$target_url" "$tarball" "$sha"; then
		echo -e "${ERROR} ${name} 内核整包下载失败！"
		return 1
	fi

	local members details
	if ! members=$(LC_ALL=C TAR_OPTIONS= tar tzPf "$tarball" 2>/dev/null) || [[ -z "$members" ]]; then
		echo -e "${ERROR} ${name} 内核整包无法读取或不含成员。"
		rm -f "$tarball"
		return 1
	fi
	if printf '%s\n' "$members" | grep -qE '(^/)|(^|/)\.\.(/|$)'; then
		echo -e "${ERROR} ${name} 内核整包含有越界路径成员，已拒绝解压。"
		rm -f "$tarball"
		return 1
	fi
	if ! details=$(LC_ALL=C TAR_OPTIONS= tar tvzPf "$tarball" 2>/dev/null) || \
		printf '%s\n' "$details" | grep -qvE '^[-dl]'; then
		echo -e "${ERROR} ${name} 内核整包含有硬链接或特殊成员，已拒绝解压。"
		rm -f "$tarball"
		return 1
	fi
	if ! TAR_OPTIONS= tar xzf "$tarball" -C "$dest" --no-same-owner --no-same-permissions; then
		echo -e "${ERROR} ${name} 内核整包解压失败 (文件可能损坏或磁盘空间不足)。"
		rm -f "$tarball"
		return 1
	fi
	local dest_root="$dest" link resolved
	[[ "$dest_root" == /* ]] || dest_root="$(pwd)/${dest}"
	dest_root="${dest_root%/}"
	while IFS= read -r link; do
		[[ -n "$link" ]] || continue
		resolved=$(readlink -m -- "$link" 2>/dev/null)
		case "$resolved" in
		"$dest_root"/*) ;;
		*)
			echo -e "${ERROR} ${name} 内核整包含有指向目标目录之外的符号链接，已中止。"
			rm -f "$tarball"
			return 1
			;;
		esac
	done < <(find "$dest" -type l 2>/dev/null)
	rm -f "$tarball"
	return 0
}

# 安装 Lotserver (锐速) 专属内核
installlot() {
	pre_install_check || return 1

	[[ "$OS_ARCH" != "x86_64" ]] && {
		echo -e "${ERROR} Lotserver 仅支持 x86_64 架构！"
		return 1
	}

	if [[ "${OS_TYPE}" == "CentOS" && "${OS_VERSION_ID}" != "6" && "${OS_VERSION_ID}" != "7" ]]; then
		echo -e "${ERROR} Lotserver 内核仅支持 CentOS 6/7，当前为 CentOS ${OS_VERSION_ID}！"
		return 1
	fi

	local work_dir
	work_dir=$(mktemp -d /tmp/lot_install.XXXXXX) || {
		echo -e "${ERROR} 无法创建临时目录！"
		return 1
	}
	trap 'cd /tmp; rm -rf "$work_dir"; trap - RETURN' RETURN
	cd "$work_dir" || {
		echo -e "${ERROR} 无法进入临时目录 ${work_dir}！"
		return 1
	}

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		local lot_ver="4.11.2-1"
		[[ "${OS_VERSION_ID}" == "6" ]] && lot_ver="2.6.32-504"

		if ! fetch_kernel_archive "lotserver" "$work_dir"; then
			echo -e "${ERROR} Lotserver 内核包获取失败，已中止 (系统未做任何更改)。"
			return 1
		fi
		local lot_dir="${work_dir}/lotserver/centos/${OS_VERSION_ID}/x64"

		local pkg
		for pkg in kernel-firmware kernel kernel-headers kernel-devel; do
			if [[ ! -f "${lot_dir}/${pkg}-${lot_ver}.rpm" ]]; then
				echo -e "${ERROR} Lotserver 组件 ${pkg}-${lot_ver}.rpm 缺失，已中止 (系统未做任何更改)。"
				return 1
			fi
		done

		rpm --import "${work_dir}/lotserver/centos/RPM-GPG-KEY-elrepo.org" >/dev/null 2>&1
		remove_old_headers
		yum remove -y kernel-firmware kernel-headers >/dev/null 2>&1

		echo -e "${INFO} 正在安装 Lotserver 专属内核组件..."
		if ! yum install -y "${lot_dir}/kernel-firmware-${lot_ver}.rpm" "${lot_dir}/kernel-${lot_ver}.rpm" "${lot_dir}/kernel-headers-${lot_ver}.rpm" "${lot_dir}/kernel-devel-${lot_ver}.rpm"; then
			echo -e "${ERROR} Lotserver 内核安装失败！"
			return 1
		fi

	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		local base_deb="" img_deb=""
		if [[ "$OS_ID" == "debian" && "$OS_VERSION_ID" == "8" ]]; then
			base_deb="https://snapshot.debian.org/archive/debian/20120304T220938Z/pool/main/l/linux-base/linux-base_3.5_all.deb"
			img_deb="https://snapshot.debian.org/archive/debian/20171008T163152Z/pool/main/l/linux/linux-image-3.16.0-4-amd64_3.16.43-2+deb8u5_amd64.deb"
		elif [[ "$OS_ID" == "debian" && "$OS_VERSION_ID" == "9" ]]; then
			base_deb="https://snapshot.debian.org/archive/debian/20160917T042239Z/pool/main/l/linux-base/linux-base_4.5_all.deb"
			img_deb="https://snapshot.debian.org/archive/debian/20171224T175424Z/pool/main/l/linux/linux-image-4.9.0-4-amd64_4.9.65-3+deb9u1_amd64.deb"
		else
			echo -e "${ERROR} Lotserver 不支持当前系统版本！"
			return 1
		fi

		if ! safe_wget "$base_deb" "linux-base.deb" || ! safe_wget "$img_deb" "linux-image.deb"; then
			echo -e "${ERROR} Lotserver 内核组件下载失败，已中止 (系统未做任何更改)。"
			return 1
		fi

		apt-get autoremove -y >/dev/null 2>&1
		remove_old_headers

		dpkg-query -W -f='${Status}' linux-base 2>/dev/null | grep -q "install ok installed" || dpkg -i linux-base.deb
		if ! apt-get install -y --allow-downgrades ./linux-image.deb; then
			echo -e "${ERROR} Lotserver 内核安装失败！"
			return 1
		fi
	fi

	echo -e "${INFO} Lotserver 内核包安装完成，正在更新系统引导..."
	BBR_grub
}

ask_workload_profile() {
	local ans
	echo -e "${INFO} 请选择本机用途 (影响 合包/conntrack 等场景参数；内核转发默认全开):" >&2
	echo -e "      [1] 网站 / 通用          (Nginx/PHP/DB，主要入站短连接)" >&2
	echo -e "      [2] 代理 / 转发组网      (SS/Xray/Trojan/Hysteria/WireGuard/tun) <-- 默认" >&2
	read -t 10 -rp "      输入 1/2 (10 秒无输入或回车默认 [2] 代理): " ans
	echo >&2
	case "$ans" in
	1) echo "web" ;;
	*) echo "proxy" ;;
	esac
}

render_ipv6_ra_config() {
	[[ -d /proc/sys/net/ipv6/conf ]] || return 0
	local ra_file iface ra config=""
	for ra_file in /proc/sys/net/ipv6/conf/*/accept_ra; do
		[[ -f "$ra_file" ]] || continue
		iface=${ra_file%/accept_ra}
		iface=${iface##*/}
		case "$iface" in all | lo) continue ;; esac
		if [[ ! "$iface" =~ ^[a-zA-Z0-9_.:-]+$ ]]; then
			echo -e "${ERROR} 网卡名 ${iface} 无法安全写入 sysctl 配置，已停止修改。" >&2
			return 1
		fi
		if ! read -r ra <"$ra_file" || [[ ! "$ra" =~ ^[012]$ ]]; then
			echo -e "${ERROR} 无法读取 ${iface} 的 accept_ra，已停止修改，避免破坏 IPv6。" >&2
			return 1
		fi
		[[ "$ra" == "1" ]] && ra=2
		printf -v config '%snet/ipv6/conf/%s/accept_ra = %s\n' "$config" "$iface" "$ra"
	done
	[[ -n "$config" ]] || return 0
	printf '# BEGIN TCPX IPv6 RA\n# 1→2 兼容转发；0 保留禁用/用户态 RA。自定义覆盖请写在本块之后。\n%s# END TCPX IPv6 RA\n' "$config"
}

ensure_ipv6_ra_config() {
	local conf="/etc/sysctl.d/99-sysctl.conf" ra_config tmp
	[[ -f "$conf" ]] || return 0
	conf=$(readlink -f -- "$conf") || {
		echo -e "${ERROR} 无法解析 sysctl 配置真实路径，本次不修改或应用。" >&2
		return 1
	}
	grep -Eq '^[[:space:]]*net\.ipv6\.conf\.all\.forwarding[[:space:]]*=[[:space:]]*1([[:space:]#;]|$)' "$conf" || return 0
	if ! awk '
		/^# BEGIN TCPX IPv6 RA[[:space:]]*$/ {if (seen) bad=1; seen=1; inside=1}
		/^# END TCPX IPv6 RA[[:space:]]*$/ {if (!inside) bad=1; inside=0}
		END {exit (bad || inside)}' "$conf"; then
		echo -e "${ERROR} ${conf} 的 IPv6 RA 标记块损坏，请先检查文件；本次不应用转发参数。" >&2
		return 1
	fi
	if [[ "${1:-}" != "refresh" ]] && grep -Eq '^# BEGIN TCPX IPv6 RA[[:space:]]*$' "$conf"; then
		return 0
	fi
	ra_config=$(render_ipv6_ra_config) || return 1
	[[ -n "$ra_config" ]] || return 0
	tmp=$(mktemp "${conf}.ipv6-ra.XXXXXX") || {
		echo -e "${ERROR} 无法创建 IPv6 RA 配置临时文件，本次不应用转发参数。" >&2
		return 1
	}
	if ! {
		printf '%s\n' "$ra_config" >"$tmp" &&
			awk '/^# BEGIN TCPX IPv6 RA[[:space:]]*$/ {skip=1; next} /^# END TCPX IPv6 RA[[:space:]]*$/ {skip=0; next} !skip' "$conf" >>"$tmp" &&
			chown --reference="$conf" "$tmp" && chmod --reference="$conf" "$tmp" &&
			{ [[ -e "${conf}.before-ipv6-ra.bak" ]] || cp -p "$conf" "${conf}.before-ipv6-ra.bak"; } &&
			mv -f "$tmp" "$conf"
	}; then
		rm -f "$tmp"
		echo -e "${ERROR} IPv6 RA 配置写入失败，本次不应用转发参数。" >&2
		return 1
	fi
	echo -e "${INFO} 已补齐 IPv6 RA 兼容配置（保留 forwarding 和显式 RA=0），原配置备份: ${conf}.before-ipv6-ra.bak" >&2
}

check_ipv6_ra() {
	local ra_file iface ra forwarding disabled status=0
	for ra_file in /proc/sys/net/ipv6/conf/*/accept_ra; do
		[[ -f "$ra_file" ]] || continue
		iface=${ra_file%/accept_ra}
		case "${iface##*/}" in all | lo) continue ;; esac
		read -r ra <"$ra_file" || continue
		read -r forwarding <"$iface/forwarding" || continue
		read -r disabled <"$iface/disable_ipv6" || continue
		if [[ "$disabled" == "0" && "$forwarding" == "1" && "$ra" == "1" ]]; then
			echo -e "${TIP} ${iface##*/}: forwarding=1、accept_ra=1，内核不会接收 RA；请检查其它 sysctl/网络管理器的覆盖（菜单 [39] 可修复旧配置）。" >&2
			status=1
		fi
	done
	return "$status"
}

apply_sysctl() {
	ensure_ipv6_ra_config || return 1
	local status=0
	sysctl -e --system || status=$?
	if [[ -f /etc/sysctl.d/99-sysctl.conf ]] && grep -Eq '^# BEGIN TCPX IPv6 RA[[:space:]]*$' /etc/sysctl.d/99-sysctl.conf; then
		check_ipv6_ra || status=1
	fi
	return "$status"
}

repair_ipv6_ra() {
	if [[ ! -f /etc/sysctl.d/99-sysctl.conf ]]; then
		echo -e "${TIP} 未找到 tcpx 的 sysctl 配置，无需迁移。"
		return 0
	fi
	ensure_ipv6_ra_config refresh || return 1
	apply_sysctl >/dev/null || return 1
	echo -e "${INFO} IPv6 RA 配置已检查并应用；未关闭转发，也未重启网络。"
	echo -e "${TIP} RA=0 的接口保持原策略（可能由 networkd/NetworkManager 接管）；本操作不强行启用 IPv6 或地址自动配置。"
	if command -v ip >/dev/null 2>&1; then
		local addresses routes
		addresses=$(ip -6 addr show scope global)
		routes=$(ip -6 route show default)
		printf '\nIPv6 全局地址:\n%s\nIPv6 默认路由:\n%s\n' "${addresses:-（暂无）}" "${routes:-（暂无）}"
		if [[ -z "$addresses" || -z "$routes" ]]; then
			echo -e "${TIP} 尚未确认 IPv6 连通性；若本机依赖 SLAAC，请等待新的 RA，或用 rdisc6 <公网网卡> 主动请求。" >&2
			echo -e "${TIP} 若仍不恢复，请核对网络管理器的 RA 配置及 ICMPv6；不要在唯一的 SSH 会话中直接重启网络。" >&2
		fi
	fi
}

# =================================================
#  系统级网络与资源自适应优化
# =================================================
optimizing_system() {
	if tcpfit_present; then
		echo -e "${TIP} 检测到 tcpfit 正在管理网络 sysctl (/etc/sysctl.d/99-tcpfit.conf)。"
		echo -e "${TIP} tcpx 的整体优化会与其重叠，重叠键最终以 tcpfit 为准，且可能引入"
		echo -e "      tcpfit 有意省略的参数。建议改用菜单 [60] 调起 tcpfit 精调。"
		read -rp "仍要继续执行 tcpx 的系统优化吗？(请输入大写 YES 继续): " _go
		if [[ "$_go" != "YES" ]]; then
			echo -e "${INFO} 已跳过，网络精调交由 tcpfit 负责。"
			return 0
		fi
	fi

	echo -e "${INFO} 开始进行系统级网络优化 (自适应 CPU/内存/内核版本)..."

	local total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
	local total_mem_mb=$((total_mem_kb / 1024))
	local cpu_cores=$(nproc)
	local kernel_major=$(uname -r | cut -d. -f1)
	local kernel_minor=$(uname -r | cut -d. -f2)

	local current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "bbr")
	local current_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "fq")
	[[ "$current_cc" == "unknown" || -z "$current_cc" ]] && current_cc="bbr"
	[[ "$current_qdisc" == "unknown" || -z "$current_qdisc" ]] && current_qdisc="fq"

	local current_disable_ipv6=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "0")
	[[ "$current_disable_ipv6" != "1" ]] && current_disable_ipv6="0"
	if [[ "$current_disable_ipv6" == "1" ]]; then
		echo -e "${TIP} 检测到当前已禁用 IPv6，本次优化将保持该状态 (如需开启请用菜单 [36])。"
	fi

	local workload autocork tune_conntrack
	workload=$(ask_workload_profile)
	case "$workload" in
	web)
		autocork=1
		tune_conntrack=0
		echo -e "${INFO} 用途=网站/通用：开启合包(autocorking 提升小响应效率)。"
		;;
	*)
		autocork=0
		tune_conntrack=1
		echo -e "${INFO} 用途=代理/转发：关闭合包(低延迟)、抬高 conntrack 上限。"
		;;
	esac

	local sock_buf_max somaxconn file_max syn_backlog
	if [ "$total_mem_mb" -ge 8192 ]; then
		sock_buf_max=67108864
		somaxconn=1048576
		file_max=2097152
		syn_backlog=65535
	elif [ "$total_mem_mb" -ge 2048 ]; then
		sock_buf_max=33554432
		somaxconn=65535
		file_max=1048576
		syn_backlog=32768
	else
		sock_buf_max=16777216
		somaxconn=32768
		file_max=524288
		syn_backlog=16384
	fi

	local netdev_max_backlog=$((10000 * cpu_cores))
	[[ $netdev_max_backlog -lt 32768 ]] && netdev_max_backlog=32768
	[[ $netdev_max_backlog -gt 100000 ]] && netdev_max_backlog=100000

	local netdev_budget=$((300 + 20 * cpu_cores))
	[[ $netdev_budget -gt 50000 ]] && netdev_budget=50000

	local ra_config
	ra_config=$(render_ipv6_ra_config) || return 1

	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	[[ -f "$sysctl_conf" ]] && cp "$sysctl_conf" "${sysctl_conf}.bak"
	cat /dev/null >"$sysctl_conf"

	cat >>"$sysctl_conf" <<EOF
# --- 文件系统与内存基础 ---
fs.file-max = $file_max
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = $file_max
kernel.pid_max = 4194304
vm.swappiness = 1

# --- 网络核心队列与连接数 ---
net.core.somaxconn = $somaxconn
net.core.netdev_max_backlog = $netdev_max_backlog
net.core.netdev_budget = $netdev_budget
net.core.rmem_max = $sock_buf_max
net.core.wmem_max = $sock_buf_max
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.optmem_max = 65536

# --- TCP 核心调优 (缓冲区自适应) ---
net.ipv4.tcp_rmem = 4096 131072 $sock_buf_max
net.ipv4.tcp_wmem = 4096 65536 $sock_buf_max
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_autocorking = $autocork
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = $syn_backlog
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1

# --- TCP 超时、重传与 KeepAlive 优化 ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 2
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_tw_buckets = 55000
net.ipv4.tcp_fastopen = 3

$ra_config

# --- 路由转发 (默认全开，兼容 Docker/Tailscale/WireGuard 等) ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.lo.forwarding = 1
net.ipv6.conf.all.disable_ipv6 = $current_disable_ipv6
net.ipv6.conf.default.disable_ipv6 = $current_disable_ipv6

# --- 默认拥塞控制 (动态继承) ---
net.core.default_qdisc = $current_qdisc
net.ipv4.tcp_congestion_control = $current_cc
EOF

	if [[ "$tune_conntrack" -eq 1 ]]; then
		local ct_max=262144
		local ct_hashsize=$((ct_max / 4))
		modprobe nf_conntrack >/dev/null 2>&1
		echo "nf_conntrack" >/etc/modules-load.d/tcpx-conntrack.conf
		echo "options nf_conntrack hashsize=${ct_hashsize}" >/etc/modprobe.d/tcpx-conntrack.conf
		[[ -w /sys/module/nf_conntrack/parameters/hashsize ]] &&
			echo "$ct_hashsize" >/sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
		cat >>"$sysctl_conf" <<EOF

# --- 连接跟踪 (用途=代理/转发，繁忙节点防 conntrack 表溢出) ---
net.netfilter.nf_conntrack_max = $ct_max
EOF
	fi

	if [[ "$kernel_major" -lt 4 || ("$kernel_major" -eq 4 && "$kernel_minor" -lt 12) ]]; then
		echo "net.ipv4.tcp_tw_recycle = 0" >>"$sysctl_conf"
	fi
	if [[ "$kernel_major" -lt 4 || ("$kernel_major" -eq 4 && "$kernel_minor" -lt 11) ]]; then
		echo "net.ipv4.tcp_fack = 1" >>"$sysctl_conf"
	fi

	echo -e "${INFO} 正在根据内存大小自动优化系统文件描述符限制..."

	if [[ -d "/etc/systemd" ]]; then
		[[ -f /etc/systemd/system.conf && ! -f /etc/systemd/system.conf.bak ]] &&
			cp /etc/systemd/system.conf /etc/systemd/system.conf.bak
		cat >/etc/systemd/system.conf <<EOF
[Manager]
DefaultTimeoutStopSec=30s
DefaultLimitCORE=0
DefaultLimitNOFILE=$file_max
DefaultLimitNPROC=infinity
DefaultTasksMax=infinity
EOF
		systemctl daemon-reload >/dev/null 2>&1
	fi

	[[ -f /etc/security/limits.conf && ! -f /etc/security/limits.conf.bak ]] &&
		cp /etc/security/limits.conf /etc/security/limits.conf.bak
	cat >/etc/security/limits.conf <<EOF
* soft   nofile    $file_max
* hard   nofile    $file_max
* soft   nproc     unlimited
* hard   nproc     unlimited
* soft   core      0
* hard   core      0
root  soft   nofile    $file_max
root  hard   nofile    $file_max
root  soft   nproc     unlimited
root  hard   nproc     unlimited
root  soft   core      0
root  hard   core      0
EOF

	sed -i '/ulimit -SHn/d' /etc/profile
	sed -i '/ulimit -SHu/d' /etc/profile
	echo "ulimit -SHn $file_max" >>/etc/profile

	if [[ -f "/etc/pam.d/common-session" ]] && ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
		echo "session required pam_limits.so" >>/etc/pam.d/common-session
	fi

	echo -e "${INFO} 正在应用自适应内核配置..."
	apply_sysctl >/dev/null || return 1

	if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
		echo madvise >/sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
		cat >/etc/systemd/system/tcpx-thp.service <<'EOF'
[Unit]
Description=Set Transparent HugePage to madvise (tcpx)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
		systemctl daemon-reload >/dev/null 2>&1
		systemctl enable tcpx-thp.service >/dev/null 2>&1
	fi

	echo -e "${INFO} 系统网络与资源限制自适应优化完成！(建议完成后重启服务器以全面生效)"
}

# =================================================
#  网络加速统一切换引擎
# =================================================

tcpfit_present() {
	[[ -f /etc/sysctl.d/99-tcpfit.conf ]] && return 0
	[[ -d /var/lib/tcpfit ]] && return 0
	systemctl list-unit-files 2>/dev/null | grep -q '^tcpfit-qdisc\.service' && return 0
	return 1
}

readonly TCPX_ACCEL_DROPIN="/etc/sysctl.d/99-zz-tcpx-accel.conf"
readonly LOTSPEED_BOOT_SERVICE="/etc/systemd/system/lotspeed-boot.service"
accel_conf_path() {
	if tcpfit_present; then
		echo "$TCPX_ACCEL_DROPIN"
	else
		echo "/etc/sysctl.d/99-sysctl.conf"
	fi
}

tcpfit_shaper_active() {
	systemctl is-active tcpfit-qdisc.service >/dev/null 2>&1
}

maybe_offer_disable_tcpfit_shaper() {
	tcpfit_shaper_active || return 0
	echo -e "${TIP} 检测到 tcpfit 出向整形 (tcpfit-qdisc.service) 正在运行。"
	echo -e "${TIP} 它会对网卡出向限速/整形，从而限制本次加速算法的实际吞吐。"
	read -rp "是否停用 tcpfit 整形以便加速全速生效？(y=停用 / 回车=保留): " _shaper_ans
	if [[ "$_shaper_ans" =~ ^[yY]$ ]]; then
		systemctl disable --now tcpfit-qdisc.service >/dev/null 2>&1
		echo -e "${INFO} 已停用 tcpfit 出向整形 (恢复: systemctl enable --now tcpfit-qdisc.service，或重新运行 tcpfit)。"
	else
		echo -e "${INFO} 已保留 tcpfit 整形，加速算法吞吐仍会受其限制。"
	fi
}

disable_tcpfit_shaper_force() {
	tcpfit_shaper_active || return 0
	systemctl disable --now tcpfit-qdisc.service >/dev/null 2>&1
	echo -e "${INFO} 已自动停用 tcpfit 出向整形 (tcpfit-qdisc.service)，以便 LotSpeed 全速生效。"
	echo -e "${TIP} 如需恢复: systemctl enable --now tcpfit-qdisc.service，或重新运行 tcpfit。"
}

remove_bbr_lotserver() {
	local apply_status=0
	ensure_ipv6_ra_config || return 1
	echo -e "${INFO} 正在清理旧的拥塞控制与队列算法配置..."
	local f
	for f in /etc/sysctl.d/99-sysctl.conf /etc/sysctl.conf "$TCPX_ACCEL_DROPIN"; do
		[[ -f "$f" ]] && sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d; /net\.ipv4\.tcp_ecn[[:space:]]*=/d' "$f"
	done

	apply_sysctl >/dev/null || apply_status=$?
	if [[ "$apply_status" -ne 0 && "${1:-}" != "cleanup" ]]; then
		return "$apply_status"
	fi

	systemctl disable --now lotspeed-boot.service >/dev/null 2>&1

	local lotspeed_bin
	if lotspeed_bin=$(trusted_command_path lotspeed); then
		"$lotspeed_bin" stop >/dev/null 2>&1
		rmmod lotspeed >/dev/null 2>&1
	elif command -v lotspeed >/dev/null 2>&1; then
		echo -e "${TIP} LotSpeed 助手文件或父目录不可信，已跳过执行。" >&2
	fi
	if lsmod | grep -q "lotspeed"; then
		rmmod lotspeed >/dev/null 2>&1
	fi

	if is_trusted_root_file /appex/bin/lotServer.sh; then
		local tmp_lot
		tmp_lot=$(mktemp /tmp/lotserver.XXXXXX)
		if fetch_remote_script "https://raw.githubusercontent.com/fei5seven/lotServer/master/lotServerInstall.sh" "$tmp_lot" >/dev/null 2>&1; then
			echo | run_with_github_accel bash "$tmp_lot" uninstall >/dev/null 2>&1
		fi
		rm -f "$tmp_lot"
	fi
	return "$apply_status"
}

ensure_qdisc_module() {
	local q="$1"
	[[ -z "$q" ]] && return 0
	modprobe "sch_${q}" >/dev/null 2>&1
	echo "sch_${q}" >/etc/modules-load.d/tcpx-qdisc.conf
}

enable_acceleration() {
	local qdisc="$1"
	local cc="$2"

	local prev_ecn
	prev_ecn=$(cat /proc/sys/net/ipv4/tcp_ecn 2>/dev/null)
	[[ ! "$prev_ecn" =~ ^[0-2]$ ]] && prev_ecn=""

	remove_bbr_lotserver || return 1
	maybe_offer_disable_tcpfit_shaper

	echo -e "${INFO} 正在应用: ${cc} + ${qdisc} ..."
	ensure_qdisc_module "$qdisc"
	local sysctl_conf
	sysctl_conf=$(accel_conf_path)
	if [[ "$sysctl_conf" == "$TCPX_ACCEL_DROPIN" ]]; then
		echo -e "${TIP} 检测到 tcpfit，已将本次选择写入高优先级文件 ${sysctl_conf}"
		echo -e "${TIP} 以覆盖 tcpfit 默认的 bbr/fq (仅覆盖 cc/qdisc，其余精调仍归 tcpfit)。"
	fi
	echo "net.core.default_qdisc=$qdisc" >>"$sysctl_conf"
	echo "net.ipv4.tcp_congestion_control=$cc" >>"$sysctl_conf"
	[[ -n "$prev_ecn" ]] && echo "net.ipv4.tcp_ecn=$prev_ecn" >>"$sysctl_conf"

	apply_sysctl >/dev/null || return 1
	echo -e "${INFO} 加速算法修改成功！如果未立即生效，请重启服务器。"
}

# 启用 Lotserver (子脚本内部的 lotServer.log / 内核模块 / lotServer.tar 下载均通过沙箱自动加速)
startlotserver() {
	remove_bbr_lotserver || return 1
	maybe_offer_disable_tcpfit_shaper
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		yum install ethtool -y
	else
		apt-get update && apt-get install ethtool -y
	fi

	local tmp_lot
	tmp_lot=$(mktemp /tmp/lotserver.XXXXXX) || return 1
	if ! fetch_remote_script "https://raw.githubusercontent.com/fei5seven/lotServer/master/lotServerInstall.sh" "$tmp_lot"; then
		rm -f "$tmp_lot"
		echo -e "${ERROR} lotServer 安装脚本下载失败！"
		return 1
	fi
	echo | run_with_github_accel bash "$tmp_lot" install
	rm -f "$tmp_lot"

	if [[ ! -f /appex/etc/config ]]; then
		echo -e "${ERROR} lotServer 安装失败，未生成配置文件 /appex/etc/config！"
		return 1
	fi
	if ! is_trusted_root_file /appex/bin/lotServer.sh || ! is_trusted_root_file /appex/etc/config; then
		echo -e "${ERROR} /appex 下的助手或配置不是 root 拥有的普通文件，拒绝以 root 执行/改写。" >&2
		return 1
	fi
	sed -i '/advinacc/d; /maxmode/d' /appex/etc/config
	echo -e "advinacc=\"1\"\nmaxmode=\"1\"" >>/appex/etc/config
	/appex/bin/lotServer.sh restart
}

set_ecn() {
	local status="$1"
	local sysctl_conf
	sysctl_conf=$(accel_conf_path)
	sed -i '/net\.ipv4\.tcp_ecn[[:space:]]*=/d' /etc/sysctl.d/99-sysctl.conf /etc/sysctl.conf "$TCPX_ACCEL_DROPIN" 2>/dev/null
	echo "net.ipv4.tcp_ecn=$status" >>"$sysctl_conf"
	apply_sysctl >/dev/null || return 1
	[[ "$status" == "1" ]] && echo -e "${INFO} ECN 已开启！" || echo -e "${INFO} ECN 已关闭！"
}

_tcpfit_manual_restore() {
	local snap="/var/lib/tcpfit/pre-tune.snapshot"
	local iface gw
	systemctl disable --now tcpfit-qdisc.service >/dev/null 2>&1
	iface=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
	[[ -z "$iface" ]] && iface=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
	[[ -n "$iface" ]] && tc qdisc del dev "$iface" root 2>/dev/null
	gw=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
	[[ -n "$gw" && -n "$iface" ]] && ip route replace default via "$gw" dev "$iface" 2>/dev/null
	if [[ -f "$snap" ]]; then
		grep -E '^(net|vm|fs)\.' "$snap" | while IFS='=' read -r _k _v; do
			_k=$(echo "$_k" | xargs)
			_v=$(echo "$_v" | xargs)
			[[ -n "$_k" && -n "$_v" ]] && sysctl -qw "$_k=$_v" 2>/dev/null
		done
		echo -e "${INFO} 已按 tcpfit 快照还原 sysctl。"
	else
		echo -e "${TIP} 未找到 tcpfit 快照，仅移除其配置文件；已生效的运行值将在重启后回到内核默认。"
	fi
	if [[ -f /var/lib/tcpfit/swapfile.owned ]]; then
		echo -e "${TIP} 检测到 tcpfit 创建的 /swapfile；为避免误删占用中的 swap，未自动移除。"
		echo -e "${TIP} 如需删除请手动确认后执行: swapoff /swapfile && rm -f /swapfile 并清理 /etc/fstab。"
	fi
}

remove_tcpfit_full() {
	echo -e "${INFO} 正在还原并清理 tcpfit ..."
	if [[ -x /usr/local/bin/tcpfit ]]; then
		echo -e "${INFO} 调用 tcpfit rollback 还原其全部改动 ..."
		/usr/local/bin/tcpfit rollback --purge-swap ||
			echo -e "${TIP} tcpfit rollback 返回非 0，继续清理其残留文件。"
	else
		echo -e "${TIP} 未找到 /usr/local/bin/tcpfit 程序，改用兜底方式还原。"
		_tcpfit_manual_restore
	fi

	systemctl disable --now tcpfit-qdisc.service >/dev/null 2>&1
	rm -f /etc/systemd/system/tcpfit-qdisc.service /usr/local/sbin/tcpfit-qdisc.sh
	rm -f /etc/sysctl.d/99-tcpfit.conf
	rm -f /etc/networkd-dispatcher/routable.d/50-tcpfit-initcwnd
	rm -f /etc/modules-load.d/tcpfit-bbr.conf
	rm -f /usr/local/bin/tcpfit /usr/local/sbin/tcpfit.sh
	rm -rf /var/lib/tcpfit
	systemctl disable --now nettune-qdisc.service >/dev/null 2>&1
	rm -f /etc/systemd/system/nettune-qdisc.service /usr/local/sbin/nettune-qdisc.sh
	rm -f /etc/sysctl.d/99-nettune.conf /etc/networkd-dispatcher/routable.d/50-nettune-initcwnd
	rm -f /etc/modules-load.d/nettune-bbr.conf /usr/local/sbin/nettune.sh
	rm -rf /var/lib/nettune

	systemctl daemon-reload >/dev/null 2>&1
	apply_sysctl >/dev/null || return 1
	echo -e "${INFO} tcpfit 已还原并清理完成。"
}

remove_all() {
	local apply_status=0
	echo -e "${INFO} 正在清空网络优化与系统限制..."
	rm -f /etc/sysctl.d/99-sysctl.conf
	rm -f "$TCPX_ACCEL_DROPIN"
	cat /dev/null >/etc/sysctl.conf
	apply_sysctl >/dev/null || apply_status=$?

	[[ -f /etc/systemd/system.conf ]] && sed -i '/DefaultTimeoutStopSec/d; /DefaultLimitCORE/d; /DefaultLimitNOFILE/d; /DefaultLimitNPROC/d' /etc/systemd/system.conf
	[[ -f /etc/security/limits.conf ]] && sed -i '/soft   nofile/d; /hard   nofile/d; /soft   nproc/d; /hard   nproc/d; /soft   core/d; /hard   core/d' /etc/security/limits.conf
	[[ -f /etc/profile ]] && sed -i '/ulimit -SHn/d' /etc/profile
	[[ -f /etc/pam.d/common-session ]] && sed -i '/required pam_limits.so/d' /etc/pam.d/common-session

	systemctl daemon-reload
	remove_bbr_lotserver cleanup || apply_status=$?
	rm -f /usr/local/bin/lotspeed
	rm -rf /opt/lotspeed
	rm -f "$LOTSPEED_BOOT_SERVICE"

	systemctl disable --now tcpx-thp.service >/dev/null 2>&1
	rm -f /etc/systemd/system/tcpx-thp.service
	rm -f /etc/modules-load.d/tcpx-qdisc.conf
	rm -f /etc/modules-load.d/tcpx-conntrack.conf
	rm -f /etc/modprobe.d/tcpx-conntrack.conf
	systemctl daemon-reload >/dev/null 2>&1
	if tcpfit_present; then
		echo
		echo -e "${TIP} 检测到 tcpfit 仍在管理本机网络参数 (99-tcpfit.conf / tcpfit-qdisc.service / /var/lib/tcpfit 等)。"
		echo -e "${TIP} 选择清理将会："
		echo -e "        1) 还原 tcpfit 的全部改动 (按快照回写 sysctl、拆除出向整形 qdisc、复原默认路由、停用并删除 systemd 单元与路由钩子)"
		echo -e "        2) 删除 tcpfit 程序本体 (/usr/local/bin/tcpfit) 与状态目录 (/var/lib/tcpfit)"
		echo -e "        3) 撤销 tcpfit 自建的 swap (仅限其创建且可安全 swapoff 的，外来 swap 不动)"
		read -rp "是否一并还原并清理 tcpfit？(y=清理 / 回车=保留，默认否): " _tcpfit_ans
		if [[ "$_tcpfit_ans" =~ ^[yY]$ ]]; then
			remove_tcpfit_full
		else
			echo -e "${INFO} 已保留 tcpfit。如需彻底还原请执行: tcpfit rollback (加 --purge-swap 连 swap 一并撤销)。"
		fi
	fi
	if [[ "$apply_status" -ne 0 ]]; then
		echo -e "${TIP} 已继续清理加速器和优化文件，但 sysctl 重载有错误，请按上方输出检查其它配置。" >&2
		return "$apply_status"
	fi
	echo -e "${INFO} 系统已恢复原生状态。"
}

# =================================================
#  系统引导与内核管理引擎
# =================================================

BBR_grub() {
	echo -e "${INFO} 正在更新系统引导..."
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		if command -v grubby >/dev/null 2>&1; then
			local latest_kernel
			latest_kernel=$(grubby --info=ALL |
				awk -F= '/^kernel/{gsub(/"/,"",$2); print $2}' |
				sort -V | tail -n 1)
			if [[ -n "$latest_kernel" ]]; then
				grubby --set-default="$latest_kernel" >/dev/null 2>&1
				echo -e "${INFO} 默认启动内核已更新为: ${latest_kernel##*/}"
			else
				echo -e "${TIP} grubby 未找到内核条目，回退到 grub2-mkconfig..."
				_bbr_grub2_mkconfig
			fi
		else
			_bbr_grub2_mkconfig
		fi
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		if command -v bootctl >/dev/null 2>&1 && bootctl is-installed 2>/dev/null; then
			echo -e "${INFO} 检测到 systemd-boot，引导条目已由包管理器钩子自动处理。"
			bootctl update >/dev/null 2>&1 || true
		elif command -v update-grub >/dev/null 2>&1; then
			update-grub >/dev/null 2>&1
		else
			apt-get install -y grub2-common >/dev/null 2>&1
			update-grub >/dev/null 2>&1
		fi
	fi
}

_bbr_grub2_mkconfig() {
	local grub_cfg=""
	if [[ -d /boot/efi/EFI ]]; then
		grub_cfg=$(find /boot/efi/EFI -maxdepth 2 -name grub.cfg 2>/dev/null | head -n 1)
	fi
	[[ -z "$grub_cfg" && -f /boot/grub2/grub.cfg ]] && grub_cfg="/boot/grub2/grub.cfg"
	if [[ -n "$grub_cfg" ]]; then
		grub2-mkconfig -o "$grub_cfg" >/dev/null 2>&1
	fi
	grub2-set-default 0
}

show_kernels() {
	clear
	echo -e "${INFO} ==================================================="
	echo -e "${INFO} 当前系统中已安装的内核包："
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		rpm -qa | grep -E "^kernel(-ml|-lt|-uek|-rt|-plus)?(-image|-core|-modules|-devel|-headers)?-[0-9]" | sort -V
		echo -e "${INFO} ==================================================="
		echo -e "${INFO} GRUB 引导项 (通常 index=0 为默认启动项)："
		grubby --info=ALL | grep -E "^kernel|^index"
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		dpkg -l | grep -E "^ii  (linux-(image|headers|modules)|pve-kernel|proxmox-kernel|proxmox-headers|raspberrypi-kernel)" | awk '{print $2, $3}' | column -t | sort -V
		echo -e "${INFO} ==================================================="
		echo -e "${INFO} /boot 目录下的内核镜像："
		ls -1v /boot/vmlinuz-* 2>/dev/null
	fi
	echo -e "${INFO} ==================================================="
	echo -e "${TIP} 当前实际正在运行的内核: ${GREEN_FONT_PREFIX}$(uname -r)${FONT_COLOR_SUFFIX}"
	echo ""
	return 0
}

delete_kernel_custom() {
	clear
	echo -e "${INFO} ==================================================="
	echo -e "${INFO} 正在扫描系统中已安装的内核包..."
	local current_kernel=$(uname -r)
	local kernel_list=()

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		mapfile -t kernel_list < <(rpm -qa | grep -E "^kernel(-ml|-lt|-uek|-rt|-plus)?(-image|-core|-modules|-devel|-headers)?-[0-9]" | sort -V)
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		mapfile -t kernel_list < <(dpkg-query -W -f='${Package}\n' | grep -E "^(linux-(image|headers|modules)|pve-kernel|proxmox-kernel|proxmox-headers|raspberrypi-kernel)" | sort -V)
	fi

	if [[ ${#kernel_list[@]} -eq 0 ]]; then
		echo -e "${ERROR} 未检测到可管理的内核包。"
		return
	fi

	echo -e "${TIP} 当前正在运行的内核: ${GREEN_FONT_PREFIX}${current_kernel}${FONT_COLOR_SUFFIX}"
	echo -e "${INFO} ==================================================="

	for i in "${!kernel_list[@]}"; do
		local pkg="${kernel_list[$i]}"
		if [[ "$pkg" == *"$current_kernel"* ]]; then
			echo -e "  ${GREEN_FONT_PREFIX}[$i] ${pkg} [*当前运行中*]${FONT_COLOR_SUFFIX}"
		else
			echo -e "  [$i] ${pkg}"
		fi
	done
	echo -e "${INFO} ==================================================="
	echo -e "${TIP} 提示: 排序后默认从最高版本内核启动！"
	echo ""
	read -p "请输入要【删除】的内核编号 (多选请用空格分隔，例如 '0 2 3'，直接回车取消): " del_choices

	if [[ -z "$del_choices" ]]; then
		echo -e "${INFO} 已取消操作，返回主菜单。"
		return
	fi

	local pkgs_to_del=""
	local is_del_current=0
	for idx in $del_choices; do
		if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 0 ]] && [[ "$idx" -lt ${#kernel_list[@]} ]]; then
			local selected_pkg="${kernel_list[$idx]}"
			pkgs_to_del="$pkgs_to_del $selected_pkg"
			if [[ "$selected_pkg" == *"$current_kernel"* ]]; then
				is_del_current=1
			fi
		else
			echo -e "${TIP} 无效的编号: $idx，已忽略。"
		fi
	done

	if [[ -z "$pkgs_to_del" ]]; then
		echo -e "${INFO} 没有选择有效的内核，操作结束。"
		return
	fi

	local remaining_images=0
	for pkg in "${kernel_list[@]}"; do
		if [[ "${OS_TYPE}" == "Debian" ]]; then
			[[ "$pkg" != linux-image-* ]] && continue
		else
			[[ ! "$pkg" =~ ^kernel(-ml|-lt|-uek|-rt|-plus)?-[0-9] ]] && continue
		fi
		[[ " $pkgs_to_del " != *" $pkg "* ]] && remaining_images=$((remaining_images + 1))
	done
	if [[ $remaining_images -eq 0 ]]; then
		echo -e "${ERROR} 操作已阻止！删除所选包后系统将无任何可引导内核，重启即变砖！"
		echo -e "${TIP} 请至少保留一个可引导内核镜像包。"
		return 1
	fi

	echo -e "${TIP} 即将从系统中彻底卸载以下内核包:"
	echo -e "${RED_FONT_PREFIX}${pkgs_to_del}${FONT_COLOR_SUFFIX}"

	if [[ $is_del_current -eq 1 ]]; then
		echo -e ""
		echo -e "${ERROR} 高危警告！您选择了删除【当前正在运行的内核】！"
		echo -e "${TIP} 卸载当前运行中的内核，可能会导致您的 SSH 连接中断。"
		echo -e "${TIP} 请务必确保系统中还有【至少一个其他已正常安装的内核】，否则重启后机器将变砖失联！"
		read -p "您确定要继续删除选中的内核包吗？(请输入大写的 YES 确认): " confirm_danger
		if [[ "$confirm_danger" != "YES" ]]; then
			echo -e "${INFO} 操作已取消，出于安全考虑未执行删除。"
			return
		fi
	else
		read -p "请确认是否卸载？(Y/n): " confirm
		if [[ "$confirm" =~ ^[nN]$ ]]; then
			echo -e "${INFO} 操作已取消。"
			return
		fi
	fi

	echo -e "${INFO} 正在执行卸载，如果遇到断开连接请不要惊慌，稍等几分钟后尝试重启服务器..."
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		rpm -e --nodeps $pkgs_to_del
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		apt-get purge -y $pkgs_to_del
		apt-get autoremove -y >/dev/null 2>&1
	fi

	BBR_grub
	echo -e "${INFO} 指定内核卸载完毕！引导项已自动更新。"
}

# 编译安装 brutal (国内深度改造：彻底绕开被阻断的 tcp.hy2.sh 与 api.hy2.io，全走 GitHub 镜像获取脚本与 DKMS 包)
startbrutal() {
	check_status
	if [[ "$headers_status" == "已匹配" ]]; then
		echo -e "${INFO} Headers 已匹配，正在通过加速通道获取 TCP Brutal..."
		local tmp_brutal tmp_tarball=""
		tmp_brutal=$(mktemp /tmp/brutal.XXXXXX) || return 1

		# 优先从 GitHub 仓库镜像拉取官方 install_dkms.sh (等价于 tcp.hy2.sh，避开国内 hy2.sh 阻断)
		if ! fetch_remote_script "https://raw.githubusercontent.com/HyNetworks/tcp-brutal/master/scripts/install_dkms.sh" "$tmp_brutal"; then
			echo -e "${TIP} GitHub 源获取失败，尝试回退 https://tcp.hy2.sh/ ..."
			if ! fetch_remote_script "https://tcp.hy2.sh/" "$tmp_brutal"; then
				rm -f "$tmp_brutal"
				echo -e "${ERROR} Brutal 安装脚本下载失败！"
				return 1
			fi
		fi

		# 预先通过 GitHub API 加速通道获取最新 tcp-brutal.dkms.tar.gz 并用 -l 本地模式传入，彻底避开被墙的 api.hy2.io
		local brutal_meta brutal_url brutal_sha=""
		if brutal_meta=$(get_github_asset "HyNetworks/tcp-brutal" "tcp-brutal" "tcp-brutal\\.dkms\\.tar\\.gz" 2>/dev/null); then
			brutal_url="${brutal_meta%%$'	'*}"
			[[ "$brutal_meta" == *$'	'* ]] && brutal_sha="${brutal_meta#*$'	'}"
			tmp_tarball=$(mktemp /tmp/brutal_dkms.XXXXXX.tar.gz)
			if safe_wget "$brutal_url" "$tmp_tarball" "$brutal_sha"; then
				echo -e "${INFO} 已通过加速镜像预取 DKMS 源码包，开始本地安装..."
				run_with_github_accel bash "$tmp_brutal" -l "$tmp_tarball"
			else
				rm -f "$tmp_tarball"
				tmp_tarball=""
				run_with_github_accel bash "$tmp_brutal"
			fi
		else
			run_with_github_accel bash "$tmp_brutal"
		fi

		rm -f "$tmp_brutal" ${tmp_tarball:+"$tmp_tarball"}
		if lsmod | grep -q "brutal"; then
			echo -e "${INFO} Brutal 模块已成功加载！"
		else
			echo -e "${ERROR} Brutal 模块未加载，编译可能失败，请查看上方日志。"
		fi
	else
		echo -e "${ERROR} 当前内核 Headers 不匹配或未安装，无法编译 Brutal。"
		echo -e "${TIP} 请先安装对应版本的 Headers (通常随内核包一并安装，也可重新执行安装菜单)。"
	fi
}

setup_lotspeed_boot_service() {
	local lotspeed_bin sysctl_bin
	if ! lotspeed_bin=$(trusted_command_path lotspeed) || ! sysctl_bin=$(trusted_command_path sysctl); then
		echo -e "${ERROR} LotSpeed 或 sysctl 的文件/父目录不可信，拒绝写入开机执行路径。" >&2
		return 1
	fi
	if [[ -e "$LOTSPEED_BOOT_SERVICE" || -L "$LOTSPEED_BOOT_SERVICE" ]] && ! is_trusted_root_file "$LOTSPEED_BOOT_SERVICE"; then
		echo -e "${ERROR} 现有 LotSpeed 服务文件不可信，拒绝覆盖。" >&2
		return 1
	fi
	cat >"$LOTSPEED_BOOT_SERVICE" <<EOF
[Unit]
Description=Load LotSpeed and apply congestion control
After=network.target

[Service]
Type=oneshot
ExecStart=${lotspeed_bin} start
ExecStartPost=${sysctl_bin} -e --system
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
	[[ $? -eq 0 ]] || return 1
	systemctl daemon-reload >/dev/null 2>&1 || return 1
	if systemctl enable lotspeed-boot.service >/dev/null 2>&1; then
		echo -e "${INFO} 已启用 LotSpeed 开机自启 (lotspeed-boot.service)，重启后仍为默认算法。"
	else
		echo -e "${TIP} LotSpeed 开机自启服务启用失败 (非 systemd 环境?)，重启后可能需手动 lotspeed start。"
		return 1
	fi
}

# 安装启用 LotSpeed (子脚本内部的 lotspeed.c 与 Makefile 拉取均由加速沙箱自动代理)
install_lotspeed() {
	echo -e "${INFO} 准备通过加速通道安装并启用 LotSpeed (ml-tcp 分支) ..."
	local tmp_ls
	tmp_ls=$(mktemp /tmp/lotspeed.XXXXXX) || return 1
	if ! fetch_remote_script "https://raw.githubusercontent.com/uk0/lotspeed/ml-tcp/install.sh" "$tmp_ls"; then
		rm -f "$tmp_ls"
		echo -e "${ERROR} LotSpeed 安装脚本下载失败！"
		return 1
	fi
	run_with_github_accel bash "$tmp_ls"
	rm -f "$tmp_ls"

	if lsmod | grep -q "lotspeed"; then
		echo -e "${INFO} LotSpeed 模块已成功加载！"
		local sysctl_conf
		sysctl_conf=$(accel_conf_path)
		sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.d/99-sysctl.conf /etc/sysctl.conf "$TCPX_ACCEL_DROPIN" 2>/dev/null
		echo "net.ipv4.tcp_congestion_control=lotspeed" >>"$sysctl_conf"
		apply_sysctl >/dev/null || return 1
		setup_lotspeed_boot_service || return 1
		echo -e "${INFO} LotSpeed 已设置为默认拥塞控制算法！"
		disable_tcpfit_shaper_force
	else
		echo -e "${ERROR} LotSpeed 模块加载失败，请检查上方编译日志（通常是因为内核 Headers 缺失或版本过低）。"
	fi
}

enable_lotspeed_standalone() {
	if ! command -v lotspeed >/dev/null 2>&1; then
		echo -e "${ERROR} 未检测到 LotSpeed，请先执行菜单 [26] 进行编译安装！"
		sleep 3
		return
	fi
	local lotspeed_bin
	if ! lotspeed_bin=$(trusted_command_path lotspeed); then
		echo -e "${ERROR} LotSpeed 助手文件或父目录不可信，拒绝启动。" >&2
		return 1
	fi
	remove_bbr_lotserver || return 1
	disable_tcpfit_shaper_force
	echo -e "${INFO} 正在启动 LotSpeed 加速..."
	"$lotspeed_bin" start >/dev/null 2>&1 || return 1

	local sysctl_conf
	sysctl_conf=$(accel_conf_path)
	ensure_qdisc_module "fq"
	sed -i '/net.ipv4.tcp_congestion_control/d; /net.core.default_qdisc/d' /etc/sysctl.d/99-sysctl.conf /etc/sysctl.conf "$TCPX_ACCEL_DROPIN" 2>/dev/null
	echo "net.core.default_qdisc=fq" >>"$sysctl_conf"
	echo "net.ipv4.tcp_congestion_control=lotspeed" >>"$sysctl_conf"
	apply_sysctl >/dev/null || return 1

	setup_lotspeed_boot_service || return 1
	echo -e "${INFO} LotSpeed 加速已成功切换并启用！"
}

# =================================================
#  杂项与附加功能模块
# =================================================

trusted_command_path() {
	local path
	path=$(type -P "$1" 2>/dev/null) || return 1
	path=$(readlink -f -- "$path" 2>/dev/null) || return 1
	[[ "$path" =~ ^/[a-zA-Z0-9_./+-]+$ && -x "$path" ]] || return 1
	is_trusted_root_file "$path" || return 1
	printf '%s\n' "$path"
}

group_has_non_root_members() {
	local gid="$1"
	[[ -n "$gid" && "$gid" =~ ^[0-9]+$ ]] || return 0
	awk -F: -v g="$gid" '$3==g { n=split($4,m,","); for (i=1;i<=n;i++) if (m[i]!="" && m[i]!="root") { found=1; exit } } END { exit !found }' \
		/etc/group 2>/dev/null && return 0
	awk -F: -v g="$gid" '$4==g && $1!="root" { found=1; exit } END { exit !found }' /etc/passwd 2>/dev/null && return 0
	return 1
}

is_trusted_root_file() {
	local path="$1" metadata uid mode gid leaf=1
	[[ "$path" == /* && -f "$path" && ! -L "$path" ]] || return 1
	while :; do
		[[ ! -L "$path" ]] || return 1
		metadata=$(stat -c '%u %a %g' -- "$path" 2>/dev/null) || return 1
		uid="${metadata%% *}"
		mode="${metadata#* }"
		gid="${mode#* }"
		mode="${mode%% *}"
		[[ "$uid" == "0" && "$mode" =~ ^[0-7]{1,4}$ ]] || return 1
		(( (8#$mode & 8#002) == 0 )) || return 1
		if (( (8#$mode & 8#020) != 0 )); then
			if [[ "$leaf" == "1" ]]; then
				return 1
			fi
			if [[ "$gid" != "0" ]] && group_has_non_root_members "$gid"; then
				return 1
			fi
		fi
		leaf=0
		[[ "$path" == "/" ]] && break
		path="${path%/*}"
		[[ -n "$path" ]] || path="/"
		[[ -d "$path" ]] || return 1
	done
	return 0
}

# 通用的远程脚本获取器: 经由 safe_wget 全链路镜像加速 -> 校验非空且具备合法 shebang
fetch_remote_script() {
	local url="$1"
	local dest="$2"

	safe_wget "$url" "$dest" || return 1

	if [[ ! -s "$dest" ]]; then
		echo -e "${ERROR} 下载到的文件为空！"
		return 1
	fi
	if ! head -n 1 "$dest" | grep -qE '^#!.*(bash|sh)'; then
		echo -e "${ERROR} 下载到的内容不是有效的 Shell 脚本 (可能是错误页或被劫持)！"
		rm -f "$dest"
		return 1
	fi
	return 0
}

# 首次运行自安装：把脚本落地到 /usr/local/bin/tcpx
install_self() {
	local target="$TCPX_INSTALL_PATH"
	local src
	src=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")

	[[ "$src" == "$target" ]] && return 0
	[[ -w "$(dirname "$target")" ]] || return 0

	if [[ -f "$src" && -r "$src" ]]; then
		if [[ ! -f "$target" ]] || ! cmp -s "$src" "$target"; then
			if cp "$src" "$target" 2>/dev/null && chmod +x "$target" 2>/dev/null; then
				echo -e "${INFO} 已安装/更新到 ${target}，之后可直接输入 ${GREEN_FONT_PREFIX}tcpx${FONT_COLOR_SUFFIX} 运行。"
			fi
		fi
		return 0
	fi

	if [[ -n "$TCPX_SELF_URL" ]]; then
		local tmp
		tmp=$(mktemp /tmp/tcpx_self.XXXXXX) || return 0
		if fetch_remote_script "$TCPX_SELF_URL" "$tmp" >/dev/null 2>&1; then
			if mv -f "$tmp" "$target" 2>/dev/null && chmod +x "$target" 2>/dev/null; then
				echo -e "${INFO} 已安装到 ${target}，之后可直接输入 ${GREEN_FONT_PREFIX}tcpx${FONT_COLOR_SUFFIX} 运行。"
			fi
		else
			rm -f "$tmp"
			echo -e "${TIP} 自安装下载失败，建议下载到本地后执行 bash tcpx.sh 自动完成安装。"
		fi
	fi
	return 0
}

Update_Shell() {
	echo -e "${INFO} 正在检查更新脚本..."

	local update_url="${TCPX_UPDATE_URL:-${GITHUB_RAW_URL}/tcpx.sh}"
	local tmp_sh
	tmp_sh=$(mktemp /tmp/tcpx_update.XXXXXX) || {
		echo -e "${ERROR} 无法创建临时文件！"
		return 1
	}

	if ! fetch_remote_script "$update_url" "$tmp_sh"; then
		rm -f "$tmp_sh"
		echo -e "${ERROR} 脚本更新失败，已保留当前版本 (未做任何更改)。"
		return 1
	fi

	# 防止上游原版意外覆盖掉国内全链路加速补丁
	if ! grep -q 'TCPX_CN_EDITION=' "$tmp_sh" 2>/dev/null; then
		local remote_ver
		remote_ver=$(grep -m1 -oE 'SH_VER="[^"]+"' "$tmp_sh" | tr -d '"' | cut -d= -f2)
		echo -e "${TIP} 远端原版脚本 (${remote_ver:-unknown}) 未包含当前的「国内全链路加速补丁 (${TCPX_CN_EDITION})」！"
		echo -e "${TIP} 在国内网络下直接覆盖会导致 GitHub API、无摘要内核及子脚本再次无法下载。"
		read -rp "仍要覆盖为上游原版吗？(输入 YES 确认覆盖并备份当前加速版，回车取消): " _overwrite
		if [[ "$_overwrite" != "YES" ]]; then
			rm -f "$tmp_sh"
			echo -e "${INFO} 已取消覆盖，继续保留国内全链路加速版。"
			return 0
		fi
		[[ -f "$TCPX_INSTALL_PATH" ]] && cp -f "$TCPX_INSTALL_PATH" "${TCPX_INSTALL_PATH}.cn.bak" 2>/dev/null &&
			echo -e "${INFO} 已将当前国内加速版备份至: ${TCPX_INSTALL_PATH}.cn.bak"
	fi

	local self_path
	self_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
	if [[ ! -w "$(dirname "$self_path")" ]]; then
		self_path="/root/tcpx.sh"
	fi

	local current_file
	current_file=$(readlink -f "$0" 2>/dev/null || echo "$0")
	if [[ -f "$current_file" ]] && cmp -s "$tmp_sh" "$current_file"; then
		echo -e "${INFO} 当前脚本与远程一致 (文件无变化)，无需更新。"
		rm -f "$tmp_sh"
		return 0
	fi
	echo -e "${INFO} 检测到脚本内容有变化，正在应用更新..."

	mv -f "$tmp_sh" "$self_path" || {
		rm -f "$tmp_sh"
		echo -e "${ERROR} 写入 ${self_path} 失败！"
		return 1
	}
	chmod +x "$self_path"

	local reload_path="$self_path"
	if [[ "$self_path" != "$TCPX_INSTALL_PATH" && -w "$(dirname "$TCPX_INSTALL_PATH")" ]]; then
		if cp -f "$self_path" "$TCPX_INSTALL_PATH" 2>/dev/null && chmod +x "$TCPX_INSTALL_PATH" 2>/dev/null; then
			echo -e "${INFO} 已同步安装到 ${GREEN_FONT_PREFIX}${TCPX_INSTALL_PATH}${FONT_COLOR_SUFFIX}，之后可直接输入 ${GREEN_FONT_PREFIX}tcpx${FONT_COLOR_SUFFIX} 运行。"
			reload_path="$TCPX_INSTALL_PATH"
		fi
	fi

	echo -e "${INFO} 更新完成，正在重新载入脚本..."
	exec bash "$reload_path"
}

uninstall_tcpx() {
	echo -e "${TIP} 即将卸载 tcpx 管理脚本本体。"
	echo -e "${TIP} 默认仅删除 tcpx 程序文件，不会改动已应用的网络优化 (BBR/FQ/sysctl 等)。"
	echo

	echo -e "${TIP} 是否在卸载前执行「卸载全部加速」(remove_all) 还原系统网络优化？"
	echo -e "        y    = 先还原全部优化，再卸载脚本 (等同先执行菜单 55)"
	echo -e "        回车 = 保留当前网络优化，仅卸载脚本 (默认否)"
	read -rp "请选择 (y=先还原 / 回车=保留，默认否): " _restore_ans
	if [[ "$_restore_ans" =~ ^[yY]$ ]]; then
		remove_all
	else
		echo -e "${INFO} 已保留当前网络优化，仅卸载脚本本体。"
	fi

	echo
	read -rp "确认删除 tcpx 程序文件及加速配置文件？(y=确认卸载 / 回车=取消，默认否): " _confirm
	if [[ ! "$_confirm" =~ ^[yY]$ ]]; then
		echo -e "${INFO} 已取消卸载，tcpx 仍保留在本机。"
		return
	fi

	echo -e "${INFO} 正在卸载 tcpx ..."

	local removed=0
	local running_path
	running_path=$(readlink -f "$0" 2>/dev/null || echo "$0")

	if [[ -f "$TCPX_INSTALL_PATH" ]]; then
		rm -f "$TCPX_INSTALL_PATH" && { echo -e "${INFO} 已删除 ${TCPX_INSTALL_PATH}"; removed=1; }
	fi
	if [[ -f "$running_path" && "$running_path" != "$TCPX_INSTALL_PATH" ]]; then
		rm -f "$running_path" && { echo -e "${INFO} 已删除 ${running_path}"; removed=1; }
	fi
	[[ -f "$MIRROR_CONF_FILE" ]] && rm -f "$MIRROR_CONF_FILE" && echo -e "${INFO} 已删除 ${MIRROR_CONF_FILE}"

	if [[ "$removed" -eq 1 ]]; then
		echo -e "${INFO} tcpx 已卸载完成。"
	else
		echo -e "${TIP} 未发现可删除的 tcpx 程序文件 (可能以管道方式运行或已被删除)。"
	fi

	echo -e "${INFO} 感谢使用，已退出。"
	exit 0
}

# 一键 DD 重装系统 (国内优先走 bin456789 官方腾讯云 CNB 源，失败自动回退 GitHub 加速镜像)
gotodd() {
	echo -e "${INFO} 正在切换到一键 DD 系统脚本..."
	local tmp_sh
	tmp_sh=$(mktemp /tmp/reinstall.XXXXXX) || return 1

	local fetched=0
	if should_use_cn_accel; then
		echo -e "${INFO} 国内加速模式：优先从官方腾讯云 CNB 镜像获取 reinstall.sh ..."
		if fetch_remote_script "https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh" "$tmp_sh"; then
			fetched=1
		else
			echo -e "${TIP} CNB 源暂不可用，切换至 GitHub 镜像通道..."
		fi
	fi
	if [[ $fetched -eq 0 ]]; then
		if ! fetch_remote_script "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh" "$tmp_sh"; then
			rm -f "$tmp_sh"
			echo -e "${ERROR} reinstall.sh 下载失败！"
			return 1
		fi
	fi
	run_with_github_accel bash "$tmp_sh"
	rm -f "$tmp_sh"
}

closeipv6() {
	echo -e "${INFO} 正在禁用 IPv6..."
	sed -i '/net.ipv6.conf.all.disable_ipv6/d; /net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.d/99-sysctl.conf /etc/sysctl.conf 2>/dev/null
	echo "net.ipv6.conf.all.disable_ipv6 = 1" >>/etc/sysctl.d/99-sysctl.conf
	echo "net.ipv6.conf.default.disable_ipv6 = 1" >>/etc/sysctl.d/99-sysctl.conf
	apply_sysctl >/dev/null || return 1
	echo -e "${INFO} IPv6 已成功禁用！"
}

openipv6() {
	echo -e "${INFO} 正在开启 IPv6..."
	sed -i '/net.ipv6.conf.all.disable_ipv6/d; /net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.d/99-sysctl.conf /etc/sysctl.conf 2>/dev/null
	echo "net.ipv6.conf.all.disable_ipv6 = 0" >>/etc/sysctl.d/99-sysctl.conf
	echo "net.ipv6.conf.default.disable_ipv6 = 0" >>/etc/sysctl.d/99-sysctl.conf
	apply_sysctl >/dev/null || return 1
	echo -e "${INFO} IPv6 已成功开启！"
}

optimizing_ddcc() {
	echo -e "${INFO} 正在应用防 CC/DDOS 轻量优化..."
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"
	sed -i '/net.ipv4.tcp_syncookies/d; /net.ipv4.tcp_max_syn_backlog/d; /net.ipv4.tcp_synack_retries/d' "$sysctl_conf" 2>/dev/null
	cat >>"$sysctl_conf" <<EOF
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 1024000
net.ipv4.tcp_synack_retries = 1
EOF
	apply_sysctl >/dev/null || return 1
	echo -e "${INFO} 防 CC 基础参数已写入并生效！"
}

# 调起 tcpfit 进行网络精调 (改走落盘校验 + 全链路加速沙箱，解决国内直连 raw.githubusercontent.com 与 API 超时)
run_tcpfit_tune() {
	echo -e "${INFO} 正在通过加速通道调起 tcpfit 进行网络精调..."
	local tmp_tf
	tmp_tf=$(mktemp /tmp/tcpfit.XXXXXX) || return 1
	if ! fetch_remote_script "https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh" "$tmp_tf"; then
		rm -f "$tmp_tf"
		echo -e "${ERROR} tcpfit.sh 下载失败！"
		return 1
	fi
	run_with_github_accel bash "$tmp_tf"
	rm -f "$tmp_tf"
}

# =================================================
#  国内全链路加速配置与诊断面板 (菜单 [90])
# =================================================
run_cn_connectivity_diag() {
	echo -e "${INFO} ================== 全链路加速连通性诊断 =================="
	local p_file="${GH_PROXY:-${BEST_MIRROR:-}}"
	[[ "$p_file" == "poll" ]] && p_file="${DEFAULT_GITHUB_MIRRORS[0]}"
	local p_api="${GH_API_PROXY:-${GH_PROXY:-${BEST_API_MIRROR:-}}}"
	[[ "$p_api" == "poll" ]] && p_api="${DEFAULT_GITHUB_API_MIRRORS[0]}"

	# 1. Raw 文件测试
	if mirror_probe "$p_file" "${GITHUB_RAW_URL}/tcpx.sh" 4 128; then
		echo -e "  1) GitHub Raw 脚本 (${p_file:-直连}):      ${GREEN_FONT_PREFIX}正常 HTTP ${PROBE_HTTP} (${PROBE_TIME}s)${FONT_COLOR_SUFFIX}"
	else
		echo -e "  1) GitHub Raw 脚本 (${p_file:-直连}):      ${RED_FONT_PREFIX}异常 HTTP ${PROBE_HTTP:-超时}${FONT_COLOR_SUFFIX}"
	fi

	# 2. Release 大文件头测试
	if mirror_probe "$p_file" "${KERNEL_RELEASE_BASE}/lotserver.tar.gz" 5 128; then
		echo -e "  2) GitHub Release 包 (${p_file:-直连}):    ${GREEN_FONT_PREFIX}正常 HTTP ${PROBE_HTTP} (${PROBE_TIME}s)${FONT_COLOR_SUFFIX}"
	else
		echo -e "  2) GitHub Release 包 (${p_file:-直连}):    ${RED_FONT_PREFIX}异常 HTTP ${PROBE_HTTP:-超时}${FONT_COLOR_SUFFIX}"
	fi

	# 3. GitHub API JSON 测试
	local api_resp
	if api_resp=$(fetch_github_api "https://api.github.com/rate_limit" 5); then
		local remain
		remain=$(printf '%s' "$api_resp" | grep -oE '"remaining":[[:space:]]*[0-9]+' | head -n 1 | grep -oE '[0-9]+')
		echo -e "  3) GitHub REST API (${p_api:-轮询}):       ${GREEN_FONT_PREFIX}正常 JSON 响应 (当前节点剩余配额: ${remain:-未知}/hr)${FONT_COLOR_SUFFIX}"
	else
		echo -e "  3) GitHub REST API:                        ${RED_FONT_PREFIX}所有节点均失败${FONT_COLOR_SUFFIX}"
	fi

	# 4. jsDelivr Raw CDN 测试
	if mirror_probe "" "https://testingcf.jsdelivr.net/gh/ylx2016/Linux-NetSpeed@master/tcpx.sh" 4 128; then
		echo -e "  4) jsDelivr Raw CDN (testingcf):           ${GREEN_FONT_PREFIX}正常 HTTP ${PROBE_HTTP} (${PROBE_TIME}s)${FONT_COLOR_SUFFIX}"
	else
		echo -e "  4) jsDelivr Raw CDN (testingcf):           ${YELLOW_FONT_PREFIX}不可达 HTTP ${PROBE_HTTP:-超时}${FONT_COLOR_SUFFIX}"
	fi

	# 5. Debian 国内镜像源测试
	local deb_base
	deb_base=$(active_debian_mirror_base)
	if mirror_probe "" "${deb_base}/dists/stable/Release" 4 128; then
		echo -e "  5) Debian 内核池源 (${deb_base}): ${GREEN_FONT_PREFIX}正常 HTTP ${PROBE_HTTP} (${PROBE_TIME}s)${FONT_COLOR_SUFFIX}"
	else
		echo -e "  5) Debian 内核池源 (${deb_base}): ${YELLOW_FONT_PREFIX}HTTP ${PROBE_HTTP:-超时}${FONT_COLOR_SUFFIX}"
	fi
	echo -e "${INFO} =========================================================="
}

configure_cn_accel_menu() {
	while true; do
		clear
		local mode_str="自动识别 (当前 IS_CN=${IS_CN})"
		[[ "$TCPX_FORCE_CN" == "1" ]] && mode_str="强制国内加速 (1)"
		[[ "$TCPX_FORCE_CN" == "0" ]] && mode_str="强制海外直连 (0)"
		local token_str="未设置"
		[[ -n "$GITHUB_TOKEN" ]] && token_str="已设置 (${GITHUB_TOKEN:0:6}******)"

		echo -e " ———————————— 国内全链路加速与代理中心 (${MIRROR_CONF_FILE}) ————————————"
		echo -e "  当前加速策略:       ${GREEN_FONT_PREFIX}${mode_str}${FONT_COLOR_SUFFIX}"
		echo -e "  当前优选文件镜像:   ${GREEN_FONT_PREFIX}${GH_PROXY:-${BEST_MIRROR:-未探测}}${FONT_COLOR_SUFFIX}"
		echo -e "  当前优选 API 镜像:  ${GREEN_FONT_PREFIX}${GH_API_PROXY:-${BEST_API_MIRROR:-未探测}}${FONT_COLOR_SUFFIX}"
		echo -e "  自定义文件反代前缀: ${CYAN_FONT_PREFIX}${GH_PROXY:-未设置 (使用内置多镜像池)}${FONT_COLOR_SUFFIX}"
		echo -e "  自定义 API 反代前缀:${CYAN_FONT_PREFIX}${GH_API_PROXY:-未设置 (使用内置 API 镜像池)}${FONT_COLOR_SUFFIX}"
		echo -e "  HTTP/SOCKS5 代理:   ${CYAN_FONT_PREFIX}${TCPX_HTTP_PROXY:-未设置}${FONT_COLOR_SUFFIX}"
		echo -e "  GitHub API Token:   ${CYAN_FONT_PREFIX}${token_str}${FONT_COLOR_SUFFIX}"
		echo -e " ————————————————————————————————————————————————————————————————"
		echo -e "  ${GREEN_FONT_PREFIX}1.${FONT_COLOR_SUFFIX} 立即重新测速并优选最快镜像 (File + API + Debian)"
		echo -e "  ${GREEN_FONT_PREFIX}2.${FONT_COLOR_SUFFIX} 设置自定义 GitHub 全站/文件反代前缀 (如 https://gh.example.com/)"
		echo -e "  ${GREEN_FONT_PREFIX}3.${FONT_COLOR_SUFFIX} 设置专属 GitHub API 反代前缀 (留空则跟随通用反代或内置池)"
		echo -e "  ${GREEN_FONT_PREFIX}4.${FONT_COLOR_SUFFIX} 设置 HTTP / SOCKS5 代理 (如 http://127.0.0.1:7890 或 socks5h://...)"
		echo -e "  ${GREEN_FONT_PREFIX}5.${FONT_COLOR_SUFFIX} 设置 GITHUB_TOKEN (仅用于直连/可信私有反代解除 API 60次/h 限制)"
		echo -e "  ${GREEN_FONT_PREFIX}6.${FONT_COLOR_SUFFIX} 切换加速模式 (auto 自动识别 / 1 强制开启国内加速 / 0 强制直连)"
		echo -e "  ${GREEN_FONT_PREFIX}7.${FONT_COLOR_SUFFIX} 一键全链路连通性诊断 (Raw / Release / API / CDN / Debian)"
		echo -e "  ${GREEN_FONT_PREFIX}0.${FONT_COLOR_SUFFIX} 返回主菜单"
		echo -e " ————————————————————————————————————————————————————————————————"

		local sub_op
		read -rp " 请输入选项 [0-7]: " sub_op || return 0
		case "$sub_op" in
		1)
			IS_CN=1
			probe_github_mirrors
			;;
		2)
			local in_p norm_p=""
			read -rp " 请输入自定义 GitHub 反代前缀 (需 https:// 开头，直接回车清空): " in_p
			if [[ -z "$in_p" ]]; then
				GH_PROXY=""
				save_mirror_conf
				echo -e "${INFO} 已清空自定义文件反代，恢复内置镜像池。"
			elif norm_p=$(normalize_mirror_prefix "$in_p"); then
				GH_PROXY="$norm_p"
				BEST_MIRROR="$norm_p"
				save_mirror_conf
				echo -e "${INFO} 已保存自定义文件反代: ${GH_PROXY}"
			else
				echo -e "${ERROR} 地址格式不合法，必须以 https:// 开头！"
			fi
			;;
		3)
			local in_ap norm_ap=""
			read -rp " 请输入自定义 API 反代前缀 (需 https:// 开头，直接回车清空): " in_ap
			if [[ -z "$in_ap" ]]; then
				GH_API_PROXY=""
				save_mirror_conf
				echo -e "${INFO} 已清空自定义 API 反代。"
			elif norm_ap=$(normalize_mirror_prefix "$in_ap"); then
				GH_API_PROXY="$norm_ap"
				BEST_API_MIRROR="$norm_ap"
				save_mirror_conf
				echo -e "${INFO} 已保存自定义 API 反代: ${GH_API_PROXY}"
			else
				echo -e "${ERROR} 地址格式不合法，必须以 https:// 开头！"
			fi
			;;
		4)
			local in_hp
			read -rp " 请输入 HTTP/SOCKS5 代理地址 (如 http://127.0.0.1:7890，直接回车清空): " in_hp
			TCPX_HTTP_PROXY="${in_hp#"${in_hp%%[![:space:]]*}"}"
			TCPX_HTTP_PROXY="${TCPX_HTTP_PROXY%"${TCPX_HTTP_PROXY##*[![:space:]]}"}"
			apply_http_proxy_env
			save_mirror_conf
			if [[ -n "$TCPX_HTTP_PROXY" ]]; then
				echo -e "${INFO} 已启用全局代理: ${TCPX_HTTP_PROXY}"
			else
				echo -e "${INFO} 已清除代理环境变量。"
			fi
			;;
		5)
			local in_tk
			echo -e "${TIP} 安全承诺：Token 仅在直连 api.github.com (或经本机 HTTP/SOCKS5 代理) 时发送，绝不发往第三方公共镜像！"
			read -rp " 请输入 GitHub Personal Access Token (无权限只读 Token 即可，回车清空): " in_tk
			GITHUB_TOKEN="${in_tk//[[:space:]]/}"
			save_mirror_conf
			[[ -n "$GITHUB_TOKEN" ]] && echo -e "${INFO} GITHUB_TOKEN 已安全保存 (权限 0600)。" || echo -e "${INFO} GITHUB_TOKEN 已清空。"
			;;
		6)
			local in_mode
			read -rp " 请选择模式 [auto / 1 (强制国内加速) / 0 (强制直连)]: " in_mode
			case "$in_mode" in
			auto | 1 | 0)
				TCPX_FORCE_CN="$in_mode"
				save_mirror_conf
				check_cn_status
				;;
			*) echo -e "${ERROR} 无效模式，请输入 auto、1 或 0。" ;;
			esac
			;;
		7)
			run_cn_connectivity_diag
			;;
		0 | "")
			return 0
			;;
		*)
			echo -e "${ERROR} 请输入正确选项 [0-7]。"
			;;
		esac
		echo ""
		read -rp "按回车键继续..." _ || return 0
	done
}

# =================================================
#  UI 面板与主逻辑
# =================================================

get_system_info() {
	opsy="${OS_TYPE} ${OS_VERSION_ID}"
	arch="${OS_ARCH}"
	kern=$(uname -r)

	if command -v virt-what >/dev/null 2>&1; then
		virtual=$(virt-what | head -n 1)
	elif command -v systemd-detect-virt >/dev/null 2>&1; then
		virtual=$(systemd-detect-virt)
	else
		virtual="Unknown"
	fi
	[[ -z "$virtual" ]] && virtual="Dedicated"
}

show_menu_panel() {
	clear
	echo && echo -e " TCP加速 一键安装管理脚本 ${RED_FONT_PREFIX}[v${SH_VER}-${TCPX_CN_EDITION} 国内全链路加速版]${FONT_COLOR_SUFFIX} 不卸内核
 ${GREEN_FONT_PREFIX}0.${FONT_COLOR_SUFFIX} 升级脚本                 ${GREEN_FONT_PREFIX}88.${FONT_COLOR_SUFFIX} 卸载本脚本
 ———————————————————————————— 内核安装 —————————————————————————————
 ${GREEN_FONT_PREFIX}1.${FONT_COLOR_SUFFIX} 安装 BBR自编编译内核     ${GREEN_FONT_PREFIX}7.${FONT_COLOR_SUFFIX} 安装 官方稳定内核
 ${GREEN_FONT_PREFIX}2.${FONT_COLOR_SUFFIX} 安装 BBRplus版内核       ${GREEN_FONT_PREFIX}8.${FONT_COLOR_SUFFIX} 安装 官方最新内核
 ${GREEN_FONT_PREFIX}3.${FONT_COLOR_SUFFIX} 安装 Lotserver(锐速)内核 ${GREEN_FONT_PREFIX}9.${FONT_COLOR_SUFFIX} 安装 XANMOD(main)
 ${GREEN_FONT_PREFIX}4.${FONT_COLOR_SUFFIX} 安装 官方cloud内核       ${GREEN_FONT_PREFIX}10.${FONT_COLOR_SUFFIX} 安装 XANMOD(LTS)
 ${GREEN_FONT_PREFIX}5.${FONT_COLOR_SUFFIX} 安装 BBRplus新版内核     ${GREEN_FONT_PREFIX}11.${FONT_COLOR_SUFFIX} 安装 XANMOD(EDGE)
 ${GREEN_FONT_PREFIX}6.${FONT_COLOR_SUFFIX} 安装 Zen官方版内核       ${GREEN_FONT_PREFIX}12.${FONT_COLOR_SUFFIX} 安装 XANMOD(RT)
 ———————————————————————————— 加速启用 —————————————————————————————
 ${GREEN_FONT_PREFIX}20.${FONT_COLOR_SUFFIX} 使用BBR+FQ加速          ${GREEN_FONT_PREFIX}21.${FONT_COLOR_SUFFIX} 使用BBR+FQ_PIE加速
 ${GREEN_FONT_PREFIX}22.${FONT_COLOR_SUFFIX} 使用BBR+CAKE加速        ${GREEN_FONT_PREFIX}23.${FONT_COLOR_SUFFIX} 使用BBRplus+FQ版加速
 ${GREEN_FONT_PREFIX}24.${FONT_COLOR_SUFFIX} 使用Lotserver(锐速)加速 ${GREEN_FONT_PREFIX}25.${FONT_COLOR_SUFFIX} 编译安装brutal模块
 ${GREEN_FONT_PREFIX}26.${FONT_COLOR_SUFFIX} 编译安装LotSpeed模块    ${GREEN_FONT_PREFIX}27.${FONT_COLOR_SUFFIX} 使用LotSpeed加速
 ———————————————————————————— 系统配置 —————————————————————————————
 ${GREEN_FONT_PREFIX}30.${FONT_COLOR_SUFFIX} 开启ECN                 ${GREEN_FONT_PREFIX}31.${FONT_COLOR_SUFFIX} 关闭ECN
 ${GREEN_FONT_PREFIX}32.${FONT_COLOR_SUFFIX} 系统网络自适应优化      ${GREEN_FONT_PREFIX}33.${FONT_COLOR_SUFFIX} 防CC/DDOS轻量优化
 ${GREEN_FONT_PREFIX}35.${FONT_COLOR_SUFFIX} 禁用IPv6                ${GREEN_FONT_PREFIX}36.${FONT_COLOR_SUFFIX} 开启IPv6
 ${GREEN_FONT_PREFIX}37.${FONT_COLOR_SUFFIX} 手动提交合并内核参数    ${GREEN_FONT_PREFIX}38.${FONT_COLOR_SUFFIX} 手动编辑内核参数
 ${GREEN_FONT_PREFIX}39.${FONT_COLOR_SUFFIX} 修复IPv6 RA/SLAAC（保留转发）
 ———————————————————————————— 内核管理 —————————————————————————————
 ${GREEN_FONT_PREFIX}51.${FONT_COLOR_SUFFIX} 查看排序内核            ${GREEN_FONT_PREFIX}52.${FONT_COLOR_SUFFIX} 删除保留指定内核
 ${GREEN_FONT_PREFIX}55.${FONT_COLOR_SUFFIX} 卸载全部加速            ${GREEN_FONT_PREFIX}99.${FONT_COLOR_SUFFIX} 退出脚本
 ———————————————————————————— 其它工具 —————————————————————————————
 ${GREEN_FONT_PREFIX}60.${FONT_COLOR_SUFFIX} 网络精调(tcpfit联动)    ${GREEN_FONT_PREFIX}90.${FONT_COLOR_SUFFIX} 国内加速与代理设置
 ${GREEN_FONT_PREFIX}92.${FONT_COLOR_SUFFIX} 一键DD重装系统
————————————————————————————————————————————————————————————————"
	check_status
	get_system_info
	echo -e " 信息： ${FONT_COLOR_SUFFIX}$opsy ${GREEN_FONT_PREFIX}$virtual${FONT_COLOR_SUFFIX} $arch ${GREEN_FONT_PREFIX}$kern${FONT_COLOR_SUFFIX} "
	if [[ ${kernel_status} == "noinstall" ]]; then
		echo -e " 状态: ${GREEN_FONT_PREFIX}未安装${FONT_COLOR_SUFFIX} 加速内核 ${RED_FONT_PREFIX}请先安装内核${FONT_COLOR_SUFFIX}"
	else
		echo -e " 状态: ${GREEN_FONT_PREFIX}已安装${FONT_COLOR_SUFFIX} ${RED_FONT_PREFIX}${kernel_status}${FONT_COLOR_SUFFIX} 加速内核 , ${GREEN_FONT_PREFIX}${run_status}${FONT_COLOR_SUFFIX} ${RED_FONT_PREFIX}${brutal}${FONT_COLOR_SUFFIX} ${RED_FONT_PREFIX}${lotspeed_status}${FONT_COLOR_SUFFIX}"
	fi
	echo -e " 拥塞控制算法: ${GREEN_FONT_PREFIX}${net_congestion_control}${FONT_COLOR_SUFFIX} 队列算法: ${GREEN_FONT_PREFIX}${net_qdisc}${FONT_COLOR_SUFFIX} Headers状态：${GREEN_FONT_PREFIX}${headers_status}${FONT_COLOR_SUFFIX}"
	if should_use_cn_accel; then
		echo -e " 加速通道: ${GREEN_FONT_PREFIX}[国内加速已启用]${FONT_COLOR_SUFFIX} 文件:${CYAN_FONT_PREFIX}${GH_PROXY:-${BEST_MIRROR:-轮询}}${FONT_COLOR_SUFFIX} API:${CYAN_FONT_PREFIX}${GH_API_PROXY:-${BEST_API_MIRROR:-轮询}}${FONT_COLOR_SUFFIX}${TCPX_HTTP_PROXY:+ 代理:${TCPX_HTTP_PROXY}}"
	else
		echo -e " 加速通道: ${YELLOW_FONT_PREFIX}[海外直连模式]${FONT_COLOR_SUFFIX} (输入 [90] 可强制开启国内镜像或配置反代)"
	fi
	if tcpfit_present; then
		echo -e " ${YELLOW_FONT_PREFIX}检测到 tcpfit 正在管理网络参数${FONT_COLOR_SUFFIX}: 菜单 [60] 可调起 tcpfit，[32] 会让路，切算法自动抢优先级"
	fi
}

start_menu() {
	while true; do
		show_menu_panel

		if ! read -rp " 请输入数字 :" num; then
			echo ""
			echo -e "${INFO} 已退出。"
			exit 0
		fi

		case "$num" in
		0) Update_Shell ;;
		88) uninstall_tcpx ;;
		1) installbbr ;;
		2) installbbrplus ;;
		3) installlot ;;
		4) installcloud ;;
		5) installbbrplusnew ;;
		6) check_sys_official_zen ;;
		7) check_sys_official ;;
		8) check_sys_official_bbr ;;
		9) check_sys_official_xanmod_main ;;
		10) check_sys_official_xanmod_lts ;;
		11) check_sys_official_xanmod_edge ;;
		12) check_sys_official_xanmod_rt ;;
		20) enable_acceleration "fq" "bbr" ;;
		21) enable_acceleration "fq_pie" "bbr" ;;
		22) enable_acceleration "cake" "bbr" ;;
		23) enable_acceleration "fq" "bbrplus" ;;
		24) startlotserver ;;
		25) startbrutal ;;
		26) install_lotspeed ;;
		27) enable_lotspeed_standalone ;;
		30) set_ecn "1" ;;
		31) set_ecn "0" ;;
		32) optimizing_system ;;
		33) optimizing_ddcc ;;
		35) closeipv6 ;;
		36) openipv6 ;;
		37) update_sysctl_interactive ;;
		38) edit_sysctl_interactive ;;
		39) repair_ipv6_ra ;;
		51) show_kernels ;;
		52) delete_kernel_custom ;;
		55) remove_all ;;
		60) run_tcpfit_tune ;;
		90) configure_cn_accel_menu ;;
		92) gotodd ;;
		99)
			echo -e "${INFO} 已退出。"
			exit 0
			;;
		*)
			echo -e "${ERROR}: 请输入正确数字"
			;;
		esac

		echo ""
		read -rp "按回车键返回主菜单..." _ || exit 0
	done
}

update_sysctl_interactive() {
	local LC_ALL=C
	export LC_ALL

	local CONF_FILE="/etc/sysctl.d/99-sysctl.conf"
	local TMP_FILE
	local BACKUP_FILE
	local ignore_apply_error=true

	log_info() { echo "[INFO] $1"; }
	log_error() { echo "[ERROR] $1" >&2; }
	log_warn() { echo "[WARN] $1" >&2; }

	trap 'unset -f log_info log_error log_warn 2>/dev/null' RETURN

	if [[ $EUID -ne 0 ]]; then
		log_error "此函数必须以 root 权限运行，请使用 sudo。"
		return 1
	fi

	log_info "请输入或粘贴您要设置的 sysctl 参数 (格式: key = value)。"
	log_info "可参考TCP迷之调参，https://omnitt.com/"
	log_info "注释行(以 # 或 ; 开头)和空行将被忽略。"
	log_info "最后一行请以空行结束 可手动回车加一行空行"
	log_info "输入完成后，请按 Ctrl+D 结束输入。"

	readarray -t user_input

	if [ ${#user_input[@]} -eq 0 ]; then
		log_info "没有接收到任何输入，操作已取消。"
		return 0
	fi

	touch "$CONF_FILE"

	TMP_FILE=$(mktemp) || {
		log_error "无法创建临时文件"
		return 1
	}
	trap 'rm -f "$TMP_FILE"; unset -f log_info log_error log_warn 2>/dev/null' RETURN

	cp "$CONF_FILE" "$TMP_FILE"

	local -A params_to_add
	local all_params_valid=true

	log_info "正在校验所有输入参数..."
	for line in "${user_input[@]}"; do
		trimmed_line=$(echo "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

		if [[ -z "$trimmed_line" ]] || [[ "$trimmed_line" =~ ^[[:space:]]*[#\;] ]]; then
			continue
		fi

		if ! [[ "$trimmed_line" =~ ^[[:space:]]*([a-zA-Z0-9._-]+)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]]; then
			log_error "格式无效: '$trimmed_line'. 期望格式为 'key = value'."
			all_params_valid=false
			continue
		fi

		local key="${BASH_REMATCH[1]}"
		local value="${BASH_REMATCH[2]}"

		if ! sysctl -N "$key" >/dev/null 2>&1; then
			log_error "参数键名无效: '$key' 不是一个有效的内核参数。"
			all_params_valid=false
			continue
		fi

		local formatted_param="$key = $value"

		if grep -q -E "^[[:space:]]*${key//./\\.}([[:space:]]*)=.*" "$TMP_FILE"; then
			sed -i -E "s|^[[:space:]]*${key//./\\.}([[:space:]]*)=.*|$formatted_param|" "$TMP_FILE"
			log_info "已更新参数: $formatted_param"
		else
			if [[ -z "${params_to_add[$key]}" ]]; then
				params_to_add["$key"]="$formatted_param"
			fi
		fi
	done

	if ! $all_params_valid; then
		log_error "检测到无效参数，操作已中止。配置文件未做任何更改。"
		return 1
	fi

	if [ ${#params_to_add[@]} -gt 0 ]; then
		log_info "正在添加新参数..."
		echo "" >>"$TMP_FILE"
		for key in "${!params_to_add[@]}"; do
			echo "${params_to_add[$key]}" >>"$TMP_FILE"
			log_info "已添加新参数: ${params_to_add[$key]}"
		done
	fi

	BACKUP_FILE="${CONF_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
	cp "$CONF_FILE" "$BACKUP_FILE"
	log_info "原始文件已备份到 $BACKUP_FILE"

	mv "$TMP_FILE" "$CONF_FILE"
	chown root:root "$CONF_FILE"
	chmod 644 "$CONF_FILE"
	trap 'unset -f log_info log_error log_warn 2>/dev/null' RETURN

	log_info "正在应用新的 sysctl 设置..."
	if apply_output=$(apply_sysctl 2>&1); then
		log_info "Sysctl 设置已成功应用。"
		echo "--- 应用输出 ---"
		echo "$apply_output"
		echo "------------------"
		rm -f "$BACKUP_FILE"
	else
		if [[ "$ignore_apply_error" == "true" ]]; then
			log_warn "应用 sysctl 设置失败，但根据指令已忽略错误。"
			log_warn "配置文件 '${CONF_FILE}' 已被更新，但部分设置可能未生效。"
			log_warn "--- 错误详情 ---"
			echo "$apply_output" >&2
			echo "------------------"
			rm -f "$BACKUP_FILE"
			return 0
		else
			log_error "应用 sysctl 设置失败！正在回滚..."
			log_error "--- 错误详情 ---"
			echo "$apply_output"
			echo "------------------"

			mv "$BACKUP_FILE" "$CONF_FILE"
			log_info "正在恢复到之前的设置..."
			apply_sysctl >/dev/null

			log_error "回滚完成。配置文件已恢复，问题备份文件保留在 $BACKUP_FILE"
			return 1
		fi
	fi

	return 0
}

edit_sysctl_interactive() {
	local target_file="/etc/sysctl.d/99-sysctl.conf"
	local editor_cmd=""

	if [[ ! -f "$target_file" ]]; then
		echo -e "${TIP} 文件 $target_file 不存在。"
		read -r -p "是否立即创建并编辑？ (Y/n): " create_choice
		case "$create_choice" in
		[nN])
			echo -e "${INFO} 操作已取消。"
			return 0
			;;
		*) ;;
		esac
	fi

	if [[ -n "${VISUAL:-}" ]] && command -v "$VISUAL" >/dev/null 2>&1; then
		editor_cmd="$VISUAL"
	elif [[ -n "${EDITOR:-}" ]] && command -v "$EDITOR" >/dev/null 2>&1; then
		editor_cmd="$EDITOR"
	elif command -v nano >/dev/null 2>&1; then
		editor_cmd="nano"
	elif command -v vi >/dev/null 2>&1; then
		editor_cmd="vi"
		echo -e "${TIP} 将使用 vi 编辑器。按 'i' 进入插入模式，'Esc' 退出插入模式，':wq' 保存，':q!' 放弃。"
	else
		echo -e "${ERROR} 未找到可用文本编辑器 (nano / vi)，请先安装:"
		if [[ "${OS_TYPE}" == "CentOS" ]]; then
			echo -e "  yum install -y nano"
		else
			echo -e "  apt-get install -y nano"
		fi
		return 1
	fi

	echo -e "${INFO} 使用 [${editor_cmd}] 打开 ${target_file}..."
	if ! "$editor_cmd" "$target_file"; then
		echo -e "${ERROR} 编辑器启动失败或异常退出。"
		return 1
	fi

	echo ""
	echo -e "${INFO} 正在应用新配置..."
	apply_sysctl >/dev/null || return 1
	echo -e "${INFO} 内核参数已重载。部分参数需重启后才能生效。"
}

# =================================================
#  官方源内核安装模块 (含国内 ELRepo / Debian Backports 镜像加速)
# =================================================

check_sys_official() {
	pre_install_check || return 1
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		[[ "${OS_ARCH}" != "x86_64" ]] && {
			echo -e "${ERROR} 不支持x86_64以外的系统 !"
			return 1
		}
		if [[ "${OS_VERSION_ID}" == "7" ]]; then
			yum install kernel kernel-headers -y --skip-broken
		elif [[ "${OS_VERSION_ID}" == "8" || "${OS_VERSION_ID}" == "9" || "${OS_VERSION_ID}" == "10" ]]; then
			yum install kernel kernel-core kernel-headers -y --skip-broken
		else
			echo -e "${ERROR} 不支持当前系统 CentOS ${OS_VERSION_ID} !" && return 1
		fi
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		apt update
		if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "pop" || "${OS_ID_LIKE}" == *"ubuntu"* ]]; then
			apt-get install linux-image-generic linux-headers-generic -y
		else
			if [[ "${OS_ARCH}" == "x86_64" ]]; then
				apt-get install linux-image-amd64 linux-headers-amd64 -y
			elif [[ "${OS_ARCH}" == "aarch64" ]]; then
				apt-get install linux-image-arm64 linux-headers-arm64 -y
			fi
		fi
	fi
	BBR_grub
	echo -e "${TIP} 内核安装完毕。"
}

# 检查官方最新内核并安装 (国内自动切换清华 TUNA ELRepo 镜像 / Debian 国内 Backports 镜像)
check_sys_official_bbr() {
	pre_install_check || return 1
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		[[ "${OS_ARCH}" != "x86_64" ]] && {
			echo -e "${ERROR} 不支持x86_64以外的系统 !"
			return 1
		}
		if [[ "${OS_VERSION_ID}" =~ ^(7|8|9|10)$ ]]; then
			local el_ver="${OS_VERSION_ID}"
			if should_use_cn_accel && curl -fsSI -m 3 "https://mirrors.tuna.tsinghua.edu.cn/elrepo/elrepo/el${el_ver}/x86_64/repodata/repomd.xml" >/dev/null 2>&1; then
				echo -e "${INFO} 国内加速模式：使用清华 TUNA ELRepo 镜像源安装 kernel-ml..."
				rpm --import https://mirrors.tuna.tsinghua.edu.cn/elrepo/RPM-GPG-KEY-elrepo.org 2>/dev/null ||
					rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
				yum install "https://mirrors.tuna.tsinghua.edu.cn/elrepo/elrepo/el${el_ver}/x86_64/RPMS/elrepo-release-${el_ver}.el${el_ver}.elrepo.noarch.rpm" -y 2>/dev/null ||
					yum install "https://www.elrepo.org/elrepo-release-${el_ver}.el${el_ver}.elrepo.noarch.rpm" -y
				if [[ -f /etc/yum.repos.d/elrepo.repo ]]; then
					cp -n /etc/yum.repos.d/elrepo.repo /etc/yum.repos.d/elrepo.repo.bak 2>/dev/null
					sed -i -e 's|^mirrorlist=|#mirrorlist=|g' \
						-e 's|^#baseurl=http://elrepo.org/linux|baseurl=https://mirrors.tuna.tsinghua.edu.cn/elrepo|g' \
						-e 's|^baseurl=http://elrepo.org/linux|baseurl=https://mirrors.tuna.tsinghua.edu.cn/elrepo|g' \
						/etc/yum.repos.d/elrepo.repo
				fi
			else
				rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
				yum install "https://www.elrepo.org/elrepo-release-${el_ver}.el${el_ver}.elrepo.noarch.rpm" -y
			fi
			yum --enablerepo=elrepo-kernel install kernel-ml kernel-ml-headers -y --skip-broken
		else
			echo -e "${ERROR} 不支持当前系统 CentOS ${OS_VERSION_ID} !" && return 1
		fi
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		apt update
		if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "pop" || "${OS_ID_LIKE}" == *"ubuntu"* ]]; then
			echo -e "${INFO} 正在为 Ubuntu/衍生系 获取官方最新 HWE 内核..."
			if apt-cache show linux-generic-hwe-${OS_VERSION_ID} >/dev/null 2>&1; then
				apt-get install --install-recommends linux-generic-hwe-${OS_VERSION_ID} -y
			else
				echo -e "${TIP} 当前版本 (${OS_VERSION_ID}) 无专属 HWE 包，将自动为您更新至常规最新 generic 内核..."
				apt-get install linux-image-generic linux-headers-generic -y
			fi
		else
			local apt_args=""
			if [[ "${OS_ID}" == "debian" ]]; then
				local codename=$(awk -F= '/^VERSION_CODENAME/{print $2}' /etc/os-release | tr -d '"')
				[[ -z "$codename" ]] && codename=$(awk -F= '/^VERSION=/{print $2}' /etc/os-release | grep -oE '\([a-z]+\)' | tr -d '()')

				[[ -z "$codename" ]] && {
					echo -e "${ERROR} 无法获取 Debian 代号"
					return 1
				}
				local deb_base
				deb_base=$(active_debian_mirror_base)
				echo "deb ${deb_base} ${codename}-backports main" >/etc/apt/sources.list.d/${codename}-backports.list
				apt update
				apt_args="-t ${codename}-backports"
			else
				echo -e "${TIP} 检测到 ${OS_ID} (非原生 Debian)，跳过添加 Backports 源，直接从默认源安装最新内核..."
			fi

			if [[ "${OS_ARCH}" == "x86_64" ]]; then
				apt $apt_args install linux-image-amd64 linux-headers-amd64 -y
			elif [[ "${OS_ARCH}" =~ ^(arm|aarch64)$ ]]; then
				apt $apt_args install linux-image-arm64 linux-headers-arm64 -y
			fi
		fi
	fi
	BBR_grub
	echo -e "${TIP} 内核安装完毕。"
}

install_xanmod_generic() {
	local edition="$1"
	pre_install_check || return 1
	[[ "${OS_ARCH}" != "x86_64" ]] && {
		echo -e "${ERROR} Xanmod 仅支持 x86_64 !"
		return 1
	}
	[[ "${OS_TYPE}" != "Debian" ]] && {
		echo -e "${ERROR} 当前一键 Xanmod 仅支持 Debian/Ubuntu !"
		return 1
	}

	apt update
	apt-get install gnupg gnupg2 gnupg1 wget ca-certificates -y

	rm -f /etc/apt/sources.list.d/xanmod-kernel.list
	rm -f /etc/apt/sources.list.d/xanmod-release.list
	rm -f /etc/apt/sources.list.d/xanmod-kernel.sources
	sed -i '/deb.xanmod.org/d' /etc/apt/sources.list 2>/dev/null

	if ! curl -fsSL --connect-timeout 10 https://dl.xanmod.org/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/xanmod-archive-keyring.gpg; then
		echo -e "${ERROR} XanMod GPG 密钥获取失败 (dl.xanmod.org 在部分国内网络需在菜单 [90] 配置 HTTP 代理)。"
		return 1
	fi
	echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-kernel.list

	local xanmod_work
	xanmod_work=$(mktemp -d /tmp/xanmod_install.XXXXXX) || {
		echo -e "${ERROR} 无法创建临时目录！"
		return 1
	}
	trap 'cd /tmp; rm -rf "$xanmod_work"; trap - RETURN' RETURN
	cd "$xanmod_work" || {
		echo -e "${ERROR} 无法进入临时目录！"
		return 1
	}

	local cpu_level="1"
	if wget -qO check_x86-64_psabi.sh https://dl.xanmod.org/check_x86-64_psabi.sh 2>/dev/null &&
		[[ -s check_x86-64_psabi.sh ]]; then
		chmod +x check_x86-64_psabi.sh
		cpu_level=$(./check_x86-64_psabi.sh 2>/dev/null |
			grep -oE '\bv[1-4]\b' | tail -n 1 | tr -d 'v')
		[[ -z "$cpu_level" ]] && cpu_level="1"
	else
		echo -e "${TIP} CPU 等级检测脚本下载失败，将使用 v1 (最兼容) 版本。"
	fi
	echo -e "${INFO} CPU 支持等级: \033[32mv${cpu_level}\033[0m"

	apt update
	local pkg_name="linux-xanmod"
	[[ "$edition" != "main" ]] && pkg_name="linux-xanmod-${edition}"

	if [[ "$cpu_level" -ge 3 ]]; then
		apt install "${pkg_name}-x64v3" -y
	elif [[ "$cpu_level" -ge 2 ]]; then
		apt install "${pkg_name}-x64v2" -y
	else
		apt install "${pkg_name}-x64v1" -y
	fi

	BBR_grub
	echo -e "${TIP} 内核安装完毕。"
}

check_sys_official_xanmod_main() { install_xanmod_generic "main"; }
check_sys_official_xanmod_lts() { install_xanmod_generic "lts"; }
check_sys_official_xanmod_edge() { install_xanmod_generic "edge"; }
check_sys_official_xanmod_rt() { install_xanmod_generic "rt"; }

check_sys_official_zen() {
	pre_install_check || return 1
	[[ "${OS_ARCH}" != "x86_64" ]] && {
		echo -e "${ERROR} Zen内核仅支持x86_64 !"
		return 1
	}
	if [[ "${OS_ID}" == "debian" || "${OS_ID}" == "kali" || "${OS_ID_LIKE}" == *"debian"* ]] && [[ "${OS_ID_LIKE}" != *"ubuntu"* && "${OS_ID}" != "ubuntu" && "${OS_ID}" != "pop" ]]; then
		local tmp_lqx
		tmp_lqx=$(mktemp /tmp/liquorix.XXXXXX) || return 1
		if ! fetch_remote_script "https://liquorix.net/add-liquorix-repo.sh" "$tmp_lqx"; then
			rm -f "$tmp_lqx"
			echo -e "${ERROR} Liquorix 源脚本下载失败！"
			return 1
		fi
		run_with_github_accel bash "$tmp_lqx"
		rm -f "$tmp_lqx"
		apt-get install linux-image-liquorix-amd64 linux-headers-liquorix-amd64 -y
	elif [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "pop" || "${OS_ID_LIKE}" == *"ubuntu"* ]]; then
		apt-get install software-properties-common -y
		add-apt-repository ppa:damentz/liquorix -y
		# 国内 Ubuntu 自动替换 Launchpad PPA 为中科大反向代理加速源
		if should_use_cn_accel; then
			sed -i 's|https\?://ppa\.launchpadcontent\.net|https://launchpad.proxy.ustclug.org|g; s|https\?://ppa\.launchpad\.net|https://launchpad.proxy.ustclug.org|g' \
				/etc/apt/sources.list.d/*liquorix* 2>/dev/null || true
		fi
		apt-get update
		apt-get install linux-image-liquorix-amd64 linux-headers-liquorix-amd64 -y
	else
		echo -e "${ERROR} Zen内核当前脚本仅支持 Debian/Ubuntu 及衍生版 !" && return 1
	fi
	BBR_grub
	echo -e "${TIP} 内核安装完毕。"
}

check_status() {
	kernel_version=$(uname -r | awk -F "-" '{print $1}')
	kernel_version_full=$(uname -r)
	net_congestion_control=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "unknown")
	net_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "unknown")

	if [[ "$kernel_version_full" == *bbrplus* ]]; then
		kernel_status="BBRplus"
	elif [[ "$kernel_version_full" =~ (4\.9\.0-4|4\.15\.0-30|4\.8\.0-36|3\.16\.0-77|3\.16\.0-4|3\.2\.0-4|4\.11\.2-1|2\.6\.32-504|4\.4\.0-47|3\.13\.0-29) ]]; then
		kernel_status="Lotserver"
	elif read major minor <<<$(echo "$kernel_version" | awk -F'.' '{print $1, $2}') &&
		{ [[ "$major" == "4" && "$minor" -ge 9 ]] || [[ "$major" -ge 5 ]]; }; then
		kernel_status="BBR"
	else
		kernel_status="noinstall"
	fi

	if [[ "$kernel_status" == "BBR" ]]; then
		case "$net_congestion_control" in
		"bbr") run_status="BBR启动成功" ;;
		"bbr2") run_status="BBR2启动成功" ;;
		"tsunami")
			if lsmod | grep -q "^tcp_tsunami"; then
				run_status="BBR魔改版启动成功"
			else
				run_status="BBR魔改版启动失败"
			fi
			;;
		"nanqinlang")
			if lsmod | grep -q "^tcp_nanqinlang"; then
				run_status="暴力BBR魔改版启动成功"
			else
				run_status="暴力BBR魔改版启动失败"
			fi
			;;
		*) run_status="未安装加速模块" ;;
		esac
	elif [[ "$kernel_status" == "Lotserver" ]]; then
		if is_trusted_root_file /appex/bin/lotServer.sh; then
			run_status=$(bash /appex/bin/lotServer.sh status | grep "LotServer" | awk '{print $3}')
			[[ "$run_status" == "running!" ]] && run_status="启动成功" || run_status="启动失败"
		else
			run_status="未安装加速模块"
		fi
	elif [[ "$kernel_status" == "BBRplus" ]]; then
		case "$net_congestion_control" in
		"bbrplus") run_status="BBRplus启动成功" ;;
		"bbr") run_status="BBR启动成功" ;;
		*) run_status="未安装加速模块" ;;
		esac
	else
		run_status="未安装加速模块"
	fi

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		installed_headers=$(rpm -qa | grep -E "kernel(-ml|-lt|-uek|-rt|-plus)?-(devel|headers)" | grep -v '^$' || echo "")
		if [[ -z "$installed_headers" ]]; then
			headers_status="未安装"
		else
			if echo "$installed_headers" | grep -qF -e "-devel-${kernel_version_full}" -e "-headers-${kernel_version_full}"; then
				headers_status="已匹配"
			else
				headers_status="未匹配"
			fi
		fi
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		installed_headers=$(dpkg -l | grep -E "(linux|proxmox|pve|raspberrypi)-(headers|image)" | awk '{print $2}' | grep -v '^$' || echo "")
		if [[ -z "$installed_headers" ]]; then
			headers_status="未安装"
		else
			if echo "$installed_headers" | grep -qF -- "-headers-${kernel_version_full}"; then
				headers_status="已匹配"
			else
				headers_status="未匹配"
			fi
		fi
	else
		headers_status="不支持的操作系统"
	fi

	brutal=""
	if lsmod | grep -q "brutal"; then
		brutal="brutal已加载"
	fi

	lotspeed_status=""
	if lsmod | grep -q "lotspeed"; then
		if [[ "$net_congestion_control" == "lotspeed" ]]; then
			run_status="LotSpeed启动成功"
		else
			lotspeed_status="LotSpeed已加载(未设为默认)"
		fi
	fi
}

# =================================================
#  入口执行逻辑
# =================================================

# 1. 载入持久化国内加速/代理配置 (/etc/tcpx_mirror.conf)
load_mirror_conf

# 2. 系统检测与国内多通道镜像测速
check_sys
check_cn_status

# 3. 首次运行时自安装到 /usr/local/bin/tcpx (现已在 check_cn_status 之后，管道安装亦可走镜像加速)
install_self

# 4. 命令行静默调用参数解析
if [ $# -gt 0 ]; then
	case $1 in
	op0 | op1 | op2)
		optimizing_system
		exit
		;;
	op3)
		update_sysctl_interactive
		exit
		;;
	op4)
		edit_sysctl_interactive
		exit
		;;
	ipv6-ra)
		repair_ipv6_ra
		exit $?
		;;
	diag)
		run_cn_connectivity_diag
		exit $?
		;;
	*)
		echo -e "${ERROR} 未知选项: \"$1\""
		exit 1
		;;
	esac
fi

# 5. 常规交互式启动
start_menu
