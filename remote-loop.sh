#!/bin/bash
# CONFIG
WORKING_DIR=$(dirname "$0")
AVAILABILITY_CHECK_INTERVAL_SECONDS=${1:-60} # default 60s
DATABASE_FILE="$WORKING_DIR/remote-loop.db"
HOSTS_FILE="$WORKING_DIR/hosts.txt"
LOG_DIR="$WORKING_DIR/log"

clearLine='\e[1A\e[K' # For clearing output on the stdout if supported

# CODE
mkdir -p "$LOG_DIR"

function save_db() {
  declare -p database >"$DATABASE_FILE"
}

function timestamp() {
  date +%s # current time in ms
}

function return_code_symbol() {
  declare code="$1"
  if [[ $code == 0 ]]; then
    echo "✓"
  else
    echo "✗"
  fi
}

# Read update db and create file if not existing
declare -A database
if [ -f "$DATABASE_FILE" ]; then
  source "$DATABASE_FILE"
else
  save_db
fi

i=0
while true; do
  i=$((i + 1))
  echo -e "\n--- Loop #${i} ---"

  # Read hosts file
  hosts=()
  if [ -f "$HOSTS_FILE" ]; then
    readarray -t hosts <"$HOSTS_FILE"
  fi

  function executeSpecialCommand() {
    declare name=$1

    for host in "${hosts[@]}"; do
      IFS=' ' read -r special command <<<"$host"
      if [[ "$special" == $name* ]]; then
        echo "$name command: Executing…"
        ( # Subshell to not stop due to error
          eval "$command" >"$LOG_DIR/$name.txt" 2>&1
        )
        success=$?
        echo -e "${clearLine}$name command: $(return_code_symbol $success)"
      fi
    done
  }

  executeSpecialCommand "\$BEFORE_LOOP"

  # Loop over hosts
  for host in "${hosts[@]}"; do
    # Extract hostname and port
    IFS=' ' read -r hostname_port host_interval_seconds command <<<"$host"
    IFS=: read -r hostname port <<<"$hostname_port"

    # Ignore hosts entry if empty line or starts with # (comment)
    if [[ "$hostname" == "" ]] || [[ "$hostname" == [\#$]* ]]; then
      continue
    fi

    now=$(timestamp)
    if ((database[$hostname] < $now - $host_interval_seconds)); then
      echo "$hostname: Checking availability…"
      if nc -z "$hostname" ${port:-22} 2>/dev/null; then
        echo -e "${clearLine}${hostname}: Executing command…"
        host_log_file="$LOG_DIR/$hostname.txt"

        export now
        export host
        export host_log_file
        (# Subshell to not stop due to error
          eval "$command" >"$host_log_file" 2>&1
        )
        success=$?

        database[$hostname]=$now
        save_db
        echo -e "${clearLine}$hostname: $(return_code_symbol $success)"
      else
        echo -e "${clearLine}$hostname: ?"
      fi
    else
      echo "$hostname: ⧖"
    fi
  done

  executeSpecialCommand "\$AFTER_LOOP"

  echo -e "--- Loop end ---"

  # Wait some time
  sleep $AVAILABILITY_CHECK_INTERVAL_SECONDS
done
