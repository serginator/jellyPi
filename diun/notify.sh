#!/bin/sh
# Diun script notifier: queue the new tag for update-containers.py (poll), which
# turns it into a Telegram approval message. Runs inside the diun container.
echo "$DIUN_ENTRY_IMAGE" >> /data/new-tags.txt
