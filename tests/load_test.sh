#!/bin/bash
# =============================================================
# load_test.sh — ALB 무중단 배포 검증 + 로드밸런싱 확인
# 사용법: bash load_test.sh <ALB_DNS> [MODE] [DURATION_SEC]
# MODE: balance(분산확인) | zero-downtime(무중단) | stress(부하)
# 예시:  bash load_test.sh ha-lab-alb-xxx.elb.amazonaws.com zero-downtime 120
# =============================================================
set -uo pipefail

ALB_DNS="${1:-}"
MODE="${2:-balance}"
DURATION="${3:-60}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

if [ -z "$ALB_DNS" ]; then
  echo -e "${RED}사용법: bash load_test.sh <ALB_DNS> [MODE] [DURATION_SEC]${NC}"
  echo "  MODE: balance | zero-downtime | stress"
  exit 1
fi

# ── 공통: HTTP 요청 함수 ────────────────────────────────────
http_get() {
  local url="$1"
  curl -s -o /dev/null -w "%{http_code}|%{time_total}|%{size_download}" \
    --max-time 10 "$url" 2>/dev/null || echo "000|0|0"
}

http_get_body() {
  curl -s --max-time 10 "$1" 2>/dev/null || echo ""
}

# ═══════════════════════════════════════════════════
# MODE 1: balance — 로드밸런싱 분산 확인
# ═══════════════════════════════════════════════════
if [ "$MODE" = "balance" ]; then
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}  로드밸런싱 분산 확인  (${DURATION}초간)${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  declare -A IID_COUNT
  TOTAL=0; OK=0; FAIL=0
  START=$(date +%s)

  while [ $(( $(date +%s) - START )) -lt "$DURATION" ]; do
    BODY=$(http_get_body "http://$ALB_DNS")
    RESP=$(http_get "http://$ALB_DNS")
    CODE=$(echo "$RESP" | cut -d'|' -f1)
    TIME=$(echo "$RESP" | cut -d'|' -f2)

    ((TOTAL++))
    if [ "$CODE" = "200" ]; then
      ((OK++))
      IID=$(echo "$BODY" | grep -oE 'i-[0-9a-f]{8,17}' | head -1 || echo "unknown")
      IID_COUNT["$IID"]=$(( ${IID_COUNT["$IID"]:-0} + 1 ))
      printf "  [%3d] ${GREEN}HTTP %s${NC}  %.3fs  %s\n" "$TOTAL" "$CODE" "$TIME" "$IID"
    else
      ((FAIL++))
      printf "  [%3d] ${RED}HTTP %s${NC}  %.3fs\n" "$TOTAL" "$CODE" "$TIME"
    fi
    sleep 2
  done

  echo ""
  echo -e "${CYAN}── 결과 집계 ───────────────────────────────────${NC}"
  echo -e "  총 요청: $TOTAL | ${GREEN}성공: $OK${NC} | ${RED}실패: $FAIL${NC}"
  echo -e "  성공률: $(echo "scale=1; $OK * 100 / $TOTAL" | bc -l 2>/dev/null || echo "?")%"
  echo ""
  echo "  인스턴스별 응답 분포:"
  for iid in "${!IID_COUNT[@]}"; do
    PCT=$(echo "scale=1; ${IID_COUNT[$iid]} * 100 / $OK" | bc -l 2>/dev/null || echo "?")
    echo -e "    ${BLUE}$iid${NC}: ${IID_COUNT[$iid]}회 (${PCT}%)"
  done
  UNIQUE=${#IID_COUNT[@]}
  echo ""
  if [ "$FAIL" -eq 0 ] && [ "$UNIQUE" -ge 2 ]; then
    echo -e "  ${GREEN}✅ 로드밸런싱 확인: $UNIQUE개 인스턴스로 분산, 실패 없음${NC}"
  elif [ "$FAIL" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠  응답은 정상이나 단일 인스턴스만 응답 (ASG 인스턴스 수 확인)${NC}"
  else
    echo -e "  ${RED}❌ 실패 ${FAIL}회 발생${NC}"
  fi
fi

# ═══════════════════════════════════════════════════
# MODE 2: zero-downtime — 무중단 배포 검증
# ═══════════════════════════════════════════════════
if [ "$MODE" = "zero-downtime" ]; then
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}  무중단 배포 검증 (${DURATION}초간 HTTP 200 유지 확인)${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━════════════${NC}"
  echo -e "  ${YELLOW}지금 다른 터미널에서 git push 를 실행하세요!${NC}"
  echo ""

  TOTAL=0; OK=0; FAIL=0
  MAX_CONSECUTIVE_FAIL=0; CONSECUTIVE_FAIL=0
  START=$(date +%s)
  PREV_VERSION=""

  while [ $(( $(date +%s) - START )) -lt "$DURATION" ]; do
    RESP=$(http_get "http://$ALB_DNS")
    CODE=$(echo "$RESP" | cut -d'|' -f1)
    TIME=$(echo "$RESP" | cut -d'|' -f2)
    ELAPSED=$(( $(date +%s) - START ))

    ((TOTAL++))
    if [ "$CODE" = "200" ]; then
      ((OK++))
      CONSECUTIVE_FAIL=0
      BODY=$(http_get_body "http://$ALB_DNS")
      VERSION=$(echo "$BODY" | grep -oP '배포 버전:\s*\K[^\s<"]+' | head -1 \
              || echo "$BODY" | grep -oP 'v[0-9]+\.[0-9]+' | head -1 \
              || echo "?")

      if [ "$VERSION" != "$PREV_VERSION" ] && [ "$PREV_VERSION" != "" ] && [ "$VERSION" != "?" ]; then
        printf "  [%3ds] ${GREEN}HTTP %s${NC}  %.3fs  ${CYAN}🔄 버전 변경: %s → %s${NC}\n" \
          "$ELAPSED" "$CODE" "$TIME" "$PREV_VERSION" "$VERSION"
      else
        printf "  [%3ds] ${GREEN}HTTP %s${NC}  %.3fs  ver:%s\n" "$ELAPSED" "$CODE" "$TIME" "$VERSION"
      fi
      PREV_VERSION="$VERSION"
    else
      ((FAIL++))
      ((CONSECUTIVE_FAIL++))
      [ "$CONSECUTIVE_FAIL" -gt "$MAX_CONSECUTIVE_FAIL" ] && MAX_CONSECUTIVE_FAIL=$CONSECUTIVE_FAIL
      printf "  [%3ds] ${RED}HTTP %s${NC}  %.3fs  ← 서비스 중단!\n" "$ELAPSED" "$CODE" "$TIME"
    fi
    sleep 3
  done

  echo ""
  echo -e "${CYAN}── 무중단 배포 결과 ────────────────────────────${NC}"
  echo -e "  총 요청: $TOTAL | ${GREEN}성공: $OK${NC} | ${RED}실패: $FAIL${NC}"
  UPTIME=$(echo "scale=2; $OK * 100 / $TOTAL" | bc -l 2>/dev/null || echo "?")
  echo -e "  가용성(Uptime): ${UPTIME}%"
  echo -e "  최대 연속 실패: ${MAX_CONSECUTIVE_FAIL}회"
  echo ""
  if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}✅ 완벽한 무중단 배포 확인 — 서비스 중단 없음 (가용성 100%)${NC}"
  elif [ "$FAIL" -le 2 ]; then
    echo -e "  ${YELLOW}⚠  ${FAIL}회 실패 (허용 범위 내) — Health Check 간격 조정 권장${NC}"
  else
    echo -e "  ${RED}❌ 서비스 중단 ${FAIL}회 — Rolling 배포 설정 및 Warmup 시간 확인 필요${NC}"
  fi
fi

# ═══════════════════════════════════════════════════
# MODE 3: stress — Auto Scaling 트리거용 부하 생성
# ═══════════════════════════════════════════════════
if [ "$MODE" = "stress" ]; then
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}  ALB 부하 테스트 — Auto Scaling 트리거 유도${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ${YELLOW}주의: ALB에 부하를 주어 CloudWatch 지표를 높입니다.${NC}"
  echo -e "  동시 요청 수: 10 / 테스트 시간: ${DURATION}초"
  echo ""

  TOTAL=0; OK=0; FAIL=0
  START=$(date +%s)

  # 병렬 요청 함수
  send_burst() {
    local count=10
    for _ in $(seq 1 $count); do
      curl -s -o /dev/null --max-time 5 "http://$ALB_DNS" &
    done
    wait
  }

  while [ $(( $(date +%s) - START )) -lt "$DURATION" ]; do
    ELAPSED=$(( $(date +%s) - START ))
    send_burst
    # 단건 측정
    RESP=$(http_get "http://$ALB_DNS")
    CODE=$(echo "$RESP" | cut -d'|' -f1)
    ((TOTAL+=11))
    if [ "$CODE" = "200" ]; then
      ((OK++))
      printf "\r  [%3ds] 요청 누적: %-5d  ${GREEN}OK${NC}" "$ELAPSED" "$TOTAL"
    else
      ((FAIL++))
      printf "\r  [%3ds] 요청 누적: %-5d  ${RED}FAIL:$CODE${NC}" "$ELAPSED" "$TOTAL"
    fi
    sleep 1
  done

  echo ""
  echo ""
  echo -e "${CYAN}── 부하 테스트 결과 ────────────────────────────${NC}"
  echo -e "  누적 요청: ~$TOTAL회 / ${DURATION}초"
  echo -e "  ${YELLOW}⚡ CloudWatch → ASG 콘솔에서 Scale Out 이벤트를 확인하세요.${NC}"
  echo -e "  확인 명령어:"
  echo -e "    aws autoscaling describe-scaling-activities \\"
  echo -e "      --auto-scaling-group-name ha-lab-asg --max-items 5"
fi
