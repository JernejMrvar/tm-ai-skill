#!/bin/bash
set -e

# Download skill doc to Claude's global config
mkdir -p ~/.claude
curl -sSL -o ~/.claude/tm-api.md \
  https://raw.githubusercontent.com/JernejMrvar/tm-ai-skill/main/SKILL.md

# Register in global CLAUDE.md (only once)
if ! grep -q "tm-api.md" ~/.claude/CLAUDE.md 2>/dev/null; then
  echo "" >> ~/.claude/CLAUDE.md
  echo "@~/.claude/tm-api.md" >> ~/.claude/CLAUDE.md
fi

# Create config template if it doesn't exist
if [ ! -f ~/.tm-config ]; then
  cat > ~/.tm-config << 'EOF'
TM_TOKEN=
TM_BASE_URL=https://test-management-project.vercel.app
EOF
  echo "Created ~/.tm-config — open it and add your token and base URL"
else
  echo "~/.tm-config already exists, skipping"
fi

echo ""
echo "Done. Next steps:"
echo "  1. Open ~/.tm-config and add your TM_TOKEN and TM_BASE_URL"
echo "  2. Restart Cursor or Claude Code"
