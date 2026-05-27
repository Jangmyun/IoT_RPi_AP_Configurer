#!/bin/bash
# ============================================================
# IoT RPi AP Configurer - 통합 셋업 스크립트
#
# 고정 서브넷:
#   RPi #1 (HOP=1): AP IP 192.168.101.1  (인터넷 게이트웨이)
#   RPi #2 (HOP=2): AP IP 192.168.102.1  (중간 릴레이)
#   RPi #3 (HOP=3): AP IP 192.168.103.1  (끝단)
#
# AP 인터페이스 우선순위:
#   1) USB WiFi 동글 (wlxXXX) — 독립 라디오, 채널 자유
#   2) ap0 가상 인터페이스 (wlan0 위) — fallback, 채널 일치 필요
#
# 권장 채널: HOP1=CH1, HOP2=CH6, HOP3=CH11 (2.4GHz 비중첩)
# ============================================================

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "================================================"
echo "  IoT RPi AP Configurer - 통합 셋업"
echo "================================================"
echo ""

# ---------- HOP 번호 ----------
read -rp "이 RPi의 홉 번호 (1=게이트웨이 / 2=중간 / 3=끝단): " HOP
if ! [[ "$HOP" =~ ^[123]$ ]]; then
    echo "홉 번호는 1, 2, 3 중 하나여야 합니다."
    exit 1
fi

SUBNET=$((100 + HOP))
AP_IP="192.168.${SUBNET}.1"
DHCP_START="192.168.${SUBNET}.10"
DHCP_END="192.168.${SUBNET}.100"

# ---------- AP / STA 인터페이스 자동 감지 ----------
# 기본 가정: AP=USB 동글, STA=wlan0(내장)
# 동글이 AP 모드 미지원 시 자동 스왑: AP=wlan0, STA=동글
DONGLE_IF=$(iw dev 2>/dev/null | grep -oP 'Interface \Kwlx\S+' | head -1)
AP_IF=""
STA_IF="wlan0"

_phy_supports_ap() {
    local _phy
    _phy=$(iw dev "$1" info 2>/dev/null | awk '/wiphy/{print "phy"$NF}')
    [[ -z "$_phy" ]] && return 1
    iw phy "$_phy" info 2>/dev/null | grep -qE '^\s+\* AP$'
}

if [[ -n "$DONGLE_IF" ]]; then
    if _phy_supports_ap "$DONGLE_IF"; then
        AP_IF="$DONGLE_IF"
        STA_IF="wlan0"
        echo ""
        echo "  USB 동글(${DONGLE_IF}) AP 모드 지원 → AP=${AP_IF}, STA=${STA_IF}"
    else
        echo ""
        echo "  USB 동글(${DONGLE_IF})이 AP 모드를 지원하지 않습니다."
        if _phy_supports_ap "wlan0"; then
            AP_IF="wlan0"
            STA_IF="$DONGLE_IF"
            echo "  → 자동 스왑: AP=wlan0 (내장), STA=${DONGLE_IF}"
        else
            echo "  [오류] 내장 wlan0도 AP 모드 미지원."
            iw dev "$DONGLE_IF" info 2>/dev/null | awk '/wiphy/{print "phy"$NF}' \
                | xargs -I{} iw phy {} info 2>/dev/null | grep -A 6 "Supported interface modes" || true
            exit 1
        fi
    fi
else
    echo ""
    echo "  경고: USB WiFi 동글(wlx*)을 감지하지 못했습니다."
    read -rp "  ap0 가상 인터페이스(wlan0 공유)로 대신 진행하시겠습니까? (y/N): " FALLBACK
    if [[ "$FALLBACK" =~ ^[yY]$ ]]; then
        AP_IF="ap0"
        STA_IF="wlan0"  # ap0은 wlan0 위에 가상 생성 — STA 역할도 wlan0이 겸함 (채널 일치 필요)
    else
        echo "종료합니다."
        exit 1
    fi
fi

# ---------- SSID / 비밀번호 ----------
SSID="iot2-${HOP}"
WPA_PASS="00000000"

