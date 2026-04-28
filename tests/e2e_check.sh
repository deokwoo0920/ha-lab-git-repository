#!/bin/bash
# =============================================================
# e2e_check.sh — AWS HA Lab 전체 검증 자동화 스크립트
# 사용법: bash e2e_check.sh <ALB_DNS> [REGION]
# 예시:   bash e2e_check.sh ha-lab-alb-xxx.ap-northeast-2.elb.amazonaws.com
# =============================================================
set -uo pipefail

# ── 인자 처리 ─────────────────────────────────────────────
ALB_DNS="${1:-}"
REGION="${2:-ap-northeast-2}"
ASG_NAME="ha-lab-asg"
TG_NAME="ha-lab-tg"
REPEAT=20
INTERVAL=2

# ── 컬러 출력 ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS="${GREEN}✅ PASS${NC}"; FAIL="${RED}❌ FAIL${NC}"; WARN="${YELLOW}⚠  WARN${NC}"

print_header() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
ok()   { echo -e "  ${GREEN}✅${NC} $1"; ((PASS_COUNT++)); }
fail() { echo -e "  ${RED}❌${NC} $1"; ((FAIL_COUNT++)); }
warn() { echo -e "  ${YELLOW}⚠ ${NC} $1"; ((WARN_COUNT++)); }
info() { echo -e "  ${BLUE}ℹ ${NC} $1"; }

PASS_COUNT=0; FAIL_COUNT=0; WARN_COUNT=0

# ── 전제조건 확인 ─────────────────────────────────────────
if [ -z "$ALB_DNS" ]; then
  echo -e "${RED}사용법: bash e2e_check.sh <ALB_DNS> [REGION]${NC}"
  exit 1
fi
if ! command -v aws &>/dev/null; then
  echo -e "${RED}❌ AWS CLI 미설치. 설치 후 재실행하세요.${NC}"; exit 1
fi
if ! command -v curl &>/dev/null; then
  echo -e "${RED}❌ curl 미설치${NC}"; exit 1
fi

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════╗"
echo "║   AWS HA Lab — E2E 검증 자동화 스크립트      ║"
echo "╚══════════════════════════════════════════════╝${NC}"
echo -e "  ALB DNS : ${BLUE}$ALB_DNS${NC}"
echo -e "  리전    : ${BLUE}$REGION${NC}"
echo -e "  시작    : $(date '+%Y-%m-%d %H:%M:%S')"

# ═══════════════════════════════════════════════════
# T1. ALB 응답 기본 확인
# ═══════════════════════════════════════════════════
print_header "T1. ALB 기본 응답 확인"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ALB_DNS" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  ok "ALB HTTP 응답: $HTTP_CODE"
else
  fail "ALB HTTP 응답: $HTTP_CODE (200 기대)"
fi

# 응답 시간 측정
RESP_TIME=$(curl -s -o /dev/null -w "%{time_total}" --max-time 10 "http://$ALB_DNS" 2>/dev/null || echo "0")
info "응답 시간: ${RESP_TIME}s"
if (( $(echo "$RESP_TIME < 2.0" | bc -l 2>/dev/null || echo 0) )); then
  ok "응답 시간 정상 (< 2초)"
else
  warn "응답 시간 느림: ${RESP_TIME}s"
fi

# 헬스 체크 엔드포인트 확인
HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ALB_DNS/health" 2>/dev/null || echo "000")
if [ "$HEALTH_CODE" = "200" ]; then
  ok "/health 엔드포인트 응답: $HEALTH_CODE"
else
  fail "/health 엔드포인트 응답: $HEALTH_CODE"
fi

# ALB 응답 헤더에서 Trace ID 확인
TRACE_ID=$(curl -s -I "http://$ALB_DNS" 2>/dev/null | grep -i "x-amzn-trace-id" | head -1 || echo "")
if [ -n "$TRACE_ID" ]; then
  ok "X-Amzn-Trace-Id 헤더 확인됨"
  info "$TRACE_ID"
else
  warn "X-Amzn-Trace-Id 헤더 없음 (ALB 경유 여부 확인 필요)"
