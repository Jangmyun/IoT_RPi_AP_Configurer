# lib/sta.sh — STA 측 설정 (HOP>1 전용)
# 모든 함수는 HOP<=1 일 때 조기 return하므로 main에서 무조건 호출 가능.

# 업스트림 SSID / 정적 IP / GW 도출 (HOP>1 가정)
_sta_compute() {
    PREV_SUBNET=$((SUBNET - 1))
    STA_STATIC_IP="192.168.${PREV_SUBNET}.2"
    STA_GW="192.168.${PREV_SUBNET}.1"
    UPSTREAM_SSID="iot2-$((HOP - 1))"
}

# /etc/dhcpcd.conf 에 STA_IF 정적 IP 블록 등록
write_sta_static_ip_dhcpcd() {
    [[ "$HOP" -le 1 ]] && return 0
    _sta_compute
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
}

# 인터페이스별 + 글로벌 wpa_supplicant.conf 둘 다 우리 SSID만 남도록 덮어쓴다.
# update_config=0  → 런타임 변경/저장 금지 (다른 SSID 학습 방지)
# priority=10      → 다른 네트워크가 끼어들어도 이 SSID 우선
# scan_ssid=1      → hidden/약신호 SSID도 능동 스캔
write_sta_wpa_conf() {
    [[ "$HOP" -le 1 ]] && return 0
    _sta_compute
    local UPSTREAM_PSK
    UPSTREAM_PSK=$(wpa_passphrase "$UPSTREAM_SSID" "${WPA_PASS:-00000000}" | grep -E '^\s+psk=' | tr -d '\t ')
    local _WPA_CONF_BODY
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
    echo "$_WPA_CONF_BODY" | sudo tee "/etc/wpa_supplicant/wpa_supplicant-${STA_IF}.conf" > /dev/null
    echo "$_WPA_CONF_BODY" | sudo tee /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null
}

# NetworkManager에 저장된 모든 Wi-Fi 프로필 일괄 삭제
# → 재부팅 시 자동 연결되는 옛 SSID 차단
cleanup_nm_wifi_profiles() {
    [[ "$HOP" -le 1 ]] && return 0
    if command -v nmcli &>/dev/null; then
        nmcli -t -f UUID,TYPE connection show 2>/dev/null \
            | awk -F: '$2=="802-11-wireless"{print $1}' \
            | xargs -r -n1 sudo nmcli connection delete 2>/dev/null || true
        echo "    NetworkManager 저장 Wi-Fi 프로필 삭제 완료"
    fi
}

# 충돌 가능 wpa_supplicant 서비스 비활성화
# - 글로벌 wpa_supplicant.service: 인터페이스 미지정 → 중복 인스턴스 위험
# - wpa_supplicant@wlan0: AP_IF=wlan0 스왑 시 hostapd와 충돌
disable_conflicting_wpa_services() {
    [[ "$HOP" -le 1 ]] && return 0
    sudo systemctl disable --now wpa_supplicant 2>/dev/null || true
    if [[ "$AP_IF" == "wlan0" ]]; then
        sudo systemctl disable --now wpa_supplicant@wlan0 2>/dev/null || true
    fi
}

# STA용 wpa_supplicant 강제 재시작 (잔여 인스턴스 정리 후)
restart_sta_wpa() {
    [[ "$HOP" -le 1 ]] && return 0
    _sta_compute
    sudo pkill -f "wpa_supplicant.*${STA_IF}" 2>/dev/null || true
    sleep 1
    sudo systemctl enable "wpa_supplicant@${STA_IF}" 2>/dev/null || true
    sudo systemctl restart "wpa_supplicant@${STA_IF}" 2>/dev/null || true
    echo "    wpa_supplicant@${STA_IF}: ${UPSTREAM_SSID} 전용 설정으로 재시작"
}

# STA_IF에 정적 IP/default route 즉시 부여
# dhcpcd가 부팅 시 STA 정적 IP를 적용하지 못하는 케이스 대비
# (association은 되지만 IP가 없어 통신 불가 — 수동 ip addr add로 회복되는 현상)
assign_sta_ip_immediate() {
    [[ "$HOP" -le 1 ]] && return 0
    _sta_compute
    sudo ip link set "$STA_IF" up 2>/dev/null || true
    local _i
    for _i in $(seq 1 15); do
        iw dev "$STA_IF" link 2>/dev/null | grep -q "Connected to" && break
        sleep 1
    done
    sudo ip addr flush dev "$STA_IF" 2>/dev/null || true
    sudo ip addr add "${STA_STATIC_IP}/24" dev "$STA_IF"
    sudo ip route del default 2>/dev/null || true
    sudo ip route add default via "$STA_GW" dev "$STA_IF" 2>/dev/null \
        || echo "    [경고] default via ${STA_GW} 추가 실패 (association 미완 가능성)"
    echo "    ${STA_IF} 정적 IP 적용: ${STA_STATIC_IP}/24 via ${STA_GW}"
}
