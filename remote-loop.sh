#!/bin/bash
# CONFIG
WORKING_DIR=${1:-$(dirname "$0")}
AVAILABILITY_CHECK_INTERVAL_SECONDS=5 #$((60*10))
DATABASE_FILE="$WORKING_DIR/remote-loop.db"
HOSTS_FILE="$WORKING_DIR/hosts.txt"
LOG_DIR="$WORKING_DIR/log"

clearLine='\e[1A\e[K'

# CODE
mkdir -p "$LOG_DIR"

function save_db () {
  declare -p database > "$DATABASE_FILE"
}

function timestamp() {
  date +%s # current time in ms
}

# Read update db and create file if not existing
declare -A database
if [ -f "$DATABASE_FILE" ];then
  source "$DATABASE_FILE"
else
  save_db
fi

i=0;
while true
do
  i=$((i+1))
  echo -e "\nLoop #${i}"

	# Read hosts file
	hosts=()
	if [ -f "$HOSTS_FILE" ];then
    readarray -t hosts < "$HOSTS_FILE"
  fi

  # Loop over hosts
  for host in "${hosts[@]}"
  do
    # Extract hostname and port
    IFS=' ' read -r hostname_port host_interval_seconds command <<< "$host"
    IFS=: read -r hostname port <<< "$hostname_port"

    now=$(timestamp)
    if (( database[$hostname] < $now - $host_interval_seconds  )); then
      echo "$hostname: Checking availability…"
      if nc -z $hostname ${port:-22} 2>/dev/null; then
          echo -e "${clearLine}${hostname}: Executing command…"
          ( # Subshell to not stop due to error
            eval $command > "$LOG_DIR/$hostname.txt"
          )
          database[$hostname]=$now
          save_db
          echo -e "${clearLine}$hostname: ✓"
      else
          echo -e "${clearLine}$hostname: ✗"
      fi
    else
      echo "$hostname: -"
    fi
  done

  # Wait some time
	sleep $AVAILABILITY_CHECK_INTERVAL_SECONDS
done

