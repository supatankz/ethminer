#!/bin/bash

declare LOG_FILE LOG_BACKUP_FILE WALLET_ADDRESS MINING_POOL
WALLET_ADDRESS="0x8456b6c7b7e5c971fa562efcbafec4592fabd5de"
LOG_FILE="/tmp/ethminer.log"
DEBUG_MODE=false

logit() {
	echo "[$(date '+%D %T')]: $*"
}

# Overwrite the log message on the same line.
same_line_log() {
  # \b is code for backspace. The for loop will hit backspace 1000 times
  for ((i=0; i<1000; i++)); do echo -ne "\b"; done
	# Print message on same line
	echo -n "[$(date '+%D %T')]: $* "
  for ((i=0; i<50; i++)); do echo -ne " "; done
  for ((i=0; i<50; i++)); do echo -ne "\b"; done
}
Restart_Ethminer() {

  LOG_BACKUP_FILE="/tmp/ethminer-$(date +%d%m%Y_%T)-backup.log"
	logit "Re-Starting ethminer. Reason: $1"
	ETHMINER_COMMAND="./ethminer -G -P stratum1+tcp://$WALLET_ADDRESS@$MINING_POOL"
	if $DEBUG_MODE; then 
	  logit "DEBUG: $ETHMINER_COMMAND"
	  return 0;
	fi

	# Interrupt any existing running instance.
	pkill -INT ethminer
	# wait for it to die
	cp -fv "$LOG_FILE" "$LOG_BACKUP_FILE"

	 $ETHMINER_COMMAND > "$LOG_FILE" 2>&1 &
}

IsFileGrowing() {
  prev_count=$1
	current_count=$2
	if [[ $current_count -gt $prev_count ]]; then return true; fi

	return false
}

ParseFlags() {
  declare -A MINING_POOL_PATHS
	MINING_POOL_PATHS[ethermine]="us2.ethermine.org:4444"
	MINING_POOL_PATHS[ethpool]="us1.ethpool.org:3333"
	MINING_POOL_PATHS[2miners]="eth.2miners.com:2020"

  if [[ -n "$1" ]] && [[ -n "${MINING_POOL_PATHS[$1]}" ]]
	then MINING_POOL=${MINING_POOL_PATHS[$1]}
	else logit "ERROR: Invalid mining pool option: '$1'. Valid options: ${!MINING_POOL_PATHS[@]}"
			 return 1
	fi
	logit "Selected ${MINING_POOL_PATHS[$1]} for '$1'"
}

if ! ParseFlags $*;
then
  logit "Exiting.."
	exit 1;
fi

CHECK_EVERY_SECONDS=10
ALLOW_HASHRATE_FOR_SECONDS=200
if $DEBUG_MODE
then
  CHECK_EVERY_SECONDS=2
	ALLOW_HASHRATE_FOR_SECONDS=20
	LOG_FILE=/tmp/ethminer-debug.log
	touch $LOG_FILE
fi

Restart_Ethminer "FIRST_START"

logit "Monitoring ethminer every $CHECK_EVERY_SECONDS seconds for failures.."
num_lines_in_file_previous=0
prev_low_hashrate_count=0
while sleep $CHECK_EVERY_SECONDS  # check every $CHECK_EVERY_SECONDS
do # Check whether the log file is growing and hashrate

	# Find number of lines in file.
  num_lines_in_file=$(wc -l "$LOG_FILE" | cut -d' ' -f1)

	# Use ansi2txt to remove formatting characters from log line.
	latest_hashrate=$(grep ' m ' "$LOG_FILE" | ansi2txt | tail -1 | cut -d' ' -f11)
	# remove floating point and keep the int section
	latest_hashrate=${latest_hashrate%.*}
	# hashrate could be "" when the program has started few mins ago.
	# hence, set latest_hashrate to higher than threashold
	if [[ "$latest_hashrate" == "" ]]; then latest_hashrate=11; fi

	latest_hashrate_log=$(grep ' m ' "$LOG_FILE" | tail -1 | cut -d' ' -f 3,7,8)
	num_accepted=$(grep '**Accepted' "$LOG_FILE" | wc -l)
	num_rejected=$(grep '**Rejected' "$LOG_FILE" | wc -l)

	same_line_log "Lines: $num_lines_in_file/$num_lines_in_file_previous; "\
	              "Acceptance: $num_accepted/$num_rejected; "\
								"hashrate:($latest_hashrate) $latest_hashrate_log";

  has_ethminer_crashed=false
  if grep -q 'SIGSEGV' "$LOG_FILE"; then has_ethminer_crashed=true; fi

	hashrate_too_low=false
	prev_low_hashrate_count=$low_hashrate_count
	# Hashrate can go down temporarily.  So let's keep track of how long it is zero
	if [[ "$latest_hashrate" -lt 10 ]]
	then ((low_hashrate_count++));
	else low_hashrate_count=0; fi

	# Add a new line to save the log around hashrate changes
	# It's one when hashrate goes zero for first time.
	if [[ "$low_hashrate_count" -eq 1 ]] || \
	   [[ "$prev_low_hashrate_count" -gt "$low_hashrate_count" ]]
	then echo; fi

	if [[ $latest_hashrate -lt 10 ]] && \
	   [[ $((low_hashrate_count * CHECK_EVERY_SECONDS)) -ge $ALLOW_HASHRATE_FOR_SECONDS ]] 
	then hashrate_too_low=true; fi

  if $hashrate_too_low || $has_ethminer_crashed
	then # Either hashrate is too low for too long, or program crashed with SIGSEGV
	  echo # Add a blank
		reason="unknown"
		if $has_ethminer_crashed; then reason="SIGSEGV"; 
		elif $hashrate_too_low; then reason="TOO_LOW_HASHRATE($latest_hashrate, ${low_hashrate_count}x${CHECK_EVERY_SECONDS}s)"
		fi

		Restart_Ethminer "$reason"
		num_lines_in_file_previous=0
		num_lines_in_file=0
		low_hashrate_count=0
	fi
	# The file is growing, and hashrate is more than 0, which means it's working
	num_lines_in_file_previous=$num_lines_in_file
done
