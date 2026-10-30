#!/bin/sh
# One entry point for all apps (each has its own script in Scripts/<app>/).
#   ./bundle.sh clipboard             only Clipboard Manager (.app + .dmg)
#   ./bundle.sh prompter              only Prompter (.app + .dmg)
#   ./bundle.sh prompter install      only Prompter, install to /Applications and launch (also: prompter app = .app only)
#   ./bundle.sh adwall                only Adwall (.app + .dmg); adwall app = .app only; adwall install = .app, install to /Applications and launch
#   ./bundle.sh                       clipboard + prompter (same as: all)
set -e
cd "$(dirname "$0")"
case "${1:-all}" in
  clipboard) shift; exec Scripts/clipboard/bundle.sh "$@" ;;
  prompter)  shift; [ $# -eq 0 ] && set -- dmg; [ "$1" = app ] && shift; exec Scripts/prompter/bundle.sh "$@" ;;
  adwall)    shift; exec Scripts/adwall/bundle.sh "$@" ;;
  all)       Scripts/clipboard/bundle.sh; Scripts/prompter/bundle.sh dmg ;;
  *)         echo "usage: ./bundle.sh [clipboard|prompter|adwall|all] [args]" >&2; exit 1 ;;
esac
