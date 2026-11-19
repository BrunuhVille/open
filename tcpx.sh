#!/usr/bin/env bash

# 命令搜索路径必须是固定的 root 目录集合：不要追加 ~/bin，
# 因为 ~ 由调用方的 HOME 展开，sudo 保留 HOME 时本地用户可借此投毒 root 执行的命令。
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

# =================================================
#  全局配置区 (Configuration as Data)
# =================================================
readonly SH_VER="100.0.6.16"
readonly SH_CN_MOD="CN全链路加速版 v2.0"
readonly GITHUB_RAW_URL="https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master"
# 内核二进制 (bbr/bbrplus/lotserver) 已从仓库迁移到 Release，按目录整包托管，避免仓库臃肿。
readonly KERNEL_RELEASE_BASE="https://github.com/ylx2016/Linux-NetSpeed/releases/download/kernels"
readonly CLOUD_STATE_FILE="/etc/tcpx_cloud_lastver" # installcloud 记忆上次探测到的最高可安装 Cloud 内核
readonly ACCEL_CONF_FILE="/etc/tcpx_accel.conf"     # 加速镜像/代理持久化配置文件
# Cloud 内核 headers (arch/-common/kbuild) 所在 pool；国内环境会自动切换至清华/中科大/阿里云等国内镜像
CLOUD_HDR_POOL="https://deb.debian.org/debian/pool/main/l/linux/"

# 自安装：把脚本落地到 /usr/local/bin/tcpx，安装后可直接输入 tcpx 运行。
# 以 bash <(curl -fsSL <URL>) 这类管道方式运行时本地没有文件副本，只能从下面的地址重新下载。
# 默认走内置 GitHub 加速引擎拉取；也可用环境变量 TCPX_URL 覆盖为自建镜像地址：
#   TCPX_URL=<地址> bash <(curl -fsSL <地址>)
readonly TCPX_URL_DEFAULT="${GITHUB_RAW_URL}/tcpx.sh"
# 允许任意合法 HTTPS 地址（兼容自建反代/国内加速镜像）；下载后仍强制经 fetch_remote_script 校验。
resolve_self_url() {
	local url="${1:-}"
	if [[ -n "$url" && "$url" =~ ^https://[^[:space:]]+$ ]]; then
		printf '%s\n' "$url"
		return 0
	fi
	[[ -n "$url" ]] && echo -e "已忽略不受支持的 TCPX_URL (仅允许 https 地址)，改用默认地址。" >&2
	printf '%s\n' "$TCPX_URL_DEFAULT"
}
readonly TCPX_SELF_URL="$(resolve_self_url "${TCPX_URL:-}")"
readonly TCPX_INSTALL_PATH="/usr/local/bin/tcpx"

# 颜色变量定义
readonly GREEN_FONT_PREFIX="\033[32m"
readonly RED_FONT_PREFIX="\033[31m"
readonly YELLOW_FONT_PREFIX="\033[33m"
readonly FONT_COLOR_SUFFIX="\033[0m"
readonly INFO="${GREEN_FONT_PREFIX}[信息]${FONT_COLOR_SUFFIX}"
readonly ERROR="${RED_FONT_PREFIX}[错误]${FONT_COLOR_SUFFIX}"
readonly TIP="${YELLOW_FONT_PREFIX}[注意]${FONT_COLOR_SUFFIX}"

# 系统信息全局变量 (初始化)
OS_TYPE=""
OS_ID=""
OS_VERSION_ID=""
OS_ARCH=""

# 检查当前用户是否为 root
if [ "$EUID" -ne 0 ]; then
	echo -e "${ERROR} 请使用 root 用户身份运行此脚本"
	exit 1
fi

# =================================================
#  系统检测模块
# =================================================
check_sys() {
	# 1. 检测架构 (使用最通用的 uname)
	OS_ARCH=$(uname -m)

	# 2. 现代化系统信息获取
	if [[ -f /etc/os-release ]]; then
		# 直接 source 解析标准的 os-release 文件
		. /etc/os-release
		OS_ID="${ID:-unknown}"
		OS_VERSION_ID="${VERSION_ID:-}"
		OS_ID_LIKE="${ID_LIKE:-}" # 新增：获取上游衍生关系
		# 兼容 Debian testing/sid 没有 VERSION_ID 的情况
		if [[ -z "$OS_VERSION_ID" && "$OS_ID" == "debian" && -f /etc/debian_version ]]; then
			OS_VERSION_ID=$(grep -oE '^[0-9]+' /etc/debian_version | head -n 1)
			[[ -z "$OS_VERSION_ID" ]] && OS_VERSION_ID=$(awk -F'/' '{print $1}' /etc/debian_version)
		fi
		[[ -z "$OS_VERSION_ID" ]] && OS_VERSION_ID="unknown"
	elif [[ -f /etc/redhat-release || -f /etc/centos-release ]]; then
		# 兼容极少数没有 os-release 的老旧 CentOS
		OS_ID="centos"
		OS_VERSION_ID=$(grep -oE '[0-9.]+' /etc/redhat-release | awk -F'.' '{print $1}')
	else
		echo -e "${ERROR} 无法检测到受支持的系统版本。此脚本仅支持现代 Debian/Ubuntu/CentOS/Alma/Rocky 系统。"
		exit 1
	fi

	# 3. 规范化 OS_TYPE (引入 ID_LIKE 增强泛衍生版兼容性)
	if [[ "$OS_ID" =~ ^(centos|rhel|almalinux|rocky|oracle|fedora)$ ]] || [[ "$OS_ID_LIKE" =~ (rhel|centos|fedora) ]]; then
		OS_TYPE="CentOS"
		# 提取主版本号
		OS_VERSION_ID=$(echo "$OS_VERSION_ID" | awk -F'.' '{print $1}')
	elif [[ "$OS_ID" =~ ^(debian|ubuntu|pop|kali|linuxmint|deepin|elementary|zorin|armbian)$ ]] || [[ "$OS_ID_LIKE" =~ (debian|ubuntu) ]]; then
		OS_TYPE="Debian"
	else
		echo -e "${ERROR} 不支持的系统分支: ${OS_ID} (ID_LIKE: ${OS_ID_LIKE})"
		exit 1
	fi

	echo -e "${INFO} 检测到系统: ${OS_TYPE} (${OS_ID} ${OS_VERSION_ID}) - 架构: ${OS_ARCH}"

	# 4. 精简依赖检查 (不强制 jq/EPEL；有 jq 才启用发布摘要解析，无 jq 仅允许上游直连)
	local required_cmds=("curl" "wget" "awk")

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		for cmd in "${required_cmds[@]}"; do
			if ! command -v "$cmd" >/dev/null 2>&1; then
				echo -e "${INFO} 正在安装缺失依赖: $cmd ..."
				yum install -y "$cmd" >/dev/null 2>&1
			fi
		done
		# CA 证书更新
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
		# CA 证书更新
		if ! dpkg-query -W ca-certificates >/dev/null 2>&1; then
			[[ $need_update -eq 0 ]] && apt-get update >/dev/null 2>&1
			apt-get install ca-certificates -y >/dev/null 2>&1
			update-ca-certificates >/dev/null 2>&1
		fi
	fi

	# 4.1 依赖复检：上面所有安装命令的输出都被重定向丢弃了，装失败也毫无提示。
	# 若不在此处硬失败，后续联网抓取会因缺少 curl/wget 而静默失败，
	# 用户只能看到"无法获取资源列表"这种完全误导性的报错。
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

	# 5. 补充底层内核模块管理依赖 (应对极简版 LXC/VPS 模板)
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

# 检测是否运行在容器中。容器共用宿主机内核，装内核毫无意义且可能破坏容器。
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

	# 兜底: 部分老旧 OpenVZ/LXC 无 systemd-detect-virt，用特征文件识别
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

# 检查 /boot 剩余空间。小 /boot 在生成 initramfs 阶段中途失败会留下半配置状态，重启即失联。
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

# 内核安装统一前置检查
pre_install_check() {
	check_container || return 1
	check_boot_space 300 || return 1
	return 0
}

# =================================================
#  全链路加速、网络通信与下载模块 (CN 深度优化版)
# =================================================

# 全局变量：节点网络归属。
#   0 = 海外 (直连优先，若配置了自定义镜像则优先自定义)
#   1 = 中国大陆 (并行测速后，多类镜像全链路加速 + 直连兜底)
#   2 = 归属地无法判定 (默认按国内加速处理，末尾保留直连兜底)
IS_CN=0

# 各类资源当前最优镜像缓存
BEST_MIRROR=""
BEST_MIRROR_FULL_URL=1
BEST_API_MIRROR=""
BEST_API_MIRROR_FULL_URL=1
BEST_DEBIAN_MIRROR=""
BEST_ELREPO_MIRROR=""
_ACCEL_CONFIG_LOADED=0

# 记录每个镜像实测偏好的拼接方式: 1=前缀+完整URL(https://...), 0=前缀+去协议头
declare -A MIRROR_URL_MODE=()

# 记录调用方是否通过环境变量显式指定了开关型配置（用于覆盖配置文件）
_ENV_FORCE_CN_SET=0
[[ -n "${TCPX_FORCE_CN:-}" ]] && _ENV_FORCE_CN_SET=1
_ENV_STRICT_SET=0
[[ -n "${TCPX_STRICT_DIGEST:-}" ]] && _ENV_STRICT_SET=1

# 用户可配置加速参数（支持 /etc/tcpx_accel.conf 持久化及环境变量覆盖）
TCPX_FORCE_CN="${TCPX_FORCE_CN:-auto}"
TCPX_MIRROR="${TCPX_MIRROR:-${GH_PROXY:-}}"
TCPX_API_MIRROR="${TCPX_API_MIRROR:-}"
TCPX_RAW_MIRROR="${TCPX_RAW_MIRROR:-}"
TCPX_UNIVERSAL_PROXY="${TCPX_UNIVERSAL_PROXY:-}"
TCPX_HTTP_PROXY="${TCPX_HTTP_PROXY:-}"
TCPX_DEBIAN_MIRROR="${TCPX_DEBIAN_MIRROR:-}"
TCPX_ELREPO_MIRROR="${TCPX_ELREPO_MIRROR:-}"
TCPX_STRICT_DIGEST="${TCPX_STRICT_DIGEST:-0}"
TCPX_GITHUB_TOKEN="${TCPX_GITHUB_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
TCPX_UPDATE_URL="${TCPX_UPDATE_URL:-}"

# --- 实测验证的多类加速镜像池 ---
# 1) GitHub 文件/Raw/Release 加速池 (全部经过真实内容校验，兼顾 EdgeOne/CDN/IPv6/多线路)
GH_FILE_MIRRORS=(
	"https://edgeone.gh-proxy.org/"
	"https://cdn.gh-proxy.org/"
	"https://gh-proxy.com/"
	"https://gh-proxy.org/"
	"https://v6.gh-proxy.org/"
	"https://ghfast.top/"
	"https://ghproxy.net/"
	"https://githubproxy.cc/"
	"https://wget.la/"
	"https://gh.nxnow.top/"
	"https://fastgit.cc/"
)

# 2) GitHub REST API (api.github.com) 专用加速池 (仅保留实测可返回真实 JSON 的节点)
GH_API_MIRRORS=(
	"https://edgeone.gh-proxy.org/"
	"https://cdn.gh-proxy.org/"
	"https://gh-proxy.com/"
	"https://gh-proxy.org/"
	"https://v6.gh-proxy.org/"
	"https://wget.la/"
	"https://gh.nxnow.top/"
)

# 3) jsDelivr Raw CDN 二级兜底池 (仅用于 raw.githubusercontent.com / github.com/.../raw/ 文件)
JSDELIVR_MIRRORS=(
	"https://fastly.jsdelivr.net"
	"https://gcore.jsdelivr.net"
	"https://testingcf.jsdelivr.net"
)

# 4) 国内 Debian 官方镜像池 (用于 Cloud 内核池、Headers 池、Backports 源)
CN_DEBIAN_MIRRORS=(
	"https://mirrors.tuna.tsinghua.edu.cn/debian"
	"https://mirrors.ustc.edu.cn/debian"
	"https://mirrors.aliyun.com/debian"
	"https://mirrors.cloud.tencent.com/debian"
	"https://mirrors.huaweicloud.com/debian"
)

# 5) 国内 ELRepo 官方镜像池 (用于 CentOS/Alma/Rocky kernel-ml 内核)
CN_ELREPO_MIRRORS=(
	"https://mirrors.tuna.tsinghua.edu.cn/elrepo"
	"https://mirrors.aliyun.com/elrepo"
	"https://mirrors.ustc.edu.cn/elrepo"
)

# 归属地检测端点：优先国内可秒回的端点，避免在海外端点上白白挂满超时
CN_STATUS_ENDPOINTS=(
	"cn|https://myip.ipip.net"
	"cf|http://www.qualcomm.cn/cdn-cgi/trace"
	"cf|https://cloudflare.com/cdn-cgi/trace"
	"code|https://ipinfo.io/country"
)
CN_STATUS_TIMEOUT=2

# 规范化镜像前缀（确保非空时以 / 结尾）
normalize_mirror_prefix() {
	local p="${1:-}"
	p="${p#"${p%%[![:space:]]*}"}"
	p="${p%"${p##*[![:space:]]}"}"
	[[ -z "$p" ]] && return 0
	[[ "$p" != */ ]] && p="${p}/"
	printf '%s' "$p"
}

# 去除末尾斜杠（用于 Debian/ELRepo 基础 URL）
strip_trailing_slash() {
	local u="${1:-}"
	u="${u#"${u%%[![:space:]]*}"}"
	u="${u%"${u##*[![:space:]]}"}"
	while [[ "$u" == */ ]]; do
		u="${u%/}"
	done
	printf '%s' "$u"
}

# 安全读取持久化加速配置（仅启动时加载一次；不 source 任意代码；调用方环境变量优先级更高）
load_accel_config() {
	if [[ "${_ACCEL_CONFIG_LOADED:-0}" == "1" ]]; then
		apply_http_proxy_env
		return 0
	fi
	_ACCEL_CONFIG_LOADED=1

	local env_mirror="${TCPX_MIRROR:-}"
	local env_api_mirror="${TCPX_API_MIRROR:-}"
	local env_raw_mirror="${TCPX_RAW_MIRROR:-}"
	local env_uproxy="${TCPX_UNIVERSAL_PROXY:-}"
	local env_hproxy="${TCPX_HTTP_PROXY:-}"
	local env_deb_mirror="${TCPX_DEBIAN_MIRROR:-}"
	local env_elrepo_mirror="${TCPX_ELREPO_MIRROR:-}"
	local env_token="${TCPX_GITHUB_TOKEN:-}"
	local env_update_url="${TCPX_UPDATE_URL:-}"

	if [[ -f "$ACCEL_CONF_FILE" && ! -L "$ACCEL_CONF_FILE" ]]; then
		local owner
		owner=$(stat -c '%u' "$ACCEL_CONF_FILE" 2>/dev/null || echo "")
		if [[ "$owner" == "0" ]]; then
			local line key val
			while IFS= read -r line || [[ -n "$line" ]]; do
				line="${line//$'\r'/}"
				[[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
				[[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]] || continue
				key="${BASH_REMATCH[1]}"
				val="${BASH_REMATCH[2]}"
				if [[ "$val" =~ ^\"(.*)\"$ ]]; then
					val="${BASH_REMATCH[1]}"
				elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
					val="${BASH_REMATCH[1]}"
				fi
				case "$key" in
				TCPX_FORCE_CN) [[ $_ENV_FORCE_CN_SET -eq 0 ]] && TCPX_FORCE_CN="$val" ;;
				TCPX_MIRROR) [[ -z "$env_mirror" ]] && TCPX_MIRROR="$val" ;;
				TCPX_API_MIRROR) [[ -z "$env_api_mirror" ]] && TCPX_API_MIRROR="$val" ;;
				TCPX_RAW_MIRROR) [[ -z "$env_raw_mirror" ]] && TCPX_RAW_MIRROR="$val" ;;
				TCPX_UNIVERSAL_PROXY) [[ -z "$env_uproxy" ]] && TCPX_UNIVERSAL_PROXY="$val" ;;
				TCPX_HTTP_PROXY) [[ -z "$env_hproxy" ]] && TCPX_HTTP_PROXY="$val" ;;
				TCPX_DEBIAN_MIRROR) [[ -z "$env_deb_mirror" ]] && TCPX_DEBIAN_MIRROR="$val" ;;
				TCPX_ELREPO_MIRROR) [[ -z "$env_elrepo_mirror" ]] && TCPX_ELREPO_MIRROR="$val" ;;
				TCPX_STRICT_DIGEST) [[ $_ENV_STRICT_SET -eq 0 ]] && TCPX_STRICT_DIGEST="$val" ;;
				TCPX_GITHUB_TOKEN) [[ -z "$env_token" ]] && TCPX_GITHUB_TOKEN="$val" ;;
				TCPX_UPDATE_URL) [[ -z "$env_update_url" ]] && TCPX_UPDATE_URL="$val" ;;
				esac
			done <"$ACCEL_CONF_FILE"
		fi
	fi

	# 规范化 URL 格式
	TCPX_MIRROR=$(normalize_mirror_prefix "$TCPX_MIRROR")
	TCPX_API_MIRROR=$(normalize_mirror_prefix "$TCPX_API_MIRROR")
	TCPX_RAW_MIRROR=$(normalize_mirror_prefix "$TCPX_RAW_MIRROR")
	TCPX_UNIVERSAL_PROXY=$(normalize_mirror_prefix "$TCPX_UNIVERSAL_PROXY")
	TCPX_DEBIAN_MIRROR=$(strip_trailing_slash "$TCPX_DEBIAN_MIRROR")
	TCPX_ELREPO_MIRROR=$(strip_trailing_slash "$TCPX_ELREPO_MIRROR")

	apply_http_proxy_env
}

# 将加速配置持久化写入 /etc/tcpx_accel.conf (权限 600，保护可选 Token)
save_accel_config() {
	local tmp_cfg
	tmp_cfg=$(mktemp /tmp/tcpx_accel_cfg.XXXXXX) || return 1
	chmod 600 "$tmp_cfg"
	{
		echo "# tcpx.sh 全链路加速配置文件 (由菜单 [70] 管理)"
		printf 'TCPX_FORCE_CN="%s"\n' "${TCPX_FORCE_CN//\"/}"
		printf 'TCPX_MIRROR="%s"\n' "${TCPX_MIRROR//\"/}"
		printf 'TCPX_API_MIRROR="%s"\n' "${TCPX_API_MIRROR//\"/}"
		printf 'TCPX_RAW_MIRROR="%s"\n' "${TCPX_RAW_MIRROR//\"/}"
		printf 'TCPX_UNIVERSAL_PROXY="%s"\n' "${TCPX_UNIVERSAL_PROXY//\"/}"
		printf 'TCPX_HTTP_PROXY="%s"\n' "${TCPX_HTTP_PROXY//\"/}"
		printf 'TCPX_DEBIAN_MIRROR="%s"\n' "${TCPX_DEBIAN_MIRROR//\"/}"
		printf 'TCPX_ELREPO_MIRROR="%s"\n' "${TCPX_ELREPO_MIRROR//\"/}"
		printf 'TCPX_STRICT_DIGEST="%s"\n' "${TCPX_STRICT_DIGEST//\"/}"
		printf 'TCPX_GITHUB_TOKEN="%s"\n' "${TCPX_GITHUB_TOKEN//\"/}"
		printf 'TCPX_UPDATE_URL="%s"\n' "${TCPX_UPDATE_URL//\"/}"
	} >"$tmp_cfg"
	mv -f "$tmp_cfg" "$ACCEL_CONF_FILE"
	chmod 600 "$ACCEL_CONF_FILE"
}

# 将 TCPX_HTTP_PROXY 应用到当前会话的代理环境变量 (curl / wget / yum / apt 均受益)
apply_http_proxy_env() {
	if [[ -n "${TCPX_HTTP_PROXY:-}" ]]; then
		export http_proxy="$TCPX_HTTP_PROXY"
		export https_proxy="$TCPX_HTTP_PROXY"
		export HTTP_PROXY="$TCPX_HTTP_PROXY"
		export HTTPS_PROXY="$TCPX_HTTP_PROXY"
		export all_proxy="$TCPX_HTTP_PROXY"
		export ALL_PROXY="$TCPX_HTTP_PROXY"
	fi
}

# 生成 apt 代理参数（当用户配置了 TCPX_HTTP_PROXY 时透传给 apt/apt-get）
apt_proxy_opts() {
	if [[ -n "${TCPX_HTTP_PROXY:-}" ]]; then
		printf '%s\n' "-o" "Acquire::http::Proxy=${TCPX_HTTP_PROXY}" "-o" "Acquire::https::Proxy=${TCPX_HTTP_PROXY}"
	fi
}

