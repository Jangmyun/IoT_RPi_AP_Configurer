#!/bin/bash
# ============================================================
# verify.sh — RPi AP Configurer 설정 검증
#
# setup.sh 가 작성한 /etc/rpi-ap/state.env 를 기준으로
# 실제 시스템 상태(인터페이스, IP, 라우팅, 서비스, 연결성)를 점검한다.
# 재부팅 후 실행해 비정상 동작을 빠르게 식별하는 용도.
#
# 사용:
#   ./verify.sh           # 사람용 컬러 출력
#   ./verify.sh --quiet   # 실패 항목만 출력
# 종료코드: 0=모두 PASS, 그 외=실패 개수
# ============================================================

STATE_FILE="/etc/rpi-ap/state.env"

if [[ ! -r "$STATE_FILE" ]]; then
    echo "[오류] $STATE_FILE 를 읽을 수 없습니다. setup.sh 를 먼저 실행하세요."
    exit 127
fi

# shellcheck source=/dev/null
source "$STATE_FILE"

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

if [[ -t 1 ]]; then
    C_OK="\033[32m"; C_BAD="\033[31m"; C_DIM="\033[2m"; C_RST="\033[0m"
else
    C_OK=""; C_BAD=""; C_DIM=""; C_RST=""
fi

PASS=0
FAIL=0
FAILURES=()

_pass() {
    ((PASS++))
    [[ $QUIET -eq 0 ]] && printf "  ${C_OK}✓${C_RST} %s\n" "$1"
}
_fail() {
    ((FAIL++))
    FAILURES+=("$1")
    printf "  ${C_BAD}✗${C_RST} %s${C_DIM}%s${C_RST}\n" "$1" "${2:+ — $2}"
}

# ---------- 헬퍼 ----------
check_cmd() {
    # check_cmd "설명" command args...
    local desc="$1"; shift
    local out
    if out=$("$@" 2>&1); then
        _pass "$desc"
    else
        _fail "$desc" "${out:0:120}"
    fi
}

check_iface_up() {
    local desc="$1" iface="$2"
    if ! ip link show "$iface" >/dev/null 2>&1; then
        _fail "$desc" "인터페이스 없음"
        return
    fi
    local state
    state=$(ip -o link show "$iface" | grep -oP 'state \K\S+')
    if [[ "$state" == "UP" || "$state" == "UNKNOWN" ]]; then
        _pass "$desc (state=$state)"
    else
        _fail "$desc" "state=$state"
    fi
}

check_iface_ip() {
    local desc="$1" iface="$2" expected_cidr="$3"
    local actual
    actual=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)
    if [[ "$actual" == "$expected_cidr" ]]; then
        _pass "$desc ($actual)"
    else
        _fail "$desc" "expected=$expected_cidr actual=${actual:-없음}"
    fi
}

check_service_active() {
    local desc="$1" svc="$2"
    if systemctl is-active --quiet "$svc"; then
        _pass "$desc"
    else
        local st
        st=$(systemctl is-active "$svc" 2>&1)
        _fail "$desc" "status=$st"
    fi
}

check_route() {
    local desc="$1" dst="$2" expected_gw="$3"
    local actual_gw
    actual_gw=$(ip route show "$dst" 2>/dev/null | grep -oP 'via \K\S+' | head -1)
    if [[ "$actual_gw" == "$expected_gw" ]]; then
        _pass "$desc (via $actual_gw)"
    else
        _fail "$desc" "expected via $expected_gw, actual=${actual_gw:-없음}"
    fi
}

check_default_route() {
    local desc="$1" expected_gw="$2"
    local actual
    actual=$(ip route show default 2>/dev/null | grep -oP 'via \K\S+' | head -1)
    if [[ "$actual" == "$expected_gw" ]]; then
        _pass "$desc (via $actual)"
    else
        _fail "$desc" "expected via $expected_gw, actual=${actual:-없음}"
    fi
}

check_ping() {
    local desc="$1" target="$2"
    if ping -c 2 -W 2 "$target" >/dev/null 2>&1; then
        _pass "$desc ($target)"
    else
        _fail "$desc" "ping $target 실패"
    fi
}

check_sta_associated() {
    local desc="$1" iface="$2" expected_ssid="$3"
    local actual
    actual=$(iw dev "$iface" link 2>/dev/null | grep -oP '^\s*SSID:\s*\K.+' | head -1)
    if [[ "$actual" == "$expected_ssid" ]]; then
        _pass "$desc (SSID=$actual)"
    else
        _fail "$desc" "expected SSID=$expected_ssid, actual=${actual:-미연결}"
    fi
}