# ---------- WAN 인터페이스 (HOP=1 전용) ----------
WAN_IF=""
if [[ "$HOP" -eq 1 ]]; then
    echo ""
    echo "인터넷 연결 방식을 선택하세요:"
    echo "  1) eth0    (LAN 케이블)"
    echo "  2) ${STA_IF}  (WiFi)"
    read -rp "선택 (1/2): " WAN_CHOICE
    case "$WAN_CHOICE" in
        1) WAN_IF="eth0" ;;
        2) WAN_IF="$STA_IF" ;;
        *) echo "1 또는 2를 입력하세요."; exit 1 ;;
    esac
fi

# ---------- 다음 홉 IP: 고정 .2 규칙 ----------
# RPi #(N+1)의 wlan0은 항상 192.168.${SUBNET}.2로 정적 설정됨
NEXT_HOP_IP=""
if [[ "$HOP" -lt 3 ]]; then
    NEXT_HOP_IP="192.168.${SUBNET}.2"
fi

# ---------- 채널 결정 ----------
declare -A DEFAULT_CHANNEL=([1]=1 [2]=6 [3]=11)

if [[ "$AP_IF" == "ap0" ]]; then
    # ap0 fallback: ${STA_IF}와 같은 칩 → 채널 반드시 일치
    CHANNEL=$(iw dev "$STA_IF" info 2>/dev/null | grep -oP 'channel \K[0-9]+' || true)
    if [[ -z "$CHANNEL" ]]; then
        echo ""
        echo "  ${STA_IF} 채널을 감지하지 못했습니다 (ap0은 ${STA_IF} 채널과 일치해야 함)."
        if [[ "$HOP" -gt 1 ]]; then
            echo "  업스트림 AP에 ${STA_IF}이 먼저 연결되어야 합니다."
        fi
        read -rp "  채널 번호를 입력하세요 (예: 1, 6, 11): " CHANNEL
    fi
else
    # 동글: 독립 라디오 → HOP별 권장값, 오버라이드 허용
    CHANNEL=${DEFAULT_CHANNEL[$HOP]}
    echo ""
    read -rp "채널 번호 (Enter = 기본값 ${CHANNEL}, HOP#${HOP} 권장): " CHAN_OVERRIDE
    CHANNEL=${CHAN_OVERRIDE:-$CHANNEL}
fi

if ! [[ "$CHANNEL" =~ ^[0-9]+$ ]] || [[ "$CHANNEL" -lt 1 ]] || [[ "$CHANNEL" -gt 14 ]]; then
    echo "유효하지 않은 채널 번호: $CHANNEL"
    exit 1
fi

# ---------- 설정 확인 ----------
UPSTREAM_GW="192.168.$((SUBNET-1)).1"
echo ""
echo "─── 설정 확인 ───"
echo "  홉 번호    : RPi #${HOP}"
if [[ "$AP_IF" == "ap0" ]]; then
    echo "  AP 인터페이스: ap0 (${STA_IF} 가상, 채널 공유)"
elif [[ "$AP_IF" == "wlan0" ]]; then
    echo "  AP 인터페이스: wlan0 (내장, 동글 AP 미지원으로 스왑)"
    echo "  STA 인터페이스: ${STA_IF} (USB 동글)"
else
    echo "  AP 인터페이스: ${AP_IF} (USB 동글, 독립 라디오)"
    echo "  STA 인터페이스: ${STA_IF} (내장)"
fi
echo "  AP IP      : ${AP_IP}"
echo "  SSID       : ${SSID}"
echo "  채널       : ${CHANNEL}"
echo "  DHCP 범위  : ${DHCP_START} ~ ${DHCP_END}"
if [[ "$HOP" -eq 1 ]]; then
    echo "  WAN        : ${WAN_IF}"
fi
if [[ "$HOP" -gt 1 ]]; then
    echo "  업스트림 GW: default via ${UPSTREAM_GW}"
