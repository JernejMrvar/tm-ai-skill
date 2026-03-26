#!/bin/bash
set -e

SKILL_URL="https://raw.githubusercontent.com/JernejMrvar/tm-ai-skill/main/SKILL.md"

echo "Installing TestManagement AI skill..."

# --- Claude Code ---
mkdir -p ~/.claude
curl -sSL -o ~/.claude/tm-api.md "$SKILL_URL"

if ! grep -q "tm-api.md" ~/.claude/CLAUDE.md 2>/dev/null; then
  echo "" >> ~/.claude/CLAUDE.md
  echo "@~/.claude/tm-api.md" >> ~/.claude/CLAUDE.md
fi
echo "✓ Claude Code: skill registered in ~/.claude/CLAUDE.md"

# --- Cursor ---
mkdir -p ~/.cursor/rules
curl -sSL -o ~/.cursor/rules/tm-api.md "$SKILL_URL"
echo "✓ Cursor: skill saved to ~/.cursor/rules/tm-api.md"

# --- Config file ---
if [ ! -f ~/.tm-config ]; then
  cat > ~/.tm-config << 'EOF'
TM_TOKEN=
TM_BASE_URL=https://test-management-project.vercel.app
EOF
  echo "✓ Created ~/.tm-config — open it and add your TM_TOKEN"
else
  echo "✓ ~/.tm-config already exists, skipping"
fi

echo ""
echo "Done. Next steps:"
echo "  1. Open ~/.tm-config and add your TM_TOKEN"
echo "  2. Restart Cursor or Claude Code"
