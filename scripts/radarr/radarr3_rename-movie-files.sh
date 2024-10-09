#!/bin/bash
#
# Script to hit the Radarr API and rename movies using user-defined naming conventions from config.yaml
# with scheduling features to limit renames and respect run frequency
#
# Author: DN
# https://github.com/ultimate-pms/ultimate-plex-setup
#
################################################################################################

# Function to check if a command is installed
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if required commands are installed
for cmd in jq yq curl date; do
    if ! command_exists "$cmd"; then
        echo "Error: $cmd is not installed. Please install it before running this script." >&2
        exit 1
    fi
done

# Read configuration from config.yaml
CONFIG_FILE="$(dirname "$0")/config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: config.yaml not found in the same directory as the script." >&2
    exit 1
fi

RADARR_API_KEY=$(yq e '.radarr.api_key' "$CONFIG_FILE")
RADARR_HOST=$(yq e '.radarr.host' "$CONFIG_FILE")
RADARR_PORT=$(yq e '.radarr.port' "$CONFIG_FILE")
EXCLUDE_FILENAMES_CONTAINING=$(yq e '.exclude.filenames_containing' "$CONFIG_FILE")
MOVIE_FORMAT=$(yq e '.naming.movie_format' "$CONFIG_FILE")
FOLDER_FORMAT=$(yq e '.naming.folder_format' "$CONFIG_FILE")
FREQUENCY=$(yq e '.scheduling.frequency' "$CONFIG_FILE")
MAX_RENAMES_PER_RUN=$(yq e '.scheduling.max_renames_per_run' "$CONFIG_FILE")
LAST_RUN=$(yq e '.scheduling.last_run' "$CONFIG_FILE")
RENAMES_PERFORMED=$(yq e '.scheduling.renames_performed' "$CONFIG_FILE")

################################################################################################

# Function to update the config file
update_config() {
    yq e -i ".scheduling.last_run = \"$1\"" "$CONFIG_FILE"
    yq e -i ".scheduling.renames_performed = $2" "$CONFIG_FILE"
}

# Function to check if it's time to run based on frequency
should_run() {
    local current_time=$(date +%s)
    local last_run_time=$(date -d "$LAST_RUN" +%s 2>/dev/null || echo 0)
    
    case $FREQUENCY in
        daily)
            [ $((current_time - last_run_time)) -ge 86400 ]
            ;;
        weekly)
            [ $((current_time - last_run_time)) -ge 604800 ]
            ;;
        monthly)
            [ $((current_time - last_run_time)) -ge 2592000 ]
            ;;
        *)
            echo "Invalid frequency in config. Using default (weekly)."
            [ $((current_time - last_run_time)) -ge 604800 ]
            ;;
    esac
}

# Check if it's time to run
if ! should_run; then
    echo "Not time to run yet based on the $FREQUENCY schedule. Exiting."
    exit 0
fi

# Progress bar function
prog() {
    local w=50 p=$1;  shift
    printf -v dots "%*s" "$(( $p*$w/100 ))" ""; dots=${dots// /#};
    printf "\r\e[K|%-*s| %3d %% %s" "$w" "$dots" "$p" "$*";
}

echo -e "++ Radarr Movie File Renamer ++\n------------------------------\n\n"
echo "Querying API for complete movie collection - please be patient..."

TOTALITEMS=$(curl -s -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: $RADARR_API_KEY" \
    -X GET "http://$RADARR_HOST:$RADARR_PORT/api/v3/movie")

i=0
total=$(echo "$TOTALITEMS" | jq '. | length')
echo -e "\nProcessing results:"

renames_this_run=0

for row in $(echo "${TOTALITEMS}" | jq -r '.[] | @base64'); do
    _jq() {
        echo ${row} | base64 --decode | jq -r ${1}
    }
    i=$((i + 1))

    MOVIENAME=$(_jq '.title')
    DOWNLOADED=$(_jq '.downloaded')
    ID=$(_jq '.id')
    FILENAME=$(_jq '.movieFile.relativePath')

    # Simple progress bar so we know how far through the script we are (great for large collections)...
    taskpercent=$((i*100/total))
    prog "$taskpercent" "$MOVIENAME..."

    if [ "$DOWNLOADED" == "true" ] && [ $renames_this_run -lt $MAX_RENAMES_PER_RUN ]; then
        if [[ $FILENAME == *"$EXCLUDE_FILENAMES_CONTAINING"* ]]; then
            prog "$taskpercent" ""
            echo "File has been post-processed - do not rename."
        else
            RENAME_RESPONSE=$(curl -s -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -H "X-Api-Key: $RADARR_API_KEY" \
                -X GET "http://$RADARR_HOST:$RADARR_PORT/api/v3/renameMovie?movieId=$ID")

            FILE_ID=$(echo "$RENAME_RESPONSE" | jq '.[].movieFileId')

            curl -s "http://$RADARR_HOST:$RADARR_PORT/api/v3/command" \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -H "X-Api-Key: $RADARR_API_KEY" \
                --data-binary "{\"name\":\"RenameFiles\",\"movieId\":$ID,\"files\":[$FILE_ID]}" > /dev/null

            renames_this_run=$((renames_this_run + 1))
        fi
    fi

    if [ $renames_this_run -ge $MAX_RENAMES_PER_RUN ]; then
        echo "Reached maximum number of renames for this run."
        break
    fi
done

prog "$taskpercent" ""
echo -e "\nFinished. Renamed $renames_this_run files."

# Update the config file with the new last run time and renames performed
current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
update_config "$current_time" $renames_this_run

echo "Updated config file with last run time and renames performed."