fi
if [[ "$HOP" -lt 3 ]]; then
    echo "  다음 홉 IP : ${NEXT_HOP_IP}"
    for i in $(seq $((HOP+1)) 3); do
        echo "  다운스트림 : 192.168.$((100+i)).0/24 via ${NEXT_HOP_IP}"
    done
fi
echo ""
read -rp "위 설정으로 진행하시겠습니까? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "취소되었습니다."
    exit 0
fi
echo ""

# ============================================================
# [1/8] dnsmasq / hostapd 중지
# ============================================================
echo "[1/8] dnsmasq / hostapd 중지..."
sudo systemctl stop dnsmasq
sudo systemctl is-active --quiet hostapd && sudo systemctl stop hostapd || true

# ============================================================
# [2/8] hostapd.conf 생성
# ============================================================
echo "[2/8] /etc/hostapd/hostapd.conf 생성..."
sudo mkdir -p /etc/hostapd
sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=${AP_IF}
driver=nl80211

ssid=${SSID}

hw_mode=g
channel=${CHANNEL}
ieee80211n=1
wmm_enabled=1
auth_algs=1

wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${WPA_PASS}
EOF
echo "    완료: interface=${AP_IF}, ssid=${SSID}, channel=${CHANNEL}"

# ============================================================
# [3/8] dnsmasq.conf 생성
# ============================================================
echo "[3/8] /etc/dnsmasq.conf 생성..."
sudo tee /etc/dnsmasq.conf > /dev/null <<EOF
port=0

interface=${AP_IF}
dhcp-range=${DHCP_START},${DHCP_END},24h
dhcp-option=3,${AP_IP}
dhcp-option=6,8.8.8.8
EOF
echo "    완료: AP IP=${AP_IP}, DHCP=${DHCP_START}~${DHCP_END}"

# ============================================================
# [4/8] AP 인터페이스 설정
# ============================================================
echo "[4/8] AP 인터페이스 설정 (${AP_IF})..."

# NetworkManager/wpa_supplicant가 인터페이스를 nl80211 소켓으로 점유하면
# hostapd가 AP 모드 전환 불가 → 영구 unmanaged 등록 후 down/up 사이클로 강제 해제
if command -v nmcli &>/dev/null; then
    sudo mkdir -p /etc/NetworkManager/conf.d
    # AP_IF는 항상 unmanaged. STA_IF도 wpa_supplicant@STA_IF와 충돌 방지 위해 unmanaged (HOP>1)
    _NM_UNMANAGED="interface-name:${AP_IF}"
    if [[ "$HOP" -gt 1 && -n "$STA_IF" && "$STA_IF" != "$AP_IF" ]]; then
        _NM_UNMANAGED="${_NM_UNMANAGED};interface-name:${STA_IF}"
    fi
    sudo tee /etc/NetworkManager/conf.d/rpi-ap-unmanaged.conf > /dev/null <<EOF
[keyfile]
unmanaged-devices=${_NM_UNMANAGED}
EOF
    sudo nmcli device set "$AP_IF" managed no 2>/dev/null || true
    [[ "$HOP" -gt 1 && "$STA_IF" != "$AP_IF" ]] && sudo nmcli device set "$STA_IF" managed no 2>/dev/null || true
    sudo systemctl reload NetworkManager 2>/dev/null || true
    echo "    NetworkManager: ${_NM_UNMANAGED} unmanaged 설정"
fi
# wpa_supplicant가 nl80211 소켓을 점유하면 hostapd AP 모드 전환 불가 → 강제 종료
sudo wpa_cli -i "$AP_IF" terminate 2>/dev/null || true
sudo pkill -f "wpa_supplicant.*${AP_IF}" 2>/dev/null || true
sleep 1
# 인터페이스 down → up 사이클로 잔여 소켓 정리
sudo ip link set "$AP_IF" down 2>/dev/null || true
sleep 1

if [[ "$AP_IF" == "ap0" ]]; then
    # 가상 인터페이스: wlan0 위에 생성 (fallback)
    sudo iw dev ap0 del 2>/dev/null || true
    sudo iw dev wlan0 interface add ap0 type __ap
    sudo ip link set ap0 up
    sudo ip addr add "${AP_IP}/24" dev ap0
