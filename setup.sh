#!/bin/bash
# ============================================================
# IoT RPi AP Configurer - 통합 셋업 스크립트
# SSID, 서브넷, 비밀번호를 입력받아 conf 생성 후 AP 환경 세팅
# ============================================================

set -e

echo "================================================"
echo "  IoT RPi AP Configurer - 통합 셋업"
echo "================================================"
echo ""

# ---------- 설정값 입력 ----------
read -rp "AP SSID (예: RojanAP_1): " SSID
if [[ -z "$SSID" ]]; then
    echo "SSID는 필수 입력입니다."
    exit 1
fi

read -rp "서브넷 번호 (1~254, AP IP = 192.168.N.1): " HOP
if ! [[ "$HOP" =~ ^[0-9]+$ ]] || [[ "$HOP" -lt 1 ]] || [[ "$HOP" -gt 254 ]]; then
    echo "서브넷 번호는 1~254 사이 숫자여야 합니다."
    exit 1
fi

read -rsp "WPA 비밀번호 (8자 이상): " WPA_PASS
echo ""
if [[ ${#WPA_PASS} -lt 8 ]]; then
    echo "비밀번호는 8자 이상이어야 합니다."
    exit 1
fi

AP_IP="192.168.${HOP}.1"
DHCP_START="192.168.${HOP}.10"
DHCP_END="192.168.${HOP}.100"

echo ""
echo "─── 설정 확인 ───"
echo "  SSID       : $SSID"
echo "  AP IP      : $AP_IP"
echo "  DHCP 범위  : $DHCP_START ~ $DHCP_END"
echo ""
read -rp "위 설정으로 진행하시겠습니까? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "취소되었습니다."
    exit 0
fi
echo ""

# ---------- 1. dnsmasq / hostapd 중지 ----------
echo "[1/6] dnsmasq / hostapd 중지..."
sudo systemctl stop dnsmasq
sudo systemctl is-active --quiet hostapd && sudo systemctl stop hostapd || true

# ---------- 2. hostapd.conf 생성 ----------
echo "[2/6] /etc/hostapd/hostapd.conf 생성..."
sudo mkdir -p /etc/hostapd
sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=ap0
driver=nl80211

ssid=${SSID}

hw_mode=g
channel=1
ieee80211n=1
wmm_enabled=1
auth_algs=1

wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${WPA_PASS}
EOF
echo "    완료: ssid=${SSID}"

# ---------- 3. dnsmasq.conf 생성 ----------
echo "[3/6] /etc/dnsmasq.conf 생성..."
sudo tee /etc/dnsmasq.conf > /dev/null <<EOF
port=0

interface=ap0
dhcp-range=${DHCP_START},${DHCP_END},24h
dhcp-option=3,${AP_IP}
dhcp-option=6,8.8.8.8
EOF
echo "    완료: AP IP=${AP_IP}, DHCP=${DHCP_START}~${DHCP_END}"

# ---------- 4. 기존 ap0 정리 및 재생성 ----------
echo "[4/6] ap0 인터페이스 재생성..."
sudo iw dev ap0 del 2>/dev/null || true
sudo iw dev wlan0 interface add ap0 type __ap
sudo ip link set ap0 up
sudo ip addr add "${AP_IP}/24" dev ap0

# ---------- 5. dnsmasq 시작 ----------
echo "[5/6] dnsmasq 시작..."
sudo systemctl start dnsmasq

# ---------- 6. 상태 확인 ----------
echo "[6/6] 상태 확인..."
echo ""
echo "─── ap0 상태 ───"
ip addr show ap0 | grep -E "inet|state"
echo ""
echo "─── dnsmasq 상태 ───"
sudo systemctl is-active dnsmasq

echo ""
echo "================================================"
echo "  셋업 완료!"
echo "================================================"
echo ""
echo "다음 명령으로 hostapd와 FastAPI를 실행:"
echo ""
echo "  [터미널 1] sudo hostapd /etc/hostapd/hostapd.conf"
echo "  [터미널 2] source venv/bin/activate && sudo venv/bin/python -m src.main"
echo ""
echo "ap0 클라이언트에 인터넷을 제공하려면 (최초 1회):"
echo ""
echo "  sudo bash setup-nat.sh"
echo ""
