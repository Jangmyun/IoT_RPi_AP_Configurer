#!/bin/bash
# ============================================================
# IoT RPi AP Configurer - 통합 셋업 스크립트
#
# 고정 서브넷:
#   RPi #1 (HOP=1): ap0 = 192.168.101.1  (인터넷 게이트웨이)
#   RPi #2 (HOP=2): ap0 = 192.168.102.1  (중간 릴레이)
#   RPi #3 (HOP=3): ap0 = 192.168.103.1  (끝단)
#
# 수행 순서:
#   1) conf 생성 (hostapd, dnsmasq)
#   2) ap0 인터페이스 설정
#   3) IP 포워딩 + 정적 라우팅
#   4) NAT (HOP=1 전용)
# ============================================================

set -e

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

# ---------- SSID / 비밀번호 ----------
read -rp "AP SSID: " SSID
if [[ -z "$SSID" ]]; then
    echo "SSID는 필수 입력입니다."
    exit 1
fi

read -rsp "WPA 비밀번호 (8자 이상): " WPA_PASS
echo ""
if [[ ${#WPA_PASS} -lt 8 ]]; then
    echo "비밀번호는 8자 이상이어야 합니다."
    exit 1
fi

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

# ---------- 다음 홉 IP (HOP < 3 전용) ----------
NEXT_HOP_IP=""
if [[ "$HOP" -lt 3 ]]; then
    echo ""
    read -rp "다음 홉(RPi #$((HOP+1)))의 wlan0 IP (192.168.${SUBNET}.x): " NEXT_HOP_IP
    if [[ -z "$NEXT_HOP_IP" ]]; then
        echo "다음 홉 IP는 필수 입력입니다."
        exit 1
    fi
fi

# ---------- wlan0 채널 자동 감지 ----------
CHANNEL=$(iw dev wlan0 info 2>/dev/null | grep -oP 'channel \K[0-9]+' || true)
CHANNEL=${CHANNEL:-1}

# ---------- 설정 확인 ----------
UPSTREAM_GW="192.168.$((SUBNET-1)).1"
echo ""
echo "─── 설정 확인 ───"
echo "  홉 번호    : RPi #${HOP}"
echo "  AP IP      : ${AP_IP}"
echo "  SSID       : ${SSID}"
echo "  채널       : ${CHANNEL} (wlan0 자동 감지)"
echo "  DHCP 범위  : ${DHCP_START} ~ ${DHCP_END}"
if [[ "$HOP" -eq 1 ]]; then
    echo "  WAN 인터페이스: ${WAN_IF}"
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
# [1/7] dnsmasq / hostapd 중지
# ============================================================
echo "[1/7] dnsmasq / hostapd 중지..."
sudo systemctl stop dnsmasq
sudo systemctl is-active --quiet hostapd && sudo systemctl stop hostapd || true

# ============================================================
# [2/7] hostapd.conf 생성
# ============================================================
echo "[2/7] /etc/hostapd/hostapd.conf 생성..."
sudo mkdir -p /etc/hostapd
sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=ap0
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
echo "    완료: ssid=${SSID}, channel=${CHANNEL}"

# ============================================================
# [3/7] dnsmasq.conf 생성
# ============================================================
echo "[3/7] /etc/dnsmasq.conf 생성..."
sudo tee /etc/dnsmasq.conf > /dev/null <<EOF
port=0

interface=ap0
dhcp-range=${DHCP_START},${DHCP_END},24h
dhcp-option=3,${AP_IP}
dhcp-option=6,8.8.8.8
EOF
echo "    완료: AP IP=${AP_IP}, DHCP=${DHCP_START}~${DHCP_END}"

# ============================================================
# [4/7] ap0 인터페이스 재생성
# ============================================================
echo "[4/7] ap0 인터페이스 재생성..."
sudo iw dev ap0 del 2>/dev/null || true
sudo iw dev wlan0 interface add ap0 type __ap
sudo ip link set ap0 up
sudo ip addr add "${AP_IP}/24" dev ap0
echo "    완료: ap0 = ${AP_IP}/24"

# ============================================================
# [5/7] IP 포워딩 활성화
# ============================================================
echo "[5/7] IP 포워딩 활성화..."
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
if grep -qE '^#?\s*net\.ipv4\.ip_forward\s*=' /etc/sysctl.conf; then
    sudo sed -i 's/^#\?\s*net\.ipv4\.ip_forward\s*=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
fi
echo "    완료"

# ============================================================
# [6/7] 정적 라우팅
# ============================================================
echo "[6/7] 정적 라우팅 설정..."

# 업스트림 기본 라우트 (HOP > 1)
if [[ "$HOP" -gt 1 ]]; then
    sudo ip route del default 2>/dev/null || true
    sudo ip route add default via "$UPSTREAM_GW"
    echo "    default via ${UPSTREAM_GW}"
fi

# 다운스트림 라우트 (HOP < 3)
if [[ "$HOP" -lt 3 ]]; then
    for i in $(seq $((HOP+1)) 3); do
        SUBNET_ROUTE="192.168.$((100+i)).0/24"
        sudo ip route replace "$SUBNET_ROUTE" via "$NEXT_HOP_IP"
        echo "    ${SUBNET_ROUTE} via ${NEXT_HOP_IP}"
    done
fi

# ============================================================
# [7/7] dnsmasq 시작 + NAT (HOP=1)
# ============================================================
echo "[7/7] dnsmasq 시작..."
sudo systemctl start dnsmasq

if [[ "$HOP" -eq 1 ]]; then
    echo "    NAT 설정 (${WAN_IF})..."
    # 기존 규칙 제거 후 재추가
    sudo iptables -t nat -D POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
    sudo iptables -D FORWARD -i ap0 -o "$WAN_IF" -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -i "$WAN_IF" -o ap0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    sudo iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
    sudo iptables -A FORWARD -i ap0 -o "$WAN_IF" -j ACCEPT
    sudo iptables -A FORWARD -i "$WAN_IF" -o ap0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    echo "    완료: ap0 → ${WAN_IF} → 인터넷"
fi

# ============================================================
# 상태 확인
# ============================================================
echo ""
echo "─── ap0 상태 ───"
ip addr show ap0 | grep -E "inet|state"
echo ""
echo "─── 라우팅 테이블 ───"
ip route show | grep -E "default|192\.168\."
echo ""
echo "─── dnsmasq 상태 ───"
sudo systemctl is-active dnsmasq

echo ""
echo "================================================"
echo "  셋업 완료! (RPi #${HOP})"
echo "================================================"
echo ""
echo "hostapd 실행:"
echo "  sudo hostapd /etc/hostapd/hostapd.conf"
echo ""
echo "FastAPI 실행:"
echo "  source venv/bin/activate && sudo venv/bin/python -m src.main"
echo ""

# ---------- End-to-End 검증 명령어 ----------
echo "─── End-to-End 검증 ───"
if [[ "$HOP" -eq 1 ]]; then
    echo ""
    echo "  # RPi #3 ap0 클라이언트 IP 확인 후:"
    echo "  ping 192.168.103.x        # E2E ping (소스 IP: ${AP_IP})"
    echo ""
    echo "  # RPi #3에서 iperf3 서버 실행 후:"
    echo "  iperf3 -c 192.168.103.x   # E2E 대역폭 측정"
elif [[ "$HOP" -eq 3 ]]; then
    echo ""
    echo "  ping 192.168.101.1        # 게이트웨이 E2E ping"
    echo "  iperf3 -s                 # iperf3 서버 (RPi #1에서 클라이언트 실행)"
else
    echo ""
    echo "  ping 192.168.101.1        # 업스트림 게이트웨이 ping"
    echo "  ping 192.168.103.x        # 다운스트림 끝단 ping"
fi
echo ""
