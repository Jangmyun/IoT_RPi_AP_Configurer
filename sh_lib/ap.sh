# lib/ap.sh — AP 측 설정 (hostapd, dnsmasq, AP 인터페이스, NAT)

stop_ap_services() {
    sudo systemctl stop dnsmasq
    sudo systemctl is-active --quiet hostapd && sudo systemctl stop hostapd || true
}

write_hostapd_conf() {
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
}

write_dnsmasq_conf() {
    sudo tee /etc/dnsmasq.conf > /dev/null <<EOF
port=0

interface=${AP_IF}
dhcp-range=${DHCP_START},${DHCP_END},24h
dhcp-option=3,${AP_IP}
dhcp-option=6,8.8.8.8
EOF
    echo "    완료: AP IP=${AP_IP}, DHCP=${DHCP_START}~${DHCP_END}"
}

# NM/wpa_supplicant 점유 해제 + AP IP 부여
# - NetworkManager: AP_IF와 (HOP>1일 때) STA_IF를 영구 unmanaged
# - wpa_supplicant: AP_IF의 잔여 인스턴스 강제 종료, 인터페이스 down 사이클
# - ap0: wlan0 위에 가상 인터페이스 생성 / 동글: IP만 할당, DOWN 유지 (hostapd가 UP)
configure_ap_interface() {
    if command -v nmcli &>/dev/null; then
        sudo mkdir -p /etc/NetworkManager/conf.d
        local _NM_UNMANAGED="interface-name:${AP_IF}"
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
    # wpa_supplicant가 nl80211 소켓 점유 시 hostapd AP 모드 전환 불가 → 강제 종료
    sudo wpa_cli -i "$AP_IF" terminate 2>/dev/null || true
    sudo pkill -f "wpa_supplicant.*${AP_IF}" 2>/dev/null || true
    sleep 1
    sudo ip link set "$AP_IF" down 2>/dev/null || true
    sleep 1

    if [[ "$AP_IF" == "ap0" ]]; then
        sudo iw dev ap0 del 2>/dev/null || true
        sudo iw dev wlan0 interface add ap0 type __ap
        sudo ip link set ap0 up
        sudo ip addr add "${AP_IP}/24" dev ap0
    else
        # USB 동글 또는 wlan0(스왑): IP 할당만, DOWN 유지 (hostapd가 UP)
        sudo ip addr flush dev "$AP_IF" 2>/dev/null || true
        sudo ip addr add "${AP_IP}/24" dev "$AP_IF"
    fi
    echo "    완료: ${AP_IF} = ${AP_IP}/24 (DOWN 유지, hostapd가 UP)"
}

start_dnsmasq_service() {
    sudo systemctl start dnsmasq
}

# HOP=1 전용: iptables MASQUERADE + FORWARD 규칙
setup_nat() {
    [[ "$HOP" -ne 1 ]] && return 0
    echo "    NAT 설정 (${AP_IF} → ${WAN_IF})..."
    sudo iptables -t nat -D POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
    sudo iptables -D FORWARD -i "$AP_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -i "$WAN_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    sudo iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
    sudo iptables -A FORWARD -i "$AP_IF" -o "$WAN_IF" -j ACCEPT
    sudo iptables -A FORWARD -i "$WAN_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
    echo "    완료: ${AP_IF} → ${WAN_IF} → 인터넷"
}
