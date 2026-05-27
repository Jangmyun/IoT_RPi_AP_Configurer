#!/bin/bash
# ============================================================
# IoT RPi AP Configurer - 통합 셋업 (오케스트레이션)
#
# 실제 로직은 sh_lib/ 모듈에 분리되어 있다:
#   sh_lib/common.sh   — 헬퍼, 상수, state.env
#   sh_lib/inputs.sh   — 대화형 입력, 인터페이스 감지
#   sh_lib/ap.sh       — hostapd / dnsmasq / AP 인터페이스 / NAT
#   sh_lib/routing.sh  — IP 포워딩, default/다운스트림 라우트
#   sh_lib/sta.sh      — STA 측 (HOP>1)
#   sh_lib/boot.sh     — /usr/local/bin/rpi-ap-boot.sh 생성
#   sh_lib/services.sh — systemd 유닛, 서비스 활성화, 상태 출력
# ============================================================

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$PROJECT_DIR/sh_lib"

for _mod in common inputs ap routing sta boot services; do
    # shellcheck source=/dev/null
    source "$LIB_DIR/${_mod}.sh"
done

echo "================================================"
echo "  IoT RPi AP Configurer - 통합 셋업"
echo "================================================"
echo ""

# ---------- 입력 수집 ----------
prompt_hop
detect_interfaces
prompt_wan
compute_next_hop
prompt_channel
confirm_settings
write_state_env

# ---------- 시스템 적용 ----------
log_step 1 8 "dnsmasq / hostapd 중지";              stop_ap_services
log_step 2 8 "/etc/hostapd/hostapd.conf 생성";       write_hostapd_conf
log_step 3 8 "/etc/dnsmasq.conf 생성";               write_dnsmasq_conf
log_step 4 8 "AP 인터페이스 설정 (${AP_IF})";        configure_ap_interface
log_step 5 8 "IP 포워딩 활성화";                     enable_ip_forward
log_step 6 8 "정적 라우팅 설정";                     setup_default_route
log_step 7 8 "dnsmasq 시작 + NAT";                   start_dnsmasq_service; setup_nat
log_step 8 8 "부팅 자동 시작 설정"

# --- STA 측 (HOP>1만 실제 적용; 함수 내부에서 가드) ---
write_sta_static_ip_dhcpcd
write_sta_wpa_conf
cleanup_nm_wifi_profiles
disable_conflicting_wpa_services
restart_sta_wpa
assign_sta_ip_immediate

# --- 부팅 스크립트 + systemd 유닛 ---
generate_boot_script
write_systemd_units
activate_services

# --- 다운스트림 라우트 (hostapd UP 이후) ---
add_downstream_routes

# ---------- 최종 상태 출력 ----------
print_final_status
