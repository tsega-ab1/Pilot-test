#!/usr/bin/env bash
# check_pilot_test_repo.sh
# Usage:
#   ./check_pilot_test_repo.sh [github_username] [repo_name]
# Examples:
#   ./check_pilot_test_repo.sh myuser Pilot-test
#   ./check_pilot_test_repo.sh           # tries to infer owner from git remote, repo defaults to Pilot-test

set -e

# Defaults
REPO_NAME="${2:-Pilot-test}"
GITHUB_USER="$1"
GHTOKEN="${GHTOKEN:-}"   # optional: export GHTOKEN="your_token" before running

# Helper: try to infer owner from git remote if not provided
if [ -z "$GITHUB_USER" ]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # try to get origin URL
    origin_url=$(git remote get-url origin 2>/dev/null || true)
    if [ -n "$origin_url" ]; then
      # support URLs like git@github.com:owner/repo.git or https://github.com/owner/repo.git
      if [[ "$origin_url" =~ github.com[:/]+([^/]+)/([^/.]+) ]]; then
        GITHUB_USER="${BASH_REMATCH[1]}"
        # If repo name not explicitly passed, try to match it from remote
        if [ -z "$2" ]; then
          REPO_NAME="${BASH_REMATCH[2]}"
        fi
      fi
    fi
  fi
fi

# Final sanity check
if [ -z "$GITHUB_USER" ]; then
  echo "Error: GitHub username not provided and could not be inferred from git remote."
  echo "Usage: $0 [github_username] [repo_name]"
  exit 1
fi

echo "Checking repository: $GITHUB_USER/$REPO_NAME"
echo

# Show local folder listing if run inside the project folder
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Local repository (relative listing):"
  # show up to 3 levels deep to keep it readable
  find . -maxdepth 3 -print | sed 's#^\./##' | sed '/^$/d'
  echo
fi

# Try GitHub API: get recursive tree for main branch, fallback to master
api_call() {
  local branch="$1"
  local url="https://api.github.com/repos/${GITHUB_USER}/${REPO_NAME}/git/trees/${branch}?recursive=1"
  if [ -n "$GHTOKEN" ]; then
    curl -s -H "Authorization: token ${GHTOKEN}" "$url"
  else
    curl -s "$url"
  fi
}

echo "Remote repository content (GitHub API):"
# try main then master
resp="$(api_call main)"
# check if response contains "Not Found" or "422"
if echo "$resp" | grep -q '"message": "Not Found"' || echo "$resp" | grep -q '"message": "Invalid request"' || [ -z "$resp" ]; then
  echo " - Branch 'main' not found or API returned error. Trying branch 'master'..."
  resp="$(api_call master)"
fi

# If still error, print raw response and exit non-fatally
if echo "$resp" | grep -q '"message":'; then
  echo "GitHub API response:"
  echo "$resp" | sed -n '1,200p'
  echo
  echo "If this shows 'Bad credentials' or 'Not Found' check that:"
  echo " - Repo name & owner are correct"
  echo " - If private, you have set GHTOKEN with repo scope: export GHTOKEN=\"YOUR_TOKEN\""
  exit 1
fi

# Parse the tree and print path + type + size (if present)
if command -v jq >/dev/null 2>&1; then
  echo "$resp" | jq -r '.tree[] | "\(.type) \t \(.path) \t\(.size // "-")"' | column -t -s $'\t'
else
  # fallback to Python parser if jq not available
  python3 - <<PY - "$resp"
import sys, json
data = json.loads(sys.argv[1])
tree = data.get("tree", [])
for item in tree:
    typ = item.get("type","")
    path = item.get("path","")
    size = item.get("size", "-")
    print(f"{typ}\t{path}\t{size}")
PY "$resp" | column -t -s $'\t' 2>/dev/null || true
fi

echo
echo "Done."
