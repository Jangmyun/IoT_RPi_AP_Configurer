# lib/common.sh — 공통 헬퍼 및 상수
# ============================================================
# 고정 서브넷:
#   RPi #1 (HOP=1): AP IP 192.168.101.1  (인터넷 게이트웨이)
#   RPi #2 (HOP=2): AP IP 192.168.102.1  (중간 릴레이)
#   RPi #3 (HOP=3): AP IP 192.168.103.1  (끝단)
# 권장 채널: HOP1=CH1, HOP2=CH6, HOP3=CH11 (2.4GHz 비중첩)
# ============================================================

# WPA 공유 비밀번호 (모든 홉 공통)
WPA_PASS="00000000"

# HOP별 기본 2.4GHz 비중첩 채널
declare -gA DEFAULT_CHANNEL=([1]=1 [2]=6 [3]=11)

# [N/total] msg... 형식 단계 로그
log_step() {
    local n="$1" total="$2" msg="$3"
    echo "[${n}/${total}] ${msg}..."
}

# /etc/rpi-ap/state.env 작성 — verify.sh 가 참조
write_state_env() {
    sudo mkdir -p /etc/rpi-ap
    sudo tee /etc/rpi-ap/state.env > /dev/null <<EOF
HOP=${HOP}
AP_IF=${AP_IF}
STA_IF=${STA_IF}
AP_IP=${AP_IP}
SSID=${SSID}
CHANNEL=${CHANNEL}
SUBNET=${SUBNET}
DHCP_START=${DHCP_START}
DHCP_END=${DHCP_END}
WAN_IF=${WAN_IF}
UPSTREAM_GW=${UPSTREAM_GW}
NEXT_HOP_IP=${NEXT_HOP_IP}
UPSTREAM_SSID=$([[ "$HOP" -gt 1 ]] && echo "iot2-$((HOP-1))" || echo "")
STA_STATIC_IP=$([[ "$HOP" -gt 1 ]] && echo "192.168.$((SUBNET-1)).2" || echo "")
EOF
}