# 覆盖全部 GitHub 相关域名 (含 api / raw / releases / objects / release-assets / codeload / gist)
is_github_url() {
	local url="$1"
	[[ "$url" =~ ^https?://(www\.)?(github\.com|raw\.githubusercontent\.com|api\.github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com|github-releases\.githubusercontent\.com|codeload\.github\.com|gist\.githubusercontent\.com|gist\.github\.com)/ ]]
}

is_github_api_url() {
	local url="$1"
	[[ "$url" =~ ^https?://api\.github\.com/ ]]
}

is_github_raw_url() {
	local url="$1"
	[[ "$url" =~ ^https?://raw\.githubusercontent\.com/ ]] || [[ "$url" =~ ^https?://(www\.)?github\.com/[^/]+/[^/]+/raw/ ]]
}

# 识别已是国内高速镜像的地址（避免套一层海外通用反代反而变慢）
is_cn_domestic_mirror_url() {
	local url="$1"
	[[ "$url" =~ ^https?://(mirrors\.(tuna\.tsinghua\.edu\.cn|ustc\.edu\.cn|aliyun\.com|cloud\.tencent\.com|huaweicloud\.com|nju\.edu\.cn|163\.com|bfsu\.edu\.cn)|cnb\.cool|myip\.ipip\.net|www\.qualcomm\.cn)/ ]]
}

# 将 raw.githubusercontent.com 或 github.com/.../raw/... 转为 jsDelivr 多边缘 CDN 地址（二级兜底）
github_raw_to_jsdelivr_urls() {
	local url="$1" owner="" repo="" ref="" path=""
	if [[ "$url" =~ ^https?://raw\.githubusercontent\.com/([^/]+)/([^/]+)/refs/heads/([^/]+)/(.+)$ ]]; then
		owner="${BASH_REMATCH[1]}"
		repo="${BASH_REMATCH[2]}"
		ref="${BASH_REMATCH[3]}"
		path="${BASH_REMATCH[4]}"
	elif [[ "$url" =~ ^https?://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$ ]]; then
		owner="${BASH_REMATCH[1]}"
		repo="${BASH_REMATCH[2]}"
		ref="${BASH_REMATCH[3]}"
		path="${BASH_REMATCH[4]}"
	elif [[ "$url" =~ ^https?://(www\.)?github\.com/([^/]+)/([^/]+)/raw/([^/]+)/(.+)$ ]]; then
		owner="${BASH_REMATCH[2]}"
		repo="${BASH_REMATCH[3]}"
		ref="${BASH_REMATCH[4]}"
		path="${BASH_REMATCH[5]}"
	else
		return 1
	fi
	local cdn
	for cdn in "${JSDELIVR_MIRRORS[@]}"; do
		printf '%s/gh/%s/%s@%s/%s\n' "$cdn" "$owner" "$repo" "$ref" "$path"
	done
	return 0
}

# 统一的镜像 URL 组装规则 (测速与实际下载共用)
#   use_full_url=1 (默认): 前缀 + 完整 URL (实测全部主流镜像及自建 CF Worker/Nginx 均支持)
#   use_full_url=0        : 前缀 + 去协议头 URL (兼容少数只认去协议头格式的站点)
build_mirror_url() {
	local prefix="$1"
	local url="$2"
	local use_full_url="${3:-1}"
	if [[ -z "$prefix" ]]; then
		printf '%s\n' "$url"
		return 0
	fi
	prefix=$(normalize_mirror_prefix "$prefix")
	if [[ "$use_full_url" == "1" ]]; then
		printf '%s%s\n' "$prefix" "$url"
	else
		local stripped="$url"
		stripped="${stripped#https://}"
		stripped="${stripped#http://}"
		printf '%s%s\n' "$prefix" "$stripped"
	fi
}

# 获取某镜像默认偏好的拼接模式 (1=完整URL, 0=去协议头)
get_mirror_preferred_mode() {
	local prefix
	prefix=$(normalize_mirror_prefix "$1")
	if [[ -n "${MIRROR_URL_MODE[$prefix]:-}" ]]; then
		printf '%s' "${MIRROR_URL_MODE[$prefix]}"
		return 0
	fi
	printf '1'
}

# 判断文件内容是否为 HTML（防止失效镜像返回 HTTP 200 首页/错误页污染下载）
is_html_file() {
	local file="$1"
	local head_txt
	head_txt=$(head -c 512 "$file" 2>/dev/null | tr '\0' ' ')
	printf '%s' "$head_txt" | grep -qiE '^[[:space:]]*(<!DOCTYPE[[:space:]]+html|<html[[:space:]>]|<head[[:space:]>]|<title>)'
}

# 按文件类型做魔数与防 HTML 校验（无上游 SHA-256 时的关键防线）
validate_downloaded_file() {
	local file="$1"
	local hint_dest="${2:-$file}"
	local hint_url="${3:-}"
	[[ -s "$file" ]] || return 1

	local clean_url="${hint_url%%\?*}"
	local lower_dest="${hint_dest,,}"
	local lower_url="${clean_url,,}"
	local ext_hint="$lower_dest"
	case "$lower_dest" in
	*.deb | *.rpm | *.tar.gz | *.tgz | *.gz | *.sh | *.json | *.key | *.gpg) ;;
	*) ext_hint="$lower_url" ;;
	esac

	local magic=""
	case "$ext_hint" in
	*.deb)
		head -c 8 "$file" 2>/dev/null | grep -q '!<arch>' || return 1
		;;
	*.rpm)
		if command -v od >/dev/null 2>&1; then
			magic=$(od -An -tx1 -N4 "$file" 2>/dev/null | tr -d ' \n\r')
			[[ "$magic" == "edabeedb" ]] || return 1
		else
			is_html_file "$file" && return 1
		fi
		;;
	*.tar.gz | *.tgz | *.gz)
		if command -v od >/dev/null 2>&1; then
			magic=$(od -An -tx1 -N2 "$file" 2>/dev/null | tr -d ' \n\r')
			[[ "$magic" == "1f8b" ]] || return 1
		else
			is_html_file "$file" && return 1
		fi
		;;
	*.sh)
		head -n 1 "$file" 2>/dev/null | grep -qE '^#!.*(bash|sh|awk)' || return 1
		;;
	*.json)
		is_html_file "$file" && return 1
		head -c 64 "$file" 2>/dev/null | grep -qE '^[[:space:]]*[\[\{]' || return 1
		;;
	*.html | *.htm)
		;;
	*)
		is_html_file "$file" && return 1
		;;
	esac
	return 0
}

# 探测单个文件镜像：同时校验 HTTP 状态码 (200/206) 与真实 SHA256 内容，彻底免疫假 200 HTML 页
mirror_probe() {
	local prefix="$1"
	local url="$2"
	local max_time="${3:-3}"
	local range_limit="${4:-512}"

	local tmp_body probe http_code time_cost mode
	tmp_body=$(mktemp /tmp/tcpx_mp.XXXXXX) || return 1

	for mode in 1 0; do
		probe=$(curl -q -sL -m "$max_time" -r "0-${range_limit}" -o "$tmp_body" \
			-w "%{http_code} %{time_total}" \
			"$(build_mirror_url "$prefix" "$url" "$mode")" 2>/dev/null)
		http_code=${probe%% *}
		time_cost=${probe#* }
		[[ "$time_cost" == "$probe" ]] && time_cost=""

		if [[ "$http_code" =~ ^(200|206)$ && -n "$time_cost" ]] &&
			! is_html_file "$tmp_body" &&
			head -c 128 "$tmp_body" 2>/dev/null | grep -qE '^[0-9a-fA-F]{64}'; then
			PROBE_HTTP="$http_code"
			PROBE_TIME="$time_cost"
			PROBE_FULL_URL="$mode"
			PROBE_OK=1
			rm -f "$tmp_body"
			return 0
		fi
		# 连接超时/无法建立连接时不浪费时间重试第二种拼法
		[[ -z "$http_code" || "$http_code" == "000" ]] && break
	done

	PROBE_HTTP="${http_code:-000}"
	PROBE_TIME="${time_cost:-}"
	PROBE_FULL_URL=1
	PROBE_OK=0
	rm -f "$tmp_body"
	return 1
}

# 探测单个 GitHub API 镜像：验证 HTTP 200 + 真实 JSON + 未触发 API 限速
api_mirror_probe() {
	local prefix="$1"
	local api_url="$2"
	local max_time="${3:-4}"

	local tmp_body probe http_code time_cost mode
	tmp_body=$(mktemp /tmp/tcpx_ap.XXXXXX) || return 1

	for mode in 1 0; do
		probe=$(curl -q -sL -m "$max_time" -H "User-Agent: tcpx-cn-accel/2.0" -H "Accept: application/vnd.github+json" \
			-o "$tmp_body" -w "%{http_code} %{time_total}" \
			"$(build_mirror_url "$prefix" "$api_url" "$mode")" 2>/dev/null)
		http_code=${probe%% *}
		time_cost=${probe#* }
		[[ "$time_cost" == "$probe" ]] && time_cost=""

		if [[ "$http_code" == "200" && -n "$time_cost" ]] &&
			! is_html_file "$tmp_body" &&
			! grep -qiE 'API rate limit exceeded|secondary rate limit' "$tmp_body" 2>/dev/null &&
			grep -q '"tag_name"' "$tmp_body" 2>/dev/null; then
			PROBE_HTTP="$http_code"
			PROBE_TIME="$time_cost"
			PROBE_FULL_URL="$mode"
			PROBE_OK=1
			rm -f "$tmp_body"
			return 0
		fi
		[[ -z "$http_code" || "$http_code" == "000" ]] && break
	done

	PROBE_HTTP="${http_code:-000}"
	PROBE_TIME="${time_cost:-}"
	PROBE_FULL_URL=1
	PROBE_OK=0
	rm -f "$tmp_body"
	return 1
}

# 并行探测所有 GitHub 文件镜像与 API 镜像 (总耗时仅约 2~4 秒)
probe_github_mirrors() {
	local probe_dir
	probe_dir=$(mktemp -d /tmp/tcpx_probe.XXXXXX) || return 1

	local file_candidates=(
		"https://edgeone.gh-proxy.org/"
		"https://cdn.gh-proxy.org/"
		"https://gh-proxy.com/"
		"https://gh-proxy.org/"
		"https://v6.gh-proxy.org/"
		"https://ghfast.top/"
		"https://ghproxy.net/"
		"https://githubproxy.cc/"
		"https://wget.la/"
	)
	local test_file_url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64.sha256"
	local api_test_url="https://api.github.com/repos/ylx2016/Linux-NetSpeed/releases/tags/kernels"

	local idx=0 prefix
	for prefix in "${file_candidates[@]}"; do
		idx=$((idx + 1))
		(
			if mirror_probe "$prefix" "$test_file_url" 3 512; then
				printf '%s|%s|%s\n' "$PROBE_TIME" "$prefix" "$PROBE_FULL_URL" >"${probe_dir}/file_${idx}.ok"
			else
				printf '%s|%s\n' "$prefix" "${PROBE_HTTP:-000}" >"${probe_dir}/file_${idx}.fail"
			fi
		) &
	done

	local aidx=0
	for prefix in "${GH_API_MIRRORS[@]}"; do
		aidx=$((aidx + 1))
		(
			if api_mirror_probe "$prefix" "$api_test_url" 4; then
				printf '%s|%s|%s\n' "$PROBE_TIME" "$prefix" "$PROBE_FULL_URL" >"${probe_dir}/api_${aidx}.ok"
			else
				printf '%s|%s\n' "$prefix" "${PROBE_HTTP:-000}" >"${probe_dir}/api_${aidx}.fail"
			fi
		) &
	done

	wait

	# 汇总文件镜像最优结果
	local best_time="9999" f t p m
	BEST_MIRROR="poll"
	BEST_MIRROR_FULL_URL=1
	for f in "${probe_dir}"/file_*.ok; do
		[[ -f "$f" ]] || continue
		IFS='|' read -r t p m <"$f"
		MIRROR_URL_MODE["$p"]="$m"
		if awk "BEGIN {exit !($t < $best_time)}"; then
			best_time="$t"
			BEST_MIRROR="$p"
			BEST_MIRROR_FULL_URL="$m"
		fi
	done

	# 汇总 API 镜像最优结果
	local best_api_time="9999"
	BEST_API_MIRROR="poll"
	BEST_API_MIRROR_FULL_URL=1
	for f in "${probe_dir}"/api_*.ok; do
		[[ -f "$f" ]] || continue
		IFS='|' read -r t p m <"$f"
		if awk "BEGIN {exit !($t < $best_api_time)}"; then
			best_api_time="$t"
			BEST_API_MIRROR="$p"
			BEST_API_MIRROR_FULL_URL="$m"
		fi
	done

	if [[ "$BEST_MIRROR" != "poll" ]]; then
		echo -e "${INFO} 最优 GitHub 文件/Raw 镜像: ${GREEN_FONT_PREFIX}${BEST_MIRROR}${FONT_COLOR_SUFFIX} (${best_time}s)"
	else
		echo -e "${TIP} 公共文件镜像测速均超时，下载时将自动全池轮询并保留 jsDelivr/直连兜底。"
	fi

	if [[ "$BEST_API_MIRROR" != "poll" ]]; then
		echo -e "${INFO} 最优 GitHub API 镜像     : ${GREEN_FONT_PREFIX}${BEST_API_MIRROR}${FONT_COLOR_SUFFIX} (${best_api_time}s)"
	else
		echo -e "${TIP} 公共 API 镜像测速均超时或受限，请求时将自动全池轮询并保留直连兜底。"
	fi

	local failed_list=()
	for f in "${probe_dir}"/file_*.fail; do
		[[ -f "$f" ]] || continue
		IFS='|' read -r p m <"$f"
		failed_list+=("${p} (${m})")
	done
	if [[ ${#failed_list[@]} -gt 0 ]]; then
		echo -e "${TIP} 已自动剔除不可用文件镜像: ${failed_list[*]}"
	fi

	rm -rf "$probe_dir"
}

# 懒加载并测速国内 Debian 官方镜像（用于 Cloud 内核池与 Backports）
ensure_debian_mirror() {
	if [[ -n "$TCPX_DEBIAN_MIRROR" ]]; then
		BEST_DEBIAN_MIRROR="$TCPX_DEBIAN_MIRROR"
		CLOUD_HDR_POOL="${BEST_DEBIAN_MIRROR}/pool/main/l/linux/"
		return 0
	fi
	if [[ -n "$BEST_DEBIAN_MIRROR" ]]; then
		CLOUD_HDR_POOL="${BEST_DEBIAN_MIRROR}/pool/main/l/linux/"
		return 0
	fi
	if [[ $IS_CN -eq 0 ]]; then
		BEST_DEBIAN_MIRROR="https://deb.debian.org/debian"
		CLOUD_HDR_POOL="${BEST_DEBIAN_MIRROR}/pool/main/l/linux/"
		return 0
	fi

	local probe_dir idx=0 m
	probe_dir=$(mktemp -d /tmp/tcpx_deb.XXXXXX) || {
		BEST_DEBIAN_MIRROR="https://deb.debian.org/debian"
		CLOUD_HDR_POOL="${BEST_DEBIAN_MIRROR}/pool/main/l/linux/"
		return 0
	}
	echo -e "${INFO} 正在测速国内 Debian 镜像源 (清华/中科大/阿里云/腾讯云/华为云)..." >&2
	for m in "${CN_DEBIAN_MIRRORS[@]}"; do
		idx=$((idx + 1))
		(
			local res code t
			res=$(curl -q -sL -m 3 -r 0-256 -o /dev/null -w "%{http_code} %{time_total}" "${m}/pool/main/l/linux/" 2>/dev/null)
			code=${res%% *}
			t=${res#* }
			if [[ "$code" =~ ^(200|206)$ && -n "$t" && "$t" != "$res" ]]; then
				printf '%s|%s\n' "$t" "$m" >"${probe_dir}/deb_${idx}.ok"
			fi
		) &
	done
	wait

	local best_t="9999" best_m="" f t
	for f in "${probe_dir}"/deb_*.ok; do
		[[ -f "$f" ]] || continue
		IFS='|' read -r t m <"$f"
		if awk "BEGIN {exit !($t < $best_t)}"; then
			best_t="$t"
			best_m="$m"
		fi
	done
	rm -rf "$probe_dir"

	if [[ -n "$best_m" ]]; then
		BEST_DEBIAN_MIRROR="$best_m"
		echo -e "${INFO} 已选用最快国内 Debian 镜像: ${GREEN_FONT_PREFIX}${BEST_DEBIAN_MIRROR}${FONT_COLOR_SUFFIX} (${best_t}s)" >&2
	else
		BEST_DEBIAN_MIRROR="https://deb.debian.org/debian"
		echo -e "${TIP} 国内 Debian 镜像测速均失败，回退至官方源 ${BEST_DEBIAN_MIRROR}" >&2
	fi
	CLOUD_HDR_POOL="${BEST_DEBIAN_MIRROR}/pool/main/l/linux/"
}

# 懒加载并测速国内 ELRepo 官方镜像（用于 CentOS/Alma/Rocky kernel-ml）
ensure_elrepo_mirror() {
	if [[ -n "$TCPX_ELREPO_MIRROR" ]]; then
		BEST_ELREPO_MIRROR="$TCPX_ELREPO_MIRROR"
		return 0
	fi
	if [[ -n "$BEST_ELREPO_MIRROR" ]]; then
		return 0
	fi
	if [[ $IS_CN -eq 0 ]]; then
		BEST_ELREPO_MIRROR=""
		return 0
	fi

	local el_ver="${OS_VERSION_ID:-9}"
	local probe_dir idx=0 m
	probe_dir=$(mktemp -d /tmp/tcpx_elr.XXXXXX) || return 0
	echo -e "${INFO} 正在测速国内 ELRepo 镜像源 (清华/阿里云/中科大)..." >&2
	for m in "${CN_ELREPO_MIRRORS[@]}"; do
		idx=$((idx + 1))
		(
			local res code t
			res=$(curl -q -sL -m 3 -o /dev/null -w "%{http_code} %{time_total}" "${m}/kernel/el${el_ver}/x86_64/repodata/repomd.xml" 2>/dev/null)
			code=${res%% *}
			t=${res#* }
			if [[ "$code" == "200" && -n "$t" && "$t" != "$res" ]]; then
				printf '%s|%s\n' "$t" "$m" >"${probe_dir}/elr_${idx}.ok"
			fi
		) &
	done
	wait

	local best_t="9999" best_m="" f t
	for f in "${probe_dir}"/elr_*.ok; do
		[[ -f "$f" ]] || continue
		IFS='|' read -r t m <"$f"
		if awk "BEGIN {exit !($t < $best_t)}"; then
			best_t="$t"
			best_m="$m"
		fi
	done
	rm -rf "$probe_dir"

	if [[ -n "$best_m" ]]; then
		BEST_ELREPO_MIRROR="$best_m"
		echo -e "${INFO} 已选用最快国内 ELRepo 镜像: ${GREEN_FONT_PREFIX}${BEST_ELREPO_MIRROR}${FONT_COLOR_SUFFIX} (${best_t}s)" >&2
	else
		BEST_ELREPO_MIRROR=""
	fi
}

# curl 的 HTTPS 严格参数：-q 不读取 curlrc；--proto/--proto-redir 需要 curl 7.20.2+。
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
		echo -e "${TIP} 当前 curl 不支持中继协议限制参数，已改为下载后复核最终 URL 必须为 HTTPS。" >&2
		printf '%s\n' -q -fsSL --proto =https
	fi
}

# 单次下载尝试 (统一使用 curl，天然支持 HTTP/HTTPS/SOCKS5 代理、断速自动切换、TLS 校验、SHA-256 与魔数校验)
download_once() {
	local prefix="$1"
	local url="$2"
	local dest="$3"
	local use_full_url="${4:-1}"
	local timeout="${5:-15}"
	local expected_sha256="${6:-}"
	local target_url http_log curl_meta http_code effective dl_bytes dl_speed downloaded=0
	DOWNLOAD_HTTP=""

	[[ "$url" == https://* && ( -z "$prefix" || "$prefix" == https://* ) ]] || {
		echo -e "${ERROR} 下载地址必须使用 HTTPS。" >&2
		return 1
	}

	if [[ -n "$expected_sha256" ]]; then
		if [[ ! "$expected_sha256" =~ ^[a-fA-F0-9]{64}$ ]] || ! command -v sha256sum >/dev/null 2>&1; then
			echo -e "${ERROR} 摘要格式无效或缺少 sha256sum，拒绝跳过制品校验。" >&2
			DOWNLOAD_HTTP="digest-unavailable"
			return 1
		fi
		expected_sha256="${expected_sha256,,}"
	elif [[ "${TCPX_STRICT_DIGEST:-0}" == "1" && ( -n "$prefix" || "${TCPX_TLS_INSECURE:-0}" == "1" ) ]]; then
		echo -e "${ERROR} 严格摘要模式下，无独立摘要时禁止使用第三方镜像或关闭 TLS 校验。" >&2
		DOWNLOAD_HTTP="unauthenticated-source"
		return 1
	elif [[ "${TCPX_TLS_INSECURE:-0}" == "1" ]]; then
		echo -e "${ERROR} 无独立摘要时禁止关闭 TLS 证书校验。" >&2
		DOWNLOAD_HTTP="unauthenticated-source"
		return 1
	fi

	target_url=$(build_mirror_url "$prefix" "$url" "$use_full_url")
	if [[ -z "$prefix" ]]; then
		echo -e "${INFO} 正在下载: ${dest} (直连) ..."
	else
		echo -e "${INFO} 正在下载: ${dest} (加速节点: ${prefix}) ..."
	fi

	http_log=$(mktemp /tmp/tcpx_dl.XXXXXX) || return 1
	local curl_args=() curl_arg
	while IFS= read -r curl_arg; do
		[[ -n "$curl_arg" ]] && curl_args+=("$curl_arg")
	done < <(curl_secure_args)
	if [[ -n "$expected_sha256" && "${TCPX_TLS_INSECURE:-0}" == "1" ]]; then
		curl_args+=(-k)
		echo -e "${TIP} 已按 TCPX_TLS_INSECURE=1 关闭连接证书校验；仍强制核验独立 SHA-256。" >&2
	fi

	# 连接超时 timeout 秒；若连续 20 秒速率低于 1KB/s 自动中止并切换备用镜像，避免卡死
	if curl_meta=$(curl "${curl_args[@]}" \
		-H "User-Agent: tcpx-cn-accel/2.0" \
		--connect-timeout "$timeout" --speed-time 20 --speed-limit 1024 --retry 1 \
		-o "$dest" -w '%{http_code} %{url_effective} %{size_download} %{speed_download}' \
		"$target_url" 2>"$http_log"); then
		read -r http_code effective dl_bytes dl_speed <<<"$curl_meta"
		if [[ "$effective" != https://* ]]; then
			echo -e "${ERROR} 下载最终落点不是 HTTPS (${effective})，已拒绝该内容。" >&2
			DOWNLOAD_HTTP="insecure-redirect"
			rm -f "$http_log" "$dest"
			return 1
		fi
		downloaded=1
	else
		http_code=$(grep -oE 'returned error: [0-9]{3}' "$http_log" 2>/dev/null | awk '{print $NF}' | tail -n 1)
	fi
	DOWNLOAD_HTTP="${http_code:-000}"

	if [[ "$downloaded" == "1" && -s "$dest" ]]; then
		if [[ -n "$expected_sha256" ]]; then
			local actual_sha256
			if ! actual_sha256=$(sha256sum -- "$dest" 2>/dev/null); then
				rm -f "$http_log" "$dest"
				DOWNLOAD_HTTP="digest-error"
				return 1
			fi
			actual_sha256="${actual_sha256%% *}"
			if [[ "$actual_sha256" != "$expected_sha256" ]]; then
				echo -e "${ERROR} ${dest} SHA-256 校验不匹配，已丢弃该节点内容并切换下一节点！" >&2
				rm -f "$http_log" "$dest"
				DOWNLOAD_HTTP="digest-mismatch"
				return 1
			fi
		else
			if ! validate_downloaded_file "$dest" "$dest" "$url"; then
				echo -e "${TIP} 节点返回内容未通过格式校验 (疑似错误页/截断文件)，自动切换下一节点..." >&2
				rm -f "$http_log" "$dest"
				DOWNLOAD_HTTP="invalid-content"
				return 1
			fi
		fi

		DOWNLOAD_HTTP=200
		rm -f "$http_log"
		local speed_str=""
		if [[ -n "${dl_speed:-}" ]]; then
			speed_str=$(awk -v b="${dl_bytes:-0}" -v s="${dl_speed:-0}" 'BEGIN {
				if (b >= 1048576) sz = sprintf("%.2fMB", b/1048576);
				else if (b >= 1024) sz = sprintf("%.1fKB", b/1024);
				else sz = sprintf("%dB", b);
				if (s >= 1048576) sp = sprintf("%.2fMB/s", s/1048576);
				else sp = sprintf("%.1fKB/s", s/1024);
				printf "%s, %s", sz, sp;
			}')
		fi
		if [[ -n "$expected_sha256" ]]; then
			echo -e "${INFO} ${dest} 下载成功 (${speed_str:-OK}, SHA-256 已验证)！"
		else
			echo -e "${INFO} ${dest} 下载成功 (${speed_str:-OK})！"
		fi
		return 0
	fi

	echo -e "${TIP} 节点下载失败 (HTTP ${DOWNLOAD_HTTP:-000})，已丢弃不完整内容。" >&2
	rm -f "$http_log" "$dest"
	return 1
}

# 从端点响应解析 ISO 国家码；无法识别时输出空串。
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

# 在指定地址族下依次尝试所有端点，输出第一个有效国家码。
detect_geo_country() {
	local family="$1" entry kind url body country
	for entry in "${CN_STATUS_ENDPOINTS[@]}"; do
		kind=${entry%%|*}
		url=${entry#*|}
		body=$(curl -q "-${family}" -fsL --max-time "$CN_STATUS_TIMEOUT" "$url" 2>/dev/null) || continue
		country=$(parse_geo_country "$kind" "$body")
		[[ -n "$country" ]] && {
			printf '%s' "$country"
			return 0
		}
	done
	return 1
}

# 1. 网络环境检测与全链路镜像初始化
check_cn_status() {
	load_accel_config

	# 用户显式强制海外直连
	if [[ "$TCPX_FORCE_CN" == "0" ]]; then
		IS_CN=0
		echo -e "${INFO} 已按配置启用海外直连模式 (TCPX_FORCE_CN=0)。"
		[[ -n "$TCPX_UNIVERSAL_PROXY" ]] && echo -e "${INFO} 已启用自定义全站反代: ${GREEN_FONT_PREFIX}${TCPX_UNIVERSAL_PROXY}${FONT_COLOR_SUFFIX}"
		[[ -n "$TCPX_HTTP_PROXY" ]] && echo -e "${INFO} 已启用系统代理: ${GREEN_FONT_PREFIX}${TCPX_HTTP_PROXY}${FONT_COLOR_SUFFIX}"
		return 0
	fi

	# 判断网络归属 (支持强制国内加速)
	local country="" ip_version
	if [[ "$TCPX_FORCE_CN" == "1" ]]; then
		IS_CN=1
		echo -e "${INFO} 已按配置强制启用国内全链路加速模式 (TCPX_FORCE_CN=1)。"
	else
		for ip_version in 4 6; do
			country=$(detect_geo_country "$ip_version") || country=""
			[[ -n "$country" ]] && break
		done
		if [[ "$country" == "CN" ]]; then
			IS_CN=1
			echo -e "${INFO} 检测到当前节点位于中国大陆，正在并行测速 GitHub 文件与 API 加速节点..."
		elif [[ -n "$country" ]]; then
			IS_CN=0
			echo -e "${INFO} 当前节点位于海外 (${country})，默认使用直连网络。"
			[[ -n "$TCPX_MIRROR" ]] && echo -e "${INFO} 已配置自定义 GitHub 镜像: ${GREEN_FONT_PREFIX}${TCPX_MIRROR}${FONT_COLOR_SUFFIX}"
			[[ -n "$TCPX_UNIVERSAL_PROXY" ]] && echo -e "${INFO} 已配置自定义全站反代: ${GREEN_FONT_PREFIX}${TCPX_UNIVERSAL_PROXY}${FONT_COLOR_SUFFIX}"
			return 0
		else
			IS_CN=2
			echo -e "${TIP} 归属地检测超时，默认启用国内全链路加速模式 (镜像优先 + 直连兜底)..."
		fi
	fi

	[[ -n "$TCPX_HTTP_PROXY" ]] && echo -e "${INFO} 已启用 HTTP/SOCKS 代理: ${GREEN_FONT_PREFIX}${TCPX_HTTP_PROXY}${FONT_COLOR_SUFFIX}"
	if [[ -n "$TCPX_UNIVERSAL_PROXY" ]]; then
		echo -e "${INFO} 已优先使用自建全站通用反代: ${GREEN_FONT_PREFIX}${TCPX_UNIVERSAL_PROXY}${FONT_COLOR_SUFFIX}"
	fi
	if [[ -n "$TCPX_MIRROR" ]]; then
		echo -e "${INFO} 已优先使用自定义 GitHub 镜像: ${GREEN_FONT_PREFIX}${TCPX_MIRROR}${FONT_COLOR_SUFFIX}"
	fi
	if [[ -n "$TCPX_API_MIRROR" ]]; then
		echo -e "${INFO} 已优先使用自定义 GitHub API 镜像: ${GREEN_FONT_PREFIX}${TCPX_API_MIRROR}${FONT_COLOR_SUFFIX}"
	fi

	# 若未通过自建全站反代全覆盖，则仍做快速并行探测作为无缝兜底
	if [[ -z "$TCPX_UNIVERSAL_PROXY" && ( -z "$TCPX_MIRROR" || -z "$TCPX_API_MIRROR" ) ]]; then
		probe_github_mirrors
	fi
}

# 向候选数组去重追加项 (兼容 Bash 4.2)
_append_unique_mirror() {
	local val="$1" existing
	shift
	for existing in "$@"; do
		[[ "$existing" == "$val" ]] && return 1
	done
	return 0
}

# 2. 全链路安全可靠下载函数
#    - GitHub 资源 (raw / release / archive / objects): 自定义镜像 -> 最优测速节点 -> 全池轮询 -> jsDelivr (Raw) -> 直连兜底
#    - 非 GitHub 海外资源 (XanMod / Liquorix / Brutal / ELRepo / Snapshot): 若配置了 TCPX_UNIVERSAL_PROXY 则优先走反代 -> 直连兜底
safe_wget() {
	local url="$1"
	local dest="$2"
	local expected_sha256="${3:-}"
	local timeout=15

	local mirrors=() m

	if is_github_url "$url"; then
		if [[ "${TCPX_STRICT_DIGEST:-0}" == "1" && -z "$expected_sha256" ]]; then
			echo -e "${TIP} 严格摘要模式且上游无摘要，本次仅使用上游 HTTPS 直连。" >&2
			mirrors=("")
		elif [[ $IS_CN -eq 0 && -z "$TCPX_MIRROR" && -z "$TCPX_RAW_MIRROR" && -z "$TCPX_UNIVERSAL_PROXY" ]]; then
			mirrors=("")
		else
			if is_github_raw_url "$url" && [[ -n "$TCPX_RAW_MIRROR" ]]; then
				mirrors+=("$TCPX_RAW_MIRROR")
			fi
			if [[ -n "$TCPX_MIRROR" ]] && _append_unique_mirror "$TCPX_MIRROR" "${mirrors[@]}"; then
				mirrors+=("$TCPX_MIRROR")
			fi
			if [[ -n "$TCPX_UNIVERSAL_PROXY" ]] && _append_unique_mirror "$TCPX_UNIVERSAL_PROXY" "${mirrors[@]}"; then
				mirrors+=("$TCPX_UNIVERSAL_PROXY")
			fi
			if [[ -n "$BEST_MIRROR" && "$BEST_MIRROR" != "poll" ]] && _append_unique_mirror "$BEST_MIRROR" "${mirrors[@]}"; then
				mirrors+=("$BEST_MIRROR")
			fi
			for m in "${GH_FILE_MIRRORS[@]}"; do
				_append_unique_mirror "$m" "${mirrors[@]}" && mirrors+=("$m")
			done
			mirrors+=("")
		fi
	else
		if [[ -n "$TCPX_UNIVERSAL_PROXY" ]] && ! is_cn_domestic_mirror_url "$url"; then
			mirrors=("$TCPX_UNIVERSAL_PROXY" "")
		else
			mirrors=("")
		fi
	fi

	local prefix pref_mode alt_mode tried_alt
	for prefix in "${mirrors[@]}"; do
		pref_mode=1
		[[ -n "$prefix" ]] && pref_mode=$(get_mirror_preferred_mode "$prefix")
		alt_mode=$((1 - pref_mode))
		tried_alt=0

		while :; do
			if download_once "$prefix" "$url" "$dest" "$pref_mode" "$timeout" "$expected_sha256"; then
				[[ -n "$prefix" ]] && MIRROR_URL_MODE["$(normalize_mirror_prefix "$prefix")"]="$pref_mode"
				return 0
			fi
			if [[ -n "$prefix" && "$tried_alt" == "0" && ( "$DOWNLOAD_HTTP" == "404" || "$DOWNLOAD_HTTP" == "400" || "$DOWNLOAD_HTTP" == "invalid-content" ) ]]; then
				echo -e "${TIP} 节点 ${prefix} 尝试切换另一种 URL 拼接格式重试..." >&2
				pref_mode="$alt_mode"
				tried_alt=1
				continue
			fi
			break
		done

		[[ ${#mirrors[@]} -gt 1 ]] && echo -e "${TIP} 正在无缝切换至下一个备用节点..." >&2
	done

	# Raw 文件二级 CDN 兜底：jsDelivr (Fastly / Gcore / TestingCF)
	if [[ $IS_CN -ne 0 && "${TCPX_STRICT_DIGEST:-0}" != "1" ]] && is_github_raw_url "$url"; then
		local jsd_url
		while IFS= read -r jsd_url; do
			[[ -z "$jsd_url" ]] && continue
			echo -e "${TIP} 尝试 jsDelivr CDN 二级兜底: ${jsd_url}" >&2
			if download_once "" "$jsd_url" "$dest" 1 "$timeout" "$expected_sha256"; then
				return 0
			fi
		done < <(github_raw_to_jsdelivr_urls "$url")
	fi

	echo -e "${ERROR} 文件 ${dest} 所有下载节点均失效，请检查网络或在菜单 [70] 配置自建加速反代/代理！" >&2
	return 1
}

# 3. GitHub REST API 全链路加速请求函数
#    - 内置 300 秒会话缓存，避免同一仓库重复请求 (installbbr 等一次安装只需 1 次 API 请求)
#    - 多 API 镜像自动容灾，触发 403 频率限制自动轮换下一节点
#    - 安全原则：TCPX_GITHUB_TOKEN 仅发往直连 api.github.com 或用户自建私有反代，绝不发往公共镜像
github_api_get() {
	local api_url="$1"
	local nocache="${2:-0}"

	# 会话级缓存 (TTL 300s)
	local cache_key cache_file now mtime
	cache_key=$(printf '%s' "$api_url" | tr -c 'a-zA-Z0-9._-' '_')
	cache_file="/tmp/tcpx_api_cache_${cache_key:0:120}.json"
	if [[ "$nocache" != "1" && -s "$cache_file" && ! -L "$cache_file" ]]; then
		now=$(date +%s 2>/dev/null || echo 0)
		mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
		if [[ $((now - mtime)) -lt 300 ]]; then
			cat "$cache_file"
			return 0
		fi
	fi

	local candidates=() seen_prefixes=() p
	_add_api_cand() {
		local priv="$1" pref="$2" ex
		for ex in "${seen_prefixes[@]}"; do
			[[ "$ex" == "$pref" ]] && return 0
		done
		seen_prefixes+=("$pref")
		candidates+=("${priv}|${pref}")
	}

	local tmp_resp
	tmp_resp=$(mktemp /tmp/tcpx_api.XXXXXX) || {
		unset -f _add_api_cand 2>/dev/null
		return 1
	}
	trap 'rm -f "$tmp_resp"; unset -f _add_api_cand 2>/dev/null; trap - RETURN' RETURN

	if [[ $IS_CN -eq 0 && -z "$TCPX_API_MIRROR" && -z "$TCPX_UNIVERSAL_PROXY" ]]; then
		_add_api_cand 1 ""
		for p in "${GH_API_MIRRORS[@]}"; do
			_add_api_cand 0 "$p"
		done
	else
		[[ -n "$TCPX_API_MIRROR" ]] && _add_api_cand 1 "$TCPX_API_MIRROR"
		[[ -n "$TCPX_UNIVERSAL_PROXY" ]] && _add_api_cand 1 "$TCPX_UNIVERSAL_PROXY"
		[[ -n "$BEST_API_MIRROR" && "$BEST_API_MIRROR" != "poll" ]] && _add_api_cand 0 "$BEST_API_MIRROR"
		for p in "${GH_API_MIRRORS[@]}"; do
			_add_api_cand 0 "$p"
		done
		_add_api_cand 1 ""
	fi

	local curl_base=() curl_arg
	while IFS= read -r curl_arg; do
		[[ -n "$curl_arg" ]] && curl_base+=("$curl_arg")
	done < <(curl_secure_args)

	local entry is_priv prefix target_url http_code mode label
	for entry in "${candidates[@]}"; do
		is_priv="${entry%%|*}"
		prefix="${entry#*|}"
		label="${prefix:-api.github.com (直连)}"

		for mode in 1 0; do
			[[ -z "$prefix" && "$mode" == "0" ]] && break
			target_url=$(build_mirror_url "$prefix" "$api_url" "$mode")

			local req_args=("${curl_base[@]}" --connect-timeout 8 --max-time 20
				-H "User-Agent: tcpx-cn-accel/2.0"
				-H "Accept: application/vnd.github+json")
			if [[ "$is_priv" == "1" && -n "${TCPX_GITHUB_TOKEN:-}" ]]; then
				req_args+=(-H "Authorization: Bearer ${TCPX_GITHUB_TOKEN}")
			fi

			http_code=$(curl "${req_args[@]}" -o "$tmp_resp" -w '%{http_code}' "$target_url" 2>/dev/null) || http_code="${http_code:-000}"

			if [[ "$http_code" == "200" && -s "$tmp_resp" ]] &&
				! is_html_file "$tmp_resp" &&
				head -c 64 "$tmp_resp" 2>/dev/null | grep -qE '^[[:space:]]*[\[\{]'; then
				if grep -qiE 'API rate limit exceeded|secondary rate limit' "$tmp_resp" 2>/dev/null; then
					echo -e "${TIP} API 节点 ${label} 触发频率限制，自动切换下一节点..." >&2
					break
				fi
				cp -f "$tmp_resp" "$cache_file" 2>/dev/null && chmod 600 "$cache_file" 2>/dev/null || true
				cat "$tmp_resp"
				return 0
			fi

			if [[ "$http_code" == "403" ]] && grep -qiE 'rate limit' "$tmp_resp" 2>/dev/null; then
				echo -e "${TIP} API 节点 ${label} 触发 GitHub API 频率限制 (403)，自动切换下一节点..." >&2
				break
			fi

			[[ -z "$http_code" || "$http_code" == "000" ]] && break
		done
	done

	echo -e "${ERROR} 所有 GitHub API 节点均请求失败或触发限速！可在菜单 [70] 配置自建反代或 GitHub Token。" >&2
	return 1
}

# 4. 从候选链接中挑出版本号最高的一条 (get_github_asset 的收尾步骤)
pick_latest_asset() {
	local url base ver
	local unversioned=""
	local versioned=()
	while IFS= read -r url; do
		[[ -z "$url" ]] && continue
		base="${url##*/}"
		ver=$(printf '%s\n' "$base" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
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

# 从同一 GitHub asset 对象中精确关联 URL 与 SHA-256（支持 jq -> python3 -> 优雅降级）
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
				else error("invalid SHA-256 digest") end
			end'); then
			return 1
		fi
		printf '%s' "${digest,,}"
		return 0
	elif command -v python3 >/dev/null 2>&1; then
		if ! digest=$(printf '%s' "$response" | python3 -c '
import json, re, sys
target = sys.argv[1]
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(1)
matches = [a for r in data for a in (r.get("assets") or []) if a.get("browser_download_url") == target]
if len(matches) != 1:
    sys.exit(1)
d = matches[0].get("digest")
if d is None:
    print("", end="")
elif isinstance(d, str) and re.fullmatch(r"sha256:[0-9a-fA-F]{64}", d):
    print(d[7:].lower(), end="")
else:
    sys.exit(1)
' "$url" 2>/dev/null); then
			return 1
		fi
		printf '%s' "$digest"
		return 0
	fi

	echo -e "${TIP} 未检测到 jq / python3，跳过独立摘要解析（下载将启用文件格式魔数校验）。" >&2
	return 0
}

# 查询单个 Release Tag 下某文件的 SHA-256（供 fetch_kernel_archive 对 437MB 整包做校验）
get_release_asset_digest() {
	local repo="$1"
	local tag="$2"
	local filename="$3"
	local api_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"
	local response digest=""

	response=$(github_api_get "$api_url" 2>/dev/null) || return 1
	if command -v jq >/dev/null 2>&1; then
		digest=$(printf '%s' "$response" | jq -r --arg name "$filename" '
			(.assets // [])[] | select(.name == $name) | .digest // ""' 2>/dev/null | head -n 1)
	elif command -v python3 >/dev/null 2>&1; then
		digest=$(printf '%s' "$response" | python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
for a in (data.get("assets") or []):
    if a.get("name") == name and a.get("digest"):
        print(a["digest"])
        break
' "$filename" 2>/dev/null)
	fi
	if [[ "$digest" =~ ^sha256:([0-9a-fA-F]{64})$ ]]; then
		printf '%s' "${BASH_REMATCH[1],,}"
		return 0
	fi
	return 1
}

# 5. 稳健的 GitHub 资源获取函数 (经由 github_api_get 全链路加速 + 容灾 + 缓存)
# 用法: get_github_asset <仓库名> <Tag关键词> <文件名关键词> [架构关键词]
get_github_asset() {
	local repo="$1"
	local tag_kw="$2"
	local ast_kw="$3"
	local arch_kw="$4"
	local api_url="https://api.github.com/repos/${repo}/releases?per_page=100"

	local response
	if ! response=$(github_api_get "$api_url"); then
		echo -e "${ERROR} GitHub API 请求失败，无法获取 ${repo} 发布列表。" >&2
		return 1
	fi

	local all_urls=""
	if command -v jq >/dev/null 2>&1; then
		all_urls=$(printf '%s' "$response" | jq -er '
			if type != "array" then error("invalid releases response") else . end |
			.[] | .assets[]? | .browser_download_url |
			select(type == "string") | select(startswith("https://"))') || return 1
	elif command -v python3 >/dev/null 2>&1; then
		all_urls=$(printf '%s' "$response" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(1)
for r in data:
    for a in (r.get("assets") or []):
        u = a.get("browser_download_url", "")
        if isinstance(u, str) and u.startswith("https://"):
            print(u)
' 2>/dev/null) || return 1
	else
		all_urls=$(printf '%s\n' "$response" | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' | grep -oE 'https://[^"]+')
	fi

	if [[ -z "$all_urls" ]]; then
		echo -e "${ERROR} 无法从 ${repo} 获取资源列表，请检查网络或稍后再试！" >&2
		return 1
	fi

	local result
	result=$(printf '%s\n' "$all_urls" | grep -iE "$tag_kw" | grep -iE "$ast_kw")
	[[ -n "$arch_kw" ]] && result=$(printf '%s\n' "$result" | grep -iE "$arch_kw")

	# 排除调试符号包与未签名包
	result=$(printf '%s\n' "$result" | grep -viE 'dbg|debug|unsigned')

	# 防呆：x86_64 排除 arm64/aarch64
	if [[ "$arch_kw" != *"arm64"* && "$tag_kw" != *"arm64"* && "$OS_ARCH" != "aarch64" ]]; then
		result=$(printf '%s\n' "$result" | grep -viE "arm64|aarch64")
	fi

	local asset_url
	asset_url=$(printf '%s\n' "$result" | pick_latest_asset)
	if [[ -z "$asset_url" ]]; then
		echo -e "${ERROR} 无法在 ${repo} 中解析到匹配关键字 (${tag_kw} -> ${ast_kw} -> ${arch_kw}) 的文件！" >&2
		return 1
	fi

	local digest=""
	if ! digest=$(asset_digest_for_url "$response" "$asset_url"); then
		echo -e "${ERROR} 无法可靠关联资源与摘要，已中止。" >&2
		return 1
	fi
	printf '%s\t%s\n' "$asset_url" "$digest"
}

# 6. 获取当前生效的 GitHub 文件/API 加速前缀（供子脚本动态改写使用）
get_active_github_mirror_prefix() {
	if [[ $IS_CN -eq 0 && -z "$TCPX_MIRROR" && -z "$TCPX_UNIVERSAL_PROXY" ]]; then
		return 0
	fi
	local p=""
	if [[ -n "$TCPX_MIRROR" ]]; then
		p="$TCPX_MIRROR"
	elif [[ -n "$TCPX_UNIVERSAL_PROXY" ]]; then
		p="$TCPX_UNIVERSAL_PROXY"
	elif [[ -n "$BEST_MIRROR" && "$BEST_MIRROR" != "poll" ]]; then
		p="$BEST_MIRROR"
	else
		p="${GH_FILE_MIRRORS[0]}"
	fi
	normalize_mirror_prefix "$p"
}

get_active_api_mirror_prefix() {
	if [[ $IS_CN -eq 0 && -z "$TCPX_API_MIRROR" && -z "$TCPX_UNIVERSAL_PROXY" ]]; then
		return 0
	fi
	local p=""
	if [[ -n "$TCPX_API_MIRROR" ]]; then
		p="$TCPX_API_MIRROR"
	elif [[ -n "$TCPX_UNIVERSAL_PROXY" ]]; then
		p="$TCPX_UNIVERSAL_PROXY"
	elif [[ -n "$BEST_API_MIRROR" && "$BEST_API_MIRROR" != "poll" ]]; then
		p="$BEST_API_MIRROR"
	else
		p="${GH_API_MIRRORS[0]}"
	fi
	normalize_mirror_prefix "$p"
}

# 7. 子脚本内部 GitHub / 海外源 URL 动态加速改写器
#    解决“主脚本用镜像下好了子脚本，子脚本一跑又直连 GitHub 卡死”的顽疾！
#    用法: patch_child_script_mirrors <临时脚本路径> <类型: lotserver|lotspeed|brutal|tcpfit|liquorix>
patch_child_script_mirrors() {
	local script_file="$1"
	local kind="$2"
	[[ -f "$script_file" ]] || return 0

	local file_prefix api_prefix uproxy
	file_prefix=$(get_active_github_mirror_prefix)
	api_prefix=$(get_active_api_mirror_prefix)
	uproxy=$(normalize_mirror_prefix "${TCPX_UNIVERSAL_PROXY:-}")

	case "$kind" in
	lotserver)
		if [[ -n "$file_prefix" ]]; then
			sed -i "s|https://github.com/fei5seven/lotServer/raw/master/|${file_prefix}https://github.com/fei5seven/lotServer/raw/master/|g" "$script_file"
			echo -e "${INFO} 已为 lotServer 安装脚本注入国内加速镜像 (${file_prefix})。"
		fi
		;;
	lotspeed)
		if [[ -n "$file_prefix" ]]; then
			sed -i "s|https://raw.githubusercontent.com/|${file_prefix}https://raw.githubusercontent.com/|g" "$script_file"
			echo -e "${INFO} 已为 LotSpeed 安装脚本注入国内加速镜像 (${file_prefix})。"
		fi
		;;
	brutal)
		if [[ -n "$file_prefix" ]]; then
			sed -i "s|REPO_URL=\"https://github.com/HyNetworks/tcp-brutal\"|REPO_URL=\"${file_prefix}https://github.com/HyNetworks/tcp-brutal\"|g" "$script_file"
			echo -e "${INFO} 已为 Brutal 安装脚本注入 GitHub Release 加速镜像 (${file_prefix})。"
		fi
		if [[ -n "$uproxy" ]]; then
			sed -i "s|HY2_API_BASE_URL=\"https://api.hy2.io/v1\"|HY2_API_BASE_URL=\"${uproxy}https://api.hy2.io/v1\"|g" "$script_file"
		fi
		;;
	tcpfit)
		if [[ -n "$file_prefix" ]]; then
			sed -i "s|https://raw.githubusercontent.com/Kylin010/tcpfit/|${file_prefix}https://raw.githubusercontent.com/Kylin010/tcpfit/|g" "$script_file"
			sed -i "s|https://github.com/Kylin010/tcpfit/releases/download/|${file_prefix}https://github.com/Kylin010/tcpfit/releases/download/|g" "$script_file"
		fi
		if [[ -n "$api_prefix" ]]; then
			sed -i "s|https://api.github.com/repos/Kylin010/tcpfit/|${api_prefix}https://api.github.com/repos/Kylin010/tcpfit/|g" "$script_file"
		fi
		[[ -n "$file_prefix" || -n "$api_prefix" ]] && echo -e "${INFO} 已为 tcpfit 脚本注入 Raw / Release / API 国内加速镜像。"
		;;
	liquorix)
		if [[ -n "$uproxy" ]]; then
			sed -i "s|https://liquorix.net|${uproxy}https://liquorix.net|g" "$script_file"
			echo -e "${INFO} 已为 Liquorix 源脚本注入通用反代 (${uproxy})。"
		fi
		;;
	esac
}

# 8. 全链路连通性体检工具 (菜单 [70] / 命令行 tcpx accel-test 调用)
run_accel_diagnostics() {
	echo -e "${INFO} ========================================================="
	echo -e "${INFO}  tcpx 全链路加速连通性体检 (Raw / Release / API / 镜像源)"
	echo -e "${INFO} ========================================================="

	local fp ap
	fp=$(get_active_github_mirror_prefix)
	ap=$(get_active_api_mirror_prefix)
	ensure_debian_mirror
	[[ "${OS_TYPE}" == "CentOS" ]] && ensure_elrepo_mirror

	_diag_check() {
		local label="$1" url="$2" expect="$3"
		local tmp out code t ok=0
		tmp=$(mktemp /tmp/tcpx_diag.XXXXXX) || return
		out=$(curl -q -sL -m 6 -H "User-Agent: tcpx-cn-accel/2.0" -r 0-2048 -o "$tmp" -w "%{http_code} %{time_total}" "$url" 2>/dev/null)
		code=${out%% *}
		t=${out#* }
		if [[ "$code" =~ ^(200|206)$ ]] && ! is_html_file "$tmp"; then
			case "$expect" in
			sh) head -n 1 "$tmp" 2>/dev/null | grep -qE '^#!' && ok=1 ;;
			sha) head -c 128 "$tmp" 2>/dev/null | grep -qE '^[0-9a-fA-F]{64}' && ok=1 ;;
			json) grep -qE '"tag_name"|"browser_download_url"' "$tmp" 2>/dev/null && ok=1 ;;
			any) [[ -s "$tmp" ]] && ok=1 ;;
			esac
		elif [[ "$expect" == "html" && "$code" =~ ^(200|206)$ && -s "$tmp" ]]; then
			ok=1
		fi
		rm -f "$tmp"
		if [[ $ok -eq 1 ]]; then
			printf "  [ ${GREEN_FONT_PREFIX}正常${FONT_COLOR_SUFFIX} ] %-24s (%ss, HTTP %s)\n" "$label" "$t" "$code"
		else
			printf "  [ ${RED_FONT_PREFIX}异常${FONT_COLOR_SUFFIX} ] %-24s (HTTP %s, %ss)\n" "$label" "${code:-000}" "${t:-timeout}"
		fi
	}
	trap 'unset -f _diag_check 2>/dev/null; trap - RETURN' RETURN

	_diag_check "GitHub Raw (tcpx.sh)" "$(build_mirror_url "$fp" "${GITHUB_RAW_URL}/tcpx.sh" 1)" "sh"
	_diag_check "GitHub Release (校验文件)" "$(build_mirror_url "$fp" "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64.sha256" 1)" "sha"
	_diag_check "GitHub API (releases)" "$(build_mirror_url "$ap" "https://api.github.com/repos/ylx2016/Linux-NetSpeed/releases/tags/kernels" 1)" "json"
	_diag_check "jsDelivr Raw 兜底" "https://fastly.jsdelivr.net/gh/ylx2016/Linux-NetSpeed@master/tcpx.sh" "sh"
	_diag_check "Debian Cloud 镜像池" "${BEST_DEBIAN_MIRROR}/pool/main/l/linux/" "html"
	_diag_check "CNB 一键DD 国内源" "https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh" "sh"
	if [[ -n "$BEST_ELREPO_MIRROR" ]]; then
		_diag_check "ELRepo 国内镜像" "${BEST_ELREPO_MIRROR}/kernel/el9/x86_64/repodata/repomd.xml" "any"
	else
		_diag_check "ELRepo 清华镜像" "https://mirrors.tuna.tsinghua.edu.cn/elrepo/kernel/el9/x86_64/repodata/repomd.xml" "any"
	fi
	if [[ -n "$TCPX_UNIVERSAL_PROXY" ]]; then
		_diag_check "自建全站反代 (XanMod)" "$(build_mirror_url "$TCPX_UNIVERSAL_PROXY" "https://dl.xanmod.org/archive.key" 1)" "any"
	fi
	echo -e "${INFO} ========================================================="
}

# 9. 菜单 [70]: 网络加速与镜像管理中心
manage_accel_settings() {
	while true; do
		clear
		local mode_desc="自动检测"
		[[ "$TCPX_FORCE_CN" == "1" ]] && mode_desc="强制国内加速"
		[[ "$TCPX_FORCE_CN" == "0" ]] && mode_desc="强制海外直连"

		local active_file_m active_api_m
		active_file_m=$(get_active_github_mirror_prefix)
		active_api_m=$(get_active_api_mirror_prefix)

		echo -e "${INFO} ========================================================="
		echo -e "${INFO}  tcpx 全链路加速与镜像管理中心 (${SH_CN_MOD})"
		echo -e "${INFO} ========================================================="
		echo -e "  当前运行状态 : $([[ $IS_CN -ne 0 ]] && echo -e "${GREEN_FONT_PREFIX}国内全链路加速${FONT_COLOR_SUFFIX}" || echo -e "${YELLOW_FONT_PREFIX}海外直连${FONT_COLOR_SUFFIX}") (策略: ${mode_desc})"
		echo -e "  GitHub 文件镜像: ${GREEN_FONT_PREFIX}${active_file_m:-直连}${FONT_COLOR_SUFFIX}"
		echo -e "  GitHub API 镜像: ${GREEN_FONT_PREFIX}${active_api_m:-直连}${FONT_COLOR_SUFFIX}"
		echo -e "  Debian 镜像源  : ${GREEN_FONT_PREFIX}${BEST_DEBIAN_MIRROR:-${TCPX_DEBIAN_MIRROR:-自动探测}}${FONT_COLOR_SUFFIX}"
		echo -e "  ELRepo 镜像源  : ${GREEN_FONT_PREFIX}${BEST_ELREPO_MIRROR:-${TCPX_ELREPO_MIRROR:-自动探测}}${FONT_COLOR_SUFFIX}"
		echo -e "  全站通用反代   : ${YELLOW_FONT_PREFIX}${TCPX_UNIVERSAL_PROXY:-未配置}${FONT_COLOR_SUFFIX}"
		echo -e "  HTTP/SOCKS代理 : ${YELLOW_FONT_PREFIX}${TCPX_HTTP_PROXY:-未配置}${FONT_COLOR_SUFFIX}"
		echo -e "  GitHub Token   : $([[ -n "$TCPX_GITHUB_TOKEN" ]] && echo -e "${GREEN_FONT_PREFIX}已配置 (仅直连/自建反代使用)${FONT_COLOR_SUFFIX}" || echo "未配置")"
		echo -e "  严格摘要模式   : $([[ "$TCPX_STRICT_DIGEST" == "1" ]] && echo "开启 (无摘要仅直连)" || echo "关闭 (国内推荐：有摘要校验SHA256，无摘要校验魔数)")"
		echo -e " ---------------------------------------------------------"
		echo -e "  ${GREEN_FONT_PREFIX}1.${FONT_COLOR_SUFFIX} 重新测速并刷新全部最优镜像 (GitHub 文件 / API / Debian / ELRepo)"
		echo -e "  ${GREEN_FONT_PREFIX}2.${FONT_COLOR_SUFFIX} 设置自定义 GitHub 加速镜像 (同时用于 Raw / Release / API)"
		echo -e "  ${GREEN_FONT_PREFIX}3.${FONT_COLOR_SUFFIX} 设置自建全站通用反代 (加速 GitHub + XanMod + Liquorix + Brutal)"
		echo -e "  ${GREEN_FONT_PREFIX}4.${FONT_COLOR_SUFFIX} 设置 HTTP / HTTPS / SOCKS5 代理 (作用于 curl / apt / yum)"
		echo -e "  ${GREEN_FONT_PREFIX}5.${FONT_COLOR_SUFFIX} 切换网络模式 (自动检测 / 强制国内加速 / 强制海外直连)"
		echo -e "  ${GREEN_FONT_PREFIX}6.${FONT_COLOR_SUFFIX} 设置 GitHub Token (解决 API 限速，绝不发往公共镜像)"
		echo -e "  ${GREEN_FONT_PREFIX}7.${FONT_COLOR_SUFFIX} 运行全链路连通性体检"
		echo -e "  ${GREEN_FONT_PREFIX}8.${FONT_COLOR_SUFFIX} 切换严格摘要模式 (当前: ${TCPX_STRICT_DIGEST})"
		echo -e "  ${GREEN_FONT_PREFIX}9.${FONT_COLOR_SUFFIX} 清除自定义配置并恢复默认"
		echo -e "  ${GREEN_FONT_PREFIX}0.${FONT_COLOR_SUFFIX} 返回主菜单"
		echo -e " ---------------------------------------------------------"

		local sub=""
		read -rp " 请选择 [0-9]: " sub || return 0
		case "$sub" in
		1)
			rm -f /tmp/tcpx_api_cache_*.json 2>/dev/null
			BEST_DEBIAN_MIRROR=""
			BEST_ELREPO_MIRROR=""
			probe_github_mirrors
			ensure_debian_mirror
			[[ "${OS_TYPE}" == "CentOS" ]] && ensure_elrepo_mirror
			;;
		2)
			local inp=""
			echo -e "${TIP} 示例: https://gh-proxy.org/ 或 https://你的CFWorker域名/ (直接回车清除)"
			read -rp "请输入自定义 GitHub 加速镜像前缀: " inp
			if [[ -z "$inp" ]]; then
				TCPX_MIRROR=""
				TCPX_API_MIRROR=""
				echo -e "${INFO} 已清除自定义 GitHub 镜像。"
			elif [[ "$inp" =~ ^https://[^[:space:]]+$ ]]; then
				TCPX_MIRROR=$(normalize_mirror_prefix "$inp")
				TCPX_API_MIRROR="$TCPX_MIRROR"
				echo -e "${INFO} 已设置自定义 GitHub 镜像 (文件+API): ${TCPX_MIRROR}"
			else
				echo -e "${ERROR} 地址无效，必须以 https:// 开头。"
			fi
			save_accel_config
			;;
		3)
			local inp=""
			echo -e "${TIP} 配合配套 proxy/cf-worker.js 或 proxy/nginx-tcpx-proxy.conf 使用"
			echo -e "${TIP} 示例: https://proxy.example.com/ 或 https://proxy.example.com/k/密钥/ (回车清除)"
			read -rp "请输入全站通用反代前缀: " inp
			if [[ -z "$inp" ]]; then
				TCPX_UNIVERSAL_PROXY=""
				echo -e "${INFO} 已清除全站通用反代。"
			elif [[ "$inp" =~ ^https://[^[:space:]]+$ ]]; then
				TCPX_UNIVERSAL_PROXY=$(normalize_mirror_prefix "$inp")
				echo -e "${INFO} 已设置全站通用反代: ${TCPX_UNIVERSAL_PROXY}"
			else
				echo -e "${ERROR} 地址无效，必须以 https:// 开头。"
			fi
			save_accel_config
			;;
		4)
			local inp=""
			echo -e "${TIP} 示例: http://127.0.0.1:7890 或 socks5h://127.0.0.1:1080 (回车清除)"
			read -rp "请输入代理地址: " inp
			if [[ -z "$inp" ]]; then
				TCPX_HTTP_PROXY=""
				unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
				echo -e "${INFO} 已清除代理配置。"
			elif [[ "$inp" =~ ^(http|https|socks5|socks5h)://[^[:space:]]+$ ]]; then
				TCPX_HTTP_PROXY="$inp"
				apply_http_proxy_env
				echo -e "${INFO} 已启用代理: ${TCPX_HTTP_PROXY}"
			else
				echo -e "${ERROR} 代理格式无效 (支持 http://, https://, socks5://, socks5h://)。"
			fi
			save_accel_config
			;;
		5)
			local m_sel=""
			echo -e "  1) 自动检测 (auto)"
			echo -e "  2) 强制国内全链路加速 (1)"
			echo -e "  3) 强制海外直连 (0)"
			read -rp "请选择模式 [1-3]: " m_sel
			case "$m_sel" in
			1) TCPX_FORCE_CN="auto" ;;
			2) TCPX_FORCE_CN="1"; IS_CN=1 ;;
			3) TCPX_FORCE_CN="0"; IS_CN=0 ;;
			*) echo -e "${TIP} 未更改。" ;;
			esac
			save_accel_config
			check_cn_status
			;;
		6)
			local inp=""
			echo -e "${TIP} 安全说明：Token 仅用于直连 api.github.com 或你自建的私有反代，绝不会发送给任何公共镜像。"
			read -rp "请输入 GitHub PAT Token (直接回车清除): " inp
			TCPX_GITHUB_TOKEN="$inp"
			save_accel_config
			echo -e "${INFO} GitHub Token 配置已保存 (权限 600)。"
			;;
		7)
			run_accel_diagnostics
			;;
		8)
			if [[ "$TCPX_STRICT_DIGEST" == "1" ]]; then
				TCPX_STRICT_DIGEST="0"
				echo -e "${INFO} 已关闭严格摘要模式 (国内推荐：有摘要验 SHA-256，无摘要验文件魔数)。"
			else
				TCPX_STRICT_DIGEST="1"
				echo -e "${TIP} 已开启严格摘要模式 (上游无 SHA-256 的文件将仅直连 GitHub)。"
			fi
			save_accel_config
			;;
		9)
			rm -f "$ACCEL_CONF_FILE" /tmp/tcpx_api_cache_*.json
			TCPX_FORCE_CN="auto"
			TCPX_MIRROR=""
			TCPX_API_MIRROR=""
			TCPX_RAW_MIRROR=""
			TCPX_UNIVERSAL_PROXY=""
			TCPX_HTTP_PROXY=""
			TCPX_DEBIAN_MIRROR=""
			TCPX_ELREPO_MIRROR=""
			TCPX_STRICT_DIGEST="0"
			TCPX_GITHUB_TOKEN=""
			TCPX_UPDATE_URL=""
			BEST_DEBIAN_MIRROR=""
			BEST_ELREPO_MIRROR=""
			unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
			echo -e "${INFO} 已恢复全部默认配置，正在重新探测网络..."
			check_cn_status
			;;
		0)
			return 0
			;;
		*)
			echo -e "${ERROR} 无效选项。"
			;;
		esac
		echo ""
		read -rp "按回车继续..." _ || return 0
	done
}

# =================================================
#  内核安装核心引擎
# =================================================

# 清理旧的 Headers (精简重构)
remove_old_headers() {
	echo -e "${INFO} 正在清理旧的内核 Headers 防止冲突..."
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		# 找出不是当前正在运行的 kernel-headers 并卸载
		local current_ker=$(uname -r)
		rpm -qa | grep -E 'kernel(-ml|-lt|-uek|-rt|-plus)?-headers' | grep -v "$current_ker" | xargs -r rpm -e --nodeps >/dev/null 2>&1
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		dpkg -l | grep -E '(linux|proxmox|pve|raspberrypi)-headers' | awk '{print $2}' | grep -v "$(uname -r)" | xargs -r apt-get purge -y >/dev/null 2>&1
		apt-get autoremove -y >/dev/null 2>&1
	fi
}

# 终极内核安装函数
# 用法: install_kernel_generic <内核描述名称> <Headers_URL> <Image_URL> <版本号>
install_kernel_generic() {
	local kernel_desc="$1"
	local head_url="$2"
	local img_url="$3"
	local kernel_version="$4" # 新增参数，用于 UI 显示
	local head_sha256="${5:-}" # 可选: Headers 包摘要，来自受 TLS 保护的发布元数据
	local img_sha256="${6:-}"  # 可选: 内核包摘要；为空表示该源不提供摘要，此时仅依赖 TLS

	echo -e "${INFO} ================================================"
	if [[ -n "$kernel_version" ]]; then
		echo -e "${INFO} 开始安装: ${kernel_desc} (版本: \033[32m${kernel_version}\033[0m)"
	else
		echo -e "${INFO} 开始安装: ${kernel_desc}"
	fi
	echo -e "${INFO} ================================================"

	# 只强制检查 img_url，因为某些内核（如 Cloud）本身可能不强制要求 Headers
	if [[ -z "$img_url" ]]; then
		echo -e "${ERROR} 传入的镜像文件下载链接为空，可能是 API 解析失败或上游移除了文件！"
		return 1
	fi

	# 创建独立的工作目录 (mktemp 避免 /tmp 下可预测目录名被抢先创建)
	local work_dir
	work_dir=$(mktemp -d /tmp/kernel_install.XXXXXX) || {
		echo -e "${ERROR} 无法创建临时目录！"
		return 1
	}
	# apt 会用沙箱用户 _apt 访问此目录；700 权限会触发 "unsandboxed" 警告。
	# 755 仅允许读/遍历，.deb 文件本身仍由 root 拥有，不存在安全问题。
	chmod 755 "$work_dir"
	trap 'cd /tmp; rm -rf "$work_dir"; trap - RETURN' RETURN
	cd "$work_dir" || {
		echo -e "${ERROR} 无法进入临时目录 ${work_dir}！"
		return 1
	}

	# 安装前记录 /boot 中已有的内核镜像数量，用于事后验证是否真的装上了
	local vmlinuz_before=$(ls -1 /boot/vmlinuz-* 2>/dev/null | wc -l)

	# 根据系统执行不同的下载和安装逻辑
	# 关键顺序: 先把所有包下载并校验完成，再清理旧 headers，最后安装。
	# 若先清理后下载，一旦下载失败就会停在"旧 headers 已删、新内核没装"的破损状态。
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		local head_file="kernel-headers.rpm"
		local img_file="kernel-image.rpm"

		[[ -n "$head_url" ]] && { safe_wget "$head_url" "$head_file" "$head_sha256" || return 1; }
		safe_wget "$img_url" "$img_file" "$img_sha256" || return 1

		# 下载全部成功后才动系统
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

		# 下载全部成功后才动系统
		remove_old_headers

		deb_list+=("./$img_file")
		[[ -n "$head_url" && -s "$head_file" ]] && deb_list+=("./$head_file")

		# 用 apt-get install ./xxx.deb 取代 dpkg -i + apt-get -f。
		# 前者是事务性的: 会自动从源里解析 linux-modules-* 等依赖，失败时干净回滚；
		# 后者在依赖无解时 apt-get -f 可能选择"卸载刚装上的内核"来修复，且返回值常为 0。
		echo -e "${INFO} 正在执行 APT 安装 (自动解析依赖)..."
		if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${deb_list[@]}"; then
			echo -e "${ERROR} 内核包安装失败，依赖无法满足或包不兼容当前系统！"
			echo -e "${TIP} 系统未被改动，可尝试菜单 [4] 中的 'a' 自动探测可安装版本。"
			return 1
		fi
	fi

	# 验证内核镜像确实就位，避免"装失败却报成功"。
	# apt-get install ./deb 已返回成功，说明包已在系统里 (新装或早已安装)；
	# 这里只防御 apt-get -f 把刚装的内核又自动卸掉的情况——那会让镜像数"不增反减"。
	# 数目持平属正常 (目标内核本就已安装的幂等重跑)，不算失败，需继续处理 headers。
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
		# 适配新编译的 CentOS Cloud 内核
		tag_kw="CentOS_Kernel_Cloud"
		arch_kw="x86_64"
		# 【核心修复 1】直接匹配 kernel-加数字，从源头完美避开 headers 和 devel
		img_kw="kernel-[0-9]"
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		# 适配新编译的 Debian Cloud 内核
		tag_kw="Debian_Kernel_Cloud"
		arch_kw="amd64"
		img_kw="image" # Debian dpkg 生成的包名为 linux-image 开头
		if [[ "$OS_ARCH" == "aarch64" ]]; then
			tag_kw="Debian_Kernel_(Cloud.*arm64|[0-9.]+_latest_arm64)"
			arch_kw="arm64"
		fi
	fi

	echo -e "${INFO} 正在向 Github/ylx2016 请求最新 ${tag_kw} 内核数据..."

	# 获取下载链接 (现在抓取到的绝对纯净，无需二次 grep -v)
	# 返回 "URL<TAB>sha256"：摘要在下载阶段绑定镜像返回的字节
	local head_meta img_meta head_sha="" img_sha=""
	head_meta=$(get_github_asset "ylx2016/kernel" "${tag_kw}" "headers" "${arch_kw}") || return 1
	img_meta=$(get_github_asset "ylx2016/kernel" "${tag_kw}" "${img_kw}" "${arch_kw}") || return 1
	head_url="${head_meta%%$'	'*}"
	img_url="${img_meta%%$'	'*}"
	[[ "$head_meta" == *$'	'* ]] && head_sha="${head_meta#*$'	'}"
	[[ "$img_meta" == *$'	'* ]] && img_sha="${img_meta#*$'	'}"

	# 【核心修复 2】版本号仅用于界面显示：只从文件名 (${img_url##*/}) 中提取，切勿扫描整条 URL。
	# 因为发布 tag 内含构建日期 (如 Debian_Kernel_Cloud_7.2_bbr_2026.08.18-0005)，整条 URL 的首个
	# N.N.N 会误命中日期 2026.08.18；而文件名 linux-image-7.2.0_... 的首个 N.N.N 才是真内核版本。
	# 用 -oE 标准正则 (而非 -P) 以兼容不支持 PCRE 的老系统。
	local kernel_version=$(echo "${img_url##*/}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)

	if [[ -n "$kernel_version" ]]; then
		echo -e "${INFO} 解析成功！获取到的最新云端内核版本为: \033[32m${kernel_version}\033[0m"
	else
		echo -e "${INFO} 解析成功！已获取到下载链接，但未能匹配出纯净版本号。"
	fi

	# 将解析出的版本号作为第四个参数传递给安装函数
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
	# Debian 的包名为 linux-image-*，而 RPM 的包名是 kernel-<版本号>，二者必须区分
	local img_kw="image"

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		ext="rpm"
		arch_kw="x86_64"      # RPM 文件名用 x86_64，沿用 amd64 会过滤为空
		img_kw="kernel-[0-9]" # 直接匹配 kernel-加数字，从源头避开 headers/devel
		[[ "$OS_ARCH" == "aarch64" ]] && arch_kw="aarch64"
	else
		[[ "$OS_ARCH" == "aarch64" ]] && arch_kw="arm64"
	fi

	echo -e "${INFO} 正在向 UJX6N/bbrplus-6.x_stable 请求数据..."
	# 利用精准的参数向下传递
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
#  自动探测 Cloud 内核最高可安装版本 (依赖解析)
# =================================================
# 抓取 pool 目录清单，抽出所有 headers/kbuild 的 .deb 文件名 (供 headers 解析/校验复用)
fetch_cloud_pool_listing() {
	ensure_debian_mirror
	local pool_url="$CLOUD_HDR_POOL"
	if [[ -n "$TCPX_UNIVERSAL_PROXY" ]] && ! is_cn_domestic_mirror_url "$pool_url"; then
		pool_url=$(build_mirror_url "$TCPX_UNIVERSAL_PROXY" "$pool_url" 1)
	fi
	# 兼容阿里云(&#43;)与腾讯云/清华(%2b/%2B/%7e)等不同镜像站索引页的编码差异，统一归一化去重
	curl -q -sL --max-time 15 "$pool_url" |
		sed 's/&#43;/+/g; s/%2[bB]/+/g; s/%7[eE]/~/g' |
		grep -oE '(linux-headers|linux-kbuild)-[^"<> /]+\.deb' |
		sort -Vu
}

# 由 cloud image 文件名推导配套的三件 headers 包 (arch专属 + -common + kbuild) 文件名。
# 参数: <image文件名> <debarch> <pool清单>；每行输出一个清单中确实存在的 .deb 文件名；无 arch headers 时返回 1。
resolve_cloud_header_debs() {
	local img_file="$1" debarch="$2" listing="$3"
	local abi base
	abi=$(echo "$img_file" | sed -nE "s/^linux-image-(.*-cloud-${debarch})_.*/\1/p")
	[[ -z "$abi" ]] && return 1
	base="${abi%-cloud-${debarch}}" # 6.17.13+deb13-cloud-amd64 -> 6.17.13+deb13

	# 先用 arch 专属 headers 定位版本号，再据此锁定同版本 common / kbuild，避免版本错配
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

# 模拟校验某 cloud 内核的配套 headers 三件套依赖能否干净满足 (口径与镜像校验一致)。
# 参数: <image文件名> <debarch> <pool清单> <下载工作目录>；可满足返回 0，否则返回 1。
check_cloud_headers_installable() {
	local img_file="$1" debarch="$2" listing="$3" scan_dir="$4"
	local hdr_files
	hdr_files=$(resolve_cloud_header_debs "$img_file" "$debarch" "$listing") || return 1
	[[ -z "$hdr_files" ]] && return 1

	local debs=() hf
	while read -r hf; do
		[[ -z "$hf" ]] && continue
		safe_wget "${CLOUD_HDR_POOL}${hf}" "${scan_dir}/${hf}" >/dev/null 2>&1 || return 1
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

# 用法: detect_cloud_max <img_url_base> <need_headers:0|1> <debarch> <file1> <file2> ...
# 原理: pool 中混着 stable/testing/sid/experimental 全部内核，版本号最大 ≠ 能装。
#       太新的内核依赖独立的 linux-modules-*-cloud-* 包（只存在于其自身发行版源），
#       并可能要求更新的 linux-base / initramfs-tools / libc6。因此从新到旧逐个
#       下载 image 包交给 `apt-get install -s` 做模拟安装(真实依赖解析器)，第一个
#       “干净解析”的版本即当前系统最高可安装版本。
#       need_headers=1 时还会额外模拟其配套 Headers 三件套，镜像与 Headers 都干净才选中，
#       以此避开 +debN backports 这类"镜像能装、Headers 因 glibc/工具链过新装不了"的内核。
# 结果写入全局变量 CLOUD_MAX_IDX / CLOUD_MAX_FILE (仍为 -1 / 空 表示无可用版本)
CLOUD_MAX_IDX=-1
CLOUD_MAX_FILE=""
detect_cloud_max() {
	local img_url_base="$1"
	local need_headers="$2" # 1 = 同时要求配套 headers 依赖也可满足
	local debarch="$3"
	shift 3
	local versions_array=("$@")
	CLOUD_MAX_IDX=-1
	CLOUD_MAX_FILE=""

	local scan_work
	scan_work=$(mktemp -d /tmp/cloud_kernel_scan.XXXXXX) || return 1
	trap 'cd /tmp; rm -rf "$scan_work"; trap - RETURN' RETURN
	cd "$scan_work" || return 1

	# 需要连 headers 一起校验时，预取一次 pool 清单循环复用 (所有版本共用同一 pool)
	local hdr_listing=""
	[[ "$need_headers" == "1" ]] && hdr_listing=$(fetch_cloud_pool_listing)

	# 提速优化：candidate 文件名里的 +debN 表示该内核面向哪个 Debian 大版本。
	# 当前系统若是纯 Debian，凡 +debN 高于本机大版本的候选，其 Headers 必然依赖更新的
	# glibc/工具链 (如 deb13 headers 需 glibc≥2.38 而 deb12 只有 2.36) — 直接跳过不下载，
	# 免去逐个下载+apt 模拟才发现装不上的耗时。仅在 need_headers 时启用 (只装镜像时高版本仍可用)。
	# Ubuntu 等衍生系 OS_VERSION_ID 语义不同 (如 24.04) 无法与 debN 比较，故仅限 OS_ID=debian。
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
		# 校验是合法 ar 归档，防止半截包造成误判
		if ! head -c 8 probe.deb | grep -q "!<arch>"; then
			rm -f probe.deb
			continue
		fi

		# 必须强制 LC_ALL=C: 下面全部靠 grep apt 的英文输出判断依赖是否可满足，
		# 在 zh_CN 等非英文 locale 下 apt 输出被翻译，所有 grep 都匹配不到，
		# 会导致每个版本都被误判为"依赖可干净满足"，本函数彻底失效。
		local scan_log=$(LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get install -s --no-install-recommends "./probe.deb" 2>&1)
		rm -f probe.deb

		local ok=1
		# 1) 依赖无法满足 / 包破损
		if echo "$scan_log" | grep -qiE "unmet dependencies|broken packages|E: "; then
			ok=0
		fi
		# 2) 会卸载现有软件包 = 必然冲突
		if echo "$scan_log" | grep -q "will be REMOVED"; then
			ok=0
		fi
		# 3) 会升级到跨发行版核心基础库 (libc6/base-files/dpkg/systemd) = 硬装，跳过。
		#    允许升级 linux-base/initramfs-tools 等内核生态包 (当前源内可正常解决)
		if echo "$scan_log" | grep -q "will be upgraded"; then
			local upgraded=$(echo "$scan_log" | sed -n '/will be upgraded/,/^[^ ]/p' | tail -n +2)
			if echo "$upgraded" | grep -qwE "libc6|base-files|dpkg|systemd|systemd-sysv|bash|login|tzdata"; then
				ok=0
			fi
		fi

		if [[ $ok -eq 1 ]]; then
			# 镜像依赖 OK；若还要求 headers，则继续校验配套 headers 依赖，两者都过才收下
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
	# 临时目录由 RETURN trap 统一清理
}

# 确保 Debian Cloud 内核的配套 Headers 完整安装 (arch 专属 + -common + linux-kbuild)。
# 内核镜像单独安装 (installcloud 给 install_kernel_generic 传空 headers)，headers 改在此处从 pool
# 直取三件套后离线 apt 安装；这样即便是 backports (~bpoN) 内核、系统又没启用 backports 源，也能装全依赖。
ensure_cloud_headers() {
	local img_file="$1"
	local debarch="$2"

	# 从镜像文件名提取 ABI，如 6.17.13+deb13-cloud-amd64
	local abi
	abi=$(echo "$img_file" | sed -nE "s/^linux-image-(.*-cloud-${debarch})_.*/\1/p")
	[[ -z "$abi" ]] && return 0

	# 已存在编译用的 build 目录 (headers 完整) 则无需再动
	if [[ -d "/lib/modules/${abi}/build" || -d "/usr/src/linux-headers-${abi}" ]]; then
		echo -e "${INFO} 内核 ${abi} 的配套 Headers 已就绪，可直接编译内核模块。"
		return 0
	fi

	echo -e "${INFO} 正在为内核 ${abi} 补齐配套 Headers (arch + -common + kbuild，从 pool 直取以兼容 backports)..."
	local listing hdr_files
	listing=$(fetch_cloud_pool_listing)
	hdr_files=$(resolve_cloud_header_debs "$img_file" "$debarch" "$listing")
	if [[ -z "$hdr_files" ]]; then
		echo -e "${TIP} pool 中未找到 ${abi} 的 headers，已跳过 (内核镜像不受影响，仅暂无法编译模块)。"
		return 0
	fi

	# 下载三件套到临时目录，一次性 apt 离线安装 (依赖自洽，无需启用 backports 源)
	local work_dir debs=() f
	work_dir=$(mktemp -d /tmp/cloud_hdr.XXXXXX) || {
		echo -e "${TIP} 无法创建临时目录，已跳过 headers。"
		return 0
	}
	chmod 755 "$work_dir"
	while read -r f; do
		[[ -z "$f" ]] && continue
		safe_wget "${CLOUD_HDR_POOL}${f}" "${work_dir}/${f}" && debs+=("${work_dir}/${f}")
	done <<<"$hdr_files"

	local apt_out rc=1
	if [[ ${#debs[@]} -gt 0 ]]; then
		apt_out=$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${debs[@]}" 2>&1)
		rc=$?
	fi
	if [[ $rc -eq 0 ]]; then
		echo -e "${INFO} 配套 Headers 已装好，可正常编译 LotSpeed / brutal 等内核模块。"
	elif printf '%s' "$apt_out" | grep -qE 'libc6 \(>= 2\.(3[89]|[4-9])|t64 |gcc-[0-9]+-for-host'; then
		# 跨发行版内核 (如 +debN backports) 的 Headers 依赖更新的 glibc/工具链，当前较旧系统满足不了。
		# 内核镜像本身是自包含的能装上，但 Headers 编译环境装不了——与之前 LotSpeed 的 GLIBC_2.38 同源。
		echo -e "${TIP} Headers 无法安装：内核 ${abi} 是较新发行版的 backports 版，其 Headers 依赖更新的 glibc/工具链，"
		echo -e "${TIP}       与当前系统 (Debian $(cat /etc/debian_version 2>/dev/null)) 不兼容。内核镜像不受影响。"
		echo -e "${TIP} 建议：仅用 BBR 无需 Headers，重启进新内核即可；若要编译模块，请改装与本系统同发行版的 Cloud 内核"
		echo -e "${TIP}       (菜单里选不带 +debN 的版本，或输入 'h' 走 apt 装配套 headers)。"
	else
		echo -e "${TIP} Headers 安装未完成 (下载失败或依赖冲突)，内核镜像不受影响；如需编译请重启后手动安装。"
	fi
	rm -rf "$work_dir"
}

# 安装官方 Cloud 内核
installcloud() {
	pre_install_check || return 1

	[[ "${OS_TYPE}" != "Debian" ]] && {
		echo -e "${ERROR} Cloud 内核仅支持 Debian 系系统"
		return 1
	}

	# Ubuntu 及衍生版：没有 Debian 那套 pool/+debN 云内核，逐版本探测无从谈起 (deb.debian.org
	# 的包名与 Ubuntu apt 对不上，'linux-image-cloud-amd64' 在 Ubuntu 也不存在)。
	# Ubuntu 的云/虚拟机等价物是 apt 元包 linux-image-virtual，直接走 apt 最稳妥。
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

	ensure_debian_mirror
	local img_url_base="${BEST_DEBIAN_MIRROR}/pool/main/l/linux-signed-${debarch}/"
	local img_pattern='linux-image-[^"<> /]+cloud-'"${debarch}"'_[^"<> /]+_'"${debarch}"'\.deb'

	echo -e "${INFO} 正在从 Debian 镜像源 (${BEST_DEBIAN_MIRROR}) 获取 Cloud 内核列表..."
	local list_url="$img_url_base"
	if [[ -n "$TCPX_UNIVERSAL_PROXY" ]] && ! is_cn_domestic_mirror_url "$list_url"; then
		list_url=$(build_mirror_url "$TCPX_UNIVERSAL_PROXY" "$list_url" 1)
	fi
	local deb_files
	deb_files=$(curl -q -sL --max-time 15 "$list_url" |
		sed 's/&#43;/+/g; s/%2[bB]/+/g; s/%7[eE]/~/g' |
		grep -oE "$img_pattern" | sort -Vu)
	if [[ -z "$deb_files" ]]; then
		echo -e "${ERROR} 未找到可用的 Cloud 内核版本，请检查网络！"
		return 1
	fi
	mapfile -t versions_array <<<"$deb_files"

	# ---- 读取上次记录的最高可安装版本 (用于默认选中与高亮提示) ----
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

	# ---- 展示全部版本 (保持原始行为) ----
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
	# 内核安装不可逆，超时一律取消而非自动执行；60 秒留足阅读上面版本列表的时间
	if ! read -t 60 -rp "输入选项 [0-${last_idx} / a / h / q 取消，回车默认 ${def_label}]: " choice; then
		echo ""
		echo -e "${TIP} 等待超时，出于安全考虑已自动取消操作 (未做任何更改)。"
		return 0
	fi

	# ---- q: 显式取消 ----
	if [[ "$choice" =~ ^[qQ]$ ]]; then
		echo -e "${INFO} 已取消操作。"
		return 0
	fi

	# ---- a: 自动逐个尝试判断最高可安装版本 ----
	if [[ "$choice" =~ ^[aA]$ ]]; then
		# 先问是否需要 Headers：只装内核跑 BBR 不需要 Headers；要编译 LotSpeed/brutal 等模块才需要。
		# 需要时探测会同时校验内核镜像 + 配套 Headers 依赖，只有两者都能干净安装的版本才会被选中，
		# 从而自动避开像 +debN backports 这种"镜像能装、Headers 因 glibc/工具链过新装不了"的内核。
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
		# 记忆本次探测结果，下次进入默认选中
		echo "$CLOUD_MAX_FILE" >"$CLOUD_STATE_FILE"
		echo -e "${INFO} 探测完成！当前系统最高可安装版本: ${GREEN_FONT_PREFIX}${CLOUD_MAX_FILE}${FONT_COLOR_SUFFIX}，开始安装..."
		if install_kernel_generic "Debian 官方 Cloud" "" "${img_url_base}${CLOUD_MAX_FILE}"; then
			[[ $need_headers -eq 1 ]] && ensure_cloud_headers "$CLOUD_MAX_FILE" "$debarch"
		fi
		return 0
	fi

	# ---- h: 直接使用 apt 安装当前发行版云内核 ----
	if [[ "$choice" =~ ^[hH]$ ]]; then
		echo -e "${INFO} 正在使用 apt 安装 Cloud 内核及 Headers..."
		apt-get update >/dev/null 2>&1
		apt-get install -y "linux-image-cloud-${debarch}" "linux-headers-cloud-${debarch}"
		BBR_grub
		return 0
	fi

	# ---- 数字选择或回车默认 ----
	choice=${choice:-$default_idx}
	if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -gt "$last_idx" ]; then
		echo -e "${TIP} 无效选项，默认安装 ${default_idx} 号版本..."
		choice=$default_idx
	fi

	local selected_file="${versions_array[$choice]}"
	# 内核镜像单独安装 (headers 交给 ensure_cloud_headers 从 pool 直取，避免依赖拖垮镜像安装)
	if install_kernel_generic "Debian 官方 Cloud" "" "${img_url_base}${selected_file}"; then
		ensure_cloud_headers "$selected_file" "$debarch"
	fi
}

# 从 Release (kernels) 拉取指定内核二进制整包并解压到目标目录。
# name 为 bbr / bbrplus / lotserver 之一；解压后目录结构与原仓库一致 (如 lotserver/centos/7/x64/...)。
# 注意：整包体积较大 (lotserver 约 437MB)，仅在真正需要安装对应内核时才调用。
fetch_kernel_archive() {
	local name="$1"
	local dest="$2"
	local tarball="${dest}/${name}.tar.gz"

	echo -e "${INFO} 正在从 Release 下载 ${name} 内核整包 (体积较大，已自动启用国内加速节点)..."
	local archive_sha=""
	archive_sha=$(get_release_asset_digest "ylx2016/Linux-NetSpeed" "kernels" "${name}.tar.gz" 2>/dev/null) || archive_sha=""
	if ! safe_wget "${KERNEL_RELEASE_BASE}/${name}.tar.gz" "$tarball" "$archive_sha"; then
		echo -e "${ERROR} ${name} 内核整包下载失败！"
		return 1
	fi
	# 解压前先列成员：拒绝绝对路径与 .. 片段，避免归档把文件写到工作目录之外。
	# tar 自身的默认策略随版本不同（CentOS 6 tar 1.23 与 7 的 1.26 行为有差异），
	# 这里显式校验，不依赖解压器的版本相关默认值。
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
	# 名称合法不代表链接目标合法；仓库型归档常见相对符号链接，故允许 symlink，
	# 但解压后必须复核每个链接都仍落在目标目录内。硬链接/设备/FIFO 一律拒绝。
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

	# 上游仅提供 CentOS 6/7 的 Lotserver 内核包，8/9/10 请求的是不存在的路径
	if [[ "${OS_TYPE}" == "CentOS" && "${OS_VERSION_ID}" != "6" && "${OS_VERSION_ID}" != "7" ]]; then
		echo -e "${ERROR} Lotserver 内核仅支持 CentOS 6/7，当前为 CentOS ${OS_VERSION_ID}！"
		return 1
	fi

	local work_dir
	work_dir=$(mktemp -d /tmp/lot_install.XXXXXX) || {
		echo -e "${ERROR} 无法创建临时目录！"
		return 1
	}
	# 无论从哪条路径返回，都保证清理临时目录且回到安全的 CWD
	trap 'cd /tmp; rm -rf "$work_dir"; trap - RETURN' RETURN
	cd "$work_dir" || {
		echo -e "${ERROR} 无法进入临时目录 ${work_dir}！"
		return 1
	}

	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		local lot_ver="4.11.2-1" # CentOS 7 默认
		[[ "${OS_VERSION_ID}" == "6" ]] && lot_ver="2.6.32-504"

		# 内核包已迁移到 Release：下载 lotserver 整包并解压，再从本地目录取用对应文件
		if ! fetch_kernel_archive "lotserver" "$work_dir"; then
			echo -e "${ERROR} Lotserver 内核包获取失败，已中止 (系统未做任何更改)。"
			return 1
		fi
		local lot_dir="${work_dir}/lotserver/centos/${OS_VERSION_ID}/x64"

		# 校验 4 个包解压后确实存在，缺任意一个都中止 (避免删了旧包却没装上新包)
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
		# 显式列出文件名，避免下载失败时把字面量 *.rpm 传给 yum
		if ! yum install -y "${lot_dir}/kernel-firmware-${lot_ver}.rpm" "${lot_dir}/kernel-${lot_ver}.rpm" "${lot_dir}/kernel-headers-${lot_ver}.rpm" "${lot_dir}/kernel-devel-${lot_ver}.rpm"; then
			echo -e "${ERROR} Lotserver 内核安装失败！"
			return 1
		fi

	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		# Debian/Ubuntu 走老旧的 snapshot.debian.org 源
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

# 询问本机用途，决定"场景相关"参数(内核转发/合包/conntrack)。其余基座参数三种场景通用。
# 交互提示走 stderr，仅最终结果(web/proxy/forward)走 stdout，便于 $(...) 捕获。
# 10 秒无输入或直接回车 → 默认 proxy(机场代理)。
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

# IPv6 转发与 SLAAC 共存：保留原 RA 策略，只把“作为主机接收”(1)提升为“转发时也接收”(2)。
# 不根据默认路由猜网卡（故障后路由可能已经消失），不修改 all.accept_ra（它不会广播到接口）。
# 显式 0 也要逐接口持久化，否则重启时可能继承 default=2，意外打开 RA。
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
		# 斜杠形式保留 ens3.100 等接口名里的点。不能加前导 -，旧 systemd/procps 不识别。
		printf -v config '%snet/ipv6/conf/%s/accept_ra = %s\n' "$config" "$iface" "$ra"
	done
	[[ -n "$config" ]] || return 0
	printf '# BEGIN TCPX IPv6 RA\n# 1→2 兼容转发；0 保留禁用/用户态 RA。自定义覆盖请写在本块之后。\n%s# END TCPX IPv6 RA\n' "$config"
}

# 旧安装迁移：仅在 tcpx 自己的配置启用了 IPv6 全局转发时补齐 RA。
# 自动迁移一次；菜单 [39] 可按当前策略刷新。块放在前面，不盖掉用户在原文件里的显式设置。
ensure_ipv6_ra_config() {
	local conf="/etc/sysctl.d/99-sysctl.conf" ra_config tmp
	[[ -f "$conf" ]] || return 0
	# 保留管理员的符号链接关系；临时文件、备份和原子替换都落在真实目标旁。
	conf=$(readlink -f -- "$conf") || {
		echo -e "${ERROR} 无法解析 sysctl 配置真实路径，本次不修改或应用。" >&2
		return 1
	}
	grep -Eq '^[[:space:]]*net\.ipv6\.conf\.all\.forwarding[[:space:]]*=[[:space:]]*1([[:space:]#;]|$)' "$conf" || return 0
	# 同时校验配对、顺序及重复；只数 BEGIN/END 个数会在倒序时截掉用户配置。
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

# 检查实际接口，不能用 all.accept_ra 或 sysctl 的退出码代替。
# RA=0 可能属于 networkd/NM 用户态 RA，不能强制开启；也不擅自改 autoconf/IPv6 开关。
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

# 所有脚本内的 sysctl 重载共用此入口：先迁移旧配置，再应用，最后检查实际 RA 状态。
# stdout 仍可由调用方隐藏，但不能再把错误和 IPv6 冲突一起吞掉。
apply_sysctl() {
	ensure_ipv6_ra_config || return 1
	local status=0
	# -e 只容忍不存在的键（如尚未创建的网卡），权限/值错误仍会报出；兼容旧 procps。
	sysctl -e --system || status=$?
	# 未使用 tcpx 转发优化的路由器可能有意靠 RA=1 拒收 RA，不能因切 BBR 而干预它。
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
#  系统级网络与资源自适应优化 (替换旧版优化)
# =================================================
optimizing_system() {
	# 与 tcpfit 共存时让路：tcpfit 会按实测 BDP/内存推导整套 sysctl，并刻意省略
	# 某些参数 (如 tcp_notsent_lowat)。本函数整文件覆盖会与其重叠、甚至塞回它故意
	# 不设的项，且因 99-tcpfit.conf 加载在后而多半失效。故先警告并要求显式确认。
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

	# 1. 动态获取系统硬件与内核参数
	local total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
	local total_mem_mb=$((total_mem_kb / 1024))
	local cpu_cores=$(nproc)
	local kernel_major=$(uname -r | cut -d. -f1)
	local kernel_minor=$(uname -r | cut -d. -f2)

	# 新增：动态获取当前正在使用的拥塞控制算法，防止覆盖 LotSpeed 或其它自定义算法
	local current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "bbr")
	local current_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "fq")
	[[ "$current_cc" == "unknown" || -z "$current_cc" ]] && current_cc="bbr"
	[[ "$current_qdisc" == "unknown" || -z "$current_qdisc" ]] && current_qdisc="fq"

	# 同理继承当前 IPv6 开关状态。
	# 否则用户先执行 [35] 禁用 IPv6、再执行 [32] 网络优化时，
	# 本函数会无条件写回 disable_ipv6 = 0，把 IPv6 静默重新打开。
	local current_disable_ipv6=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "0")
	[[ "$current_disable_ipv6" != "1" ]] && current_disable_ipv6="0"
	if [[ "$current_disable_ipv6" == "1" ]]; then
		echo -e "${TIP} 检测到当前已禁用 IPv6，本次优化将保持该状态 (如需开启请用菜单 [36])。"
	fi

	# 1.5 询问本机用途，决定场景相关参数(合包/conntrack)，其余基座参数通用。
	#     内核转发按用户要求默认全开，不再随用途区分。
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

	# 2. 根据内存大小动态适配 (socket 缓冲上限 / 并发连接 / 文件描述符)
	#    注意: sock_buf_max 只是"每 socket 自动调优的上限"，不是默认值。默认值必须
	#    保持很小 (见下方 rmem_default/wmem_default)，否则每条连接都按上限预留内存，
	#    高并发下极易 OOM —— 这是旧版最严重的负优化 (8G 机器默认缓冲写到了 64MB)。
	local sock_buf_max somaxconn file_max syn_backlog
	if [ "$total_mem_mb" -ge 8192 ]; then
		# 8GB 及以上高配机器: 每 socket 上限 64MB (足够覆盖高 BDP 链路，且不虚高)
		sock_buf_max=67108864
		somaxconn=1048576
		file_max=2097152
		syn_backlog=65535
	elif [ "$total_mem_mb" -ge 2048 ]; then
		# 2GB - 8GB 中等配置: 32MB
		sock_buf_max=33554432
		somaxconn=65535
		file_max=1048576
		syn_backlog=32768
	else
		# 2GB 以下小内存机器: 16MB
		sock_buf_max=16777216
		somaxconn=32768
		file_max=524288
		syn_backlog=16384
	fi

	# 3. 根据 CPU 核心数动态适配网卡队列与积压
	local netdev_max_backlog=$((10000 * cpu_cores))
	[[ $netdev_max_backlog -lt 32768 ]] && netdev_max_backlog=32768
	[[ $netdev_max_backlog -gt 100000 ]] && netdev_max_backlog=100000

	local netdev_budget=$((300 + 20 * cpu_cores))
	[[ $netdev_budget -gt 50000 ]] && netdev_budget=50000

	# 在清空旧文件、开启转发之前保存接口 RA 策略；读取失败时不继续写配置。
	local ra_config
	ra_config=$(render_ipv6_ra_config) || return 1

	# 4. 生成统一的 sysctl 配置文件
	local sysctl_conf="/etc/sysctl.d/99-sysctl.conf"

	# 备份并清空原文件（比几十行 sed -i 速度快且更安全）
	[[ -f "$sysctl_conf" ]] && cp "$sysctl_conf" "${sysctl_conf}.bak"
	cat /dev/null >"$sysctl_conf"

	# 写入基础通用优化 (兼容 CentOS 7-9, Debian 9-12, Ubuntu 18-24)
	cat >>"$sysctl_conf" <<EOF
# --- 文件系统与内存基础 ---
fs.file-max = $file_max
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = $file_max
# 现代 64 位内核默认 pid_max 已是 4194304，旧版写死 65535 反而是"降级"，
# 高进程/线程数场景 (大量容器、Go/Java 服务) 会 fork 失败。取现代默认值。
kernel.pid_max = 4194304
vm.swappiness = 1

# --- 网络核心队列与连接数 ---
net.core.somaxconn = $somaxconn
net.core.netdev_max_backlog = $netdev_max_backlog
net.core.netdev_budget = $netdev_budget
net.core.rmem_max = $sock_buf_max
net.core.wmem_max = $sock_buf_max
# 默认收发缓冲保持较小，由内核在 min~max 间自动放大即可；
# 切勿设成上限的一半 (旧版在 8G 机上把默认写到 64MB，空闲连接也吃满，属严重负优化)。
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
# tcp_max_syn_backlog 单列一个更保守的值 (不再跟 somaxconn 绑死到百万级)，
# 半开连接队列过大意义有限且吃内存；配合 syncookies=1 足以应对 SYN 洪水。
net.ipv4.tcp_max_syn_backlog = $syn_backlog
# tcp_no_metrics_save=1: 不缓存上条连接的 RTT/cwnd 指标，避免一次抖动的坏指标
# 拖累后续新连接的初始拥塞窗口 (旧版设为 0 会保存陈旧指标，属负优化)。
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1

# --- TCP 超时、重传与 KeepAlive 优化 ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 2
net.ipv4.tcp_fin_timeout = 15
# synack_retries 旧版=1：弱网/丢包客户端收不到 SYN-ACK 就直接连不上(网站可达性、
# 代理手机端连接失败)。取 2，在抗 SYN 洪水与可用性之间折中。
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
# tw_buckets 旧版 5000 过低：繁忙代理/服务器一旦超过就强杀 TIME_WAIT，
# 引发端口复用异常与 RST。配合 tcp_tw_reuse=1，取一个更从容的值。
net.ipv4.tcp_max_tw_buckets = 55000
net.ipv4.tcp_fastopen = 3

$ra_config

# --- 路由转发 (默认全开，兼容 Docker/Tailscale/WireGuard 等；route_localnet 已按安全建议移除) ---
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

	# 4.1 场景相关：繁忙中转/转发节点抬高连接跟踪表上限，避免 conntrack 打满丢连接。
	#     nf_conntrack 模块未加载时该键不存在，sysctl 载入会忽略(告警已抑制)，故无害。
	if [[ "$tune_conntrack" -eq 1 ]]; then
		local ct_max=262144
		local ct_hashsize=$((ct_max / 4))
		# nf_conntrack 的 sysctl 键只在模块加载后才存在；先加载并持久化 (modules-load.d)，
		# 否则重启后该键缺失、nf_conntrack_max 设置会静默丢失。
		modprobe nf_conntrack >/dev/null 2>&1
		echo "nf_conntrack" >/etc/modules-load.d/tcpx-conntrack.conf
		# 只加大 max 不加大 hashsize(桶数) 会让哈希链变长、查表变慢。
		# hashsize 经验取 max/4，用 modprobe 选项持久化 (重启加载模块时生效)，并对当前已加载模块即时生效。
		echo "options nf_conntrack hashsize=${ct_hashsize}" >/etc/modprobe.d/tcpx-conntrack.conf
		[[ -w /sys/module/nf_conntrack/parameters/hashsize ]] &&
			echo "$ct_hashsize" >/sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
		cat >>"$sysctl_conf" <<EOF

# --- 连接跟踪 (用途=代理/转发，繁忙节点防 conntrack 表溢出) ---
net.netfilter.nf_conntrack_max = $ct_max
EOF
	fi

	# 5. 根据内核版本进行高级参数兼容
	# 移除低版本废弃参数: net.ipv4.tcp_tw_recycle (在内核 4.12 中已彻底移除，高版本强制写入会报错)
	if [[ "$kernel_major" -lt 4 || ("$kernel_major" -eq 4 && "$kernel_minor" -lt 12) ]]; then
		echo "net.ipv4.tcp_tw_recycle = 0" >>"$sysctl_conf"
	fi

	# 移除低版本废弃参数: net.ipv4.tcp_fack (在内核 4.11 中已废弃，合并到了通用重传逻辑中)
	if [[ "$kernel_major" -lt 4 || ("$kernel_major" -eq 4 && "$kernel_minor" -lt 11) ]]; then
		echo "net.ipv4.tcp_fack = 1" >>"$sysctl_conf"
	fi

	# 6. 系统资源限制极限优化 (systemd 与 limits.conf)
	echo -e "${INFO} 正在根据内存大小自动优化系统文件描述符限制..."

	# 优化 Systemd 配置
	if [[ -d "/etc/systemd" ]]; then
		# 整文件覆盖前先备份用户原有配置。仅在 .bak 不存在时备份，
		# 避免重复运行本函数时用"已被我们改写过的版本"覆盖掉最初的原始文件。
		[[ -f /etc/systemd/system.conf && ! -f /etc/systemd/system.conf.bak ]] &&
			cp /etc/systemd/system.conf /etc/systemd/system.conf.bak
		cat >/etc/systemd/system.conf <<EOF
[Manager]
DefaultTimeoutStopSec=30s
# core dump 关闭：崩溃 core 可能含 TLS 私钥/代理凭据且会撑爆磁盘，故禁用。
DefaultLimitCORE=0
DefaultLimitNOFILE=$file_max
DefaultLimitNPROC=infinity
DefaultTasksMax=infinity
EOF
		systemctl daemon-reload >/dev/null 2>&1
	fi

	# 优化 limits.conf (同样先备份原始文件，仅首次备份)
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

	# 清理旧的 ulimit 注入
	sed -i '/ulimit -SHn/d' /etc/profile
	sed -i '/ulimit -SHu/d' /etc/profile
	echo "ulimit -SHn $file_max" >>/etc/profile

	# 修复 Pam 会话限制
	if [[ -f "/etc/pam.d/common-session" ]] && ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
		echo "session required pam_limits.so" >>/etc/pam.d/common-session
	fi

	# 7. 应用内核与系统参数
	echo -e "${INFO} 正在应用自适应内核配置..."
	# sysctl --system 会按序加载 /etc/sysctl.d/ 下全部文件(含本文件)，
	# 前面单独的 sysctl -p "$sysctl_conf" 属于重复执行，已移除。
	apply_sysctl >/dev/null || return 1

	# 透明大页设为 madvise: 仅对显式 madvise(MADV_HUGEPAGE) 的程序启用大页。
	# 相比 always，可避免 Redis/数据库等延迟敏感服务因大页整理(khugepaged)
	# 产生的卡顿与内存放大；同时不影响真正需要大页的程序主动申请。
	if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
		echo madvise >/sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
		# 上面的 echo 仅本次运行生效，重启回默认。用一个 oneshot 服务在开机时重设。
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
#  网络加速统一切换引擎 (替代原来十几个 startxxx 函数)
# =================================================

# 检测本机是否已被 tcpfit "应用"(真正在管理网络参数)，而非仅仅"装了 tcpfit 这个工具"。
# 关键区别: /usr/local/bin/tcpfit 只代表命令行工具已安装，用户可能从未 apply 过；
# 此时不应弹出"tcpfit 正在管理本机"的警告与 YES 确认。已应用的证据是:
#   - /etc/sysctl.d/99-tcpfit.conf : apply 时写入的 sysctl (最确定的已应用标志)
#   - tcpfit-qdisc.service         : apply 出向整形时创建的 systemd 单元
#   - /var/lib/tcpfit              : 运行后产生的状态目录
# 故此处刻意不再检测裸二进制文件，避免"只装未用"被误判为正在管理。
tcpfit_present() {
	[[ -f /etc/sysctl.d/99-tcpfit.conf ]] && return 0
	[[ -d /var/lib/tcpfit ]] && return 0
	systemctl list-unit-files 2>/dev/null | grep -q '^tcpfit-qdisc\.service' && return 0
	return 1
}

# 返回 cc/qdisc/ecn 应写入的 sysctl 文件。
# sysctl --system 按文件名字典序加载，后者覆盖前者：99-sysctl.conf < 99-tcpfit.conf，
# 故 tcpfit 存在时若仍写 99-sysctl.conf，用户在菜单里选的算法会被 tcpfit 的 bbr 覆盖。
# 改写到 99-zz-tcpx-accel.conf (排序在 99-tcpfit.conf 之后)，让用户的显式选择生效。
readonly TCPX_ACCEL_DROPIN="/etc/sysctl.d/99-zz-tcpx-accel.conf"
# LotSpeed 开机自启服务：保证重启后 lotspeed 模块被加载且算法被重新应用 (详见 setup_lotspeed_boot_service)
readonly LOTSPEED_BOOT_SERVICE="/etc/systemd/system/lotspeed-boot.service"
accel_conf_path() {
	if tcpfit_present; then
		echo "$TCPX_ACCEL_DROPIN"
	else
		echo "/etc/sysctl.d/99-sysctl.conf"
	fi
}

# tcpfit 的出向整形是否正在运行。它对网卡出向限速/整形，会盖过任何拥塞算法
# (LotSpeed / BBR / 锐速) 的实际吞吐——换算法不会自动解除它。
tcpfit_shaper_active() {
	systemctl is-active tcpfit-qdisc.service >/dev/null 2>&1
}

# 开启加速前，若检测到 tcpfit 整形在跑，询问用户是否停用，避免"换了算法却跑不满"。
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

# 启用 LotSpeed 时无条件停用 tcpfit 出向整形 (按用户要求不再询问)。
# tcpfit-qdisc.service 对网卡出向限速/整形，会直接盖过 LotSpeed 的实际吞吐。
disable_tcpfit_shaper_force() {
	tcpfit_shaper_active || return 0
	systemctl disable --now tcpfit-qdisc.service >/dev/null 2>&1
	echo -e "${INFO} 已自动停用 tcpfit 出向整形 (tcpfit-qdisc.service)，以便 LotSpeed 全速生效。"
	echo -e "${TIP} 如需恢复: systemctl enable --now tcpfit-qdisc.service，或重新运行 tcpfit。"
}

# 卸载加速器 (清理配置)
remove_bbr_lotserver() {
	local apply_status=0
	# 清理算法行之前迁移，备份才是修改前的完整配置；失败时不继续重载旧转发设置。
	ensure_ipv6_ra_config || return 1
	echo -e "${INFO} 正在清理旧的拥塞控制与队列算法配置..."
	# 三处都清: 主文件、传统 /etc/sysctl.conf、以及 tcpfit 共存时用的高优先级 drop-in，
	# 避免切换算法后残留旧行 (drop-in 排序最靠后，残留会覆盖新选择)。
	local f
	for f in /etc/sysctl.d/99-sysctl.conf /etc/sysctl.conf "$TCPX_ACCEL_DROPIN"; do
		# tcp_ecn 用 [[:space:]]*= 收尾锚定，避免顺带删掉 net.ipv4.tcp_ecn_fallback
		[[ -f "$f" ]] && sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d; /net\.ipv4\.tcp_ecn[[:space:]]*=/d' "$f"
	done

	apply_sysctl >/dev/null || apply_status=$?
	# 切算法时失败即停止；彻底卸载时仍须停服务/卸模块，不能留下运行中的加速器。
	if [[ "$apply_status" -ne 0 && "${1:-}" != "cleanup" ]]; then
		return "$apply_status"
	fi

	# 停用 LotSpeed 开机自启服务：切换到 BBR/锐速 等其它算法时若不取消它，
	# 重启后 lotspeed-boot.service 会重新加载模块并把算法顶回 lotspeed，
	# 造成"切了却又变回来"的幽灵问题。切到 LotSpeed 的路径会在其后重新启用本服务。
	systemctl disable --now lotspeed-boot.service >/dev/null 2>&1

	# 修改：停用并卸载 LotSpeed 模块 (但不物理删除文件，以便随时通过菜单快速切换)
	local lotspeed_bin
	if lotspeed_bin=$(trusted_command_path lotspeed); then
		"$lotspeed_bin" stop >/dev/null 2>&1
		rmmod lotspeed >/dev/null 2>&1
	elif command -v lotspeed >/dev/null 2>&1; then
		echo -e "${TIP} LotSpeed 助手文件或父目录不可信，已跳过执行。" >&2
	fi
	# 如果没有 helper 脚本但也加载了模块的兜底清理
	if lsmod | grep -q "lotspeed"; then
		rmmod lotspeed >/dev/null 2>&1
	fi

	if is_trusted_root_file /appex/bin/lotServer.sh; then
		local tmp_lot
		tmp_lot=$(mktemp /tmp/lotserver.XXXXXX)
		if fetch_remote_script "https://raw.githubusercontent.com/fei5seven/lotServer/master/lotServerInstall.sh" "$tmp_lot" >/dev/null 2>&1; then
			patch_child_script_mirrors "$tmp_lot" "lotserver" >/dev/null 2>&1
			echo | bash "$tmp_lot" uninstall >/dev/null 2>&1
		fi
		rm -f "$tmp_lot"
	fi
	return "$apply_status"
}

# 确保 qdisc 对应的 sch_ 模块已加载并在重启后自动加载。
# 拥塞算法(tcp_congestion_control)写入时内核会按需自动 request_module，
# 但 default_qdisc 不会：cake/fq_pie 等模块若未加载，写 default_qdisc 会静默失败。
ensure_qdisc_module() {
	local q="$1"
	[[ -z "$q" ]] && return 0
	modprobe "sch_${q}" >/dev/null 2>&1
	echo "sch_${q}" >/etc/modules-load.d/tcpx-qdisc.conf
}

# 统一加速开启函数
# 用法: enable_acceleration <队列算法> <拥塞控制算法>
enable_acceleration() {
	local qdisc="$1"
	local cc="$2"

	# remove_bbr_lotserver 会连同 tcp_ecn 行一并删除。先记住当前 ECN 状态，
	# 切换算法后按原样写回，避免用户在菜单 [30] 开启的 ECN 被静默清掉。
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
	# 保留切换前的 ECN 设置
	[[ -n "$prev_ecn" ]] && echo "net.ipv4.tcp_ecn=$prev_ecn" >>"$sysctl_conf"

	apply_sysctl >/dev/null || return 1
	echo -e "${INFO} 加速算法修改成功！如果未立即生效，请重启服务器。"
}

# 启用 Lotserver
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
	patch_child_script_mirrors "$tmp_lot" "lotserver"
	echo | bash "$tmp_lot" install
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

# 开启/关闭 ECN (显式控制)
set_ecn() {
	local status="$1"
	local sysctl_conf
	sysctl_conf=$(accel_conf_path)
	# 从所有可能位置清掉旧 ecn 行，再写入到当前生效优先级最高的文件
	# 收尾锚定 [[:space:]]*=，只删 tcp_ecn 本身，不误伤 tcp_ecn_fallback
	sed -i '/net\.ipv4\.tcp_ecn[[:space:]]*=/d' /etc/sysctl.d/99-sysctl.conf /etc/sysctl.conf "$TCPX_ACCEL_DROPIN" 2>/dev/null
	echo "net.ipv4.tcp_ecn=$status" >>"$sysctl_conf"
	apply_sysctl >/dev/null || return 1
	[[ "$status" == "1" ]] && echo -e "${INFO} ECN 已开启！" || echo -e "${INFO} ECN 已关闭！"
}

# tcpfit 手动还原 —— 仅在 /usr/local/bin/tcpfit 程序缺失时的兜底路径。
# 正常走 tcpfit 自带 rollback；这里复刻其关键还原步骤，尽量把机器还原到 tcpfit
# 调优前：停用整形、按快照回写 sysctl、拆掉出向整形 qdisc、复原默认路由。
_tcpfit_manual_restore() {
	local snap="/var/lib/tcpfit/pre-tune.snapshot"
	local iface gw
	systemctl disable --now tcpfit-qdisc.service >/dev/null 2>&1
	# 默认路由网卡：先查 v4，纯 v6 机器回退查 v6
	iface=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
	[[ -z "$iface" ]] && iface=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
	[[ -n "$iface" ]] && tc qdisc del dev "$iface" root 2>/dev/null
	gw=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
	[[ -n "$gw" && -n "$iface" ]] && ip route replace default via "$gw" dev "$iface" 2>/dev/null
	if [[ -f "$snap" ]]; then
		# 快照行形如 "net.core.rmem_max = 212992"，按第一个 = 拆分后逐项回写
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

# 应用户要求：彻底卸载时一并"还原 + 清理"tcpfit。
# ① 还原 tcpfit 的全部改动：优先调用 tcpfit 自带 rollback（权威，按快照精确回写
#    sysctl、拆 qdisc、复原路由、停用并删 systemd 单元/路由钩子/模块自加载）；
#    程序缺失时退回 _tcpfit_manual_restore 兜底。
# ② 清理 tcpfit 本体：rollback 不会删除程序与状态目录，这里补齐真正的"卸载"。
remove_tcpfit_full() {
	echo -e "${INFO} 正在还原并清理 tcpfit ..."
	if [[ -x /usr/local/bin/tcpfit ]]; then
		# --purge-swap: 连 tcpfit 自建的 swap 一并撤销。tcpfit 内部有安全门禁
		# (仅删自己创建且能成功 swapoff 的，外来或换不回内存的 swap 一律不动)，
		# 故此处放心传入。
		echo -e "${INFO} 调用 tcpfit rollback 还原其全部改动 ..."
		/usr/local/bin/tcpfit rollback --purge-swap ||
			echo -e "${TIP} tcpfit rollback 返回非 0，继续清理其残留文件。"
	else
		echo -e "${TIP} 未找到 /usr/local/bin/tcpfit 程序，改用兜底方式还原。"
		_tcpfit_manual_restore
	fi

	# 清理本体与残留（先还原后删除，确保 rollback/兜底能读到快照）
	systemctl disable --now tcpfit-qdisc.service >/dev/null 2>&1
	rm -f /etc/systemd/system/tcpfit-qdisc.service /usr/local/sbin/tcpfit-qdisc.sh
	rm -f /etc/sysctl.d/99-tcpfit.conf
	rm -f /etc/networkd-dispatcher/routable.d/50-tcpfit-initcwnd
	rm -f /etc/modules-load.d/tcpfit-bbr.conf
	rm -f /usr/local/bin/tcpfit /usr/local/sbin/tcpfit.sh
	rm -rf /var/lib/tcpfit
	# 顺带清掉 tcpfit v0.3.1 之前旧名 nettune 的残留，避免改名前的老部署漏网
	systemctl disable --now nettune-qdisc.service >/dev/null 2>&1
	rm -f /etc/systemd/system/nettune-qdisc.service /usr/local/sbin/nettune-qdisc.sh
	rm -f /etc/sysctl.d/99-nettune.conf /etc/networkd-dispatcher/routable.d/50-nettune-initcwnd
	rm -f /etc/modules-load.d/nettune-bbr.conf /usr/local/sbin/nettune.sh
	rm -rf /var/lib/nettune

	systemctl daemon-reload >/dev/null 2>&1
	apply_sysctl >/dev/null || return 1
	echo -e "${INFO} tcpfit 已还原并清理完成。"
}

# 彻底卸载全部加速与优化 (抛弃几十个 sed 删除，直接清空文件)
remove_all() {
	local apply_status=0
	echo -e "${INFO} 正在清空网络优化与系统限制..."
	rm -f /etc/sysctl.d/99-sysctl.conf
	rm -f "$TCPX_ACCEL_DROPIN"
	cat /dev/null >/etc/sysctl.conf
	# 卸载即使遇到其它配置的载入错误，也继续清理服务和资源限制。
	apply_sysctl >/dev/null || apply_status=$?

	# 逐个文件加存在性守卫：如 /etc/pam.d/common-session 在 CentOS 上并不存在，
	# 无守卫的 sed -i 会打印 "No such file" 噪声错误。
	[[ -f /etc/systemd/system.conf ]] && sed -i '/DefaultTimeoutStopSec/d; /DefaultLimitCORE/d; /DefaultLimitNOFILE/d; /DefaultLimitNPROC/d' /etc/systemd/system.conf
	[[ -f /etc/security/limits.conf ]] && sed -i '/soft   nofile/d; /hard   nofile/d; /soft   nproc/d; /hard   nproc/d; /soft   core/d; /hard   core/d' /etc/security/limits.conf
	[[ -f /etc/profile ]] && sed -i '/ulimit -SHn/d' /etc/profile
	[[ -f /etc/pam.d/common-session ]] && sed -i '/required pam_limits.so/d' /etc/pam.d/common-session

	systemctl daemon-reload
	remove_bbr_lotserver cleanup || apply_status=$?
	# 新增：彻底卸载时，物理清理 LotSpeed 残留文件
	rm -f /usr/local/bin/lotspeed
	rm -rf /opt/lotspeed
	# remove_bbr_lotserver 已 disable --now 了开机服务，这里再物理删除 unit 文件并重载
	rm -f "$LOTSPEED_BOOT_SERVICE"

	# 清理系统优化持久化产物: THP 服务、qdisc/conntrack 模块自加载与 modprobe 选项
	systemctl disable --now tcpx-thp.service >/dev/null 2>&1
	rm -f /etc/systemd/system/tcpx-thp.service
	rm -f /etc/modules-load.d/tcpx-qdisc.conf
	rm -f /etc/modules-load.d/tcpx-conntrack.conf
	rm -f /etc/modprobe.d/tcpx-conntrack.conf
	systemctl daemon-reload >/dev/null 2>&1
	# tcpfit 是独立工具，其 sysctl/整形/systemd 单元/程序本体默认不归本脚本管理。
	# 应用户要求：检测到时询问是否一并还原并清理 (默认否，回车即保留)。
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

# 现代化更新引导 (GRUB)
BBR_grub() {
	echo -e "${INFO} 正在更新系统引导..."
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		if command -v grubby >/dev/null 2>&1; then
			# grubby 在 BLS (RHEL/CentOS 8-10) 和传统 GRUB2 下均可用。
			# 用 gsub 去掉 RHEL 9 输出中可能带的引号，再按版本号排序取最新内核，
			# 避免依赖 index 顺序 (index=0 是当前默认，不一定是版本最新的)。
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
		# systemd-boot: deb 包的 postinst 钩子 (kernel-install) 已自动更新引导条目，
		# 此处只需将 systemd-boot 加载器二进制本身更新到最新即可，无需操作 GRUB。
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

# grub2-mkconfig 回退辅助函数 (UEFI 优先，再 BIOS legacy)
_bbr_grub2_mkconfig() {
	local grub_cfg=""
	# UEFI: /boot/efi/EFI/<distro>/grub.cfg
	if [[ -d /boot/efi/EFI ]]; then
		grub_cfg=$(find /boot/efi/EFI -maxdepth 2 -name grub.cfg 2>/dev/null | head -n 1)
	fi
	# BIOS legacy fallback
	[[ -z "$grub_cfg" && -f /boot/grub2/grub.cfg ]] && grub_cfg="/boot/grub2/grub.cfg"
	if [[ -n "$grub_cfg" ]]; then
		grub2-mkconfig -o "$grub_cfg" >/dev/null 2>&1
	fi
	grub2-set-default 0
}

# 查看已安装的内核与排序
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

# 高级交互式内核管理 (精准多选删除，支持删除当前内核)
delete_kernel_custom() {
	clear
	echo -e "${INFO} ==================================================="
	echo -e "${INFO} 正在扫描系统中已安装的内核包..."
	local current_kernel=$(uname -r)
	local kernel_list=()

	# 使用更精准的包查询方式，防止名字过长被截断
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

	# 打印带编号的内核列表
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

	# 遍历用户输入，提取包名
	local pkgs_to_del=""
	local is_del_current=0
	for idx in $del_choices; do
		if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 0 ]] && [[ "$idx" -lt ${#kernel_list[@]} ]]; then
			local selected_pkg="${kernel_list[$idx]}"
			pkgs_to_del="$pkgs_to_del $selected_pkg"
			# 标记是否包含当前内核
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

	# 安全屏障：确保删除后至少还剩一个可引导内核镜像，防止变砖
	local remaining_images=0
	for pkg in "${kernel_list[@]}"; do
		# 仅统计镜像包 (跳过 headers / modules / devel)
		if [[ "${OS_TYPE}" == "Debian" ]]; then
			[[ "$pkg" != linux-image-* ]] && continue
		else
			# CentOS: kernel(-ml|-lt|…)-<版本号> 格式，排除 headers/devel
			[[ ! "$pkg" =~ ^kernel(-ml|-lt|-uek|-rt|-plus)?-[0-9] ]] && continue
		fi
		# 该镜像不在待删除列表中 → 会被保留
		# 用赋值式自增而非 ((remaining_images++))：后者在结果为 0 时返回退出码 1，
		# 将来若启用 set -e 会在此静默中断循环。
		[[ " $pkgs_to_del " != *" $pkg "* ]] && remaining_images=$((remaining_images + 1))
	done
	if [[ $remaining_images -eq 0 ]]; then
		echo -e "${ERROR} 操作已阻止！删除所选包后系统将无任何可引导内核，重启即变砖！"
		echo -e "${TIP} 请至少保留一个可引导内核镜像包。"
		return 1
	fi

	echo -e "${TIP} 即将从系统中彻底卸载以下内核包:"
	echo -e "${RED_FONT_PREFIX}${pkgs_to_del}${FONT_COLOR_SUFFIX}"

	# 强力警告与二次确认机制
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

# 编译安装 brutal
startbrutal() {
	# headers_status 由 check_status 填充。在此处主动刷新，
	# 避免依赖菜单循环是否已调用过 check_status 的不确定状态。
	check_status
	if [[ "$headers_status" == "已匹配" ]]; then
		echo -e "${INFO} Headers 已匹配，开始编译 Brutal..."
		# 统一走 fetch_remote_script: 落盘 + 校验 (非空 & 是 shell 脚本) 后再执行，
		# 避免 curl | bash 把 404/劫持页直接喂给 bash 以 root 运行。
		local tmp_brutal brutal_ok=0
		tmp_brutal=$(mktemp /tmp/brutal.XXXXXX) || return 1
		# 国内优先走 GitHub 权威源脚本 (自动走加速镜像)，避免 tcp.hy2.sh 在国内超时
		if [[ $IS_CN -ne 0 ]]; then
			if fetch_remote_script "https://raw.githubusercontent.com/HyNetworks/tcp-brutal/master/scripts/install_dkms.sh" "$tmp_brutal" ||
				fetch_remote_script "https://tcp.hy2.sh/" "$tmp_brutal"; then
				brutal_ok=1
			fi
		else
			if fetch_remote_script "https://tcp.hy2.sh/" "$tmp_brutal" ||
				fetch_remote_script "https://raw.githubusercontent.com/HyNetworks/tcp-brutal/master/scripts/install_dkms.sh" "$tmp_brutal"; then
				brutal_ok=1
			fi
		fi
		if [[ $brutal_ok -ne 1 ]]; then
			rm -f "$tmp_brutal"
			echo -e "${ERROR} Brutal 安装脚本下载失败！"
			return 1
		fi
		patch_child_script_mirrors "$tmp_brutal" "brutal"

		# 若国内网络无法连通 api.hy2.io，则改用加速后的 GitHub API 自动解析目标版本号
		local brutal_args=()
		if [[ $IS_CN -ne 0 && -z "$TCPX_UNIVERSAL_PROXY" ]]; then
			if ! curl -q -fsSL --max-time 4 "https://api.hy2.io/v1/update?cver=installscript&arch=generic&plat=linux&chan=tcp-brutal" >/dev/null 2>&1; then
				echo -e "${TIP} 检测到 api.hy2.io 直连不可达，自动通过 GitHub API 加速镜像解析 Brutal 最新版本..."
				local kmaj kmin brutal_ver=""
				kmaj=$(uname -r | cut -d. -f1)
				kmin=$(uname -r | cut -d. -f2)
				if [[ "$kmaj" -lt 5 || ( "$kmaj" -eq 5 && "$kmin" -lt 10 ) ]]; then
					brutal_ver="v1.0.3"
				else
					local b_json
					if b_json=$(github_api_get "https://api.github.com/repos/HyNetworks/tcp-brutal/releases/latest"); then
						brutal_ver=$(printf '%s' "$b_json" | grep -m1 -oE '"tag_name":[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/')
					fi
				fi
				if [[ -n "$brutal_ver" ]]; then
					echo -e "${INFO} 已解析 Brutal 目标版本: ${GREEN_FONT_PREFIX}${brutal_ver}${FONT_COLOR_SUFFIX}"
					brutal_args=("install" "--version" "$brutal_ver")
				fi
			fi
		fi
		bash "$tmp_brutal" "${brutal_args[@]}"
		rm -f "$tmp_brutal"
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

# 创建并启用 LotSpeed 开机自启服务。
# 开机时 systemd-sysctl 加载 sysctl.d 时 lotspeed 模块可能尚未 modprobe，
# 那行 tcp_congestion_control=lotspeed 会静默失败并退回 tcpfit 的 bbr。
# 故用一个 oneshot 服务：先 lotspeed start 加载模块，再 sysctl --system 重刷，
# 让 99-zz-tcpx-accel.conf 里的 lotspeed 生效 (排序在 99-tcpfit.conf 之后，稳压其默认)。
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
	# 只 enable 建立开机软链，不用 --now：此刻 LotSpeed 已在运行，若再触发 oneshot 里的
	# `lotspeed start` 会因重复启动返回非零，导致误报"启用失败"。开机自启才是这里的目的。
	if systemctl enable lotspeed-boot.service >/dev/null 2>&1; then
		echo -e "${INFO} 已启用 LotSpeed 开机自启 (lotspeed-boot.service)，重启后仍为默认算法。"
	else
		echo -e "${TIP} LotSpeed 开机自启服务启用失败 (非 systemd 环境?)，重启后可能需手动 lotspeed start。"
		return 1
	fi
}

# 安装启用 LotSpeed (uk0开发)
install_lotspeed() {
	echo -e "${INFO} 准备安装并启用 LotSpeed (ml-tcp 分支) ..."
	# 执行官方一键安装脚本 (走 safe_wget 以便国内机可通过镜像获取)
	local tmp_ls
	tmp_ls=$(mktemp /tmp/lotspeed.XXXXXX) || return 1
	if ! fetch_remote_script "https://raw.githubusercontent.com/uk0/lotspeed/ml-tcp/install.sh" "$tmp_ls"; then
		rm -f "$tmp_ls"
		echo -e "${ERROR} LotSpeed 安装脚本下载失败！"
		return 1
	fi
	patch_child_script_mirrors "$tmp_ls" "lotspeed"
	bash "$tmp_ls"
	rm -f "$tmp_ls"

	if lsmod | grep -q "lotspeed"; then
		echo -e "${INFO} LotSpeed 模块已成功加载！"
		# 将其写入生效优先级最高的文件确保重启后也是默认算法
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

# 单独启用 LotSpeed 加速 (免编译快速切换)
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

	# 确保将其写死为默认启动项
	local sysctl_conf
	sysctl_conf=$(accel_conf_path)
	ensure_qdisc_module "fq"
	sed -i '/net.ipv4.tcp_congestion_control/d; /net.core.default_qdisc/d' /etc/sysctl.d/99-sysctl.conf /etc/sysctl.conf "$TCPX_ACCEL_DROPIN" 2>/dev/null
	echo "net.core.default_qdisc=fq" >>"$sysctl_conf"
	echo "net.ipv4.tcp_congestion_control=lotspeed" >>"$sysctl_conf"
	apply_sysctl >/dev/null || return 1

	# remove_bbr_lotserver 已先禁用旧的开机服务，此处按当前 LotSpeed 状态重新启用
	setup_lotspeed_boot_service || return 1

	echo -e "${INFO} LotSpeed 加速已成功切换并启用！"
}

# =================================================
#  杂项与附加功能模块 (补齐缺失的函数)
# =================================================

# 命令必须解析为可执行的受信普通文件；返回规范绝对路径，兼容 /sbin -> /usr/sbin。
# 固定返回路径后再使用，避免之后重新走 PATH；拒绝 systemd 的空白、% 等特殊字符。
trusted_command_path() {
	local path
	path=$(type -P "$1" 2>/dev/null) || return 1
	path=$(readlink -f -- "$path" 2>/dev/null) || return 1
	[[ "$path" =~ ^/[a-zA-Z0-9_./+-]+$ && -x "$path" ]] || return 1
	is_trusted_root_file "$path" || return 1
	printf '%s\n' "$path"
}

# 该组是否存在 root 之外的成员（显式成员，或把它当作主组）。
# Debian/Ubuntu 的 /usr/local/bin 默认是 root:staff 2775；只有确认组内没有其他可写主体时才接受。
group_has_non_root_members() {
	local gid="$1"
	[[ -n "$gid" && "$gid" =~ ^[0-9]+$ ]] || return 0
	awk -F: -v g="$gid" '$3==g { n=split($4,m,","); for (i=1;i<=n;i++) if (m[i]!="" && m[i]!="root") { found=1; exit } } END { exit !found }' \
		/etc/group 2>/dev/null && return 0
	awk -F: -v g="$gid" '$4==g && $1!="root" { found=1; exit } END { exit !found }' /etc/passwd 2>/dev/null && return 0
	return 1
}

# 文件及每级父目录都必须由 UID 0 拥有，不能为符号链接。
# 叶子不允许他人写；父目录不允许他人写，组可写时要求该组没有 root 之外的成员，
# 这样既接受发行版默认的 root:staff 系统目录，也排除普通用户可改名替换的目录。
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
			# 组可写父目录：root 组视为受信（加入 root 组本身已需 root 授权）；
			# 其它组要求没有 root 之外的成员，覆盖 Debian 的 root:staff 2775 系统目录。
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

# 通用的远程脚本获取器: 下载到临时文件 -> 校验 -> 交给调用方处理
# 统一走 safe_wget；脚本没有独立摘要时必须直连上游 HTTPS，不经第三方镜像。
fetch_remote_script() {
	local url="$1"
	local dest="$2"

	safe_wget "$url" "$dest" || return 1

	# 校验：非空 + 是 shell 脚本 (防止把 404 页面/运营商劫持页当脚本执行)
	if [[ ! -s "$dest" ]]; then
		echo -e "${ERROR} 下载到的文件为空！"
		return 1
	fi
	if ! head -n 1 "$dest" | grep -qE '^#!.*(bash|sh)'; then
		echo -e "${ERROR} 下载到的内容不是有效的 Shell 脚本 (可能是错误页或被劫持)！"
		return 1
	fi
	return 0
}

# 首次运行自安装：把脚本落地到 /usr/local/bin/tcpx，之后可直接输入 tcpx 运行。
# 兼容两种运行方式：
#   1) 本地文件   (bash tcpx.sh / ./tcpx.sh)        -> 直接复制自身
#   2) 管道/进程替换 (bash <(curl -fsSL <URL>))      -> 本地无副本，需从 TCPX_SELF_URL 重新下载
install_self() {
	local target="$TCPX_INSTALL_PATH"
	local src
	src=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")

	# 正在运行的就是安装后的副本，无需再装
	[[ "$src" == "$target" ]] && return 0

	# 目标目录不可写(极少数只读环境)则跳过，不阻断正常使用
	[[ -w "$(dirname "$target")" ]] || return 0

	if [[ -f "$src" && -r "$src" ]]; then
		# 本地文件方式：内容有变化才复制，避免每次运行都写盘
		if [[ ! -f "$target" ]] || ! cmp -s "$src" "$target"; then
			if cp "$src" "$target" 2>/dev/null && chmod +x "$target" 2>/dev/null; then
				echo -e "${INFO} 已安装/更新到 ${target}，之后可直接输入 ${GREEN_FONT_PREFIX}tcpx${FONT_COLOR_SUFFIX} 运行。"
			fi
		fi
		return 0
	fi

	# 管道/进程替换方式：本地没有文件副本，必须从权威地址重新下载
	if [[ -n "$TCPX_SELF_URL" ]]; then
		local tmp
		tmp=$(mktemp /tmp/tcpx_self.XXXXXX) || return 0
		if fetch_remote_script "$TCPX_SELF_URL" "$tmp" >/dev/null 2>&1; then
			if mv -f "$tmp" "$target" 2>/dev/null && chmod +x "$target" 2>/dev/null; then
				echo -e "${INFO} 已安装到 ${target}，之后可直接输入 ${GREEN_FONT_PREFIX}tcpx${FONT_COLOR_SUFFIX} 运行。"
			fi
		else
			rm -f "$tmp"
			echo -e "${TIP} 自安装下载失败(地址不可达或非脚本内容)，本次仍可正常使用菜单。"
		fi
	else
		echo -e "${TIP} 检测到以管道方式运行，但未配置下载地址，无法自安装到 ${target}。"
		echo -e "${TIP} 可用 ${GREEN_FONT_PREFIX}TCPX_URL=<地址> bash <(curl -fsSL <地址>)${FONT_COLOR_SUFFIX} 重新运行以启用自安装。"
	fi
	return 0
}

Update_Shell() {
	local update_url="${TCPX_UPDATE_URL:-}"
	if [[ -z "$update_url" ]]; then
		echo -e "${INFO} 当前运行版本: v${SH_VER} (${SH_CN_MOD})"
		echo -e "${TIP} 注意：上游原版 (${GITHUB_RAW_URL}/tcpx.sh) 不包含本版的全链路国内加速引擎。"
		echo -e "  ${GREEN_FONT_PREFIX}1.${FONT_COLOR_SUFFIX} 仅检查上游最新版本号 (不覆盖当前加速版)"
		echo -e "  ${GREEN_FONT_PREFIX}2.${FONT_COLOR_SUFFIX} 从自定义镜像/仓库 URL 更新 (可指向你自己托管的加速版)"
		echo -e "  ${GREEN_FONT_PREFIX}3.${FONT_COLOR_SUFFIX} 强制覆盖为上游原版 tcpx.sh (通过加速镜像下载)"
		echo -e "  ${GREEN_FONT_PREFIX}0.${FONT_COLOR_SUFFIX} 取消返回"
		local up_choice=""
		read -rp "请选择 [0-3]: " up_choice || return 0
		case "$up_choice" in
		1)
			local chk_tmp
			chk_tmp=$(mktemp /tmp/tcpx_verchk.XXXXXX) || return 1
			if fetch_remote_script "${GITHUB_RAW_URL}/tcpx.sh" "$chk_tmp"; then
				local remote_ver
				remote_ver=$(grep -m1 -oE 'SH_VER="[^"]+"' "$chk_tmp" | cut -d'"' -f2)
				echo -e "${INFO} 本地版本: v${SH_VER} | 上游 GitHub 最新版本: v${remote_ver:-未知}"
			else
				echo -e "${ERROR} 无法连接上游检查版本。"
			fi
			rm -f "$chk_tmp"
			return 0
			;;
		2)
			read -rp "请输入自定义 tcpx.sh 更新地址 (https://...): " update_url
			if [[ ! "$update_url" =~ ^https://[^[:space:]]+$ ]]; then
				echo -e "${ERROR} 地址无效，已取消。"
				return 1
			fi
			TCPX_UPDATE_URL="$update_url"
			save_accel_config
			;;
		3)
			update_url="${GITHUB_RAW_URL}/tcpx.sh"
			;;
		*)
			echo -e "${INFO} 已取消更新。"
			return 0
			;;
		esac
	fi

	echo -e "${INFO} 正在从 ${update_url} 拉取更新..."

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

	# 解析目标位置：优先覆盖当前脚本自身
	local self_path
	self_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
	if [[ ! -w "$(dirname "$self_path")" ]]; then
		echo -e "${TIP} 当前脚本所在目录不可写，将安装到 /root/tcpx.sh"
		self_path="/root/tcpx.sh"
	fi

	# 改为"文件内容变化才更新"(旧逻辑)：不再比较 SH_VER 版本号，而是直接比对下载内容与
	# 当前正在运行的脚本。这样即使改了脚本却忘记抬版本号也能检测到更新，且与 install_self
	# 落地到 /usr/local/bin/tcpx 时用的 cmp 判定方式保持一致。
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

	# 同步安装/刷新到 /usr/local/bin/tcpx，保证升级后可直接输入 tcpx 运行，
	# 不再依赖"旧版本升级后是否会重新执行并触发 install_self"这一不确定链路。
	local reload_path="$self_path"
	if [[ "$self_path" != "$TCPX_INSTALL_PATH" && -w "$(dirname "$TCPX_INSTALL_PATH")" ]]; then
		if cp -f "$self_path" "$TCPX_INSTALL_PATH" 2>/dev/null && chmod +x "$TCPX_INSTALL_PATH" 2>/dev/null; then
			echo -e "${INFO} 已同步安装到 ${GREEN_FONT_PREFIX}${TCPX_INSTALL_PATH}${FONT_COLOR_SUFFIX}，之后可直接输入 ${GREEN_FONT_PREFIX}tcpx${FONT_COLOR_SUFFIX} 运行。"
			# 从安装后的规范路径重载，后续升级即针对 /usr/local/bin/tcpx 生效
			reload_path="$TCPX_INSTALL_PATH"
		fi
	fi

	echo -e "${INFO} 更新完成，正在重新载入脚本..."
	exec bash "$reload_path"
}

# 单独卸载本脚本 (tcpx 工具自身)
# 与菜单 55「卸载全部加速」(remove_all) 的分工：
#   - remove_all 只还原系统网络优化 (sysctl/加速/服务)，不会删除 tcpx 程序本体；
#   - 本函数删除 tcpx 程序本体，并在删除前询问是否先执行 remove_all 还原系统优化。
uninstall_tcpx() {
	echo -e "${TIP} 即将卸载 tcpx 管理脚本本体。"
	echo -e "${TIP} 默认仅删除 tcpx 程序文件，不会改动已应用的网络优化 (BBR/FQ/sysctl 等)。"
	echo

	# 卸载前先询问是否执行 remove_all 还原系统优化 (默认否，保留当前优化)
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
	# 最终确认删除程序本体 (默认否)
	read -rp "确认删除 tcpx 程序文件？(y=确认卸载 / 回车=取消，默认否): " _confirm
	if [[ ! "$_confirm" =~ ^[yY]$ ]]; then
		echo -e "${INFO} 已取消卸载，tcpx 仍保留在本机。"
		return
	fi

	echo -e "${INFO} 正在卸载 tcpx ..."

	local removed=0
	local running_path
	running_path=$(readlink -f "$0" 2>/dev/null || echo "$0")

	# 1) 删除规范安装路径 /usr/local/bin/tcpx
	if [[ -f "$TCPX_INSTALL_PATH" ]]; then
		if rm -f "$TCPX_INSTALL_PATH"; then
			echo -e "${INFO} 已删除 ${TCPX_INSTALL_PATH}"
			removed=1
		fi
	fi

	# 2) 若从非安装路径运行 (如 /root/tcpx.sh) 且为真实文件，一并删除该副本。
	#    进程替换 (bash <(curl ...)) 下 $0 不是普通文件，[[ -f ]] 守卫会自动跳过。
	if [[ -f "$running_path" && "$running_path" != "$TCPX_INSTALL_PATH" ]]; then
		if rm -f "$running_path"; then
			echo -e "${INFO} 已删除 ${running_path}"
			removed=1
		fi
	fi

	if [[ "$removed" -eq 1 ]]; then
		echo -e "${INFO} tcpx 已卸载完成。"
	else
		echo -e "${TIP} 未发现可删除的 tcpx 程序文件 (可能以管道方式运行或已被删除)。"
	fi

	# 正在运行的脚本文件即便被删除，本进程仍可继续 (inode 保持打开)；
	# 卸载后返回菜单已无意义，直接退出。
	echo -e "${INFO} 感谢使用，已退出。"
	exit 0
}

gotodd() {
	echo -e "${INFO} 正在切换到一键 DD 系统脚本 (reinstall.sh)..."
	local tmp_sh dd_ok=0
	tmp_sh=$(mktemp /tmp/reinstall.XXXXXX) || return 1

	if [[ $IS_CN -ne 0 ]]; then
		echo -e "${INFO} 国内环境优先使用 reinstall 官方 CNB 国内高速镜像..."
		if fetch_remote_script "https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh" "$tmp_sh" ||
			fetch_remote_script "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh" "$tmp_sh"; then
			dd_ok=1
		fi
	else
		if fetch_remote_script "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh" "$tmp_sh"; then
			dd_ok=1
		fi
	fi
	if [[ $dd_ok -ne 1 ]]; then
		rm -f "$tmp_sh"
		echo -e "${ERROR} reinstall.sh 下载失败！"
		return 1
	fi
	bash "$tmp_sh"
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

# 调起 tcpfit 进行网络精调 (自适应 BDP/内存的独立工具)
# 按要求：菜单 [60] 直接从上游一键运行 tcpfit，不做任何检测或提示。
# 注意: 此处走原生 curl 直连，未使用脚本内的镜像/落盘校验逻辑；
#       国内网络若无法直连 raw.githubusercontent.com 可能失败。
run_tcpfit_tune() {
	echo -e "${INFO} 正在通过全链路加速通道拉取并启动 tcpfit 网络精调..."
	local tmp_tf
	tmp_tf=$(mktemp /tmp/tcpfit.XXXXXX) || return 1
	if ! fetch_remote_script "https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh" "$tmp_tf"; then
		rm -f "$tmp_tf"
		echo -e "${ERROR} tcpfit.sh 下载失败！"
		return 1
	fi
	patch_child_script_mirrors "$tmp_tf" "tcpfit"
	bash "$tmp_tf"
	rm -f "$tmp_tf"
}

# =================================================
#  UI 面板与主逻辑
# =================================================

# 获取系统面板信息
get_system_info() {
	opsy="${OS_TYPE} ${OS_VERSION_ID}"
	arch="${OS_ARCH}"
	kern=$(uname -r)

	# 获取虚拟化类型
	if command -v virt-what >/dev/null 2>&1; then
		virtual=$(virt-what | head -n 1)
	elif command -v systemd-detect-virt >/dev/null 2>&1; then
		virtual=$(systemd-detect-virt)
	else
		virtual="Unknown"
	fi
	[[ -z "$virtual" ]] && virtual="Dedicated"
}

# 开始菜单
# 绘制菜单与状态面板 (不含读取输入，便于循环复用)
show_menu_panel() {
	clear
	echo && echo -e " TCP加速 一键安装管理脚本 ${RED_FONT_PREFIX}[v${SH_VER} · ${SH_CN_MOD}] 不卸内核${FONT_COLOR_SUFFIX} from blog.ylx.me 母鸡慎用
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
 ${GREEN_FONT_PREFIX}60.${FONT_COLOR_SUFFIX} 网络精调(tcpfit联动)    ${GREEN_FONT_PREFIX}70.${FONT_COLOR_SUFFIX} 网络加速与镜像管理
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
	local _disp_fm _disp_am
	_disp_fm=$(get_active_github_mirror_prefix)
	_disp_am=$(get_active_api_mirror_prefix)
	if [[ $IS_CN -ne 0 || -n "$TCPX_UNIVERSAL_PROXY" || -n "$TCPX_MIRROR" ]]; then
		echo -e " 加速通道: ${GREEN_FONT_PREFIX}已启用${FONT_COLOR_SUFFIX} | 文件: ${GREEN_FONT_PREFIX}${_disp_fm:-直连}${FONT_COLOR_SUFFIX} | API: ${GREEN_FONT_PREFIX}${_disp_am:-直连}${FONT_COLOR_SUFFIX}${TCPX_HTTP_PROXY:+ | 代理: ${YELLOW_FONT_PREFIX}${TCPX_HTTP_PROXY}${FONT_COLOR_SUFFIX}}"
	else
		echo -e " 加速通道: ${YELLOW_FONT_PREFIX}海外直连${FONT_COLOR_SUFFIX}${TCPX_HTTP_PROXY:+ | 代理: ${YELLOW_FONT_PREFIX}${TCPX_HTTP_PROXY}${FONT_COLOR_SUFFIX}} (菜单 [70] 可切换)"
	fi
	if tcpfit_present; then
		echo -e " ${YELLOW_FONT_PREFIX}检测到 tcpfit 正在管理网络参数${FONT_COLOR_SUFFIX}: 菜单 [60] 可调起 tcpfit，[32] 会让路，切算法自动抢优先级"
	fi
}

# 开始菜单 (改为循环驱动)
# 原实现里各功能函数末尾靠递归调用 start_menu 回到菜单，存在两个问题:
#   1) 递归会不断累积调用栈，且大多数分支根本没有递归，执行完就直接退出脚本；
#   2) 安装函数里的 exit 会连带杀掉整个交互式脚本。
# 现统一由本循环驱动，功能函数只需 return。
start_menu() {
	while true; do
		show_menu_panel

		# 用 read 的返回值捕获 EOF (Ctrl-D)，否则会陷入空输入死循环
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
		70) manage_accel_settings ;;
		92) gotodd ;;
		99)
			echo -e "${INFO} 已退出。"
			exit 0
			;;
		*)
			echo -e "${ERROR}: 请输入正确数字"
			;;
		esac

		# 统一在此暂停，让用户看清上面命令的输出后再刷新菜单
		echo ""
		read -rp "按回车键返回主菜单..." _ || exit 0
	done
}

#-----------------------------------------------------------------------
# 函数: update_sysctl_interactive (V4 - 增加错误忽略参数)
# 功能: 以交互方式安全地更新 sysctl 配置文件并应用。
#       命令执行失败时，将不会回滚文件更改。
#-----------------------------------------------------------------------
update_sysctl_interactive() {
	# 强制使用C语言环境，确保正则表达式的行为可预测且一致。
	# 注意: 必须 export，否则 sed/grep/sysctl 等子进程根本看不到这个变量，
	# 仅 local 声明等于完全没生效。
	local LC_ALL=C
	export LC_ALL

	# --- 配置与参数解析 ---
	local CONF_FILE="/etc/sysctl.d/99-sysctl.conf"
	local TMP_FILE
	local BACKUP_FILE
	local ignore_apply_error=true

	# --- 帮助函数 (仅本函数内部使用，退出前会 unset 以免污染全局命名空间) ---
	log_info() {
		echo "[INFO] $1"
	}

	log_error() {
		echo "[ERROR] $1" >&2
	}

	log_warn() {
		echo "[WARN] $1" >&2
	}

	# 函数返回时清理这三个临时函数定义
	trap 'unset -f log_info log_error log_warn 2>/dev/null' RETURN

	# --- 主逻辑 ---

	# 1. 权限检查
	if [[ $EUID -ne 0 ]]; then
		log_error "此函数必须以 root 权限运行，请使用 sudo。"
		return 1
	fi

	# 2. 交互式获取用户输入
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

	# 确保配置文件存在
	touch "$CONF_FILE"

	# 3. 创建临时文件
	TMP_FILE=$(mktemp) || {
		log_error "无法创建临时文件"
		return 1
	}
	# 覆盖上面的 RETURN trap，追加临时文件清理 (bash 每个信号只保留一个 trap)
	trap 'rm -f "$TMP_FILE"; unset -f log_info log_error log_warn 2>/dev/null' RETURN

	cp "$CONF_FILE" "$TMP_FILE"

	local -A params_to_add
	local all_params_valid=true

	# 4. 预处理所有输入，检查合法性
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

	# 5. 将所有新参数追加到临时文件末尾
	if [ ${#params_to_add[@]} -gt 0 ]; then
		log_info "正在添加新参数..."
		echo "" >>"$TMP_FILE"
		for key in "${!params_to_add[@]}"; do
			echo "${params_to_add[$key]}" >>"$TMP_FILE"
			log_info "已添加新参数: ${params_to_add[$key]}"
		done
	fi

	# 6. 原子替换与应用
	BACKUP_FILE="${CONF_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
	cp "$CONF_FILE" "$BACKUP_FILE"
	log_info "原始文件已备份到 $BACKUP_FILE"

	mv "$TMP_FILE" "$CONF_FILE"
	chown root:root "$CONF_FILE"
	chmod 644 "$CONF_FILE"
	# TMP_FILE 已被 mv 走，无需再清理，但仍需在返回时收回临时函数定义
	trap 'unset -f log_info log_error log_warn 2>/dev/null' RETURN

	# 7. 应用配置并进行错误处理
	log_info "正在应用新的 sysctl 设置..."
	# 与脚本其余部分统一使用 sysctl --system，按 /etc/sysctl.d/ 的优先级顺序
	# 加载全部配置文件，得到与重启后一致的最终合并结果。
	if apply_output=$(apply_sysctl 2>&1); then
		log_info "Sysctl 设置已成功应用。"
		echo "--- 应用输出 ---"
		echo "$apply_output"
		echo "------------------"
		rm -f "$BACKUP_FILE"
	else
		# 应用失败时的逻辑
		if [[ "$ignore_apply_error" == "true" ]]; then
			log_warn "应用 sysctl 设置失败，但根据指令已忽略错误。"
			log_warn "配置文件 '${CONF_FILE}' 已被更新，但部分设置可能未生效。"
			log_warn "--- 错误详情 ---"
			echo "$apply_output" >&2
			echo "------------------"
			rm -f "$BACKUP_FILE" # 忽略错误，所以也删除备份
			return 0             # 返回成功状态
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

	# --- 1. 检查文件是否存在 ---
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

	# --- 2. 按优先级选择编辑器: $VISUAL → $EDITOR → nano → vi ---
	# 脚本要求 root 运行，此处无需 sudo。
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

	# --- 3. 执行编辑 ---
	echo -e "${INFO} 使用 [${editor_cmd}] 打开 ${target_file}..."
	if ! "$editor_cmd" "$target_file"; then
		echo -e "${ERROR} 编辑器启动失败或异常退出。"
		return 1
	fi

	# --- 4. 应用新配置 ---
	echo ""
	echo -e "${INFO} 正在应用新配置..."
	# sysctl --system 加载 /etc/sysctl.d/ 全部文件，比 sysctl -p 单文件更完整
	apply_sysctl >/dev/null || return 1
	echo -e "${INFO} 内核参数已重载。部分参数需重启后才能生效。"
}

# =================================================
#  官方源内核安装模块 (包含 CentOS 10 战未来支持)
# =================================================

#检查官方稳定内核并安装
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
			# CentOS 8、9、10 都是同样的包结构
			yum install kernel kernel-core kernel-headers -y --skip-broken
		else
			echo -e "${ERROR} 不支持当前系统 CentOS ${OS_VERSION_ID} !" && return 1
		fi
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		apt update
		if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "pop" || "${OS_ID_LIKE}" == *"ubuntu"* ]]; then
			# Ubuntu 及衍生版 (如 Mint) 使用 generic 命名
			apt-get install linux-image-generic linux-headers-generic -y
		else
			# Debian 及衍生版 (如 Kali, Armbian) 使用 amd64/arm64 命名
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

#检查官方最新内核并安装 (ELRepo / Backports / HWE)
check_sys_official_bbr() {
	pre_install_check || return 1
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		[[ "${OS_ARCH}" != "x86_64" ]] && {
			echo -e "${ERROR} 不支持x86_64以外的系统 !"
			return 1
		}
		if [[ ! "${OS_VERSION_ID}" =~ ^(7|8|9|10)$ ]]; then
			echo -e "${ERROR} 不支持当前系统 CentOS ${OS_VERSION_ID} !" && return 1
		fi
		ensure_elrepo_mirror
		local elrepo_installed=0
		if [[ -n "$BEST_ELREPO_MIRROR" ]]; then
			echo -e "${INFO} 正在从国内 ELRepo 镜像 (${BEST_ELREPO_MIRROR}) 安装 elrepo-release..."
			local rpms_dir="${BEST_ELREPO_MIRROR}/elrepo/el${OS_VERSION_ID}/x86_64/RPMS/"
			local rel_rpm
			rel_rpm=$(curl -q -fsSL --max-time 12 "$rpms_dir" |
				grep -oE "elrepo-release-[^\"<> /]+\.el${OS_VERSION_ID}\.elrepo\.noarch\.rpm" |
				sort -Vu | tail -n 1)
			if [[ -n "$rel_rpm" ]]; then
				local tmp_elr_rpm
				tmp_elr_rpm=$(mktemp /tmp/elrepo_release.XXXXXX.rpm)
				if safe_wget "${rpms_dir}${rel_rpm}" "$tmp_elr_rpm"; then
					# 安装 release 包（包内自带 /etc/pki/rpm-gpg/RPM-GPG-KEY-elrepo.org，随后内核安装开启完整 GPG 校验）
					if yum install -y --nogpgcheck "$tmp_elr_rpm"; then
						elrepo_installed=1
					fi
				fi
				rm -f "$tmp_elr_rpm"
			fi
		fi
		if [[ $elrepo_installed -ne 1 ]]; then
			local gpg_url="https://www.elrepo.org/RPM-GPG-KEY-elrepo.org"
			local rel_url="https://www.elrepo.org/elrepo-release-${OS_VERSION_ID}.el${OS_VERSION_ID}.elrepo.noarch.rpm"
			if [[ -n "$TCPX_UNIVERSAL_PROXY" ]]; then
				gpg_url=$(build_mirror_url "$TCPX_UNIVERSAL_PROXY" "$gpg_url" 1)
				rel_url=$(build_mirror_url "$TCPX_UNIVERSAL_PROXY" "$rel_url" 1)
			fi
			rpm --import "$gpg_url"
			yum install "$rel_url" -y
		fi
		# 将 elrepo.repo 全面替换为国内镜像（清华/阿里云/中科大），加速 kernel-ml 下载
		if [[ -n "$BEST_ELREPO_MIRROR" && -f /etc/yum.repos.d/elrepo.repo ]]; then
			[[ ! -f /etc/yum.repos.d/elrepo.repo.bak ]] && cp -p /etc/yum.repos.d/elrepo.repo /etc/yum.repos.d/elrepo.repo.bak
			sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/elrepo.repo
			sed -i -E "s|^#?baseurl=https?://elrepo\.org/linux|baseurl=${BEST_ELREPO_MIRROR}|g" /etc/yum.repos.d/elrepo.repo
			# 注释掉其余海外备用 mirror 行，避免 yum 慢回退到海外站点
			sed -i -E 's|^[[:space:]]+https?://(mirrors\.coreix\.net|mirror\.rackspace\.com|repos\.lax-noc\.com|elrepo\.org)/|#&|g' /etc/yum.repos.d/elrepo.repo
			echo -e "${INFO} 已将 /etc/yum.repos.d/elrepo.repo 切换至国内高速镜像: ${BEST_ELREPO_MIRROR}"
		fi
		yum --enablerepo=elrepo-kernel install kernel-ml kernel-ml-headers -y --skip-broken
	elif [[ "${OS_TYPE}" == "Debian" ]]; then
		apt update
		if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "pop" || "${OS_ID_LIKE}" == *"ubuntu"* ]]; then
			# Ubuntu 及衍生版安装官方最新内核 (HWE - 硬件使能内核)
			echo -e "${INFO} 正在为 Ubuntu/衍生系 获取官方最新 HWE 内核..."
			if apt-cache show linux-generic-hwe-${OS_VERSION_ID} >/dev/null 2>&1; then
				apt-get install --install-recommends linux-generic-hwe-${OS_VERSION_ID} -y
			else
				echo -e "${TIP} 当前版本 (${OS_VERSION_ID}) 无专属 HWE 包，将自动为您更新至常规最新 generic 内核..."
				apt-get install linux-image-generic linux-headers-generic -y
			fi
		else
			# Debian 及衍生版 (如 Kali, Deepin)
			local apt_args=""
			# 仅为纯净 Debian 添加 Backports 源，避免搞坏 Kali 的滚动源
			if [[ "${OS_ID}" == "debian" ]]; then
				# 原生读取 os-release，彻底摆脱 lsb_release 依赖
				local codename=$(awk -F= '/^VERSION_CODENAME/{print $2}' /etc/os-release | tr -d '"')
				[[ -z "$codename" ]] && codename=$(awk -F= '/^VERSION=/{print $2}' /etc/os-release | grep -oP '(?<=\().*(?=\))')

				[[ -z "$codename" ]] && {
					echo -e "${ERROR} 无法获取 Debian 代号"
					return 1
				}
				ensure_debian_mirror
				echo "deb ${BEST_DEBIAN_MIRROR} ${codename}-backports main" >/etc/apt/sources.list.d/${codename}-backports.list
				echo -e "${INFO} 已添加 Backports 源: ${BEST_DEBIAN_MIRROR} (${codename}-backports)"
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

# 统一 Xanmod 安装引擎
install_xanmod_generic() {
	local edition="$1" # main, lts, edge, rt
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
	apt-get install gnupg gnupg2 gnupg1 wget -y

	# 清除可能存在的旧版或重复源 (兼容 PR 提到的 .sources 与冲突问题)
	rm -f /etc/apt/sources.list.d/xanmod-kernel.list
	rm -f /etc/apt/sources.list.d/xanmod-release.list
	rm -f /etc/apt/sources.list.d/xanmod-kernel.sources
	sed -i '/deb.xanmod.org/d' /etc/apt/sources.list 2>/dev/null

	local _apt_proxy=() _parg
	while IFS= read -r _parg; do
		[[ -n "$_parg" ]] && _apt_proxy+=("$_parg")
	done < <(apt_proxy_opts)

	if [[ $IS_CN -ne 0 && -z "$TCPX_UNIVERSAL_PROXY" && -z "$TCPX_HTTP_PROXY" ]]; then
		echo -e "${TIP} 提示：XanMod 官方源位于海外且国内无公共镜像；如遇下载缓慢，可在菜单 [70] 配置全站反代或 HTTP/SOCKS 代理。"
	fi

	# 使用现代化的 signed-by 格式写入 GPG 密钥与源（经由 safe_wget 支持全站反代/代理）
	local tmp_xan_key
	tmp_xan_key=$(mktemp /tmp/xanmod_gpg.XXXXXX) || return 1
	if ! safe_wget "https://dl.xanmod.org/archive.key" "$tmp_xan_key" &&
		! safe_wget "https://dl.xanmod.org/gpg.key" "$tmp_xan_key"; then
		rm -f "$tmp_xan_key"
		echo -e "${ERROR} XanMod GPG 密钥下载失败！"
		return 1
	fi
	gpg --dearmor --yes -o /usr/share/keyrings/xanmod-archive-keyring.gpg <"$tmp_xan_key"
	rm -f "$tmp_xan_key"

	local xanmod_repo_url="https://deb.xanmod.org"
	if [[ -n "$TCPX_UNIVERSAL_PROXY" ]]; then
		xanmod_repo_url="${TCPX_UNIVERSAL_PROXY}https://deb.xanmod.org"
		echo -e "${INFO} 已通过全站反代加速 XanMod APT 源: ${xanmod_repo_url}"
	fi
	# 适配 XanMod 新版按发行版代号分仓 (bookworm/trixie/noble 等)，若无则回退 bookworm/releases
	local xan_codename xan_suite="" cand_suite probe_code
	xan_codename=$(awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
	for cand_suite in ${xan_codename:+"$xan_codename"} bookworm releases; do
		probe_code=$(curl -q -sL -m 5 -r 0-64 -o /dev/null -w '%{http_code}' "${xanmod_repo_url}/dists/${cand_suite}/InRelease" 2>/dev/null)
		if [[ "$probe_code" =~ ^(200|206)$ ]]; then
			xan_suite="$cand_suite"
			break
		fi
	done
	[[ -z "$xan_suite" ]] && xan_suite="${xan_codename:-releases}"
	echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] ${xanmod_repo_url} ${xan_suite} main" | tee /etc/apt/sources.list.d/xanmod-kernel.list

	# 本地原生检测 CPU x86-64 psABI 等级 (等价于 XanMod 官方 check_x86-64_psabi.sh，零联网耗时)
	local cpu_level
	cpu_level=$(awk '
		BEGIN {
			level = 1
			while ((getline < "/proc/cpuinfo") > 0) {
				if (/^flags[[:space:]]*:/) {
					if (/lm/ && /cmov/ && /cx8/ && /fpu/ && /fxsr/ && /mmx/ && /syscall/ && /sse2/) level = 1
					if (level == 1 && /cx16/ && /lahf/ && /popcnt/ && /sse4_1/ && /sse4_2/ && /ssse3/) level = 2
					if (level == 2 && /avx/ && /avx2/ && /bmi1/ && /bmi2/ && /f16c/ && /fma/ && /abm/ && /movbe/ && /xsave/) level = 3
					if (level == 3 && /avx512f/ && /avx512bw/ && /avx512cd/ && /avx512dq/ && /avx512vl/) level = 4
					break
				}
			}
			print level
		}' 2>/dev/null)
	[[ "$cpu_level" =~ ^[1-4]$ ]] || cpu_level="1"
	echo -e "${INFO} CPU 支持等级 (本地检测): \033[32mv${cpu_level}\033[0m"

	apt "${_apt_proxy[@]}" update
	local pkg_name="linux-xanmod"
	[[ "$edition" != "main" ]] && pkg_name="linux-xanmod-${edition}"

	if [[ "$cpu_level" -ge 3 ]]; then
		apt "${_apt_proxy[@]}" install "${pkg_name}-x64v3" -y
	elif [[ "$cpu_level" -ge 2 ]]; then
		apt "${_apt_proxy[@]}" install "${pkg_name}-x64v2" -y
	else
		apt "${_apt_proxy[@]}" install "${pkg_name}-x64v1" -y
	fi

	BBR_grub
	echo -e "${TIP} 内核安装完毕。"
}

check_sys_official_xanmod_main() { install_xanmod_generic "main"; }
check_sys_official_xanmod_lts() { install_xanmod_generic "lts"; }
check_sys_official_xanmod_edge() { install_xanmod_generic "edge"; }
check_sys_official_xanmod_rt() { install_xanmod_generic "rt"; }

#检查Zen官方内核并安装
check_sys_official_zen() {
	pre_install_check || return 1
	[[ "${OS_ARCH}" != "x86_64" ]] && {
		echo -e "${ERROR} Zen内核仅支持x86_64 !"
		return 1
	}
	if [[ "${OS_ID}" == "debian" || "${OS_ID}" == "kali" || "${OS_ID_LIKE}" == *"debian"* ]] && [[ "${OS_ID_LIKE}" != *"ubuntu"* && "${OS_ID}" != "ubuntu" && "${OS_ID}" != "pop" ]]; then
		# 落盘校验后再执行 Liquorix 加源脚本，避免 curl | bash
		local tmp_lqx
		tmp_lqx=$(mktemp /tmp/liquorix.XXXXXX) || return 1
		local _apt_proxy=() _parg
		while IFS= read -r _parg; do
			[[ -n "$_parg" ]] && _apt_proxy+=("$_parg")
		done < <(apt_proxy_opts)
		if [[ $IS_CN -ne 0 && -z "$TCPX_UNIVERSAL_PROXY" && -z "$TCPX_HTTP_PROXY" ]]; then
			echo -e "${TIP} 提示：Liquorix 源位于海外；如遇超时，可在菜单 [70] 配置全站反代或 HTTP/SOCKS 代理。"
		fi
		if ! fetch_remote_script "https://liquorix.net/add-liquorix-repo.sh" "$tmp_lqx"; then
			rm -f "$tmp_lqx"
			echo -e "${ERROR} Liquorix 源脚本下载失败！"
			return 1
		fi
		patch_child_script_mirrors "$tmp_lqx" "liquorix"
		bash "$tmp_lqx"
		rm -f "$tmp_lqx"
		apt-get "${_apt_proxy[@]}" install linux-image-liquorix-amd64 linux-headers-liquorix-amd64 -y
	elif [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "pop" || "${OS_ID_LIKE}" == *"ubuntu"* ]]; then
		local _apt_proxy=() _parg
		while IFS= read -r _parg; do
			[[ -n "$_parg" ]] && _apt_proxy+=("$_parg")
		done < <(apt_proxy_opts)
		apt-get "${_apt_proxy[@]}" install software-properties-common -y
		add-apt-repository ppa:damentz/liquorix -y && apt-get "${_apt_proxy[@]}" update
		apt-get "${_apt_proxy[@]}" install linux-image-liquorix-amd64 linux-headers-liquorix-amd64 -y
	else
		echo -e "${ERROR} Zen内核当前脚本仅支持 Debian/Ubuntu 及衍生版 !" && return 1
	fi
	BBR_grub
	echo -e "${TIP} 内核安装完毕。"
}

#检查系统当前状态
check_status() {
	# 初始化变量，避免重复读取文件
	kernel_version=$(uname -r | awk -F "-" '{print $1}')
	kernel_version_full=$(uname -r)
	net_congestion_control=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "unknown")
	net_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "unknown")

	# 检测内核类型
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

	# 运行状态检测
	if [[ "$kernel_status" == "BBR" ]]; then
		case "$net_congestion_control" in
		"bbr")
			run_status="BBR启动成功"
			;;
		"bbr2")
			run_status="BBR2启动成功"
			;;
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
		*)
			run_status="未安装加速模块"
			;;
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
		"bbrplus")
			run_status="BBRplus启动成功"
			;;
		"bbr")
			run_status="BBR启动成功"
			;;
		*)
			run_status="未安装加速模块"
			;;
		esac
	else
		run_status="未安装加速模块"
	fi

	# 检查 Headers 状态 (利用全局 OS_TYPE)
	if [[ "${OS_TYPE}" == "CentOS" ]]; then
		installed_headers=$(rpm -qa | grep -E "kernel(-ml|-lt|-uek|-rt|-plus)?-(devel|headers)" | grep -v '^$' || echo "")
		if [[ -z "$installed_headers" ]]; then
			headers_status="未安装"
		else
			# 用固定字符串匹配 (kernel_version_full 含 + . 等正则元字符, -E 会误判)。
			# 已过滤过的行必为 kernel*-devel/headers-*, 只需核对版本后缀是否为当前内核。
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
			# 同理用固定字符串匹配, 避免 6.12.95+deb12-cloud-amd64 里的 + 被当量词。
			if echo "$installed_headers" | grep -qF -- "-headers-${kernel_version_full}"; then
				headers_status="已匹配"
			else
				headers_status="未匹配"
			fi
		fi
	else
		headers_status="不支持的操作系统"
	fi

	# Brutal 状态检测
	brutal=""
	if lsmod | grep -q "brutal"; then
		brutal="brutal已加载"
	fi

	# 新增：LotSpeed 状态检测
	lotspeed_status=""
	if lsmod | grep -q "lotspeed"; then
		if [[ "$net_congestion_control" == "lotspeed" ]]; then
			run_status="LotSpeed启动成功" # 直接覆盖掉上面错误的“未安装”提示
		else
			lotspeed_status="LotSpeed已加载(未设为默认)"
		fi
	fi
}

#############系统检测组件#############
# =================================================
#  入口执行逻辑
# =================================================

# 系统检测与镜像测速 (两种入口共用，只跑一次)
check_sys
check_cn_status

# 首次运行时自安装到 /usr/local/bin/tcpx (支持 bash <(curl -fsSL ...) 管道方式)
install_self

# 命令行静默调用参数解析 (免菜单执行)
if [ $# -gt 0 ]; then
	case $1 in
	op0 | op1 | op2)
		# 兼容老指令，重定向到自适应新版优化
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
	accel-test)
		run_accel_diagnostics
		exit $?
		;;
	accel-config)
		manage_accel_settings
		exit $?
		;;
	*)
		echo -e "${ERROR} 未知选项: \"$1\""
		exit 1
		;;
	esac
fi

# 常规交互式启动
start_menu
