#!/bin/bash
# ============================================================
# IoT RPi AP Configurer - Setup Script
# 라즈베리파이 부팅 후 한 번 실행하면 AP 환경 세팅 완료
# ============================================================

set -e

echo "================================================"
echo "  IoT RPi AP Configurer - 환경 세팅 시작"
echo "================================================"

# ---------- 1. dnsmasq 먼저 중지 ----------
# (ap0 없는 상태에서 떠있으면 인터페이스 인식 못 함)
echo "[1/5] dnsmasq 중지..."
sudo systemctl stop dnsmasq

# ---------- 2. 기존 ap0 정리 ----------
echo "[2/5] 기존 ap0 인터페이스 정리..."
sudo iw dev ap0 del 2>/dev/null || true

# ---------- 3. ap0 가상 인터페이스 생성 ----------
echo "[3/5] ap0 가상 인터페이스 생성..."
sudo iw dev wlan0 interface add ap0 type __ap
sudo ip link set ap0 up
sudo ip addr add 192.168.100.1/24 dev ap0

# ---------- 4. dnsmasq 시작 (ap0 인식하도록) ----------
echo "[4/5] dnsmasq 시작..."
sudo systemctl start dnsmasq

# ---------- 5. 상태 확인 ----------
echo "[5/5] 상태 확인..."
echo ""
echo "─── ap0 상태 ───"
ip addr show ap0 | grep -E "inet|state"
echo ""
echo "─── wlan0 상태 ───"
iw dev wlan0 info | grep -E "ssid|channel|type"
echo ""
echo "─── dnsmasq 상태 ───"
sudo systemctl is-active dnsmasq

echo ""
echo "================================================"
echo "  환경 세팅 완료!"
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