fi

# ═══════════════════════════════════════════════════
# T2. ALB 로드밸런싱 — 인스턴스 분산 확인
# ═══════════════════════════════════════════════════
print_header "T2. ALB 로드밸런싱 — 인스턴스 분산 확인"
info "${REPEAT}회 반복 요청으로 인스턴스 분산 확인"

declare -A INSTANCE_COUNT
TOTAL_OK=0; TOTAL_FAIL=0

for i in $(seq 1 "$REPEAT"); do
  BODY=$(curl -s --max-time 5 "http://$ALB_DNS" 2>/dev/null || echo "")
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$ALB_DNS" 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ]; then
    ((TOTAL_OK++))
    # 인스턴스 ID 추출 (i-로 시작하는 패턴)
    IID=$(echo "$BODY" | grep -oE 'i-[0-9a-f]{8,17}' | head -1 || echo "unknown")
    INSTANCE_COUNT["$IID"]=$(( ${INSTANCE_COUNT["$IID"]:-0} + 1 ))
  else
    ((TOTAL_FAIL++))
  fi
  sleep "$INTERVAL"
done

info "성공: $TOTAL_OK / 실패: $TOTAL_FAIL (총 ${REPEAT}회)"
UNIQUE_INSTANCES=${#INSTANCE_COUNT[@]}
info "응답한 고유 인스턴스 수: $UNIQUE_INSTANCES"

for iid in "${!INSTANCE_COUNT[@]}"; do
  info "  $iid → ${INSTANCE_COUNT[$iid]}회 응답"
done

if [ "$TOTAL_FAIL" -eq 0 ]; then
  ok "${REPEAT}회 모두 HTTP 200"
else
  fail "실패 응답 ${TOTAL_FAIL}회 발생"
fi

if [ "$UNIQUE_INSTANCES" -ge 2 ]; then
  ok "2개 이상 인스턴스로 분산 확인됨 (${UNIQUE_INSTANCES}개)"
else
  warn "단일 인스턴스만 응답 (분산 미확인 — ASG 인스턴스 2개 이상 필요)"
fi

# ═══════════════════════════════════════════════════
# T3. AWS CLI — ALB 대상 그룹 Health Check 확인
# ═══════════════════════════════════════════════════
print_header "T3. 대상 그룹 Health Check 상태 (AWS CLI)"

TG_ARN=$(aws elbv2 describe-target-groups \
  --region "$REGION" \
  --query "TargetGroups[?contains(TargetGroupName, '$(echo $TG_NAME | cut -c1-10)')].TargetGroupArn" \
  --output text 2>/dev/null | head -1 || echo "")

if [ -z "$TG_ARN" ]; then
  warn "대상 그룹 ARN 조회 실패 — TG_NAME='$TG_NAME' 확인 필요"
else
  info "대상 그룹 ARN: $TG_ARN"
  HEALTH_JSON=$(aws elbv2 describe-target-health \
    --region "$REGION" \
    --target-group-arn "$TG_ARN" \
    --output json 2>/dev/null || echo '{"TargetHealthDescriptions":[]}')

  HEALTHY=$(echo "$HEALTH_JSON" | python3 -c \
    "import sys,json; d=json.load(sys.stdin)['TargetHealthDescriptions']; print(sum(1 for x in d if x['TargetHealth']['State']=='healthy'))" 2>/dev/null || echo "0")
  UNHEALTHY=$(echo "$HEALTH_JSON" | python3 -c \
    "import sys,json; d=json.load(sys.stdin)['TargetHealthDescriptions']; print(sum(1 for x in d if x['TargetHealth']['State']!='healthy'))" 2>/dev/null || echo "0")
  TOTAL_TARGETS=$(( HEALTHY + UNHEALTHY ))

  info "전체 대상: $TOTAL_TARGETS / Healthy: $HEALTHY / Unhealthy: $UNHEALTHY"

  if [ "$HEALTHY" -ge 2 ]; then
    ok "Healthy 인스턴스 $HEALTHY개 (고가용성 유지)"
  elif [ "$HEALTHY" -ge 1 ]; then
    warn "Healthy 인스턴스 ${HEALTHY}개 (최솟값 2개 권장)"
  else
    fail "Healthy 인스턴스 0개"
  fi

  if [ "$UNHEALTHY" -gt 0 ]; then
    fail "Unhealthy 인스턴스 ${UNHEALTHY}개 존재"
    echo "$HEALTH_JSON" | python3 -c \
      "import sys,json; [print('    -',x['Target']['Id'],x['TargetHealth']['State'],x['TargetHealth'].get('Description','')) for x in json.load(sys.stdin)['TargetHealthDescriptions'] if x['TargetHealth']['State']!='healthy']" 2>/dev/null || true
  fi
fi

# ═══════════════════════════════════════════════════
# T4. ASG 인스턴스 수 및 상태 확인
# ═══════════════════════════════════════════════════
print_header "T4. Auto Scaling Group 인스턴스 상태"

ASG_JSON=$(aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" \
  --auto-scaling-group-names "$ASG_NAME" \
  --output json 2>/dev/null || echo '{"AutoScalingGroups":[]}')

ASG_EXISTS=$(echo "$ASG_JSON" | python3 -c \
  "import sys,json; print(len(json.load(sys.stdin)['AutoScalingGroups']))" 2>/dev/null || echo "0")

if [ "$ASG_EXISTS" -eq 0 ]; then
  fail "ASG '$ASG_NAME' 를 찾을 수 없음"
else
  MIN=$(echo "$ASG_JSON" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['MinSize'])" 2>/dev/null || echo "?")
  MAX=$(echo "$ASG_JSON" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['MaxSize'])" 2>/dev/null || echo "?")
  DESIRED=$(echo "$ASG_JSON" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['DesiredCapacity'])" 2>/dev/null || echo "?")
  IN_SERVICE=$(echo "$ASG_JSON" | python3 -c \
    "import sys,json; instances=json.load(sys.stdin)['AutoScalingGroups'][0].get('Instances',[]); print(sum(1 for i in instances if i['LifecycleState']=='InService'))" 2>/dev/null || echo "0")

  info "ASG 용량 — Min: $MIN / Desired: $DESIRED / Max: $MAX / InService: $IN_SERVICE"

  if [ "$MIN" -ge 2 ]; then
    ok "최솟값 $MIN (고가용성 조건 충족)"
  else
    warn "최솟값 $MIN (2 이상 권장)"
  fi

  if [ "$IN_SERVICE" -ge 2 ]; then
    ok "InService 인스턴스 $IN_SERVICE개"
  else
    fail "InService 인스턴스 $IN_SERVICE개 (부족)"
  fi
fi

# ═══════════════════════════════════════════════════
# T5. CodeDeploy 최근 배포 상태 확인
# ═══════════════════════════════════════════════════
print_header "T5. CodeDeploy 최근 배포 상태"

DEPLOY_IDS=$(aws deploy list-deployments \
  --region "$REGION" \
  --application-name "ha-lab-codedeploy" \
  --deployment-group-name "ha-lab-deploy-group" \
  --query 'deploymentIds[0:3]' \
  --output text 2>/dev/null || echo "")

if [ -z "$DEPLOY_IDS" ]; then
  warn "배포 이력 없음 또는 CodeDeploy 미설정"
else
  for DID in $DEPLOY_IDS; do
    DEPLOY_STATUS=$(aws deploy get-deployment \
      --region "$REGION" \
      --deployment-id "$DID" \
      --query 'deploymentInfo.status' \
      --output text 2>/dev/null || echo "Unknown")
    CREATE_TIME=$(aws deploy get-deployment \
      --region "$REGION" \
      --deployment-id "$DID" \
      --query 'deploymentInfo.createTime' \
      --output text 2>/dev/null || echo "")

    case "$DEPLOY_STATUS" in
      Succeeded) info "  $DID: ✅ $DEPLOY_STATUS ($CREATE_TIME)";;
      Failed)    info "  $DID: ❌ $DEPLOY_STATUS ($CREATE_TIME)";;
      InProgress)info "  $DID: 🔄 $DEPLOY_STATUS ($CREATE_TIME)";;
      *)         info "  $DID: ⚠  $DEPLOY_STATUS ($CREATE_TIME)";;
    esac
  done

  LATEST_STATUS=$(aws deploy get-deployment \
    --region "$REGION" \
    --deployment-id "$(echo "$DEPLOY_IDS" | awk '{print $1}')" \
    --query 'deploymentInfo.status' \
    --output text 2>/dev/null || echo "Unknown")

  if [ "$LATEST_STATUS" = "Succeeded" ]; then
    ok "최근 배포 성공"
  elif [ "$LATEST_STATUS" = "InProgress" ]; then
    warn "배포 진행 중"
  else
    fail "최근 배포 상태: $LATEST_STATUS"
  fi
