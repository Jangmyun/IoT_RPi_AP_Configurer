# lib/services.sh — systemd 유닛 작성, 활성화, 최종 상태 출력

write_systemd_units() {
    # rpi-ap-setup.service: 부팅 시 boot.sh 실행 (oneshot)
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

    # rpi-ap-server.service: FastAPI 서버
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

    # hostapd config 경로 drop-in
    # Type=simple: 기존 Type=forking이 상속되면 PID 파일 대기 타임아웃 발생
    sudo mkdir -p /etc/systemd/system/hostapd.service.d
    sudo tee /etc/systemd/system/hostapd.service.d/rpi-ap.conf > /dev/null <<'EOF'
[Service]
Type=simple
ExecStart=
ExecStart=/usr/sbin/hostapd /etc/hostapd/hostapd.conf
EOF
}

activate_services() {
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
}

print_final_status() {
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
}
