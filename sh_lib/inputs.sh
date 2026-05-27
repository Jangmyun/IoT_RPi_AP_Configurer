# lib/inputs.sh — 사용자 입력 수집 + 인터페이스 자동 감지

# 특정 인터페이스의 phy가 AP 모드를 지원하는지 검사
_phy_supports_ap() {
    local _phy
    _phy=$(iw dev "$1" info 2>/dev/null | awk '/wiphy/{print "phy"$NF}')
    [[ -z "$_phy" ]] && return 1
    iw phy "$_phy" info 2>/dev/null | grep -qE '^\s+\* AP$'
}

prompt_hop() {
    read -rp "이 RPi의 홉 번호 (1=게이트웨이 / 2=중간 / 3=끝단): " HOP
    if ! [[ "$HOP" =~ ^[123]$ ]]; then
        echo "홉 번호는 1, 2, 3 중 하나여야 합니다."
        exit 1
    fi
    SUBNET=$((100 + HOP))
    AP_IP="192.168.${SUBNET}.1"
    DHCP_START="192.168.${SUBNET}.10"
    DHCP_END="192.168.${SUBNET}.100"
    SSID="iot2-${HOP}"
}

# AP / STA 인터페이스 자동 감지
# 기본: AP=USB 동글, STA=wlan0(내장)
# 동글이 AP 모드 미지원 시 자동 스왑: AP=wlan0, STA=동글
detect_interfaces() {
    local DONGLE_IF
    DONGLE_IF=$(iw dev 2>/dev/null | grep -oP 'Interface \Kwlx\S+' | head -1)
    AP_IF=""
    STA_IF="wlan0"

    if [[ -n "$DONGLE_IF" ]]; then
        if _phy_supports_ap "$DONGLE_IF"; then
            AP_IF="$DONGLE_IF"
            STA_IF="wlan0"
            echo ""
            echo "  USB 동글(${DONGLE_IF}) AP 모드 지원 → AP=${AP_IF}, STA=${STA_IF}"
        else
            echo ""
            echo "  USB 동글(${DONGLE_IF})이 AP 모드를 지원하지 않습니다."
            if _phy_supports_ap "wlan0"; then
                AP_IF="wlan0"
                STA_IF="$DONGLE_IF"
                echo "  → 자동 스왑: AP=wlan0 (내장), STA=${DONGLE_IF}"
            else
                echo "  [오류] 내장 wlan0도 AP 모드 미지원."
                iw dev "$DONGLE_IF" info 2>/dev/null | awk '/wiphy/{print "phy"$NF}' \
                    | xargs -I{} iw phy {} info 2>/dev/null | grep -A 6 "Supported interface modes" || true
                exit 1
            fi
        fi
    else
        echo ""
        echo "  경고: USB WiFi 동글(wlx*)을 감지하지 못했습니다."
        local FALLBACK
        read -rp "  ap0 가상 인터페이스(wlan0 공유)로 대신 진행하시겠습니까? (y/N): " FALLBACK
        if [[ "$FALLBACK" =~ ^[yY]$ ]]; then
            AP_IF="ap0"
            STA_IF="wlan0"
        else
            echo "종료합니다."
            exit 1
        fi
    fi
}

prompt_wan() {
    WAN_IF=""
    [[ "$HOP" -ne 1 ]] && return 0
    echo ""
    echo "인터넷 연결 방식을 선택하세요:"
    echo "  1) eth0    (LAN 케이블)"
    echo "  2) ${STA_IF}  (WiFi)"
    local WAN_CHOICE
    read -rp "선택 (1/2): " WAN_CHOICE
    case "$WAN_CHOICE" in
        1) WAN_IF="eth0" ;;
        2) WAN_IF="$STA_IF" ;;
        *) echo "1 또는 2를 입력하세요."; exit 1 ;;
    esac
}

# 다음 홉 IP: 고정 .2 규칙 (RPi #(N+1)의 wlan0이 항상 192.168.${SUBNET}.2)
compute_next_hop() {
    NEXT_HOP_IP=""
    if [[ "$HOP" -lt 3 ]]; then
        NEXT_HOP_IP="192.168.${SUBNET}.2"
    fi
}

prompt_channel() {
    if [[ "$AP_IF" == "ap0" ]]; then
        # ap0 fallback: STA_IF와 같은 칩 → 채널 반드시 일치
        CHANNEL=$(iw dev "$STA_IF" info 2>/dev/null | grep -oP 'channel \K[0-9]+' || true)
        if [[ -z "$CHANNEL" ]]; then
            echo ""
            echo "  ${STA_IF} 채널을 감지하지 못했습니다 (ap0은 ${STA_IF} 채널과 일치해야 함)."
            if [[ "$HOP" -gt 1 ]]; then
                echo "  업스트림 AP에 ${STA_IF}이 먼저 연결되어야 합니다."
            fi
            read -rp "  채널 번호를 입력하세요 (예: 1, 6, 11): " CHANNEL
        fi
    else
        # 동글: 독립 라디오 → HOP별 권장값, 오버라이드 허용
        CHANNEL=${DEFAULT_CHANNEL[$HOP]}
        echo ""
        local CHAN_OVERRIDE
        read -rp "채널 번호 (Enter = 기본값 ${CHANNEL}, HOP#${HOP} 권장): " CHAN_OVERRIDE
        CHANNEL=${CHAN_OVERRIDE:-$CHANNEL}
    fi

    if ! [[ "$CHANNEL" =~ ^[0-9]+$ ]] || [[ "$CHANNEL" -lt 1 ]] || [[ "$CHANNEL" -gt 14 ]]; then
        echo "유효하지 않은 채널 번호: $CHANNEL"
        exit 1
    fi
}

confirm_settings() {
    UPSTREAM_GW="192.168.$((SUBNET-1)).1"
    echo ""
    echo "─── 설정 확인 ───"
    echo "  홉 번호    : RPi #${HOP}"
    if [[ "$AP_IF" == "ap0" ]]; then
        echo "  AP 인터페이스: ap0 (${STA_IF} 가상, 채널 공유)"
    elif [[ "$AP_IF" == "wlan0" ]]; then
        echo "  AP 인터페이스: wlan0 (내장, 동글 AP 미지원으로 스왑)"
        echo "  STA 인터페이스: ${STA_IF} (USB 동글)"
    else
        echo "  AP 인터페이스: ${AP_IF} (USB 동글, 독립 라디오)"
        echo "  STA 인터페이스: ${STA_IF} (내장)"
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
        local i
        for i in $(seq $((HOP+1)) 3); do
            echo "  다운스트림 : 192.168.$((100+i)).0/24 via ${NEXT_HOP_IP}"
        done
    fi
    echo ""
    local CONFIRM
    read -rp "위 설정으로 진행하시겠습니까? (y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "취소되었습니다."
        exit 0
    fi
    echo ""
}
