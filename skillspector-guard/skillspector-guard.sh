#!/usr/bin/env bash
# skillspector-guard.sh — PreToolUse hook (Claude Code / Codex) que escanea con
# NVIDIA SkillSpector cualquier repo de GitHub antes de clonarlo/instalarlo.
#
#   Claude Code:  skillspector-guard.sh            (HIGH/CRITICAL -> "ask")
#   Codex:        skillspector-guard.sh --codex    (HIGH/CRITICAL -> "deny"; Codex no soporta "ask")
#
# Requiere: bash, jq, skillspector (uv tool install git+https://github.com/NVIDIA/skillspector.git)

set -u
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

MODE="claude"
[ "${1:-}" = "--codex" ] && MODE="codex"

# Límite interno del escaneo: menor que el timeout del hook (120 s) para poder
# responder "no se revisó" en vez de que el hook muera sin decir nada.
SCAN_TIMEOUT="${SKILLSPECTOR_GUARD_TIMEOUT:-100}"

# Categorías que, con HIGH/CRITICAL, hacen que se pregunte (Claude) o bloquee (Codex):
# prompt injection, supply chain, robo de datos y malware.
DANGEROUS_CATEGORIES='["Prompt Injection","MCP Tool Poisoning","MCP Rug Pull","Anti-Refusal",
  "Supply Chain",
  "Data Exfiltration","Privilege Escalation","Agent Snooping","System Prompt Leakage",
  "YARA Match","Rogue Agent"]'

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$CMD" ] && exit 0

# ---------- 1. ¿Es un comando que trae código de fuera? ----------
TRIGGER_RE='(^|[;&|(`[:space:]])(git[[:space:]]+([^;&|]*[[:space:]])?clone|gh[[:space:]]+repo[[:space:]]+clone|npx[[:space:]]+(-y[[:space:]]+|--yes[[:space:]]+)?skills(@[^[:space:]]+)?[[:space:]]+add|claude[[:space:]]+mcp[[:space:]]+add|pip3?[[:space:]]+install[[:space:]][^;&|]*git\+|python3?[[:space:]]+-m[[:space:]]+pip[[:space:]]+install[[:space:]][^;&|]*git\+|uv[[:space:]]+tool[[:space:]]+install[[:space:]][^;&|]*git\+)'
PIPE_SH_RE='(curl|wget)[^|;&]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)'

if ! printf '%s' "$CMD" | grep -Eq "$TRIGGER_RE" && ! printf '%s' "$CMD" | grep -Eq "$PIPE_SH_RE"; then
  exit 0   # Todo lo demás pasa sin tocarlo.
fi

# ---------- helpers de salida ----------
emit_warn() {   # deja pasar con aviso visible para el usuario y contexto para el modelo
  jq -cn --arg m "$1" '{systemMessage:$m, hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$m}}'
  exit 0
}
emit_block() {  # HIGH/CRITICAL peligroso
  if [ "$MODE" = "codex" ]; then
    jq -cn --arg r "$1" '{systemMessage:$r, hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
  else
    jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"ask", permissionDecisionReason:$r}}'
  fi
  exit 0
}

# ---------- 2. Sacar los repos de GitHub del comando ----------
extract_repos() {
  local c="$1"
  {
    # https://github.com/u/r, git@github.com:u/r, git+https://github.com/u/r.git@ref
    printf '%s\n' "$c" | grep -oE 'github\.com[:/][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
      | sed -E 's#^github\.com[:/]##'
    # raw.githubusercontent.com/u/r/... (típico en curl | sh)
    printf '%s\n' "$c" | grep -oE 'raw\.githubusercontent\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
      | sed -E 's#^raw\.githubusercontent\.com/##'
    # github:u/r
    printf '%s\n' "$c" | grep -oE '(^|[[:space:]])github:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
      | sed -E 's#^[[:space:]]*github:##'
    # forma corta usuario/repo tras gh repo clone / npx skills add / git clone
    printf '%s\n' "$c" | grep -oE '(gh[[:space:]]+repo[[:space:]]+clone|skills(@[^[:space:]]+)?[[:space:]]+add|git[[:space:]]+clone)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
      | grep -vE '(https?|git@|ssh|file):' \
      | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
  } | sed -E 's#\.git$##; s#[.,;:)]+$##' | awk -F/ 'NF==2 && $1!="" && $2!=""' | sort -u
}

REPOS="$(extract_repos "$CMD")"
if [ -z "$REPOS" ]; then
  emit_warn "⚠️ SkillSpector guard: este comando instala/clona código externo pero no encontré un link de GitHub. NO SE REVISÓ. Comando: ${CMD:0:200}"
fi

if ! command -v skillspector >/dev/null 2>&1; then
  emit_warn "⚠️ SkillSpector guard: skillspector no está instalado o no está en el PATH. NO SE REVISÓ: $(printf '%s' "$REPOS" | tr '\n' ' ')"
fi

# ---------- 3. Escanear, con caché y escaneo en segundo plano ----------
# Si el escaneo no termina en SCAN_TIMEOUT s, NO se mata: sigue en segundo plano y
# guarda el resultado en la caché. La próxima vez que corras el mismo comando, el
# guardia ya tiene el veredicto (repos grandes pueden tardar >10 min).
CACHE_DIR="${SKILLSPECTOR_GUARD_CACHE:-$HOME/.cache/skillspector-guard}"
CACHE_HOURS="${SKILLSPECTOR_GUARD_CACHE_HOURS:-24}"
mkdir -p "$CACHE_DIR"

is_fresh() { [ -s "$1" ] && [ -n "$(find "$1" -mmin -$((CACHE_HOURS * 60)) 2>/dev/null)" ]; }

