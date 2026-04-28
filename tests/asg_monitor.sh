#!/bin/bash
# =============================================================
# asg_monitor.sh — Auto Scaling Group 실시간 모니터링
# 사용법: bash asg_monitor.sh [ASG_NAME] [REGION] [INTERVAL_SEC]
# 예시:   bash asg_monitor.sh ha-lab-asg ap-northeast-2 15
# =============================================================
set -uo pipefail

ASG_NAME="${1:-ha-lab-asg}"
REGION="${2:-ap-northeast-2}"
INTERVAL="${3:-15}"
TG_NAME="${4:-ha-lab-tg}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

if ! command -v aws &>/dev/null; then
  echo -e "${RED}❌ AWS CLI 미설치${NC}"; exit 1
fi

clear
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   ASG 실시간 모니터링  (Ctrl+C 로 종료)          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo -e "  ASG  : ${BLUE}$ASG_NAME${NC}"
echo -e "  리전 : ${BLUE}$REGION${NC}"
echo -e "  갱신 : 매 ${INTERVAL}초"
echo ""

PREV_COUNT=0
ITERATION=0

get_cpu_metric() {
  local instance_id="$1"
  local end_time; end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local start_time; start_time=$(date -u -d "5 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -v-5M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

  if [ -z "$start_time" ]; then echo "N/A"; return; fi

  aws cloudwatch get-metric-statistics \
    --region "$REGION" \
    --namespace AWS/EC2 \
    --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value="$instance_id" \
    --start-time "$start_time" \
    --end-time "$end_time" \
    --period 300 \
    --statistics Average \
    --query 'sort_by(Datapoints, &Timestamp)[-1].Average' \
    --output text 2>/dev/null | xargs printf "%.1f" 2>/dev/null || echo "N/A"
}

get_alarm_state() {
  aws cloudwatch describe-alarms \
    --region "$REGION" \
    --alarm-name-prefix "TargetTracking-$ASG_NAME" \
    --query 'MetricAlarms[*].[AlarmName,StateValue]' \
    --output text 2>/dev/null || echo ""
}

get_tg_health() {
  local tg_arn
  tg_arn=$(aws elbv2 describe-target-groups \
    --region "$REGION" \
    --query "TargetGroups[?contains(TargetGroupName,'$(echo "$TG_NAME" | cut -c1-10)')].TargetGroupArn" \
    --output text 2>/dev/null | head -1 || echo "")

  if [ -z "$tg_arn" ]; then echo ""; return; fi

  aws elbv2 describe-target-health \
    --region "$REGION" \
    --target-group-arn "$tg_arn" \
    --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' \
    --output text 2>/dev/null || echo ""
}

while true; do
  ((ITERATION++))
  NOW=$(date '+%H:%M:%S')

  # ASG 정보 조회
  ASG_JSON=$(aws autoscaling describe-auto-scaling-groups \
    --region "$REGION" \
    --auto-scaling-group-names "$ASG_NAME" \
    --output json 2>/dev/null || echo '{"AutoScalingGroups":[]}')

  ASG_EXISTS=$(echo "$ASG_JSON" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin)['AutoScalingGroups']))" 2>/dev/null || echo "0")

  # 화면 이동 (2번째 갱신부터 덮어쓰기)
  if [ "$ITERATION" -gt 1 ]; then
    # 이전 출력 지우기 (대략 40줄)
    for _ in $(seq 1 42); do printf '\033[1A\033[2K'; done
  fi

  echo -e "${CYAN}── [$NOW] 갱신 #${ITERATION} ─────────────────────────────────────${NC}"

  if [ "$ASG_EXISTS" -eq 0 ]; then
    echo -e "  ${RED}❌ ASG '$ASG_NAME' 를 찾을 수 없습니다.${NC}"
  else
    MIN=$(echo "$ASG_JSON" | python3 -c \
      "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['MinSize'])" 2>/dev/null || echo "?")
    MAX=$(echo "$ASG_JSON" | python3 -c \
      "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['MaxSize'])" 2>/dev/null || echo "?")
    DESIRED=$(echo "$ASG_JSON" | python3 -c \
      "import sys,json; print(json.load(sys.stdin)['AutoScalingGroups'][0]['DesiredCapacity'])" 2>/dev/null || echo "?")

    INSTANCES=$(echo "$ASG_JSON" | python3 -c \
      "import sys,json; insts=json.load(sys.stdin)['AutoScalingGroups'][0].get('Instances',[]); [print(i['InstanceId']+'|'+i['LifecycleState']+'|'+i['HealthStatus']+'|'+i.get('AvailabilityZone','?')) for i in insts]" 2>/dev/null || echo "")

    CURRENT_COUNT=$(echo "$INSTANCES" | grep -c "InService" 2>/dev/null || echo 0)

    # 용량 변화 감지
    if [ "$CURRENT_COUNT" -gt "$PREV_COUNT" ] && [ "$ITERATION" -gt 1 ]; then
      echo -e "  ${GREEN}⬆  Scale OUT 감지! ${PREV_COUNT} → ${CURRENT_COUNT} 인스턴스${NC}"
    elif [ "$CURRENT_COUNT" -lt "$PREV_COUNT" ] && [ "$ITERATION" -gt 1 ]; then
      echo -e "  ${YELLOW}⬇  Scale IN 감지! ${PREV_COUNT} → ${CURRENT_COUNT} 인스턴스${NC}"
    fi
    PREV_COUNT=$CURRENT_COUNT

    # ASG 용량 표시
    echo -e "  ${BLUE}ASG 용량${NC}  Min:${MIN}  /  Desired:${DESIRED}  /  Max:${MAX}  /  현재:${CURRENT_COUNT}"
    echo ""

    # 인스턴스별 상태
    echo -e "  ${BLUE}인스턴스 상태${NC}"
    if [ -z "$INSTANCES" ]; then
      echo -e "    (인스턴스 없음)"
    else
      while IFS='|' read -r iid state health az; do
        CPU=$(get_cpu_metric "$iid")
        case "$state" in
          InService)    STATE_CLR="${GREEN}";;
          Pending*)     STATE_CLR="${YELLOW}";;
          Terminating*) STATE_CLR="${RED}";;
          *)            STATE_CLR="${NC}";;
        esac
        case "$health" in
          Healthy)   HEALTH_CLR="${GREEN}";;
          Unhealthy) HEALTH_CLR="${RED}";;
          *)         HEALTH_CLR="${YELLOW}";;
        esac
        printf "    ${BLUE}%-22s${NC}  ${STATE_CLR}%-15s${NC}  ${HEALTH_CLR}%-10s${NC}  AZ:%-15s  CPU:%s%%\n" \
          "$iid" "$state" "$health" "$az" "$CPU"
      done <<< "$INSTANCES"
    fi
    echo ""

    # ALB 대상 그룹 Health
    TG_HEALTH=$(get_tg_health)
    if [ -n "$TG_HEALTH" ]; then
      echo -e "  ${BLUE}ALB 대상 그룹 Health${NC}"
      while IFS='	' read -r iid state; do
        case "$state" in
          healthy)   SCLR="${GREEN}";;
          unhealthy) SCLR="${RED}";;
          *)         SCLR="${YELLOW}";;
        esac
        printf "    ${BLUE}%-22s${NC}  ${SCLR}%s${NC}\n" "$iid" "$state"
      done <<< "$TG_HEALTH"
      echo ""
    fi

    # CloudWatch 알람 상태
    ALARM_STATE=$(get_alarm_state)
    if [ -n "$ALARM_STATE" ]; then
      echo -e "  ${BLUE}CloudWatch 알람${NC}"
      while IFS='	' read -r aname astate; do
        case "$astate" in
          OK)        ACLR="${GREEN}";;
          ALARM)     ACLR="${RED}";;
          INSUFFICIENT_DATA) ACLR="${YELLOW}";;
          *)         ACLR="${NC}";;
        esac
        SHORT_NAME=$(echo "$aname" | sed 's/TargetTracking-ha-lab-asg-//' | cut -c1-40)
        printf "    %-42s  ${ACLR}%s${NC}\n" "$SHORT_NAME" "$astate"
      done <<< "$ALARM_STATE"
      echo ""
    fi

    # 최근 ASG 활동
    echo -e "  ${BLUE}최근 활동 (최신 3건)${NC}"
    aws autoscaling describe-scaling-activities \
      --region "$REGION" \
      --auto-scaling-group-name "$ASG_NAME" \
      --max-items 3 \
      --query 'Activities[*].[StatusCode,Description,StartTime]' \
      --output text 2>/dev/null | while IFS='	' read -r status desc stime; do
        case "$status" in
          Successful) SCLR="${GREEN}";;
          Failed)     SCLR="${RED}";;
          InProgress) SCLR="${YELLOW}";;
          *)          SCLR="${NC}";;
        esac
        SDESC=$(echo "$desc" | cut -c1-55)
        printf "    ${SCLR}%-12s${NC}  %-55s  %s\n" "$status" "$SDESC" "$(echo "$stime" | cut -c1-16)"
      done || echo "    (활동 없음)"
  fi

  echo ""
  echo -e "  ${MAGENTA}다음 갱신까지 ${INTERVAL}초... (Ctrl+C 종료)${NC}"
  sleep "$INTERVAL"
done
