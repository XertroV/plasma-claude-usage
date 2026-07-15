#!/usr/bin/env bash
set -euo pipefail

kpackagetool6 -t Plasma/Applet -u .

reload_cmd='systemctl --user restart plasma-plasmashell.service'

# Agents should not yank plasmashell mid-session; humans usually want the
# widget live immediately. Override with INSTALL_RELOAD=1 (force) or =0 (print only).
is_agent_run() {
  case "${INSTALL_RELOAD:-}" in
    0|false|no|NO) return 0 ;;
    1|true|yes|YES) return 1 ;;
  esac

  local v
  for v in \
    "${GROK_AGENT:-}" \
    "${CLAUDECODE:-}" \
    "${CLAUDE_CODE_SESSION_ID:-}" \
    "${CLAUDE_SESSION_ID:-}" \
    "${CLAUDE_CODE_ENTRYPOINT:-}" \
    "${CODEX_THREAD_ID:-}" \
    "${CODEX_SANDBOX:-}" \
    "${CURSOR_AGENT:-}" \
    "${OPENCODE_SESSION_ID:-}" \
    "${C2C_OPENCODE_SESSION_ID:-}" \
    "${ANTIGRAVITY_CONVERSATION_ID:-}"
  do
    case "$v" in
      ""|0|false|no|FALSE|NO) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

echo ""
if is_agent_run; then
  echo "Installed. Reload plasmashell when you are ready:"
  echo "  $reload_cmd"
else
  echo "Installed. Reloading plasmashell..."
  systemctl --user restart plasma-plasmashell.service
  echo "Done."
fi