else
    # USB 동글: IP 할당만, 인터페이스는 DOWN 유지
    # hostapd가 내부적으로 DOWN→AP모드전환→UP을 처리하므로 미리 UP하면 충돌
    sudo ip addr flush dev "$AP_IF" 2>/dev/null || true
    sudo ip addr add "${AP_IP}/24" dev "$AP_IF"
fi
echo "    완료: ${AP_IF} = ${AP_IP}/24 (DOWN 유지, hostapd가 UP)"

# ============================================================
# [5/8] IP 포워딩 활성화
# ============================================================
echo "[5/8] IP 포워딩 활성화..."
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
if grep -qE '^#?\s*net\.ipv4\.ip_forward\s*=' /etc/sysctl.conf; then
    sudo sed -i 's/^#\?\s*net\.ipv4\.ip_forward\s*=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
fi
echo "    완료"

# ============================================================
# [6/8] 정적 라우팅
# ============================================================
echo "[6/8] 정적 라우팅 설정..."

if [[ "$HOP" -gt 1 ]]; then
    sudo ip route del default 2>/dev/null || true
    if sudo ip route add default via "$UPSTREAM_GW" 2>/dev/null; then
        echo "    default via ${UPSTREAM_GW}"
    else
        echo "    default via ${UPSTREAM_GW} (wlan0 미연결 — 재부팅 후 dhcpcd 자동 설정)"
    fi
fi

# 다운스트림 라우트는 AP 인터페이스가 UP 된 후(hostapd 기동 후)에야
# 같은 서브넷의 게이트웨이(.2)가 reachable해지므로 [8/8] 뒤로 미룬다.

# ============================================================
# [7/8] dnsmasq 시작 + NAT (HOP=1)
# ============================================================
echo "[7/8] dnsmasq 시작..."
sudo systemctl start dnsmasq

if [[ "$HOP" -eq 1 ]]; then
    echo "    NAT 설정 (${AP_IF} → ${WAN_IF})..."
    sudo iptables -t nat -D POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
    sudo iptables -D FORWARD -i "$AP_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -i "$WAN_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    sudo iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
    sudo iptables -A FORWARD -i "$AP_IF" -o "$WAN_IF" -j ACCEPT
    sudo iptables -A FORWARD -i "$WAN_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
    echo "    완료: ${AP_IF} → ${WAN_IF} → 인터넷"
fi

# ============================================================
# [8/8] wlan0 정적 IP + 부팅 자동 시작
# ============================================================
echo "[8/8] 부팅 자동 시작 설정..."

# --- STA 인터페이스 정적 IP (HOP > 1) ---
# 이 RPi의 STA(${STA_IF})는 업스트림 AP에서 항상 .2 주소를 사용한다.
# 업스트림 RPi는 이 IP를 NEXT_HOP으로 사전에 알고 있어 별도 협상이 불필요.
if [[ "$HOP" -gt 1 ]]; then
    PREV_SUBNET=$((SUBNET - 1))
    STA_STATIC_IP="192.168.${PREV_SUBNET}.2"
    STA_GW="192.168.${PREV_SUBNET}.1"

    sudo sed -i '/# BEGIN rpi-ap-sta/,/# END rpi-ap-sta/d' /etc/dhcpcd.conf
    # 과거 버전이 남긴 wlan0 전용 블록도 정리
    sudo sed -i '/# BEGIN rpi-ap-wlan0/,/# END rpi-ap-wlan0/d' /etc/dhcpcd.conf
    sudo tee -a /etc/dhcpcd.conf > /dev/null <<EOF

