# lib/routing.sh — IP 포워딩, default route, 다운스트림 라우트

enable_ip_forward() {
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
    if grep -qE '^#?\s*net\.ipv4\.ip_forward\s*=' /etc/sysctl.conf; then
        sudo sed -i 's/^#\?\s*net\.ipv4\.ip_forward\s*=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
    fi
    echo "    완료"
}

# HOP>1: 업스트림 GW로 default route 설정
# (이 시점에 STA가 아직 association 전일 수 있음 — 실패 시 부팅 시점 dhcpcd/boot.sh가 재시도)
setup_default_route() {
    [[ "$HOP" -le 1 ]] && return 0
    sudo ip route del default 2>/dev/null || true
    if sudo ip route add default via "$UPSTREAM_GW" 2>/dev/null; then
        echo "    default via ${UPSTREAM_GW}"
    else
        echo "    default via ${UPSTREAM_GW} (wlan0 미연결 — 재부팅 후 dhcpcd 자동 설정)"
    fi
}

# 다운스트림 라우트: hostapd가 AP_IF를 UP 시킨 후에야 .2 게이트웨이가 reachable
# → activate_services() 후에 호출해야 한다.
add_downstream_routes() {
    [[ "$HOP" -ge 3 ]] && return 0
    local _i i SUBNET_ROUTE
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
}