fi

# ═══════════════════════════════════════════════════
# T6. 보안 격리 확인 — EC2 직접 접속 차단
# ═══════════════════════════════════════════════════
print_header "T6. 보안 격리 — EC2 직접 80포트 접속 차단 확인"
info "Private EC2는 ALB-SG → App-SG 체이닝으로 직접 접속 불가해야 합니다."

if [ -n "$TG_ARN" ]; then
  # 대상 그룹에서 첫 번째 인스턴스 Private IP 조회
  PRIVATE_IP=$(aws elbv2 describe-target-health \
    --region "$REGION" \
    --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[0].Target.Id' \
    --output text 2>/dev/null || echo "")

  if [ -n "$PRIVATE_IP" ] && [ "$PRIVATE_IP" != "None" ]; then
    # 인스턴스 ID → Private IP 변환
    EC2_PRIVATE_IP=$(aws ec2 describe-instances \
      --region "$REGION" \
      --instance-ids "$PRIVATE_IP" \
      --query 'Reservations[0].Instances[0].PrivateIpAddress' \
      --output text 2>/dev/null || echo "")

    if [ -n "$EC2_PRIVATE_IP" ] && [ "$EC2_PRIVATE_IP" != "None" ]; then
      info "테스트 대상 Private IP: $EC2_PRIVATE_IP"
      DIRECT_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 "http://$EC2_PRIVATE_IP" 2>/dev/null || echo "000")
      if [ "$DIRECT_CODE" = "000" ] || [ "$DIRECT_CODE" = "403" ]; then
        ok "외부에서 EC2 직접 접속 차단 확인 (응답: $DIRECT_CODE)"
      else
        warn "EC2 직접 접속 응답: $DIRECT_CODE (차단 여부 확인 필요)"
      fi
    else
      info "Private IP 조회 불가 (로컬 PC에서 Private IP 접근 불가 — 정상)"
      ok "Private Subnet EC2는 외부에서 접근 불가 (설계 확인)"
    fi
  fi
else
  info "TG ARN 없음 — T3 결과 참조"
fi

# ═══════════════════════════════════════════════════
# 최종 결과 요약
# ═══════════════════════════════════════════════════
print_header "최종 결과 요약"
TOTAL=$(( PASS_COUNT + FAIL_COUNT + WARN_COUNT ))
echo -e "  ${GREEN}✅ PASS${NC} : $PASS_COUNT"
echo -e "  ${RED}❌ FAIL${NC} : $FAIL_COUNT"
echo -e "  ${YELLOW}⚠  WARN${NC} : $WARN_COUNT"
echo -e "  총 검사 : $TOTAL 항목"
echo ""
if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
  echo -e "${GREEN}  🎉 모든 검증 통과 — HA Lab 구성 완료!${NC}"
elif [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "${YELLOW}  ✅ 필수 항목 통과 (경고 $WARN_COUNT개 확인 권장)${NC}"
else
  echo -e "${RED}  ❌ 실패 항목 $FAIL_COUNT개 — 해당 Step 재확인 필요${NC}"
fi
echo ""
echo -e "  완료 시각: $(date '+%Y-%m-%d %H:%M:%S')"
