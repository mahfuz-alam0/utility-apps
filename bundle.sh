#!/bin/sh
# One entry point for both apps (each has its own script in Scripts/<app>/).
#   ./bundle.sh [clipboard|prompter|all] [args]   default: all
#   ./bundle.sh prompter install                  extra args go to that app's script (prompter: install | dmg)
set -e
cd "$(dirname "$0")"
case "${1:-all}" in
  clipboard) shift; exec Scripts/clipboard/bundle.sh "$@" ;;
  prompter)  shift; exec Scripts/prompter/bundle.sh "$@" ;;
  all)       Scripts/clipboard/bundle.sh; Scripts/prompter/bundle.sh dmg ;;
  *)         echo "usage: ./bundle.sh [clipboard|prompter|all] [args]" >&2; exit 1 ;;
esac
