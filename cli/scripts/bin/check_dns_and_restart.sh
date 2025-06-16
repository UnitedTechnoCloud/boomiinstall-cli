#!/bin/bash

# CONFIGURATION
DOMAINS=("flow-sql-prod-01.database.windows.net" "flow-sql-test-01.database.windows.net" "AZR-SVR-APP-D01.sanimax.int" "GRB-OT-SQL-P01.sanimax.int")  # List of DNS names
SNS_TOPIC_ARN="arn:aws:sns:ca-central-1:456486178888:boomi-sanimax-ATOM-dev-runtime-stack-NotificationTopic-0l1lG1GjuUNR"
AWS_REGION="ca-central-1"
HOSTNAME=$(hostname)
RETRY_INTERVAL=10

# Function to check if IP is private
is_private_ip() {
  local ip=$1
  if [[ $ip =~ ^10\. ]] || \
	 [[ $ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
	 [[ $ip =~ ^192\.168\. ]]; then
	  return 0  # Private
  else
	  return 1  # Public
  fi
}

# Loop until all domains resolve to private IPs
while true; do
  all_private=true
  for domain in "${DOMAINS[@]}"; do
	  resolved_ip=$(nslookup "$domain" | awk '/^Address: / { print $2 }' | tail -n1)

	  if [[ -z "$resolved_ip" ]]; then
		  echo "$(date): No IP resolved for $domain" >&2
		  all_private=false
		  continue
	  fi

	  echo "$(date): $domain resolves to $resolved_ip"

	  if is_private_ip "$resolved_ip"; then
		  echo "$(date): $domain resolved to private IP."
		  aws sns publish --region "$AWS_REGION" --topic-arn "$SNS_TOPIC_ARN" --subject "DNS Warning on $HOSTNAME" --message "$DNS_NAME Resolved to PUBLIC IP: $resolved_ip."			
	  else
		  echo "$(date): $domain resolved to PUBLIC IP ($resolved_ip). Restarting systemd-resolved.."
		  all_private=false

		  # Restart systemd-resolved
		  sudo systemctl restart systemd-resolved

		  # Send SNS notification
		  aws sns publish --region "$AWS_REGION" --topic-arn "$SNS_TOPIC_ARN" --subject "DNS Warning on $HOSTNAME" --message "$DNS_NAME Resolved to PUBLIC IP: $resolved_ip."
		  # Sleep before checking again
		  sleep "$RETRY_INTERVAL"
	  fi
  done

  # If all domains are private, exit the loop
  if $all_private; then
	  echo "$(date): All domains resolved to private IPs.Done."
	  break
  fi
done