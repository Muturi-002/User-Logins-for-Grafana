#!/bin/bash

# ========================================================================================================================
# Defining log format
# ----- User login format -----
# LOG_FILE lines are CSV: epoch,source,STATUS,username,human_timestamp,message
# epoch is the original event time (from journalctl/last/lastb), NOT the time
# this script ran — that's what lets merge_and_dedupe() compare new pulls
# directly against LOG_FILE itself instead of a separate state file. username
# is needed so collected events can be filtered against GROUP_MEMBERS.
user_log_success () {
	local epoch="$1" source="$2" username="$3" message="$4"
	local human_ts=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S')
	echo "$epoch, $source, SUCCESS, $username, $human_ts, $message" | sudo tee -a "$SUPER_LOG_FILE" > /dev/null
}
# Record failed login attempts
user_log_fail () {
	local epoch="$1" source="$2" username="$3" message="$4"
	local human_ts=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S')
	echo "$epoch, $source, FAIL, $username, $human_ts, $message" | sudo tee -a "$SUPER_LOG_FILE" > /dev/null
}


# ----- Run script logs ------
script_log_success () {
        echo "$(date '+%Y-%m-%d %H:%M:%S') SUCCESS: $1" | sudo tee -a "$DIR/script_run.log" > /dev/null
}
script_log_error () {
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $1" | sudo tee -a "$DIR/script_run.log" > /dev/null
}
script_log_info () {
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: $1" | sudo tee -a "$DIR/script_run.log" > /dev/null
}

# =========================================================================================================================
# ---- Setting up base files ---
SERVICE_LOGS_DIR="/var/log"
DIR="$SERVICE_LOGS_DIR/grafana-users"
SUPER_LOG_FILE="$DIR/user-logins.log"

# --- Setting up temporary files for log comparison and ammendment ---
TEMP_LOG_DIR="/tmp/temp-grafana-loggers"
TEMP_LOG_FILE="$TEMP_LOG_DIR/tmp-grafana-"$(basename $SUPER_LOG_FILE)""


# =========================================================================================================================
# Placeholder group name - replace with your group
GROUP_NAME="$(getent group | awk -F: '{print $1}' | grep grafana-)"
script_log_info "User group assessed: $GROUP_NAME"

# --- Resolve GROUP_NAME into a flat, deduped list of usernames that belong to
# it — both supplementary members (getent group's 4th field) and users whose
# PRIMARY gid is that group, since getent group's member list alone misses
# the latter. GROUP_MEMBERS is what merge_and_dedupe() filters logins against. ---
build_group_members () {
	local members=""
	local g gid
	for g in $GROUP_NAME; do
		members="$members
		$(getent group "$g" | cut -d: -f4 | tr ',' '\n')"
		gid=$(getent group "$g" | cut -d: -f3)
		[[ -n "$gid" ]] && members="$members
		$(getent passwd | awk -F: -v gid="$gid" '$4==gid {print $1}')"
	done
	GROUP_MEMBERS=$(echo "$members" | sed 's/^[[:space:]]*//' | sed '/^$/d' | sort -u)
}
build_group_members

is_group_member () {
	echo "$GROUP_MEMBERS" | grep -qxF "$1"
}

if [[ -z "$GROUP_MEMBERS" ]]; then
	script_log_info "WARNING: no members resolved for group(s) '$GROUP_NAME' — check GROUP_NAME matches a real group. No logins will be recorded until this is fixed."
else
	script_log_info "Group members tracked:$(echo "$GROUP_MEMBERS" | tr '\n' ' ')"
fi

## Need to check purpose of both of these variables.
GROUP_MEMBERS_ARRAY=()
if [[ -n "$GROUP_MEMBERS" ]]; then
	while IFS= read -r m; do
		[[ -n "$m" ]] && GROUP_MEMBERS_ARRAY+=("$m")
	done <<< "$GROUP_MEMBERS"
