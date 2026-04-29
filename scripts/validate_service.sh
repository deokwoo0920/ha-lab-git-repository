#!/bin/bash
sleep 3
STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/)
if [ "$STATUS" = "200"]; then
  echo "검증 성공: HTTP $STATUS"
  exit 0
else
  echo "검증 실패: HTTP $STATUS"
  exit 1
fi
