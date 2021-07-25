#!/bin/bash
# ------ CONFIG ------
DEFAULT_AVAILABILITY_INTERVAL_SECONDS=60
DEFAULT_WORKING_DIR="${PWD}"
DEFAULT_AVAILABILITY_TIMEOUT_SECONDS=1

# Override defaults
for i in "$@"
do
case $i in
    --help)
    echo "Script to repeatedly check for host availability via ssh, to automatically call commands."
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo
    echo "Options:"
    echo "--help          Shows this help text."
    echo "--workingDir    Set working directory database, log and hosts file path are based on"
    echo "                (defaults to current dir found under \$PWD')."
    echo "--interval      Set availability loop interval in seconds (defaults to '${DEFAULT_AVAILABILITY_INTERVAL_SECONDS}s')."
    echo "--timeout       Set availability check timeout per host address (defaults to '${DEFAULT_AVAILABILITY_TIMEOUT_SECONDS}s')."
    exit 0
    ;;

    --workingDir=*)
    ARG_WORKING_DIR="${i#*=}"
    shift
    ;;

    --interval=*)
    ARG_AVAILABILITY_INTERVAL_SECONDS="${i#*=}"
    shift
    ;;

    --timeout=*)
    ARG_AVAILABILITY_TIMEOUT_SECONDS="${i#*=}"
    shift
    ;;

    *) # unknown option
    echo "ERROR: Unknown option '${i}'"
    exit 1
    ;;
esac
done

# Argument defaulting
AVAILABILITY_INTERVAL_SECONDS=${ARG_AVAILABILITY_INTERVAL_SECONDS:-${DEFAULT_AVAILABILITY_INTERVAL_SECONDS}} # default 60s
AVAILABILITY_TIMEOUT_SECONDS=${ARG_AVAILABILITY_TIMEOUT_SECONDS:-${DEFAULT_AVAILABILITY_TIMEOUT_SECONDS}}
WORKING_DIR=${ARG_WORKING_DIR:-${DEFAULT_WORKING_DIR}}

DATABASE_FILE="$WORKING_DIR/remote-loop.db"
HOSTS_FILE="$WORKING_DIR/hosts.txt"
LOG_DIR="$WORKING_DIR/log"

# ------ CODE ------
clearLine='\e[1A\e[K' # For clearing output on the stdout if supported

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

function extractHostAndPort () {
  address=$1

  if [[ "$address" = [* ]]; then
    rawHost=$(echo "$address" | sed -nr 's/(\[.*])(:[0-9]+)?/\1/p')
    host=$(echo "$address" | sed -nr 's/\[(.*)](:[0-9]+)?/\1/p')
    port=$(echo "$address" | sed -nr 's/.+]:([0-9]+)/\1/p')
  else
    colonCount=$(echo "$address"| grep -o ":" | wc -l)
    if (( $colonCount > 1 )); then
      rawHost="$address"
      host="$address"
      port=""
    else
      IFS=: read -r host port <<<"$address"
    fi
  fi

  echo "$rawHost"
  echo "$host"
  echo "$port"
}

function getFirstAvailableHost() {
  raw_hosts=$1
  IFS=',' read -ra addresses <<< "$raw_hosts"

  for address in "${addresses[@]}"; do
    {
      read -r rawHost
      read -r host
      read -r port
    } <<< "$( extractHostAndPort "$address" )"

    defaultedPort=${port:-22}

    #echo "Testing host '${host}' with port ${defaultedPort}" 1>&2
    if ip -6 route get "$host/128" >/dev/null 2>&1; then
      nc -6 -z -w "$AVAILABILITY_TIMEOUT_SECONDS" "$host" "$defaultedPort" 2>/dev/null
    else
      nc    -z -w "$AVAILABILITY_TIMEOUT_SECONDS" "$host" "$defaultedPort" 2>/dev/null
    fi
    available=$?

    if [[ $available == 0 ]]; then
      echo "$rawHost"
      echo "$host"
      echo "$defaultedPort"
      return 0
    fi

  done

  return 1 # Nothing found
}

echo "Started remote-loop with settings:"
echo "Availability interval: ${AVAILABILITY_INTERVAL_SECONDS}s"
echo "Availability timeout: ${AVAILABILITY_TIMEOUT_SECONDS}s"
echo "Working directory: ${WORKING_DIR}"

i=0
while true; do
  i=$((i + 1))
  echo -e "\n--- Loop #${i} ---"

  # Read update db and create file if not existing
  if [ -f "$DATABASE_FILE" ]; then
    source "$DATABASE_FILE"
  else
    declare -A database=()
    save_db
  fi

  # Read host_entries file
  if [ -f "$HOSTS_FILE" ]; then
    # First ignore comments and empty lines with grep, then remove leading and finally trailing
    # whitespaces with sed.
    IFS=$'\n' host_entries=($(cat "$HOSTS_FILE" \
      | grep -v -E "^\s*(#.*)*$" \
      | sed -e 's/^[ \t]*//' \
      | sed -e 's/[ \t]*$//'))
  fi

  # Loop over host_entries
  for entry in "${host_entries[@]}"; do
    IFS=' ' read -r id host_interval_seconds addresses command <<<"$entry"
    echo
    echo "Id: $id"
    echo "Interval: $host_interval_seconds"
    echo "Addresses: $addresses"
    echo "Command: $command"

    host_start_timestamp_seconds=$(timestamp)
    if ((database[$id] < $host_start_timestamp_seconds - $host_interval_seconds)); then
      echo "Result: Checking availability…"
      {
        read -r rawHost
        read -r host
        read -r port
      } <<< "$( getFirstAvailableHost $addresses )"
      available=$?

      if [[ $available == 0 ]]; then
        echo -e "${clearLine}${id}: Executing command…"
        mkdir -p "$LOG_DIR" # Recreate dir removed
        host_log_file="$LOG_DIR/$id.txt"

        export RL_HOST_START_TIMESTAMP_SECONDS="$host_start_timestamp_seconds"
        export RL_ID="$id"
        export RL_RAW_HOST="$rawHost"
        export RL_HOST="$host"
        export RL_PORT="$port"
        export RL_HOST_INTERVAL_SECONDS="$host_interval_seconds"
        export RL_HOST_LOG_FILE="$host_log_file"
        export RL_WORKING_DIR="$WORKING_DIR"
        (# Subshell to not stop due to error
          eval "$command" >"$host_log_file" 2>&1
        )
        success=$?

        database[$id]=$host_start_timestamp_seconds
        save_db
        echo -e "${clearLine}Result: $(return_code_symbol $success)"
      else
        echo -e "${clearLine}Result: ?"
      fi
    else
      echo "$id: ⧖"
    fi
  done

  echo -e "--- Loop end ---"

  # Wait some time
  sleep $AVAILABILITY_INTERVAL_SECONDS
done
