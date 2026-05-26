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

# ---------- AP 인터페이스 자동 감지 ----------
# USB 동글: iw dev 에서 wlx* 패턴으로 감지 (MAC 기반 이름)
AP_IF=$(iw dev 2>/dev/null | grep -oP 'Interface \Kwlx\S+' | head -1)

if [[ -z "$AP_IF" ]]; then
    echo ""
    echo "  경고: USB WiFi 동글(wlx*)을 감지하지 못했습니다."
    echo "  동글이 꽂혀 있는지 확인하세요."
    read -rp "  ap0 가상 인터페이스(wlan0 공유)로 대신 진행하시겠습니까? (y/N): " FALLBACK
    if [[ "$FALLBACK" =~ ^[yY]$ ]]; then
        AP_IF="ap0"
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
    echo "  1) eth0  (LAN 케이블)"
    echo "  2) wlan0 (WiFi)"
    read -rp "선택 (1/2): " WAN_CHOICE
    case "$WAN_CHOICE" in
        1) WAN_IF="eth0" ;;
        2) WAN_IF="wlan0" ;;
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
    # ap0 fallback: wlan0과 같은 칩 → 채널 반드시 일치
    CHANNEL=$(iw dev wlan0 info 2>/dev/null | grep -oP 'channel \K[0-9]+' || true)
    if [[ -z "$CHANNEL" ]]; then
        echo ""
        echo "  wlan0 채널을 감지하지 못했습니다 (ap0은 wlan0 채널과 일치해야 함)."
        if [[ "$HOP" -gt 1 ]]; then
            echo "  업스트림 AP에 wlan0이 먼저 연결되어야 합니다."
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
    echo "  AP 인터페이스: ap0 (wlan0 가상, 채널 공유)"
else
    echo "  AP 인터페이스: ${AP_IF} (USB 동글, 독립 라디오)"
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
if [[ "$AP_IF" == "ap0" ]]; then
    # 가상 인터페이스: wlan0 위에 생성 (fallback)
    sudo iw dev ap0 del 2>/dev/null || true
    sudo iw dev wlan0 interface add ap0 type __ap
    sudo ip link set ap0 up
    sudo ip addr add "${AP_IP}/24" dev ap0
else
    # USB 동글 물리 인터페이스: IP만 할당 (hostapd가 AP 모드 전환)
    sudo ip link set "$AP_IF" up
    sudo ip addr flush dev "$AP_IF" 2>/dev/null || true
    sudo ip addr add "${AP_IP}/24" dev "$AP_IF"
fi
echo "    완료: ${AP_IF} = ${AP_IP}/24"

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

if [[ "$HOP" -lt 3 ]]; then
    if [[ -z "$NEXT_HOP_IP" ]]; then
        echo "    [오류] NEXT_HOP_IP가 비어 있습니다 (HOP=${HOP}, SUBNET=${SUBNET})"
        exit 1
    fi
    for i in $(seq $((HOP+1)) 3); do
        SUBNET_ROUTE="192.168.$((100+i)).0/24"
        sudo ip route replace "$SUBNET_ROUTE" via "$NEXT_HOP_IP"
        echo "    ${SUBNET_ROUTE} via ${NEXT_HOP_IP}"
    done
fi

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

# --- wlan0 정적 IP (HOP > 1) ---
# 이 RPi의 wlan0은 업스트림 AP에서 항상 .2 주소를 사용한다.
# 업스트림 RPi는 이 IP를 NEXT_HOP으로 사전에 알고 있어 별도 협상이 불필요.
if [[ "$HOP" -gt 1 ]]; then
    PREV_SUBNET=$((SUBNET - 1))
    WLAN0_STATIC_IP="192.168.${PREV_SUBNET}.2"
    WLAN0_GW="192.168.${PREV_SUBNET}.1"

    sudo sed -i '/# BEGIN rpi-ap-wlan0/,/# END rpi-ap-wlan0/d' /etc/dhcpcd.conf
    sudo tee -a /etc/dhcpcd.conf > /dev/null <<EOF

# BEGIN rpi-ap-wlan0
interface wlan0
static ip_address=${WLAN0_STATIC_IP}/24
static routers=${WLAN0_GW}
static domain_name_servers=8.8.8.8
# END rpi-ap-wlan0
EOF
    echo "    wlan0 정적 IP: ${WLAN0_STATIC_IP}/24 (GW: ${WLAN0_GW})"

    # wpa_supplicant: 업스트림 AP에 자동 연결 (고정 SSID/비밀번호)
    UPSTREAM_SSID="iot2-$((HOP - 1))"
    UPSTREAM_PSK=$(wpa_passphrase "$UPSTREAM_SSID" "00000000" | grep -E '^\s+psk=' | tr -d '\t ')
    sudo tee /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=KR

network={
    ssid="${UPSTREAM_SSID}"
    ${UPSTREAM_PSK}
}
EOF
    echo "    wpa_supplicant: ${UPSTREAM_SSID} 자동 연결 설정 완료"
fi

# --- 부팅 스크립트 생성 ---
sudo tee /usr/local/bin/rpi-ap-boot.sh > /dev/null <<EOF
#!/bin/bash
# Auto-generated by setup.sh — RPi #${HOP}

AP_IF="${AP_IF}"
AP_IP="${AP_IP}"

# 인터페이스가 나타날 때까지 최대 20초 대기 (USB 동글 초기화 시간)
for _i in \$(seq 1 20); do
    ip link show "\$AP_IF" >/dev/null 2>&1 && break
    sleep 1
done

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
# /etc/default/hostapd 방식은 RPi OS 버전별로 동작이 달라 drop-in을 사용
sudo mkdir -p /etc/systemd/system/hostapd.service.d
sudo tee /etc/systemd/system/hostapd.service.d/rpi-ap.conf > /dev/null <<'EOF'
[Service]
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
    echo "    [경고] hostapd 시작 실패 — 로그 확인: sudo journalctl -u hostapd --no-pager | tail -20"
fi
sudo systemctl start rpi-ap-server
echo "    rpi-ap-server 시작 완료"

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
