#!/bin/sh
# One entry point for both apps (each has its own script in Scripts/<app>/).
#   ./bundle.sh clipboard             only Clipboard Manager (.app + .dmg)
#   ./bundle.sh prompter              only Prompter (.app + .dmg)
#   ./bundle.sh prompter install      only Prompter, install to /Applications and launch (also: prompter app = .app only)
#   ./bundle.sh downloader            only Downloader (.app + .dmg; add "install" to install to /Applications and launch)
#   ./bundle.sh                       all three (same as: all)
set -e
cd "$(dirname "$0")"
case "${1:-all}" in
  clipboard) shift; exec Scripts/clipboard/bundle.sh "$@" ;;
  prompter)  shift; [ $# -eq 0 ] && set -- dmg; [ "$1" = app ] && shift; exec Scripts/prompter/bundle.sh "$@" ;;
  downloader) shift; exec Scripts/downloader/bundle.sh "$@" ;;
  all)       Scripts/clipboard/bundle.sh; Scripts/prompter/bundle.sh dmg; Scripts/downloader/bundle.sh ;;
  *)         echo "usage: ./bundle.sh [clipboard|prompter|downloader|all] [args]" >&2; exit 1 ;;
esac
