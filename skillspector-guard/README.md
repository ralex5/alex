# SkillSpector guard

PreToolUse hook that scans GitHub repos with NVIDIA SkillSpector (`--no-llm`) before
`git clone`, `gh repo clone`, `npx skills add`, `claude mcp add`, `pip/uv install git+…`
or `curl|wget … | sh/bash` run.

- LOW: allow silently · MEDIUM: allow + short warning
- HIGH/CRITICAL in prompt-injection / supply-chain / data-theft / malware categories:
  Claude Code → `permissionDecision: "ask"`; Codex → `"deny"` (Codex does not support "ask")
- Scan failure / >100 s / no GitHub link: allow + "NO SE REVISÓ" warning

## Install
```bash
uv tool install git+https://github.com/NVIDIA/skillspector.git
mkdir -p ~/.claude/hooks && cp skillspector-guard.sh ~/.claude/hooks/ && chmod +x ~/.claude/hooks/skillspector-guard.sh
# Claude Code: merge claude-settings.snippet.json into ~/.claude/settings.json
# Codex: merge codex-hooks.json into ~/.codex/hooks.json, then approve it with /hooks
```
Requires `jq`.
