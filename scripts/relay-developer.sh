#!/usr/bin/env bash
# scripts/relay-developer.sh
# 🤖 Dual-Agent Unattended Relay Developer Pipeline
# 좌측 OMX(구현)와 우측 Gemini(리뷰)를 자동으로 번갈아 기동 및 감시하며
# 단계별로 [구현 -> 검토 -> 피드백 수정 -> 최종 승인] 프로세스를 무인으로 완수합니다.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OMX_PANE_FILE="$PROJECT_ROOT/.omx-pane"
GEMINI_PANE_FILE="$PROJECT_ROOT/.gemini-pane"

# 인자값 검증 (총 단계 수)
TOTAL_STEPS="${1:-}"
if [ -z "$TOTAL_STEPS" ] || [[ ! "$TOTAL_STEPS" =~ ^[0-9]+$ ]]; then
  echo "사용법: ./scripts/relay-developer.sh [총 개발 단계 수]"
  echo "예시  : ./scripts/relay-developer.sh 5 (총 5단계 개발 진행)"
  exit 1
fi

# Pane 정보 확인
if [ ! -f "$OMX_PANE_FILE" ] || [ ! -f "$GEMINI_PANE_FILE" ]; then
  echo "에러: tmux 세션이 실행 중이지 않거나 Pane ID 파일이 유실되었습니다."
  echo "먼저 './scripts/start-ai.sh gemini'를 실행하여 듀얼 창을 켜주세요."
  exit 1
fi

OMX_PANE="$(cat "$OMX_PANE_FILE")"
GEMINI_PANE="$(cat "$GEMINI_PANE_FILE")"

# ----------------------------------------------------
# 헬퍼 함수: 특정 Pane이 작업을 마치고 쉘(bash/zsh) 대기 상태로 복귀할 때까지 대기
# ----------------------------------------------------
wait_for_pane_idle() {
  local target_pane="$1"
  local pane_name="$2"
  echo -n "⏳ ${pane_name} 에이전트가 작업을 마칠 때까지 대기 중..."
  
  while true; do
    # 현재 Pane에서 구동 중인 최상위 명령어 확인
    local current_cmd
    current_cmd="$(tmux display-message -p -t "$target_pane" '#{pane_current_command}' 2>/dev/null || echo "inactive")"
    
    # bash, zsh, powershell 등 쉘 상태로 복귀했는지 체크 (OMX/Gemini 실행이 끝났음을 의미)
    if [[ "$current_cmd" =~ ^(bash|zsh|sh|powershell|pwsh|cmd)$ ]]; then
      echo " ✅ 완료!"
      break
    fi
    sleep 3
    echo -n "."
  done
}

# ----------------------------------------------------
# 헬퍼 함수: 특정 Pane의 최근 터미널 출력(콘텐츠) 긁어오기
# ----------------------------------------------------
capture_pane_output() {
  local target_pane="$1"
  # 최근 100라인의 터미널 출력을 긁어옴
  tmux capture-pane -p -S -100 -t "$target_pane" 2>/dev/null || echo ""
}

# ====================================================
# 메인 릴레이 파이프라인 루프 시작
# ====================================================
CURRENT_STEP=1

echo "===================================================="
echo "🤖 무인 릴레이 자동화 개발 파이프라인을 기동합니다."
echo "🎯 목표: 총 ${TOTAL_STEPS}단계 개발 완수"
echo "===================================================="

