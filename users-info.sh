#!/bin/bash

DOMAIN_MAP="/etc/userdomains"
DNS_SERVER="8.8.8.8"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

for cmd in whmapi1 uapi jq dig column; do
  command -v "$cmd" >/dev/null || {
    echo "$cmd not found"
    echo "Alma/CloudLinux/RHEL: dnf install -y jq bind-utils util-linux"
    echo "Ubuntu/Debian: apt install -y jq dnsutils bsdextrautils"
    exit 1
  }
done

join_lines() {
  local data="$1"
  if [[ -z "$data" ]]; then
    echo "-"
  else
    echo "$data" | paste -sd "," - | sed 's/,/, /g'
  fi
}

dns_raw() {
  local type="$1"
  local name="$2"

  dig @"$DNS_SERVER" +short +time=2 +tries=1 "$type" "$name" \
    | sed 's/\.$//' \
    | sort -u
}

dns_a() {
  local name="$1"

  dns_raw A "$name" \
    | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true
}

dns_cname() {
  local name="$1"

  dns_raw CNAME "$name"
}

dns_ns() {
  local name="$1"

  dns_raw NS "$name"
}

dns_mx() {
  local name="$1"

  dig @"$DNS_SERVER" +short +time=2 +tries=1 MX "$name" \
    | sed 's/\.$//' \
    | sort -n
}

mx_ips() {
  local domain="$1"
  local mx mx_host ips result=""

  mx=$(dns_mx "$domain")

  if [[ -z "$mx" ]]; then
    echo "-"
    return
  fi

  while read -r pref mx_host; do
    [[ -z "$mx_host" ]] && continue

    ips=$(dns_a "$mx_host" | paste -sd "," - | sed 's/,/, /g')

    if [[ -z "$ips" ]]; then
      result+="${mx_host} -> -; "
    else
      result+="${mx_host} -> ${ips}; "
    fi
  done <<< "$mx"

  echo "${result%; }"
}

fetch_user_info() {
  local user="$1"
  local info disklimit diskused suspended suspendedreason plan email_count

  info=$(whmapi1 accountsummary user="$user" --output=json 2>/dev/null)

  disklimit=$(echo "$info" | jq -r '.data.acct[0].disklimit // "N/A"')
  diskused=$(echo "$info" | jq -r '.data.acct[0].diskused // "N/A"')
  suspended=$(echo "$info" | jq -r '.data.acct[0].suspended // "N/A"')
  suspendedreason=$(echo "$info" | jq -r '.data.acct[0].suspendreason // "N/A"')
  plan=$(echo "$info" | jq -r '.data.acct[0].plan // "N/A"')

  email_count=$(uapi --output=json --user="$user" Email list_pops_with_disk 2>/dev/null \
    | jq -r '.result.data | length // 0')

  echo
  echo "================================================================================================================"
  echo "USER: $user"
  echo "================================================================================================================"
  echo "Disk Limit : $disklimit"
  echo "Disk Used  : $diskused"
  echo "Suspended  : $suspended"
  echo "Reason     : $suspendedreason"
  echo "Plan       : $plan"
  echo "Mailboxes  : $email_count"
  echo
}

print_dns_table() {
  local domains="$1"
  local domain ns a www_a www_cname www_result mx mxip

  {
    printf "DOMAIN\tNS\tA\tWWW A / CNAME\tMX\tMX IP\n"

    while IFS= read -r domain; do
      [[ -z "$domain" ]] && continue

      ns=$(join_lines "$(dns_ns "$domain")")
      a=$(join_lines "$(dns_a "$domain")")

      www_a=$(join_lines "$(dns_a "www.$domain")")
      www_cname=$(join_lines "$(dns_cname "www.$domain")")

      if [[ "$www_cname" != "-" && "$www_a" != "-" ]]; then
        www_result="$www_cname -> $www_a"
      elif [[ "$www_cname" != "-" ]]; then
        www_result="$www_cname"
      else
        www_result="$www_a"
      fi

      mx=$(join_lines "$(dns_mx "$domain")")
      mxip=$(mx_ips "$domain")

      printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$domain" "$ns" "$a" "$www_result" "$mx" "$mxip"

    done <<< "$domains"
  } | column -t -s $'\t'
}

declare -A user_domains

while IFS=: read -r domain user; do
  domain=$(echo "$domain" | xargs)
  user=$(echo "$user" | xargs)

  [[ -z "$domain" || -z "$user" ]] && continue
  [[ "$domain" == "*" ]] && continue
  [[ "$user" == "nobody" ]] && continue

  user_domains["$user"]+="$domain "
done < "$DOMAIN_MAP"

for user in $(printf "%s\n" "${!user_domains[@]}" | sort); do
  unique_domains=$(printf "%s\n" ${user_domains[$user]} | sort -u)

  fetch_user_info "$user"

  echo "Domains found: $(echo "$unique_domains" | grep -c .)"
  echo "DNS resolver : $DNS_SERVER"
  echo

  print_dns_table "$unique_domains"

  echo
done
