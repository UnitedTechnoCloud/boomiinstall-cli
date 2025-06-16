#!/bin/bash

CRON_JOB="*/10 * * * * /mnt/boomi/check_dns_and_restart.sh >> /var/log/dns_check.log 2>&1"
CRONTAB_TMP="/tmp/current_crontab_$$.txt"

# Dump current crontab into temp file
crontab -l 2>/dev/null > "$CRONTAB_TMP"

# Check if the job already exists
if ! grep -Fxq "$CRON_JOB" "$CRONTAB_TMP"; then
  echo "$CRON_JOB" >> "$CRONTAB_TMP"
  crontab "$CRONTAB_TMP"
  echo "Cron job added."
else
  echo "Cron job already exists. No action taken."
fi

# Clean up
rm -f "$CRONTAB_TMP"