while [ "$CURRENT_STEP" -le "$TOTAL_STEPS" ]; do
  echo ""
  echo "----------------------------------------------------"
  echo "🚀 [현재 단계: ${CURRENT_STEP} / ${TOTAL_STEPS} 단계 개발 개시]"
  echo "----------------------------------------------------"

  # 1. 좌측 OMX에게 개발 지시 전송
  echo "💾 [구현 요청] 좌측 OMX 에이전트에게 ${CURRENT_STEP}단계 코딩을 지시합니다..."
  ./scripts/ask-codex.sh "\$executor 방금 기획서와 ToDo 일정표에 정의된 [${CURRENT_STEP}단계] 개발을 진행해줘. 완료되면 파일을 저장하고 쉘 대기 상태로 멈춰줘."
  
  # 2. 좌측 OMX가 개발을 끝마칠 때까지 무한 대기
  wait_for_pane_idle "$OMX_PANE" "좌측 OMX(개발)"

  # 3. 릴레이 루프: 리뷰어와 개발자 간 피드백 탁구 루프
  FEEDBACK_LOOP_COUNT=1
  while true; do
    echo ""
    echo "🔍 [리뷰 요청] 우측 Gemini 검토관에게 코드 리뷰 및 보안성 검토를 요청합니다... (반복 횟수: ${FEEDBACK_LOOP_COUNT}회)"
    
    # 최근 git diff 및 작성 파일 기준 검토 요청 프롬프트 조립
    local review_prompt="방금 OMX가 작성하거나 수정한 코드 파일에 대해 [${CURRENT_STEP}단계] 사양에 맞는지 코드 리뷰 및 보안성 검토를 수행해줘. 
    만약 보완이 필요한 에러나 가독성 결함, 보안 취약점이 있다면 반드시 구체적인 수정 가이드라인을 적어주고 마지막에 [REJECTED]를 포함해 대답해줘. 
    모든 검토가 성공적으로 끝나 승인할 수 있다면 마지막에 반드시 [APPROVED] 단어를 포함해 대답해줘."
    
    # 우측 Gemini에게 전송
    ./scripts/ask-gemini.sh "$review_prompt"
    
    # 우측 Gemini가 분석을 완료할 때까지 대기
    wait_for_pane_idle "$GEMINI_PANE" "우측 Gemini(검토)"
    
    # Gemini의 답변 긁어오기
    local gemini_verdict
    gemini_verdict="$(capture_pane_output "$GEMINI_PANE")"
    
    # 결과 판독 및 분기
    if echo "$gemini_verdict" | grep -Eq "\[APPROVED\]|APPROVED"; then
      echo "🎉 [검토 통과] ${CURRENT_STEP}단계 최종 승인(APPROVED)을 받았습니다!"
      break
    else
      echo "⚠️ [보완 필요] Gemini 검토관이 수정 요구[REJECTED]를 보냈습니다. 피드백을 수집하여 OMX에 재전송합니다."
      
      # Gemini의 피드백 내용만 텍스트로 축출
      local feedback_summary
      feedback_summary="$(echo "$gemini_verdict" | grep -A 20 -E "\[REJECTED\]|Issues|보완|에러|버그" | tail -n 25 || echo "코드 보완 및 에러 수정 요망")"
      
      echo "💾 [수정 지시] 좌측 OMX 에이전트에게 보완 코딩을 지시합니다..."
      ./scripts/ask-codex.sh "AUTO_FIX_FROM_GEMINI_REVIEW: Gemini가 지적한 다음 문제점과 수정 가이드를 바탕으로 코드를 고치고 보완해줘: $feedback_summary"
      
      # 다시 좌측 OMX가 고칠 때까지 대기
      wait_for_pane_idle "$OMX_PANE" "좌측 OMX(개발)"
      
      FEEDBACK_LOOP_COUNT=$((FEEDBACK_LOOP_COUNT + 1))
    fi
  done

  # 4. 마지막 단계 최종 완료 검증
  if [ "$CURRENT_STEP" -eq "$TOTAL_STEPS" ]; then
    echo ""
    echo "===================================================="
    echo "🎊 [최종 완료] 마지막 ${TOTAL_STEPS}단계까지 모두 구현 및 승인이 끝났습니다!"
    echo "👑 우측 Gemini 검토관의 최종 검증과 승인이 완료되었습니다."
    echo "💻 좌측 OMX 에이전트는 무한 대기(Idle) 상태로 성공적으로 종료됩니다."
    echo "===================================================="
    break
  fi

  # 5. 단계 올리기
  CURRENT_STEP=$((CURRENT_STEP + 1))
done

echo "🎉 모든 무인 릴레이 파이프라인 프로세스가 성공적으로 완료되었습니다!"