run_scan() {  # $1=url $2=base (sin extensión) -> 0 ok (resultado en $2.json), 124 sigue corriendo, 1 fallo
  local url="$1" base="$2" pid waited=0
  is_fresh "$base.json" && return 0
  pid="$(cat "$base.running" 2>/dev/null)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$base.json" "$base.err"
    # Proceso desacoplado: no hereda stdout del hook, así el hook puede terminar antes que él.
    nohup sh -c '
      skillspector scan "$1" --no-llm -f json >"$2.partial" 2>"$2.err"
      if jq -e ".risk_assessment.score != null" "$2.partial" >/dev/null 2>&1; then mv "$2.partial" "$2.json"; else rm -f "$2.partial"; fi
      rm -f "$2.running"' sh "$url" "$base" >/dev/null 2>&1 </dev/null &
    pid=$!
    echo "$pid" >"$base.running"
  fi
  while [ "$waited" -lt "$SCAN_TIMEOUT" ]; do
    is_fresh "$base.json" && return 0
    kill -0 "$pid" 2>/dev/null || { is_fresh "$base.json" && return 0; return 1; }
    sleep 1; waited=$((waited + 1))
  done
  return 124
}

WARNINGS=""
BLOCKS=""
while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  url="https://github.com/$repo"
  base="$CACHE_DIR/$(printf '%s' "$repo" | tr '[:upper:]/' '[:lower:]_')"
  run_scan "$url" "$base"; rc=$?
  out="$base.json"

  if [ "$rc" -eq 124 ]; then
    WARNINGS+="⚠️ $url: el escaneo no terminó en ${SCAN_TIMEOUT}s. NO SE REVISÓ. Sigue escaneando en segundo plano; vuelve a intentarlo en unos minutos y el guardia usará el resultado."$'\n'
    continue
  elif [ "$rc" -ne 0 ]; then
    err="$(tail -c 300 "$base.err" 2>/dev/null | tr '\n' ' ')"
    WARNINGS+="⚠️ $url: el escaneo falló (${err:-sin detalle}). NO SE REVISÓ."$'\n'
    continue
  fi

  # ---------- 4. Leer score / severidad / hallazgos del JSON ----------
  summary="$(jq -r --argjson cats "$DANGEROUS_CATEGORIES" '
    def rank: {"CRITICAL":4,"HIGH":3,"MEDIUM":2,"LOW":1}[.] // 0;
    .risk_assessment as $ra
    | [.issues[]? | select(.severity != null)] as $all
    | ($all | map(select((.severity|rank) >= 3 and (.category as $c | $cats | index($c))))) as $dang
    | ($all | sort_by([-(.severity|rank), -(.confidence // 0)])
            | unique_by([.category, .pattern, .location.file])
            | sort_by([-(.severity|rank), -(.confidence // 0)])) as $top
    | {score: $ra.score, sev: ($ra.severity // "UNKNOWN"), dangerous: ($dang|length),
       complete: (.analysis_completeness.is_complete // true),
       top3: ($top[:3] | map("[\(.severity)] \(.category) / \(.pattern) — \(.location.file // "?"):\(.location.start_line // "?") «\((.finding // "")|tostring|.[:80])»")),
       counts: ($all | group_by(.severity) | map("\(.[0].severity)=\(length)") | join(", "))}
    | @json' "$out" 2>/dev/null)"

  if [ -z "$summary" ]; then
    WARNINGS+="⚠️ $url: no pude leer el JSON de SkillSpector. NO SE REVISÓ."$'\n'
    continue
  fi

  score="$(jq -r '.score' <<<"$summary")"
  sev="$(jq -r '.sev' <<<"$summary")"
  dangerous="$(jq -r '.dangerous' <<<"$summary")"
  counts="$(jq -r '.counts' <<<"$summary")"
  top3="$(jq -r '.top3 | to_entries | map("  \(.key+1). \(.value)") | join("\n")' <<<"$summary")"
  partial=""; [ "$(jq -r '.complete' <<<"$summary")" = "false" ] && partial=" (análisis parcial)"

  case "$sev" in
    LOW)
      : ;;  # silencio
    CRITICAL|HIGH)
      if [ "$dangerous" -gt 0 ]; then
        BLOCKS+="🛑 $url — score $score/100, $sev$partial ($counts)"$'\n'"$top3"$'\n'
      else
        WARNINGS+="⚠️ $url — score $score/100, $sev$partial, pero sin hallazgos graves de inyección/supply chain/robo de datos/malware:"$'\n'"$top3"$'\n'
      fi ;;
    MEDIUM)
      WARNINGS+="⚠️ $url — score $score/100, MEDIUM$partial ($counts):"$'\n'"$top3"$'\n' ;;
    *)
      WARNINGS+="⚠️ $url: severidad desconocida ($sev). NO SE REVISÓ bien."$'\n' ;;
  esac
done <<<"$REPOS"

# ---------- 5. Decisión ----------
if [ -n "$BLOCKS" ]; then
  if [ "$MODE" = "codex" ]; then head="SkillSpector BLOQUEÓ este comando (Codex no puede preguntarte). Reporte:"
  else head="SkillSpector encontró riesgo ALTO. ¿Quieres correrlo de todas formas?"; fi
  emit_block "$head"$'\n'"$BLOCKS${WARNINGS:+$'\n'$WARNINGS}"
fi
if [ -n "$WARNINGS" ]; then
  emit_warn "SkillSpector guard:"$'\n'"$WARNINGS"
fi
exit 0   # LOW: pasa en silencio