check_hostapd_ssid() {
    local desc="$1" expected_ssid="$2"
    if ! systemctl is-active --quiet hostapd; then
        _fail "$desc" "hostapd 비활성"
        return
    fi
    local actual
    actual=$(grep -oP '^\s*ssid=\K.+' /etc/hostapd/hostapd.conf 2>/dev/null | head -1)
    if [[ "$actual" == "$expected_ssid" ]]; then
        _pass "$desc (SSID=$actual)"
    else
        _fail "$desc" "config ssid=$actual"
    fi
}

check_ip_forward() {
    local v
    v=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if [[ "$v" == "1" ]]; then
        _pass "IP forwarding 활성"
    else
        _fail "IP forwarding 활성" "ip_forward=$v"
    fi
}

check_iptables_nat() {
    local ap="$1" wan="$2"
    if sudo iptables -t nat -C POSTROUTING -o "$wan" -j MASQUERADE 2>/dev/null; then
        _pass "iptables NAT (MASQUERADE $wan)"
    else
        _fail "iptables NAT (MASQUERADE $wan)" "규칙 없음"
    fi
    if sudo iptables -C FORWARD -i "$ap" -o "$wan" -j ACCEPT 2>/dev/null; then
        _pass "iptables FORWARD $ap→$wan"
    else
        _fail "iptables FORWARD $ap→$wan" "규칙 없음"
    fi
}

# ============================================================
echo ""
echo "================================================"
echo "  RPi AP 설정 검증 — HOP #${HOP}"
echo "  AP=${AP_IF}  STA=${STA_IF:-N/A}  WAN=${WAN_IF:-N/A}"
echo "================================================"

# ---------- 공통: AP 측 ----------
echo ""
echo "[ AP ]"
check_iface_up   "AP 인터페이스 UP" "$AP_IF"
check_iface_ip   "AP IP 할당"        "$AP_IF" "${AP_IP}/24"
check_hostapd_ssid "hostapd SSID 일치" "$SSID"
check_service_active "hostapd 활성"    hostapd
check_service_active "dnsmasq 활성"    dnsmasq
check_service_active "rpi-ap-setup 활성"  rpi-ap-setup
check_service_active "rpi-ap-server 활성" rpi-ap-server
check_ip_forward

# ---------- HOP=1 전용: WAN / NAT / 인터넷 ----------
if [[ "$HOP" -eq 1 ]]; then
    echo ""
    echo "[ WAN / NAT ]"
    check_iface_up "WAN 인터페이스 UP" "$WAN_IF"
    # WAN_IF에 IP가 있는지(eth0 DHCP 또는 wifi 연결)
    if ip -o -4 addr show "$WAN_IF" 2>/dev/null | grep -q 'inet '; then
        _pass "WAN IP 할당"
    else
        _fail "WAN IP 할당" "$WAN_IF에 IPv4 없음"
    fi
    check_iptables_nat "$AP_IF" "$WAN_IF"
    check_ping "인터넷 연결" "8.8.8.8"
fi

# ---------- HOP>1: STA / 업스트림 ----------
if [[ "$HOP" -gt 1 ]]; then
    echo ""
    echo "[ STA / 업스트림 ]"
    check_iface_up        "STA 인터페이스 UP"      "$STA_IF"
    check_sta_associated  "업스트림 SSID 연결"     "$STA_IF" "$UPSTREAM_SSID"
    check_iface_ip        "STA 정적 IP"            "$STA_IF" "${STA_STATIC_IP}/24"
    check_default_route   "default route"          "$UPSTREAM_GW"
    check_ping            "업스트림 게이트웨이"     "$UPSTREAM_GW"
    check_ping            "루트 게이트웨이(E2E)"    "192.168.101.1"
    check_ping            "인터넷(End-to-End)"      "8.8.8.8"
fi

# ---------- HOP<3: 다운스트림 라우트 ----------
if [[ "$HOP" -lt 3 ]]; then
    echo ""
    echo "[ 다운스트림 라우트 ]"
    for i in $(seq $((HOP+1)) 3); do
        check_route "192.168.$((100+i)).0/24 → ${NEXT_HOP_IP}" \
                    "192.168.$((100+i)).0/24" "$NEXT_HOP_IP"
    done
fi

# ============================================================
echo ""
echo "================================================"
TOTAL=$((PASS + FAIL))
if [[ $FAIL -eq 0 ]]; then
    printf "  ${C_OK}모든 검사 통과 (%d/%d)${C_RST}\n" "$PASS" "$TOTAL"
else
    printf "  ${C_BAD}실패 %d / 통과 %d (총 %d)${C_RST}\n" "$FAIL" "$PASS" "$TOTAL"
    echo ""
    echo "실패 항목:"
    for f in "${FAILURES[@]}"; do
        printf "  ${C_BAD}-${C_RST} %s\n" "$f"
    done
fi
echo "================================================"

exit "$FAIL"
