#!/bin/bash
# ============================================================
# IoT RPi AP Configurer - NAT Setup Script
# ap0 클라이언트가 wlan0을 통해 인터넷을 사용할 수 있도록 설정
# 최초 1회 실행 (iptables-persistent로 재부팅 후에도 유지)
# ============================================================

set -e

WAN_IF="wlan0"
AP_IF="ap0"

echo "================================================"
echo "  NAT 설정 시작 ($AP_IF → $WAN_IF)"
echo "================================================"

# ---------- 1. IP 포워딩 활성화 ----------
echo "[1/4] IP 포워딩 활성화..."

sudo sysctl -w net.ipv4.ip_forward=1

# /etc/sysctl.conf에서 주석 처리된 줄 활성화, 없으면 추가
if grep -qE '^#?\s*net\.ipv4\.ip_forward\s*=' /etc/sysctl.conf; then
    sudo sed -i 's/^#\?\s*net\.ipv4\.ip_forward\s*=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
fi
echo "    /etc/sysctl.conf 설정 완료"

# ---------- 2. 기존 관련 iptables 규칙 정리 ----------
echo "[2/4] 기존 iptables 규칙 정리..."

# 중복 방지: 이미 동일 규칙이 있으면 삭제 후 재추가
sudo iptables -t nat -D POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
sudo iptables -D FORWARD -i "$AP_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -i "$WAN_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

# ---------- 3. iptables NAT 규칙 추가 ----------
echo "[3/4] iptables NAT 규칙 추가..."

sudo iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
sudo iptables -A FORWARD -i "$AP_IF" -o "$WAN_IF" -j ACCEPT
sudo iptables -A FORWARD -i "$WAN_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
echo "    NAT 및 FORWARD 규칙 적용 완료"

# ---------- 4. 규칙 영구 저장 ----------
echo "[4/4] iptables 규칙 영구 저장..."

if ! dpkg -s iptables-persistent &>/dev/null; then
    echo "    iptables-persistent 설치 중..."
    # 설치 중 대화형 프롬프트 자동 수락
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false | sudo debconf-set-selections
    sudo apt-get install -y iptables-persistent
fi

sudo netfilter-persistent save
echo "    /etc/iptables/rules.v4 저장 완료"

# ---------- 결과 확인 ----------
echo ""
echo "─── IP 포워딩 상태 ───"
sysctl net.ipv4.ip_forward

echo ""
echo "─── NAT 규칙 ───"
sudo iptables -t nat -L POSTROUTING -n -v --line-numbers | grep -E "MASQUERADE|Chain" || true

echo ""
echo "─── FORWARD 규칙 ───"
sudo iptables -L FORWARD -n -v --line-numbers | grep -E "$AP_IF|$WAN_IF|Chain" || true

echo ""
echo "================================================"
echo "  NAT 설정 완료!"
echo "  ap0 클라이언트 → wlan0 → 인터넷"
echo "================================================"