fi
GROUP_REGEX=""
if [[ ${#GROUP_MEMBERS_ARRAY[@]} -gt 0 ]]; then
	GROUP_REGEX=$(IFS='|'; echo "${GROUP_MEMBERS_ARRAY[*]}")
fi


# Check if current user has sudo permissions

script_log_info "Current user running script '$0': $(whoami)"
if id -nG $(whoami) | grep -qw sudo; then 
	script_log_info "User '$(whoami)' has sudo privileges. Proceed with caution!!!"
else
	script_log_info "User does not have sudo privileges. Ensure user $(whoami) has these privileges or use another user with sudo privileges. Contact your admin for support and any enquiries on this script"
	exit 0
fi

# ========================================================================================================================
# ***** Base functions for checking required log files exist *****

create_dir () {
	script_log_info "Directory '$DIR' does not exist!\\nCreating directory '$(basename $"DIR")' in root subdirectory '$SERVICE_LOGS_DIR' now..."
	sudo mkdir "$DIR"
	if [[ -d $DIR ]]; then
		script_log_success "Directory '$DIR' created"
	fi
	create_log_file
}
create_log_file () {
	script_log_info "Creating new file: $SUPER_LOG_FILE"
	sudo touch "$SUPER_LOG_FILE"
	if [[ -f $SUPER_LOG_FILE ]]; then
		script_log_success "Log file created and ready for use"
	fi
	log_file_checker
}

# Ensure log and state files exist
log_file_checker () {
	echo "--- Checking base directory and file ---\n"
	if [[ -d $DIR ]]; then
		echo "Directory '$DIR' exists. Checking required log file exists..."
		if [[ -f $SUPER_LOG_FILE ]]; then
			script_log_info "Log file '$(basename $SUPER_LOG_FILE) exists in the directory '$DIR'. Proceeding to log collection"
		else
			create_log_file
		fi
	else
		script_log_info "Directory '$DIR' does not exist. Creating new one...\n"
		create_dir
	fi
}


# ========================================================================================================================
# ----- Functions for tempoary log creation and comparison -----
create_temp_dir () {
	script_log_info "Creating new temp directory: $TEMP_LOG_DIR"
	sudo mkdir "$TEMP_LOG_DIR"
	if [[ -d $TEMP_LOG_DIR ]]; then 
		script_log_success "Temporary directory created successfully."
	fi
	create_temp_logfile
}
create_temp_logfile () {
	script_log_info "Creating new temp log file: $TEMP_LOG_FILE"
	sudo touch "$TEMP_LOG_FILE"
	if [[ -f "$TEMP_LOG_FILE" ]]; then
		script_log_success "Temporary log file created successfully."
	fi
}

# Check files exist
temp_log_checker () {
	script_log_info "--- Checking required temporary directory and file(s) exist..."
	if [[ -d $TEMP_LOG_DIR ]]; then 
		script_log_info "Directory '$TEMP_LOG_FILE' exists. Checking temp log file..."
		if [[ -f $TEMP_LOG_FILE ]]; then	
			script_log_info "Log file '$(basename $TEMP_LOG_FILE)' exists. Proceed to handle log collection"
		else
			script_log_info "Temp file '$TEMP_LOG_FILE' does not exist. Creating new file..."
			create_temp_logfile
		fi
	else
		script_log_info "Temporary directory '$TEMP_LOG_DIR' does not exist. Creating now..."
		create_temp_dir
	fi
}

clean_up_temp_files () {
	script_log_info "Cleaning up temporary files $TEMP_LOG_DIR/*..."
	sudo rm -rf $TEMP_LOG_DIR
	if [[ -d $TEMP_LOG_DIR ]]; then
		script_log_error "Cleanup failed!! Contact admin"
	else
		script_log_success "Cleanup successful. $TEMP_LOG_DIR and its contents deleted successfully."
		exit
	fi
}

# ========================================================================================================================
# Start collecting user logs

# --- Normalize journalctl SSH login events into temp file as epoch,source,message ---
collect_ssh_logs () {
	if [[ -z "$GROUP_REGEX" ]]; then
		script_log_info "No group members resolved; skipping SSH log collection"
		return
	fi
 
	journalctl -u ssh -o short-iso --no-pager -g "for (${GROUP_REGEX}) from" 2>/dev/null | while IFS= read -r line; do
		ts=$(echo "$line" | awk '{print $1}')
		epoch=$(date -d "$ts" +%s 2>/dev/null)
		[[ -z "$epoch" ]] && continue
		username=$(echo "$line" | grep -oP 'for \K(invalid user )?\S+(?= from)' | sed 's/^invalid user //')
		[[ -z "$username" ]] && username="unknown"
		is_group_member "$username" || continue
		echo "$epoch ssh $username $line" | sudo tee -a "$TEMP_LOG_FILE" > /dev/null
	done
}

# --- Normalize last/lastb login history into the same epoch,source,message format ---
collect_last_logs () {
	if [[ ${#GROUP_MEMBERS_ARRAY[@]} -eq 0 ]]; then
		script_log_info "No group members resolved; skipping last/lastb log collection"
		return
	fi
 
	last -F "${GROUP_MEMBERS_ARRAY[@]}" | while IFS= read -r line; do
		[[ -z "$line" || "$line" == wtmp* ]] && continue
		raw_ts=$(echo "$line" | grep -oE '[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}')
		epoch=$(date -d "$raw_ts" +%s 2>/dev/null)
		[[ -z "$epoch" ]] && continue
		username=$(echo "$line" | awk '{print $1}')
		is_group_member "$username" || continue
		echo "$epoch last $username $line" | sudo tee -a "$TEMP_LOG_FILE" > /dev/null
	done
 
	sudo lastb -F "${GROUP_MEMBERS_ARRAY[@]}" 2>/dev/null | while IFS= read -r line; do
		[[ -z "$line" || "$line" == btmp* ]] && continue
		raw_ts=$(echo "$line" | grep -oE '[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}')
		epoch=$(date -d "$raw_ts" +%s 2>/dev/null)
		[[ -z "$epoch" ]] && continue
		username=$(echo "$line" | awk '{print $1}')
		is_group_member "$username" || continue
		echo "$epoch lastb $username $line" | sudo tee -a "$TEMP_LOG_FILE" > /dev/null
	done
}
 
# --- Normalize journalctl user/session change events (su, sudo, PAM session open/close) ---
collect_user_change_logs () {
	if [[ -z "$GROUP_REGEX" ]]; then
		script_log_info "No group members resolved; skipping user-change log collection"
		return
	fi
 
	journalctl -t su -t sudo -t systemd-logind -o short-iso --no-pager \
		-g "(for user (${GROUP_REGEX})|of user (${GROUP_REGEX}))" 2>/dev/null \
		| grep -E "session opened|session closed" | while IFS= read -r line; do
		ts=$(echo "$line" | awk '{print $1}')
		epoch=$(date -d "$ts" +%s 2>/dev/null)
		[[ -z "$epoch" ]] && continue
		# Three distinct line shapes here:
		#  1. PAM "session opened for user TARGET(...) by ACTOR(...)" (sudo, su)
		#     — ACTOR authenticated; TARGET is just the identity assumed.
		#     Attribute to ACTOR, since being sudo'd INTO isn't a login.
		#  2. systemd-logind "New session N of user X." — X's own real
		#     interactive session; attribute to X directly.
		#  3. PAM "session closed for user TARGET" (sudo, su) — closed
		#     messages carry no actor info at all, so there's no reliable way
		#     to attribute this without risking the exact misattribution
		#     being fixed here. Skip rather than guess.
		if echo "$line" | grep -qP 'for user \S+.*\bby\b'; then
			username=$(echo "$line" | grep -oP '\bby \K[^ (]+')
		elif echo "$line" | grep -qP 'session \d+ of user'; then
			username=$(echo "$line" | grep -oP 'session \d+ of user \K\S+' | sed 's/\.$//')
		else
			continue
		fi
		[[ -z "$username" ]] && username="unknown"
		is_group_member "$username" || continue
		echo "$epoch usrchg $username $line" | sudo tee -a "$TEMP_LOG_FILE" > /dev/null
	done
}
 
# --- Merge all normalized sources, drop anything already recorded in LOG_FILE, append only new lines ---
merge_and_dedupe () {
	# Snapshot of epoch,source keys already present in LOG_FILE (fields 1 and 2 of the CSV format written by user_log_success/user_log_fail).
	existing_keys=$(awk -F, 'NF{print $1","$2}' "$SUPER_LOG_FILE" 2>/dev/null | sort -u)
 
	# Sort chronologically by epoch, then dedupe on the epoch+source composite key with awk — NOT `sort -u`, since sort -u with -k1,1 only treats field 1
	# as significant and would silently drop distinct sources sharing a second.
	sort -k1,1n "$TEMP_LOG_FILE" | awk '!seen[$1","$2]++' | while IFS=' ' read -r epoch source username message; do
		[[ -z "$epoch" ]] && continue
		key="$epoch,$source"
		if echo "$existing_keys" | grep -qxF "$key"; then
			if [[ "$source" == "last" ]] && ! echo "$message" | grep -q "still logged in"; then
                        	existing_line=$(grep "^${epoch},${source},SUCCESS,${username}," "$SUPER_LOG_FILE" 2>/dev/null)
                                if echo "$existing_line" | grep -q "still logged in"; then
                                        script_log_info "Updating stale 'still logged in' record for $username (session $epoch has since ended)"
                                        sudo sed -i "\#^${epoch},${source},SUCCESS,${username},#d" "$SUPER_LOG_FILE"
                                        user_log_success "$epoch" "$source" "$username" "$message"
                                fi
                        fi
		fi
		if [[ "$source" == "lastb" ]]; then
			user_log_fail "$epoch" "$source" "$username" "$message"
		else
			user_log_success "$epoch" "$source" "$username" "$message"
		fi
	done
}	
collect_user_logs () {
	script_log_info "Starting user login/session log collection"
	collect_ssh_logs
	collect_user_change_logs
	collect_last_logs
	merge_and_dedupe
	script_log_success "User login/session log collection complete"
}

# Setup cron job, at the rate of every 5 minutes.



# ========================================================================================================================
# Run script
log_file_checker
temp_log_checker
collect_user_logs
clean_up_temp_files
