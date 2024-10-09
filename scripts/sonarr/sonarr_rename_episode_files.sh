#!/bin/bash

# Load configuration
config_file="../radarr/config.yaml"
if [ ! -f "$config_file" ]; then
    echo "Config file not found: $config_file"
    exit 1
fi

# Function to parse YAML (basic implementation)
parse_yaml() {
    local prefix=$2
    local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
    sed -ne "s|^\($s\):|\1|" \
         -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
         -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
    awk -F$fs '{
        indent = length($1)/2;
        vname[indent] = $2;
        for (i in vname) {if (i > indent) {delete vname[i]}}
        if (length($3) > 0) {
            vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
            printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
        }
    }'
}

# Load configuration values
eval $(parse_yaml "$config_file" "config_")

# Sonarr API endpoint
SONARR_API="http://${config_sonarr_host}:${config_sonarr_port}/api/v3"

# Function to rename episodes
rename_episodes() {
    local series_id=$1
    local episodes=$(curl -s "${SONARR_API}/episode?seriesId=${series_id}" -H "X-Api-Key: ${config_sonarr_api_key}")
    
    echo "$episodes" | jq -c '.[]' | while read -r episode; do
        local episode_id=$(echo "$episode" | jq -r '.id')
        local episode_file_id=$(echo "$episode" | jq -r '.episodeFileId')
        
        if [ "$episode_file_id" != "null" ]; then
            curl -s -X PUT "${SONARR_API}/episodefile/${episode_file_id}" \
                 -H "X-Api-Key: ${config_sonarr_api_key}" \
                 -H "Content-Type: application/json" \
                 -d '{}'
            echo "Renamed episode file for episode ID: ${episode_id}"
        fi
    done
}

# Get all series
series=$(curl -s "${SONARR_API}/series" -H "X-Api-Key: ${config_sonarr_api_key}")

# Iterate through series and rename episodes
echo "$series" | jq -c '.[]' | while read -r serie; do
    series_id=$(echo "$serie" | jq -r '.id')
    series_title=$(echo "$serie" | jq -r '.title')
    echo "Processing series: ${series_title}"
    rename_episodes "$series_id"
done

echo "Episode renaming process completed."