# BEGIN rpi-ap-sta
interface ${STA_IF}
static ip_address=${STA_STATIC_IP}/24
static routers=${STA_GW}
static domain_name_servers=8.8.8.8
# END rpi-ap-sta
EOF
    echo "    ${STA_IF} 정적 IP: ${STA_STATIC_IP}/24 (GW: ${STA_GW})"

    # wpa_supplicant: 업스트림 AP에 자동 연결 (고정 SSID/비밀번호)
    # update_config=0  → 런타임 변경/저장 금지 (다른 SSID 학습 방지)
    # priority=10      → 다른 네트워크가 끼어들어도 이 SSID 우선
    # scan_ssid=1      → hidden/약신호 SSID도 능동 스캔
    UPSTREAM_SSID="iot2-$((HOP - 1))"
    UPSTREAM_PSK=$(wpa_passphrase "$UPSTREAM_SSID" "00000000" | grep -E '^\s+psk=' | tr -d '\t ')
    _WPA_CONF_BODY=$(cat <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=0
country=KR
ap_scan=1

network={
    ssid="${UPSTREAM_SSID}"
    scan_ssid=1
    priority=10
    ${UPSTREAM_PSK}
}
EOF
)
    # 인터페이스별 파일과 글로벌 파일 둘 다 우리 SSID만 남도록 덮어쓴다.
    # (dhcpcd 훅 / 다른 서비스가 글로벌 파일을 쓰는 경우에도 이전 네트워크 복원 방지)
    echo "$_WPA_CONF_BODY" | sudo tee "/etc/wpa_supplicant/wpa_supplicant-${STA_IF}.conf" > /dev/null
    echo "$_WPA_CONF_BODY" | sudo tee /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null

    # NetworkManager에 저장된 기존 Wi-Fi 프로필 제거 (재부팅 시 자동 연결되는 옛 SSID 차단)
    if command -v nmcli &>/dev/null; then
        # 모든 wifi 타입 connection을 삭제 — 이 RPi는 STA_IF로만 업스트림에 붙으면 됨
        nmcli -t -f UUID,TYPE connection show 2>/dev/null \
            | awk -F: '$2=="802-11-wireless"{print $1}' \
            | xargs -r -n1 sudo nmcli connection delete 2>/dev/null || true
        echo "    NetworkManager 저장 Wi-Fi 프로필 삭제 완료"
    fi

    # 충돌 가능 서비스 정리
    # - 글로벌 wpa_supplicant.service: 인터페이스 미지정 → 중복 인스턴스 위험
    # - wpa_supplicant@wlan0: AP_IF=wlan0 스왑 시 hostapd와 충돌
    sudo systemctl disable --now wpa_supplicant 2>/dev/null || true
    if [[ "$AP_IF" == "wlan0" ]]; then
        sudo systemctl disable --now wpa_supplicant@wlan0 2>/dev/null || true
    fi
    # STA_IF용 기존 wpa_supplicant 강제 정리 후 새 설정으로 재시작
    sudo pkill -f "wpa_supplicant.*${STA_IF}" 2>/dev/null || true
    sleep 1
    sudo systemctl enable "wpa_supplicant@${STA_IF}" 2>/dev/null || true
    sudo systemctl restart "wpa_supplicant@${STA_IF}" 2>/dev/null || true
    echo "    wpa_supplicant@${STA_IF}: ${UPSTREAM_SSID} 전용 설정으로 재시작"
fi

# --- 부팅 스크립트 생성 ---
sudo tee /usr/local/bin/rpi-ap-boot.sh > /dev/null <<EOF
#!/bin/bash
# Auto-generated by setup.sh — RPi #${HOP}

AP_IF="${AP_IF}"
AP_IP="${AP_IP}"
STA_IF="${STA_IF}"
HOP="${HOP}"

# 인터페이스가 나타날 때까지 최대 20초 대기 (USB 동글 초기화 시간)
for _i in \$(seq 1 20); do
    ip link show "\$AP_IF" >/dev/null 2>&1 && break
    sleep 1
done

