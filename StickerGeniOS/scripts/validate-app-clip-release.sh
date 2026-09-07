#!/bin/sh
set -eu
# Both targets use the main app's registered public OAuth client.
if [ "${ACTION:-}" = "install" ]; then
  case "${STICKER_FACTORY_IOS_CLIENT_ID:-}" in
    ""|CONFIGURE_*|*'$('* )
      echo "error: Set the shared STICKER_FACTORY_IOS_CLIENT_ID before archiving."
      exit 1
      ;;
  esac
fi
