#!/usr/bin/env bash
# Split-Symbol check for a DeepSeek Harness install.
#
# Reports whether any @deepseek-ai package could be loaded from two physical copies
# by the node that actually runs dsh. Exit 0 = healthy, 1 = split risk, 2 = usage.
#
# The important refinement over the usual one-liner: a copy under a DIFFERENT node
# version cannot be loaded by a process running another one, so it is NOT a split.
set -uo pipefail

echo "DSH split-Symbol check"
echo "======================"
echo

# --- which node runs dsh ------------------------------------------------------
node_bin=""
pids=$(pgrep -f 'dsh web' 2>/dev/null || true)
if [ -n "${pids:-}" ]; then
  for pid in $pids; do
    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    # `pgrep -f` also matches any shell whose command line merely mentions "dsh web",
    # so only a node process counts.
    case "$(basename "${exe:-}")" in
      node*) echo "running: dsh web (pid $pid) -> $exe"; node_bin="$node_bin$exe\n" ;;
    esac
  done
else
  echo "note: no running 'dsh web' process found; using the newest node on disk"
fi
echo

# --- 1. the real poison: a materialized tree inside a profile ------------------
hits=$(find "$HOME/.dsh/profiles" -type d -path '*/node_modules/@deepseek-ai/*' 2>/dev/null)
verdict=0
if [ -n "$hits" ]; then
  echo "SPLIT RISK - real @deepseek-ai directories inside a profile:"
  echo "$hits" | sed 's/^/  /'
  echo
  echo "  These shadow the symlinks into the single global copy. Fix:"
  echo "    rm -rf ~/.dsh/profiles/<profile>/node_modules/@deepseek-ai"
  echo "    # then restart dsh, and re-install plugins by COPYING files, not via 'dsh plugin add'"
  verdict=1
else
  echo "ok: no materialized @deepseek-ai directories under ~/.dsh/profiles"
fi
echo

# --- 2. every physical copy, grouped by the node that could load it ------------
echo "physical copies of @deepseek-ai/dsh-tools on this machine:"
find "$HOME/.nvm/versions/node" -type d -name dsh-tools -path '*@deepseek-ai*' 2>/dev/null \
  | xargs -r realpath 2>/dev/null | sort -u | while read -r p; do
      ver=$(printf '%s' "$p" | sed -n 's|.*/versions/node/\([^/]*\)/.*|\1|p')
      echo "  [$ver] $p"
    done
echo
echo "A copy under another node version cannot be loaded by a process running a"
echo "different one, so it is dormant rather than split. Only copies the SAME node"
echo "can reach - typically a materialized one inside a profile - collide."
echo

# --- 3. which copy would resolve from a profile --------------------------------
prof="${DSH_PROFILE:-web}"
scope="$HOME/.dsh/profiles/$prof/node_modules/@deepseek-ai"
if [ -d "$scope" ]; then
  echo "profile '$prof' has its OWN @deepseek-ai scope directory - that is the split:"
  ls -la "$scope" | head -10
  verdict=1
else
  echo "ok: profile '$prof' resolves @deepseek-ai/* from the shared ~/.dsh/profiles/node_modules"
fi
echo

if [ "$verdict" -eq 0 ]; then
  echo "VERDICT: healthy - one reachable copy."
else
  echo "VERDICT: SPLIT RISK - see above. Every tool call will fail until it is removed."
fi
exit "$verdict"