# NM/wpa_supplicant가 인터페이스를 점유하면 hostapd AP 모드 전환 불가
# → unmanaged 설정 후 wpa_supplicant 강제 종료 + down/up 사이클
nmcli device set "\$AP_IF" managed no 2>/dev/null || true
wpa_cli -i "\$AP_IF" terminate 2>/dev/null || true
pkill -f "wpa_supplicant.*\$AP_IF" 2>/dev/null || true
sleep 1
ip link set "\$AP_IF" down 2>/dev/null || true
sleep 1

# STA_IF: 다른 SSID로 잘못 붙는 것을 막기 위해 wpa_supplicant 재시작 강제
# (dhcpcd 훅 / 잔여 인스턴스가 글로벌 conf로 다른 네트워크에 붙는 경우 차단)
if [[ "\$HOP" -gt 1 && -n "\$STA_IF" && "\$STA_IF" != "\$AP_IF" ]]; then
    nmcli device set "\$STA_IF" managed no 2>/dev/null || true
    pkill -f "wpa_supplicant.*\$STA_IF" 2>/dev/null || true
    sleep 1
    systemctl restart "wpa_supplicant@\$STA_IF" 2>/dev/null || true
fi

EOF

if [[ "$AP_IF" == "ap0" ]]; then
    sudo tee -a /usr/local/bin/rpi-ap-boot.sh > /dev/null <<'EOF'
iw dev ap0 del 2>/dev/null || true
iw dev wlan0 interface add ap0 type __ap 2>/dev/null || true
EOF
fi

sudo tee -a /usr/local/bin/rpi-ap-boot.sh > /dev/null <<EOF
rfkill unblock wifi 2>/dev/null || true
ip link set "\$AP_IF" up 2>/dev/null || true
ip addr flush dev "\$AP_IF" 2>/dev/null || true
ip addr add "\${AP_IP}/24" dev "\$AP_IF" 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1 > /dev/null || true
EOF

if [[ "$HOP" -lt 3 ]]; then
    if [[ -z "$NEXT_HOP_IP" ]]; then
        echo "    [오류] NEXT_HOP_IP가 비어 있습니다 — boot.sh 라우트 생성 불가"
        exit 1
    fi
    for i in $(seq $((HOP+1)) 3); do
        SUBNET_ROUTE="192.168.$((100+i)).0/24"
        echo "ip route replace ${SUBNET_ROUTE} via ${NEXT_HOP_IP} 2>/dev/null || true" | sudo tee -a /usr/local/bin/rpi-ap-boot.sh > /dev/null
    done
fi

if [[ "$HOP" -eq 1 ]]; then
    sudo tee -a /usr/local/bin/rpi-ap-boot.sh > /dev/null <<EOF
iptables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i ${AP_IF} -o ${WAN_IF} -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i ${WAN_IF} -o ${AP_IF} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE 2>/dev/null || true
iptables -A FORWARD -i ${AP_IF} -o ${WAN_IF} -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i ${WAN_IF} -o ${AP_IF} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
EOF
fi

# 스크립트는 항상 0으로 종료 (개별 명령 실패가 서비스 전체를 막지 않도록)
echo "exit 0" | sudo tee -a /usr/local/bin/rpi-ap-boot.sh > /dev/null

sudo chmod +x /usr/local/bin/rpi-ap-boot.sh

# --- systemd: rpi-ap-setup.service ---
sudo tee /etc/systemd/system/rpi-ap-setup.service > /dev/null <<EOF
[Unit]
Description=RPi AP interface and routing setup
After=sys-subsystem-net-devices-${AP_IF}.device network.target
Before=hostapd.service dnsmasq.service rpi-ap-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/rpi-ap-boot.sh

[Install]
WantedBy=multi-user.target
EOF

# --- systemd: rpi-ap-server.service ---
sudo tee /etc/systemd/system/rpi-ap-server.service > /dev/null <<EOF
[Unit]
Description=RPi AP Configurer FastAPI server
After=rpi-ap-setup.service hostapd.service dnsmasq.service

[Service]
Type=simple
User=root
WorkingDirectory=${PROJECT_DIR}
ExecStart=${PROJECT_DIR}/venv/bin/python -m src.main
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# --- hostapd config 경로: systemd drop-in으로 직접 지정 ---
# Type=simple: ExecStart만 교체 시 기존 Type=forking이 상속돼 PID 파일 대기 타임아웃 발생
sudo mkdir -p /etc/systemd/system/hostapd.service.d
sudo tee /etc/systemd/system/hostapd.service.d/rpi-ap.conf > /dev/null <<'EOF'
[Service]
Type=simple
ExecStart=
ExecStart=/usr/sbin/hostapd /etc/hostapd/hostapd.conf
EOF

# --- 서비스 활성화 및 즉시 시작 ---
sudo systemctl daemon-reload
sudo systemctl unmask hostapd 2>/dev/null || true
sudo systemctl enable hostapd dnsmasq rpi-ap-setup rpi-ap-server
echo "    서비스 활성화: hostapd, dnsmasq, rpi-ap-setup, rpi-ap-server"
sudo rfkill unblock wifi 2>/dev/null || true
sudo systemctl start hostapd
if sudo systemctl is-active --quiet hostapd; then
    echo "    hostapd 시작 완료"
else
    echo "    [오류] hostapd 시작 실패 — 원인:"
    sudo journalctl -u hostapd --no-pager -n 20 2>/dev/null || true
    echo ""
    echo "    위 로그를 공유해주세요."
fi
sudo systemctl start rpi-ap-server
echo "    rpi-ap-server 시작 완료"

# ---- 다운스트림 라우트: hostapd로 AP_IF가 UP 된 후에야 게이트웨이(.2)가 reachable ----
if [[ "$HOP" -lt 3 ]]; then
    # hostapd가 AP 모드 전환 + UP 완료할 시간 확보
    for _i in $(seq 1 10); do
        ip link show "$AP_IF" 2>/dev/null | grep -q 'state UP' && break
        sleep 1
    done
    for i in $(seq $((HOP+1)) 3); do
        SUBNET_ROUTE="192.168.$((100+i)).0/24"
        if sudo ip route replace "$SUBNET_ROUTE" via "$NEXT_HOP_IP" 2>/dev/null; then
            echo "    route: ${SUBNET_ROUTE} via ${NEXT_HOP_IP}"
        else
            echo "    route: ${SUBNET_ROUTE} via ${NEXT_HOP_IP} (지금은 실패 — 재부팅 후 boot.sh가 재시도)"
        fi
    done
fi

# ============================================================
# 상태 확인
# ============================================================
echo ""
echo "─── ${AP_IF} 상태 ───"
ip addr show "$AP_IF" | grep -E "inet|state"
echo ""
echo "─── 라우팅 테이블 ───"
ip route show | grep -E "default|192\.168\."
echo ""
echo "─── dnsmasq 상태 ───"
sudo systemctl is-active dnsmasq

echo ""
echo "================================================"
echo "  셋업 완료! (RPi #${HOP}, AP: ${AP_IF})"
echo "================================================"
echo ""
echo "서비스 상태 확인:"
echo "  sudo systemctl status hostapd dnsmasq rpi-ap-setup rpi-ap-server"
echo ""
if [[ "$HOP" -gt 1 ]]; then
    echo "wlan0 정적 IP (재부팅 후 적용):"
    echo "  192.168.$((SUBNET-1)).2/24"
    echo ""
fi

echo "─── End-to-End 검증 ───"
if [[ "$HOP" -eq 1 ]]; then
    echo ""
    echo "  ping 192.168.103.x        # E2E ping (소스 IP: ${AP_IP})"
    echo "  iperf3 -c 192.168.103.x   # (RPi #3에서 iperf3 -s 먼저 실행)"
elif [[ "$HOP" -eq 3 ]]; then
    echo ""
    echo "  ping 192.168.101.1        # 게이트웨이 E2E ping"
    echo "  iperf3 -s                 # iperf3 서버 실행"
else
    echo ""
    echo "  ping 192.168.101.1        # 업스트림 게이트웨이 ping"
    echo "  ping 192.168.103.x        # 다운스트림 끝단 ping"
fi
echo ""
