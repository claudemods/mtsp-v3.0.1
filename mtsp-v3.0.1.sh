#!/bin/bash

# MTSP - Music Terminal Shell Player
# Updated UI with blue/cyan color scheme and keyboard navigation

# Color Variables
BLUE='\033[0;34m'
CYAN='\033[0;36m'
LIGHT_BLUE='\033[1;34m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Highlight colors
HIGHLIGHT=$'\033[1;46m'  # Cyan background
HIGHLIGHT_RESET=$'\033[0m'

# Cursor movement
CURSOR_UP=$'\033[1A'
CURSOR_DOWN=$'\033[1B'
CURSOR_FORWARD=$'\033[1C'
CURSOR_BACK=$'\033[1D'

# Variables and Setup
MUSIC_DIR="$HOME/Music"
CURRENT_TRACK=""
IS_PLAYING=0
REPEAT_MODE=1
SHUFFLE_MODE=0
DEFAULT_PLAYLIST="My Library"
PLAYLISTS_DIR="$HOME/.mtsp/playlists"
CONFIG_DIR="$HOME/.mtsp"
DATABASE="$CONFIG_DIR/music_library.db"
CURRENT_PLAYLIST="$DEFAULT_PLAYLIST"
VOLUME=100
PLAYER_PID=""
AUTO_NEXT=1
MONITOR_PID=""

# Cleanup and Exit
cleanup_and_exit() {
    echo -e "${BLUE}Cleaning up...${NC}" > /dev/tty
    if [ -n "$PLAYER_PID" ] && ps -p "$PLAYER_PID" > /dev/null; then
        kill "$PLAYER_PID" 2>/dev/null
        sleep 0.5
        if ps -p "$PLAYER_PID" > /dev/null; then
            kill -9 "$PLAYER_PID" 2>/dev/null
        fi
    fi
    if [ -S "/tmp/mpv-socket" ]; then
        rm -f /tmp/mpv-socket
    fi
    clear
    echo -e "${BLUE}MTSP Music Player terminated.${NC}"
    exit 0
}

# Check Dependencies
check_dependencies() {
    local required_commands=("mpv" "sqlite3" "ffprobe" "socat")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" > /dev/null; then
            echo -e "${BLUE}Error: Required command '$cmd' not found. Please install it and try again.${NC}"
            return 1
        fi
    done
    return 0
}

# Setup Environment
setup_environment() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$PLAYLISTS_DIR"
    mkdir -p "$MUSIC_DIR"

    sqlite3 "$DATABASE" "
        CREATE TABLE IF NOT EXISTS tracks (
            id INTEGER PRIMARY KEY,
            filepath TEXT UNIQUE,
            title TEXT,
            artist TEXT,
            album TEXT,
            duration INTEGER
        );
        
        CREATE TABLE IF NOT EXISTS playlists (
            id INTEGER PRIMARY KEY,
            name TEXT UNIQUE
        );
        
        CREATE TABLE IF NOT EXISTS playlist_tracks (
            playlist_id INTEGER,
            track_id INTEGER,
            position INTEGER,
            FOREIGN KEY(playlist_id) REFERENCES playlists(id),
            FOREIGN KEY(track_id) REFERENCES tracks(id)
        );
        
        CREATE TABLE IF NOT EXISTS playback_history (
            id INTEGER PRIMARY KEY,
            track_id INTEGER,
            played_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(track_id) REFERENCES tracks(id)
        );
        
        CREATE TABLE IF NOT EXISTS favorites (
            track_id INTEGER UNIQUE,
            FOREIGN KEY(track_id) REFERENCES tracks(id)
        );
        
        CREATE TABLE IF NOT EXISTS queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            track_id INTEGER,
            FOREIGN KEY(track_id) REFERENCES tracks(id)
        );
        
        INSERT OR IGNORE INTO playlists (name) VALUES ('$DEFAULT_PLAYLIST');
    "

    # Add duration column to existing tracks table if it doesn't exist
    sqlite3 "$DATABASE" "ALTER TABLE tracks ADD COLUMN duration INTEGER;" 2>/dev/null || true
}

# Add Track to Database
add_track_to_db() {
    local filepath="$1"

    # Check if file exists
    if [ ! -f "$filepath" ]; then
        echo -e "${BLUE}DEBUG: File not found - $filepath${NC}"
        return 1
    fi

    # Get file info using ffprobe
    local info="$(ffprobe -v error -show_entries format=duration:format_tags=title,artist,album -of default=noprint_wrappers=1:nokey=1 "$filepath" 2>/dev/null)"
    local title="$(echo "$info" | sed -n '2p')"
    local artist="$(echo "$info" | sed -n '3p')"
    local album="$(echo "$info" | sed -n '4p')"
    local duration="$(echo "$info" | sed -n '1p')"

    # Escape single quotes in strings for SQL
    title=$(echo "$title" | sed "s/'/''/g")
    artist=$(echo "$artist" | sed "s/'/''/g")
    album=$(echo "$album" | sed "s/'/''/g")

    # Insert into database with error handling
    sqlite3 "$DATABASE" "INSERT OR IGNORE INTO tracks (filepath, title, artist, album, duration) VALUES ('$filepath', '$title', '$artist', '$album', '$duration');" 2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${BLUE}DEBUG: Track added to database successfully${NC}"
    else
        echo -e "${BLUE}DEBUG: Failed to add track to database${NC}"
    fi
}

# Notify Now Playing
notify_now_playing() {
    local filepath="$1"
    local info=$(sqlite3 "$DATABASE" "SELECT artist, title FROM tracks WHERE filepath = '$filepath';")
    local artist=$(echo "$info" | cut -d'|' -f1)
    local title=$(echo "$info" | cut -d'|' -f2)
    local notification="Now Playing: ${title:-Unknown} by ${artist:-Unknown}"
    echo -e "${LIGHT_BLUE}${notification}${NC}"
    if command -v notify-send > /dev/null; then
        notify-send "Now Playing" "${artist:-Unknown Artist} - ${title:-Unknown Title}"
    fi
}

# Play Music Function
play_music() {
    local filepath="$1"
    echo -e "${BLUE}DEBUG: play_music called with $filepath${NC}"

    # Kill previous player if running
    if [ -n "$PLAYER_PID" ] && ps -p "$PLAYER_PID" > /dev/null; then
        echo -e "${BLUE}DEBUG: Killing previous PLAYER_PID $PLAYER_PID${NC}"
        kill "$PLAYER_PID" 2>/dev/null
        sleep 0.5
    fi

    # Kill previous monitor if running
    if [ -n "$MONITOR_PID" ] && ps -p "$MONITOR_PID" > /dev/null; then
        kill "$MONITOR_PID" 2>/dev/null
        sleep 0.5
    fi

    # Remove old socket if exists
    if [ -S "/tmp/mpv-socket" ]; then
        rm -f /tmp/mpv-socket
    fi

    # Check if file exists
    if [ ! -f "$filepath" ]; then
        show_message "Error: File not found - $filepath"
        return
    fi

    # Add track to database if not exists
    add_track_to_db "$filepath"

    echo -e "${BLUE}DEBUG: Starting mpv for $filepath${NC}"

    # Start mpv with better options for audio playback
    mpv --no-terminal \
         --quiet \
         --no-video \
         --input-ipc-server=/tmp/mpv-socket \
         --volume=100 \
         --audio-display=no \
         "$filepath" &

    PLAYER_PID=$!
    CURRENT_TRACK="$filepath"
    IS_PLAYING=1

    # Wait for mpv to start and create socket
    sleep 2

    # Check if mpv started successfully
    if ! ps -p "$PLAYER_PID" > /dev/null; then
        show_message "Error: Failed to start mpv player"
        return
    fi

    # Wait for socket to be created
    local socket_wait=0
    while [ ! -S "/tmp/mpv-socket" ] && [ $socket_wait -lt 10 ]; do
        sleep 0.5
        ((socket_wait++))
    done

    echo -e "${BLUE}DEBUG: Inserting playback history for $filepath${NC}"
    sqlite3 "$DATABASE" "INSERT INTO playback_history (track_id, played_at) VALUES ((SELECT id FROM tracks WHERE filepath = '$filepath'), datetime('now'));"
    notify_now_playing "$filepath"

    # Start auto-next monitor if enabled
    if [ $AUTO_NEXT -eq 1 ]; then
        start_auto_next_monitor
    fi

    echo -e "${BLUE}DEBUG: Music started successfully${NC}"
}

# Function to get next track
get_next_track() {
    local current_track="$1"
    local playlist_name="$CURRENT_PLAYLIST"
    local next_track=""

    if [ -n "$playlist_name" ] && [ "$playlist_name" != "My Library" ]; then
        # Get next track from current playlist
        next_track=$(sqlite3 "$DATABASE" "
            SELECT t.filepath 
            FROM tracks t
            JOIN playlist_tracks pt ON t.id = pt.track_id
            JOIN playlists p ON pt.playlist_id = p.id
            WHERE p.name = '$playlist_name'
            AND t.filepath > '$current_track'
            ORDER BY t.filepath
            LIMIT 1;
        ")

        # If no next track found, get first track (loop)
        if [ -z "$next_track" ]; then
            next_track=$(sqlite3 "$DATABASE" "
                SELECT t.filepath 
                FROM tracks t
                JOIN playlist_tracks pt ON t.id = pt.track_id
                JOIN playlists p ON pt.playlist_id = p.id
                WHERE p.name = '$playlist_name'
                ORDER BY t.filepath
                LIMIT 1;
            ")
        fi
    else
        # Get next track from library
        next_track=$(sqlite3 "$DATABASE" "
            SELECT filepath 
            FROM tracks 
            WHERE filepath > '$current_track'
            ORDER BY filepath
            LIMIT 1;
        ")

        # If no next track found, get first track (loop)
        if [ -z "$next_track" ]; then
            next_track=$(sqlite3 "$DATABASE" "
                SELECT filepath 
                FROM tracks 
                ORDER BY filepath
                LIMIT 1;
            ")
        fi
    fi

    echo "$next_track"
}

# Function to start auto-next monitor
start_auto_next_monitor() {
    # Kill existing monitor if running
    if [ -n "$MONITOR_PID" ] && ps -p "$MONITOR_PID" > /dev/null; then
        kill "$MONITOR_PID" 2>/dev/null
    fi

    # Start monitor in background
    (
        while true; do
            # Check if player is still running
            if [ -z "$PLAYER_PID" ] || ! ps -p "$PLAYER_PID" > /dev/null; then
                break
            fi

            # Check if mpv socket exists
            if [ ! -S "/tmp/mpv-socket" ]; then
                sleep 1
                continue
            fi

            # Get current playback status
            local status=$(echo '{ "command": ["get_property", "idle-active"] }' | socat - /tmp/mpv-socket 2>/dev/null | grep -o 'true\|false')

            if [ "$status" = "true" ]; then
                # Player is idle (finished playing)
                sleep 1

                # Get next track
                local next_track=$(get_next_track "$CURRENT_TRACK")

                if [ -n "$next_track" ] && [ -f "$next_track" ]; then
                    # Play next track
                    play_music "$next_track"
                    break
                else
                    # No more tracks available
                    break
                fi
            fi

            sleep 2
        done
    ) &

    MONITOR_PID=$!
    echo -e "${BLUE}DEBUG: Auto-next monitor started with PID $MONITOR_PID${NC}"
}

# Change Volume
change_volume() {
    local direction="$1"

    if [ -z "$PLAYER_PID" ] || ! ps -p "$PLAYER_PID" > /dev/null; then
        show_message "No music is currently playing"
        return
    fi

    if [ "$direction" = "+" ]; then
        VOLUME=$((VOLUME + 10))
        [ $VOLUME -gt 100 ] && VOLUME=100
    elif [ "$direction" = "-" ]; then
        VOLUME=$((VOLUME - 10))
        [ $VOLUME -lt 0 ] && VOLUME=0
    else
        show_message "Invalid volume direction"
        return
    fi

    if [ -S "/tmp/mpv-socket" ]; then
        echo '{ "command": ["set_property", "volume", '"$VOLUME"'] }' | socat - /tmp/mpv-socket 2>/dev/null
        if [ $? -eq 0 ]; then
            show_message "Volume: $VOLUME%"
        else
            show_message "Failed to change volume"
        fi
    else
        show_message "MPV socket not found"
    fi
}

# Show message with blue/cyan styling
show_message() {
    clear
    echo -e "${BLUE}============================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo -e "\n${BLUE}Press any key to continue...${NC}"
    read -n1 -s
}

# Keyboard menu system
show_menu() {
    local title="$1"
    local options=("${@:2}")
    local selected=0
    local options_count=${#options[@]}
    
    while true; do
        clear
        echo -e "${BLUE}============================================${NC}"
        echo -e "${LIGHT_BLUE}$title${NC}"
        echo -e "${BLUE}============================================${NC}"
        
        for i in "${!options[@]}"; do
            if [ $i -eq $selected ]; then
                echo -e "${HIGHLIGHT}${WHITE}➤ ${options[$i]}${HIGHLIGHT_RESET}"
            else
                echo -e "${BLUE}  ${options[$i]}${NC}"
            fi
        done
        
        echo -e "${BLUE}============================================${NC}"
        echo -e "${CYAN}Use arrow keys to navigate, Enter to select${NC}"
        
        read -sn3 key
        case $key in
            $'\033[A') # Up arrow
                selected=$((selected - 1))
                [ $selected -lt 0 ] && selected=$((options_count - 1))
                ;;
            $'\033[B') # Down arrow
                selected=$((selected + 1))
                [ $selected -ge $options_count ] && selected=0
                ;;
            "") # Enter
                return $selected
                ;;
            q|Q)
                return 255
                ;;
        esac
    done
}

# Show history with keyboard navigation
show_history() {
    local tracks=$(sqlite3 "$DATABASE" "SELECT t.filepath, t.artist, t.title, ph.played_at FROM tracks t JOIN playback_history ph ON t.id = ph.track_id ORDER BY ph.played_at DESC LIMIT 20;")
    if [ -z "$tracks" ]; then
        show_message "No playback history found."
        return
    fi
    
    local options=()
    while IFS='|' read -r filepath artist title played_at; do
        options+=("${artist:-Unknown Artist} - ${title:-Unknown Title} ($played_at)")
    done <<< "$tracks"
    
    show_menu "Playback History" "${options[@]}"
    local selected=$?
    
    if [ $selected -ne 255 ]; then
        local selected_track=$(echo "$tracks" | sed -n "$((selected+1))p" | cut -d'|' -f1)
        play_music "$selected_track"
    fi
}

# Scan library function
scan_library() {
    local count=0
    while IFS= read -r file; do
        if [[ "$file" =~ \.(mp3|flac|wav|ogg|m4a)$ ]]; then
            add_track_to_db "$file"
            ((count++))
        fi
    done < <(find "$MUSIC_DIR" -type f)
    show_message "Library scan complete. Added $count tracks to database."
}

# Search library with keyboard navigation
search_library() {
    echo -e "${BLUE}Enter search term: ${NC}"
    read -r search_term
    
    if [ -n "$search_term" ]; then
        local tracks=$(sqlite3 "$DATABASE" "SELECT filepath, artist, title FROM tracks WHERE artist LIKE '%$search_term%' OR title LIKE '%$search_term%' OR album LIKE '%$search_term%';")
        if [ -z "$tracks" ]; then
            show_message "No tracks found matching '$search_term'."
            return
        fi
        
        local options=()
        while IFS='|' read -r filepath artist title; do
            options+=("${artist:-Unknown Artist} - ${title:-Unknown Title}")
        done <<< "$tracks"
        
        show_menu "Search Results" "${options[@]}"
        local selected=$?
        
        if [ $selected -ne 255 ]; then
            local selected_track=$(echo "$tracks" | sed -n "$((selected+1))p" | cut -d'|' -f1)
            play_music "$selected_track"
        fi
    fi
}

# Add to Queue
add_to_queue() {
    local filepath="$1"
    echo -e "${BLUE}DEBUG: add_to_queue called with $filepath${NC}"
    add_track_to_db "$filepath"
    sqlite3 "$DATABASE" "INSERT INTO queue (track_id) VALUES ((SELECT id FROM tracks WHERE filepath = '$filepath'));"
    show_message "Track added to queue!"
}

# Add to Favorites
add_to_favorites() {
    local filepath="$1"
    echo -e "${BLUE}DEBUG: add_to_favorites called with $filepath${NC}"
    add_track_to_db "$filepath"
    sqlite3 "$DATABASE" "INSERT OR IGNORE INTO favorites (track_id) VALUES ((SELECT id FROM tracks WHERE filepath = '$filepath'));"
    show_message "Track added to Favorites!"
}

# Play Folder
play_folder() {
    local folder="$1"
    local files=()
    while IFS= read -r file; do
        if [[ "$file" =~ \.(mp3|flac|wav|ogg|m4a)$ ]]; then
            files+=("$file")
        fi
    done < <(find "$folder" -type f | sort)

    if [ ${#files[@]} -eq 0 ]; then
        show_message "No audio files found in this folder."
        return
    fi

    # Play first file in folder
    play_music "${files[0]}"
}

# Select Multiple Files to Play
select_multiple_files_to_play() {
    local dir="$1"
    local files=()
    local options=()
    local counter=1

    while IFS= read -r file; do
        if [[ "$file" =~ \.(mp3|flac|wav|ogg|m4a)$ ]]; then
            files+=("$file")
            local display_name=$(basename "$file")
            options+=("$display_name")
        fi
    done < <(find "$dir" -maxdepth 1 -type f | sort)

    if [ ${#files[@]} -eq 0 ]; then
        show_message "No audio files found in this directory."
        return
    fi

    show_menu "Select Multiple Files" "${options[@]}"
    local selected=$?
    
    if [ $selected -ne 255 ]; then
        play_music "${files[$selected]}"
    fi
}

# File and Playlist Management Functions
browse_files() {
    local current_dir="${1:-$MUSIC_DIR}"
    local filter_type="all"
    
    while true; do
        if [ ! -d "$current_dir" ]; then
            show_message "Directory not found: $current_dir"
            return
        fi
        
        local file_list=(".. [Go up]")
        local items=()
        
        case "$filter_type" in
            mp3) items=($(find "$current_dir" -maxdepth 1 -type f -name '*.mp3' | sort)) ;;
            flac) items=($(find "$current_dir" -maxdepth 1 -type f -name '*.flac' | sort)) ;;
            wav) items=($(find "$current_dir" -maxdepth 1 -type f -name '*.wav' | sort)) ;;
            ogg) items=($(find "$current_dir" -maxdepth 1 -type f -name '*.ogg' | sort)) ;;
            m4a) items=($(find "$current_dir" -maxdepth 1 -type f -name '*.m4a' | sort)) ;;
            all) items=($(find "$current_dir" -maxdepth 1 \( -type d -o -type f \) | sort)) ;;
        esac
        
        for item in "${items[@]}"; do
            [ "$item" = "$current_dir" ] && continue
            local display_name=$(basename "$item")
            if [ -d "$item" ]; then
                file_list+=("📁 $display_name")
            elif [[ "$item" =~ \.(mp3|flac|wav|ogg|m4a)$ ]]; then
                file_list+=("🎵 $display_name")
            else
                file_list+=("$display_name")
            fi
        done
        
        local menu_options=(
            "Filter by type"
            "Search by name"
            "Select multiple files to play"
            "Return to Main Menu"
        )
        
        show_menu "Browse Music Files: $current_dir" "${file_list[@]}" "${menu_options[@]}"
        local choice=$?
        
        if [ $choice -eq 255 ]; then
            break
        fi
        
        # Handle menu options
        if [ $choice -ge ${#file_list[@]} ]; then
            local menu_choice=$((choice - ${#file_list[@]}))
            case $menu_choice in
                0) # Filter by type
                    local filter_options=(
                        "All files"
                        "MP3 only"
                        "FLAC only"
                        "WAV only"
                        "OGG only"
                        "M4A only"
                    )
                    show_menu "Filter Files" "${filter_options[@]}"
                    local filter_choice=$?
                    case $filter_choice in
                        0) filter_type="all" ;;
                        1) filter_type="mp3" ;;
                        2) filter_type="flac" ;;
                        3) filter_type="wav" ;;
                        4) filter_type="ogg" ;;
                        5) filter_type="m4a" ;;
                    esac
                    ;;
                1) # Search by name
                    echo -e "${BLUE}Enter search term: ${NC}"
                    read -r search_term
                    if [ -n "$search_term" ]; then
                        local search_results=()
                        while IFS= read -r item; do
                            if [[ "$item" =~ $search_term ]]; then
                                local display_name=$(basename "$item")
                                if [ -d "$item" ]; then
                                    search_results+=("📁 $display_name")
                                elif [[ "$item" =~ \.(mp3|flac|wav|ogg|m4a)$ ]]; then
                                    search_results+=("🎵 $display_name")
                                else
                                    search_results+=("$display_name")
                                fi
                            fi
                        done < <(find "$current_dir" -maxdepth 1 -iname "*$search_term*" | sort)
                        
                        if [ ${#search_results[@]} -eq 0 ]; then
                            show_message "No files found matching '$search_term'."
                        else
                            show_menu "Search Results" "${search_results[@]}"
                            local search_selected=$?
                            if [ $search_selected -ne 255 ]; then
                                local selected_item=$(find "$current_dir" -maxdepth 1 -iname "*$search_term*" | sort | sed -n "$((search_selected+1))p")
                                if [ -d "$selected_item" ]; then
                                    play_folder "$selected_item"
                                elif [ -f "$selected_item" ]; then
                                    show_file_metadata_and_play "$selected_item"
                                fi
                            fi
                        fi
                    fi
                    ;;
                2) # Select multiple files to play
                    select_multiple_files_to_play "$current_dir"
                    ;;
                3) # Return to Main Menu
                    break
                    ;;
            esac
        else
            # Handle file/directory selection
            local selected_item=$(find "$current_dir" -maxdepth 1 | sort | sed -n "$((choice+1))p")
            if [ -d "$selected_item" ]; then
                local folder_options=(
                    "Browse this folder"
                    "Play all audio files in this folder"
                )
                show_menu "Folder Options" "${folder_options[@]}"
                local folder_choice=$?
                if [ $folder_choice -eq 1 ]; then
                    play_folder "$selected_item"
                else
                    current_dir="$selected_item"
                fi
            elif [ -f "$selected_item" ]; then
                show_file_metadata_and_play "$selected_item"
            fi
        fi
    done
}

# Show file metadata and play options
show_file_metadata_and_play() {
    local filepath="$1"

    # Check if file exists
    if [ ! -f "$filepath" ]; then
        show_message "Error: File not found - $filepath"
        return
    fi

    # Get file info using ffprobe
    local info="$(ffprobe -v error -show_entries format=duration:format_tags=title,artist,album -of default=noprint_wrappers=1:nokey=1 "$filepath" 2>/dev/null)"
    local title="$(echo "$info" | sed -n '2p')"
    local artist="$(echo "$info" | sed -n '3p')"
    local album="$(echo "$info" | sed -n '4p')"
    local duration="$(echo "$info" | sed -n '1p')"

    # Format duration if available
    if [ -n "$duration" ] && [ "$duration" != "N/A" ]; then
        local duration_int=$(echo "$duration" | cut -d'.' -f1)
        local minutes=$((duration_int / 60))
        local seconds=$((duration_int % 60))
        duration="${minutes}:$(printf "%02d" $seconds)"
    else
        duration="Unknown"
    fi

    local options=(
        "Play this file"
        "Add to Playlist"
        "Add to Queue"
        "Add to Favorites"
        "Cancel"
    )
    
    show_menu "File Options: ${title:-Unknown}" "${options[@]}"
    local choice=$?
    
    case $choice in
        0) play_music "$filepath" ;;
        1) add_file_to_playlist_from_browser "$filepath" ;;
        2) add_to_queue "$filepath" ;;
        3) add_to_favorites "$filepath" ;;
    esac
}

# Add file to playlist from browser
add_file_to_playlist_from_browser() {
    local filepath="$1"
    echo -e "${BLUE}DEBUG: add_file_to_playlist_from_browser called with $filepath${NC}"
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists;")
    if [ -z "$playlists" ]; then
        show_message "No playlists found. Please create a playlist first."
        return
    fi
    
    local options=()
    while IFS= read -r playlist; do
        options+=("$playlist")
    done <<< "$playlists"
    
    show_menu "Add to Playlist" "${options[@]}"
    local selected=$?
    
    if [ $selected -ne 255 ]; then
        local playlist_name=$(echo "$playlists" | sed -n "$((selected+1))p")
        echo -e "${BLUE}DEBUG: Adding $filepath to playlist $playlist_name${NC}"
        sqlite3 "$DATABASE" "INSERT OR IGNORE INTO playlist_tracks (playlist_id, track_id) VALUES ((SELECT id FROM playlists WHERE name = '$playlist_name'), (SELECT id FROM tracks WHERE filepath = '$filepath'));"
        show_message "Track added to playlist '$playlist_name' successfully!"
    fi
}

# Manage playlists
manage_playlists() {
    while true; do
        local options=(
            "Create New Playlist"
            "View Playlists"
            "Add Tracks to Playlist (Browse Files)"
            "Remove Tracks from Playlist"
            "Rename Playlist"
            "Delete Playlist"
            "Return to Main Menu"
        )
        
        show_menu "Playlist Management" "${options[@]}"
        local choice=$?
        
        case $choice in
            0) create_playlist ;;
            1) view_playlists ;;
            2) browse_and_select_files_for_playlist ;;
            3) remove_tracks_from_playlist ;;
            4) rename_playlist ;;
            5) delete_playlist ;;
            6) break ;;
            255) break ;;
        esac
    done
}

# Create playlist
create_playlist() {
    echo -e "${BLUE}Enter playlist name: ${NC}"
    read -r playlist_name

    if [ -n "$playlist_name" ]; then
        local existing=$(sqlite3 "$DATABASE" "SELECT name FROM playlists WHERE name = '$playlist_name';")
        if [ -z "$existing" ]; then
            sqlite3 "$DATABASE" "INSERT INTO playlists (name) VALUES ('$playlist_name');"
            show_message "Playlist '$playlist_name' created successfully!"
        else
            show_message "A playlist with this name already exists."
        fi
    fi
}

# View playlists
view_playlists() {
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists;")
    if [ -z "$playlists" ]; then
        show_message "No playlists found."
        return
    fi
    
    local options=()
    while IFS= read -r playlist; do
        options+=("$playlist")
    done <<< "$playlists"
    
    show_menu "Your Playlists" "${options[@]}"
    local selected=$?
    
    if [ $selected -ne 255 ]; then
        local selected_playlist=$(echo "$playlists" | sed -n "$((selected+1))p")
        view_playlist_tracks "$selected_playlist"
    fi
}

# View playlist tracks
view_playlist_tracks() {
    local playlist_name="$1"
    local tracks=$(sqlite3 "$DATABASE" \
        "SELECT t.filepath, t.artist, t.title, t.album 
         FROM tracks t
         JOIN playlist_tracks pt ON t.id = pt.track_id
         JOIN playlists p ON pt.playlist_id = p.id
         WHERE p.name = '$playlist_name';")
    
    if [ -z "$tracks" ]; then
        show_message "No tracks in this playlist."
        return
    fi
    
    local options=()
    while IFS='|' read -r filepath artist title album; do
        options+=("${artist:-Unknown Artist} - ${title:-Unknown Title} [${album:-Unknown Album}]")
    done <<< "$tracks"
    
    show_menu "Playlist Tracks: $playlist_name" "${options[@]}"
    local selected=$?
    
    if [ $selected -ne 255 ]; then
        local selected_track=$(echo "$tracks" | sed -n "$((selected+1))p" | cut -d'|' -f1)
        play_music "$selected_track"
    fi
}

# Browse and select files for playlist
browse_and_select_files_for_playlist() {
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists;")
    if [ -z "$playlists" ]; then
        show_message "No playlists found. Please create a playlist first."
        return
    fi
    
    local options=()
    while IFS= read -r playlist; do
        options+=("$playlist")
    done <<< "$playlists"
    
    show_menu "Select Playlist" "${options[@]}"
    local selected=$?
    
    if [ $selected -eq 255 ]; then
        return
    fi
    
    local playlist_name=$(echo "$playlists" | sed -n "$((selected+1))p")
    local current_dir="$MUSIC_DIR"
    
    while true; do
        if [ ! -d "$current_dir" ]; then
            show_message "Directory not found: $current_dir"
            return
        fi
        
        local files=()
        local folders=()
        
        # Get audio files
        while IFS= read -r file; do
            if [ -f "$file" ] && [[ "$file" =~ \.(mp3|flac|wav|ogg|m4a)$ ]]; then
                files+=("$file")
            fi
        done < <(find "$current_dir" -maxdepth 1 -type f \( -iname "*.mp3" -o -iname "*.flac" -o -iname "*.wav" -o -iname "*.ogg" -o -iname "*.m4a" \) | sort)
        
        # Get directories
        while IFS= read -r folder; do
            if [ "$folder" != "$current_dir" ]; then
                folders+=("$folder")
            fi
        done < <(find "$current_dir" -maxdepth 1 -type d | sort)
        
        # Create menu options
        local menu_options=()
        for folder in "${folders[@]}"; do
            menu_options+=("📁 $(basename "$folder")")
        done
        
        menu_options+=("Select audio files in this folder")
        menu_options+=("Return to Playlist Menu")
        
        show_menu "Add to Playlist: $playlist_name - $current_dir" "${menu_options[@]}"
        local choice=$?
        
        if [ $choice -eq 255 ]; then
            break
        fi
        
        # Handle folder selection
        if [ $choice -lt ${#folders[@]} ]; then
            current_dir="${folders[$choice]}"
        elif [ $choice -eq ${#folders[@]} ]; then
            # Select files in current directory
            if [ ${#files[@]} -eq 0 ]; then
                show_message "No audio files found in this directory."
                continue
            fi
            
            local file_options=()
            for file in "${files[@]}"; do
                file_options+=("$(basename "$file")")
            done
            
            show_menu "Select Tracks to Add" "${file_options[@]}"
            local file_selected=$?
            
            if [ $file_selected -ne 255 ]; then
                local file_to_add="${files[$file_selected]}"
                sqlite3 "$DATABASE" "INSERT OR IGNORE INTO playlist_tracks (playlist_id, track_id) VALUES ((SELECT id FROM playlists WHERE name = '$playlist_name'), (SELECT id FROM tracks WHERE filepath = '$file_to_add'));"
                show_message "Selected tracks have been added to the playlist successfully!"
            fi
        else
            # Return to playlist menu
            break
        fi
    done
}

# Remove tracks from playlist
remove_tracks_from_playlist() {
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists;")
    if [ -z "$playlists" ]; then
        show_message "No playlists found."
        return
    fi
    
    local options=()
    while IFS= read -r playlist; do
        options+=("$playlist")
    done <<< "$playlists"
    
    show_menu "Select Playlist" "${options[@]}"
    local selected=$?
    
    if [ $selected -eq 255 ]; then
        return
    fi
    
    local playlist_name=$(echo "$playlists" | sed -n "$((selected+1))p")
    local tracks=$(sqlite3 "$DATABASE" "SELECT t.filepath, t.artist, t.title FROM tracks t JOIN playlist_tracks pt ON t.id = pt.track_id JOIN playlists p ON pt.playlist_id = p.id WHERE p.name = '$playlist_name';")
    
    if [ -z "$tracks" ]; then
        show_message "No tracks in this playlist."
        return
    fi
    
    local track_options=()
    while IFS='|' read -r filepath artist title; do
        track_options+=("${artist:-Unknown Artist} - ${title:-Unknown Title}")
    done <<< "$tracks"
    
    show_menu "Remove Tracks from $playlist_name" "${track_options[@]}"
    local track_selected=$?
    
    if [ $track_selected -ne 255 ]; then
        local selected_track=$(echo "$tracks" | sed -n "$((track_selected+1))p" | cut -d'|' -f1)
        sqlite3 "$DATABASE" "DELETE FROM playlist_tracks WHERE playlist_id = (SELECT id FROM playlists WHERE name = '$playlist_name') AND track_id = (SELECT id FROM tracks WHERE filepath = '$selected_track');"
        show_message "Track removed from playlist."
    fi
}

# Rename playlist
rename_playlist() {
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists WHERE name != 'My Library';")
    if [ -z "$playlists" ]; then
        show_message "No playlists to rename."
        return
    fi
    
    local options=()
    while IFS= read -r playlist; do
        options+=("$playlist")
    done <<< "$playlists"
    
    show_menu "Rename Playlist" "${options[@]}"
    local selected=$?
    
    if [ $selected -eq 255 ]; then
        return
    fi
    
    local old_name=$(echo "$playlists" | sed -n "$((selected+1))p")
    echo -e "${BLUE}Enter new name for playlist '$old_name': ${NC}"
    read -r new_name
    
    if [ -n "$new_name" ]; then
        local exists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists WHERE name = '$new_name';")
        if [ -z "$exists" ]; then
            sqlite3 "$DATABASE" "UPDATE playlists SET name = '$new_name' WHERE name = '$old_name';"
            show_message "Playlist renamed successfully!"
        else
            show_message "A playlist with this name already exists."
        fi
    fi
}

# Delete playlist
delete_playlist() {
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists WHERE name != 'My Library';")
    if [ -z "$playlists" ]; then
        show_message "No playlists to delete."
        return
    fi
    
    local options=()
    while IFS= read -r playlist; do
        options+=("$playlist")
    done <<< "$playlists"
    
    show_menu "Delete Playlist" "${options[@]}"
    local selected=$?
    
    if [ $selected -eq 255 ]; then
        return
    fi
    
    local playlist_name=$(echo "$playlists" | sed -n "$((selected+1))p")
    
    show_message "Are you sure you want to delete the playlist '$playlist_name'? (y/n)"
    read -n1 -s confirm
    
    if [[ "$confirm" =~ [yY] ]]; then
        sqlite3 "$DATABASE" "
            DELETE FROM playlist_tracks 
            WHERE playlist_id = (SELECT id FROM playlists WHERE name = '$playlist_name');
            DELETE FROM playlists 
            WHERE name = '$playlist_name';
        "
        show_message "Playlist '$playlist_name' deleted successfully!"
    fi
}

# Playback Control Functions
next_track() {
    if [ -n "$CURRENT_PLAYLIST" ]; then
        local tracks=$(sqlite3 "$DATABASE" "
            SELECT t.filepath 
            FROM tracks t
            JOIN playlist_tracks pt ON t.id = pt.track_id
            JOIN playlists p ON pt.playlist_id = p.id
            WHERE p.name = '$CURRENT_PLAYLIST'
            ORDER BY t.filepath;
        ")

        if [ -z "$CURRENT_TRACK" ]; then
            local first_track=$(echo "$tracks" | head -n 1)
            play_music "$first_track"
        else
            local next_track=$(echo "$tracks" | grep -A 1 "$CURRENT_TRACK" | tail -n 1)

            if [ -z "$next_track" ] && [ $REPEAT_MODE -eq 1 ]; then
                next_track=$(echo "$tracks" | head -n 1)
            fi

            if [ -n "$next_track" ]; then
                play_music "$next_track"
            fi
        fi
    else
        local track=$(sqlite3 "$DATABASE" "SELECT filepath FROM tracks ORDER BY RANDOM() LIMIT 1;")
        play_music "$track"
    fi
}

previous_track() {
    if [ -n "$CURRENT_PLAYLIST" ]; then
        local tracks=$(sqlite3 "$DATABASE" "
            SELECT t.filepath 
            FROM tracks t
            JOIN playlist_tracks pt ON t.id = pt.track_id
            JOIN playlists p ON pt.playlist_id = p.id
            WHERE p.name = '$CURRENT_PLAYLIST'
            ORDER BY t.filepath;
        ")

        if [ -z "$CURRENT_TRACK" ]; then
            local last_track=$(echo "$tracks" | tail -n 1)
            play_music "$last_track"
        else
            local prev_track=$(echo "$tracks" | grep -B 1 "$CURRENT_TRACK" | head -n 1)
            if [ -n "$prev_track" ]; then
                play_music "$prev_track"
            fi
        fi
    fi
}

toggle_repeat_mode() {
    if [ $REPEAT_MODE -eq 0 ]; then
        REPEAT_MODE=1
        show_message "Repeat Mode: ON"
    else
        REPEAT_MODE=0
        show_message "Repeat Mode: OFF"
    fi
}

toggle_playback() {
    if [ -z "$PLAYER_PID" ] || ! ps -p "$PLAYER_PID" > /dev/null; then
        # No music playing, start playing
        if [ -z "$CURRENT_TRACK" ]; then
            # Try to get first track from current playlist
            CURRENT_TRACK=$(sqlite3 "$DATABASE" "
                SELECT t.filepath 
                FROM tracks t
                JOIN playlist_tracks pt ON t.id = pt.track_id
                JOIN playlists p ON pt.playlist_id = p.id
                WHERE p.name = '$CURRENT_PLAYLIST'
                ORDER BY t.filepath
                LIMIT 1;
            ")

            # If no track in playlist, get any track from library
            if [ -z "$CURRENT_TRACK" ]; then
                CURRENT_TRACK=$(sqlite3 "$DATABASE" "SELECT filepath FROM tracks LIMIT 1;")
            fi
        fi

        if [ -n "$CURRENT_TRACK" ] && [ -f "$CURRENT_TRACK" ]; then
            play_music "$CURRENT_TRACK"
        else
            show_message "No tracks available in library or playlist. Please scan your music library first."
        fi
    else
        # Music is playing, pause/resume
        if [ $IS_PLAYING -eq 1 ]; then
            # Pause
            if [ -S "/tmp/mpv-socket" ]; then
                echo '{ "command": ["set_property", "pause", true] }' | socat - /tmp/mpv-socket 2>/dev/null
            fi
            IS_PLAYING=0
            show_message "Music paused"
        else
            # Resume
            if [ -S "/tmp/mpv-socket" ]; then
                echo '{ "command": ["set_property", "pause", false] }' | socat - /tmp/mpv-socket 2>/dev/null
            fi
            IS_PLAYING=1
            show_message "Music resumed"
        fi
    fi
}

# Favorites System
show_favorites() {
    local tracks=$(sqlite3 "$DATABASE" "SELECT t.filepath, t.artist, t.title FROM tracks t JOIN favorites f ON t.id = f.track_id;")
    if [ -z "$tracks" ]; then
        show_message "No favorite tracks found."
        return
    fi
    
    local options=()
    while IFS='|' read -r filepath artist title; do
        options+=("${artist:-Unknown Artist} - ${title:-Unknown Title}")
    done <<< "$tracks"
    
    show_menu "Favorites" "${options[@]}"
    local selected=$?
    
    if [ $selected -ne 255 ]; then
        local selected_track=$(echo "$tracks" | sed -n "$((selected+1))p" | cut -d'|' -f1)
        play_music "$selected_track"
    fi
}

remove_from_favorites() {
    local filepath="$1"
    sqlite3 "$DATABASE" "DELETE FROM favorites WHERE track_id = (SELECT id FROM tracks WHERE filepath = '$filepath');"
    show_message "Track removed from Favorites!"
}

# Recently Played & Most Played
show_recently_played() {
    local tracks=$(sqlite3 "$DATABASE" "SELECT t.filepath, t.artist, t.title, MAX(ph.played_at) FROM tracks t JOIN playback_history ph ON t.id = ph.track_id GROUP BY t.filepath ORDER BY MAX(ph.played_at) DESC LIMIT 20;")
    if [ -z "$tracks" ]; then
        show_message "No recently played tracks found."
        return
    fi
    
    local options=()
    while IFS='|' read -r filepath artist title _; do
        options+=("${artist:-Unknown Artist} - ${title:-Unknown Title}")
    done <<< "$tracks"
    
    show_menu "Recently Played" "${options[@]}"
    local selected=$?
    
    if [ $selected -ne 255 ]; then
        local selected_track=$(echo "$tracks" | sed -n "$((selected+1))p" | cut -d'|' -f1)
        play_music "$selected_track"
    fi
}

show_most_played() {
    local tracks=$(sqlite3 "$DATABASE" "SELECT t.filepath, t.artist, t.title, COUNT(ph.id) as play_count FROM tracks t JOIN playback_history ph ON t.id = ph.track_id GROUP BY t.filepath ORDER BY play_count DESC LIMIT 20;")
    if [ -z "$tracks" ]; then
        show_message "No most played tracks found."
        return
    fi
    
    local options=()
    while IFS='|' read -r filepath artist title _; do
        options+=("${artist:-Unknown Artist} - ${title:-Unknown Title}")
    done <<< "$tracks"
    
    show_menu "Most Played" "${options[@]}"
    local selected=$?
    
    if [ $selected -ne 255 ]; then
        local selected_track=$(echo "$tracks" | sed -n "$((selected+1))p" | cut -d'|' -f1)
        play_music "$selected_track"
    fi
}

# Queue System
show_queue() {
    local tracks=$(sqlite3 "$DATABASE" "SELECT t.filepath, t.artist, t.title FROM tracks t JOIN queue q ON t.id = q.track_id ORDER BY q.id;")
    if [ -z "$tracks" ]; then
        show_message "Queue is empty."
        return
    fi
    
    local options=()
    while IFS='|' read -r filepath artist title; do
        options+=("${artist:-Unknown Artist} - ${title:-Unknown Title}")
    done <<< "$tracks"
    
    show_menu "Play Queue" "${options[@]}"
    local selected=$?
    
    if [ $selected -ne 255 ]; then
        local selected_track=$(echo "$tracks" | sed -n "$((selected+1))p" | cut -d'|' -f1)
        play_music "$selected_track"
    fi
}

clear_queue() {
    sqlite3 "$DATABASE" "DELETE FROM queue;"
    show_message "Queue cleared!"
}

# Sleep Timer
sleep_timer() {
    echo -e "${BLUE}Enter minutes until stop playback: ${NC}"
    read -r minutes
    
    if [ -n "$minutes" ]; then
        (sleep $((minutes*60)); cleanup_and_exit) &
        show_message "Sleep timer set for $minutes minutes."
    fi
}

# Online URL Playback
play_online_url() {
    local url=""
    local clipboard_content=""

    # Try to get content from clipboard
    if command -v xclip > /dev/null 2>&1; then
        clipboard_content=$(xclip -selection clipboard -o 2>/dev/null)
    elif command -v xsel > /dev/null 2>&1; then
        clipboard_content=$(xsel -b 2>/dev/null)
    fi

    # Show clipboard options if content is available
    if [[ -n "$clipboard_content" && "$clipboard_content" =~ ^https?:// ]]; then
        local options=(
            "Use URL from clipboard"
            "Enter new URL manually"
            "Clear clipboard and enter URL"
            "Cancel"
        )
        
        show_menu "Clipboard URL Detected: $clipboard_content" "${options[@]}"
        local choice=$?
        
        case $choice in
            0) url="$clipboard_content" ;;
            1) 
                echo -e "${BLUE}Enter direct audio/video URL (YouTube, mp3, etc.):${NC}"
                read -r url
                ;;
            2)
                # Clear clipboard
                if command -v xclip > /dev/null 2>&1; then
                    echo "" | xclip -selection clipboard
                elif command -v xsel > /dev/null 2>&1; then
                    echo "" | xsel -b
                fi
                echo -e "${BLUE}Enter direct audio/video URL (YouTube, mp3, etc.):${NC}"
                read -r url
                ;;
            *) return ;;
        esac
    else
        # No valid URL in clipboard
        local options=(
            "Enter URL manually"
            "Paste from clipboard (if available)"
            "Cancel"
        )
        
        show_menu "Play Online URL" "${options[@]}"
        local choice=$?
        
        case $choice in
            0) 
                echo -e "${BLUE}Enter direct audio/video URL (YouTube, mp3, etc.):${NC}"
                read -r url
                ;;
            1)
                # Try to get clipboard content again
                if command -v xclip > /dev/null 2>&1; then
                    clipboard_content=$(xclip -selection clipboard -o 2>/dev/null)
                elif command -v xsel > /dev/null 2>&1; then
                    clipboard_content=$(xsel -b 2>/dev/null)
                fi

                if [[ -n "$clipboard_content" && "$clipboard_content" =~ ^https?:// ]]; then
                    url="$clipboard_content"
                    show_message "Using URL from clipboard: $url"
                else
                    show_message "No valid URL found in clipboard. Please enter URL manually."
                    echo -e "${BLUE}Enter direct audio/video URL (YouTube, mp3, etc.):${NC}"
                    read -r url
                fi
                ;;
            *) return ;;
        esac
    fi

    if [ -n "$url" ]; then
        # Validate URL
        if [[ "$url" =~ ^https?:// ]]; then
            # Stop current playback if exists
            if [ -n "$PLAYER_PID" ] && ps -p "$PLAYER_PID" > /dev/null; then
                kill "$PLAYER_PID" 2>/dev/null
                sleep 0.5
                if ps -p "$PLAYER_PID" > /dev/null; then
                    kill -9 "$PLAYER_PID" 2>/dev/null
                fi
            fi

            # Remove old socket if exists
            if [ -S "/tmp/mpv-socket" ]; then
                rm -f /tmp/mpv-socket
            fi

            # Play URL with improved settings
            mpv --no-terminal \
                 --quiet \
                 --no-video \
                 --input-ipc-server=/tmp/mpv-socket \
                 --volume=$VOLUME \
                 --audio-display=no \
                 "$url" &

            PLAYER_PID=$!
            CURRENT_TRACK="$url"
            IS_PLAYING=1

            # Wait for mpv to start and create socket
            sleep 2

            # Check if mpv started successfully
            if ! ps -p "$PLAYER_PID" > /dev/null; then
                show_message "Failed to start mpv player. Please check if the URL is valid and mpv is installed."
                return
            fi

            # Wait for socket to be created
            local socket_wait=0
            while [ ! -S "/tmp/mpv-socket" ] && [ $socket_wait -lt 10 ]; do
                sleep 0.5
                ((socket_wait++))
            done

            if [ ! -S "/tmp/mpv-socket" ]; then
                show_message "MPV socket not created. Playback may not work properly."
            fi

            # Send notification
            if command -v notify-send > /dev/null; then
                notify-send "Now Streaming" "$url" -i audio-volume-high
            fi

            show_message "URL playback started successfully!\n\nURL: $url"
        else
            show_message "The entered URL is invalid. Please make sure it starts with http:// or https://"
        fi
    fi
}

# Copy current URL to clipboard
copy_current_url() {
    if [ -n "$CURRENT_TRACK" ] && [[ "$CURRENT_TRACK" =~ ^https?:// ]]; then
        # Copy URL to clipboard
        if command -v xclip > /dev/null 2>&1; then
            echo "$CURRENT_TRACK" | xclip -selection clipboard
        elif command -v xsel > /dev/null 2>&1; then
            echo "$CURRENT_TRACK" | xsel -b
        else
            show_message "Cannot find clipboard tool (xclip or xsel).\n\nURL: $CURRENT_TRACK"
            return 1
        fi

        show_message "URL copied to clipboard successfully!\n\nURL: $CURRENT_TRACK"
    else
        show_message "No current URL to copy.\n\nYou need to play an online URL first."
    fi
}

# Saved URLs management
show_saved_urls() {
    # Default radio stations
    local default_stations=(
        "Tes3enat FM|http://178.33.135.244:20095/"
        "Nogoum FM|https://audio.nrpstream.com/listen/nogoumfm/radio.mp3"
        "Q-Cairo|https://n09.radiojar.com/8s5u5tpdtwzuv"
    )

    # Create selection list
    local options=()
    for station in "${default_stations[@]}"; do
        local name=$(echo "$station" | cut -d'|' -f1)
        options+=("$name")
    done
    
    options+=("Add New URL")
    options+=("Back")
    
    show_menu "Radio Stations" "${options[@]}"
    local choice=$?
    
    case $choice in
        0|1|2)
            local selected_station="${default_stations[$choice]}"
            local selected_name=$(echo "$selected_station" | cut -d'|' -f1)
            local selected_url=$(echo "$selected_station" | cut -d'|' -f2)
            play_saved_url "$selected_url" "$selected_name"
            ;;
        $((${#default_stations[@]})))
            add_new_saved_url
            ;;
        *)
            return
            ;;
    esac
}

add_new_saved_url() {
    local saved_urls_file="$CONFIG_DIR/saved_urls.txt"
    local name
    local url

    # Create file if it doesn't exist
    if [ ! -f "$saved_urls_file" ]; then
        touch "$saved_urls_file"
    fi

    echo -e "${BLUE}Enter a name for the radio station: ${NC}"
    read -r name

    if [ -n "$name" ]; then
        echo -e "${BLUE}Enter the radio station URL: ${NC}"
        read -r url

        if [ -n "$url" ] && [[ "$url" =~ ^https?:// ]]; then
            echo "$name|$url" >> "$saved_urls_file"
            show_message "Radio station saved successfully!"
        else
            show_message "Invalid URL!"
        fi
    fi
}

play_saved_url() {
    local url="$1"
    local name="$2"

    # Stop current playback if exists
    if [ -n "$PLAYER_PID" ] && ps -p "$PLAYER_PID" > /dev/null; then
        kill "$PLAYER_PID" 2>/dev/null
        sleep 0.5
        if ps -p "$PLAYER_PID" > /dev/null; then
            kill -9 "$PLAYER_PID" 2>/dev/null
        fi
    fi

    # Remove old socket if exists
    if [ -S "/tmp/mpv-socket" ]; then
        rm -f /tmp/mpv-socket
    fi

    # Play URL
    mpv --no-terminal \
         --quiet \
         --no-video \
         --input-ipc-server=/tmp/mpv-socket \
         --volume=$VOLUME \
         --audio-display=no \
         "$url" &

    PLAYER_PID=$!
    CURRENT_TRACK="$url"
    IS_PLAYING=1

    # Wait for mpv to start and create socket
    sleep 2

    # Check if mpv started successfully
    if ! ps -p "$PLAYER_PID" > /dev/null; then
        show_message "Failed to start mpv player for $name. Please check if the URL is valid."
        return
    fi

    # Wait for socket to be created
    local socket_wait=0
    while [ ! -S "/tmp/mpv-socket" ] && [ $socket_wait -lt 10 ]; do
        sleep 0.5
        ((socket_wait++))
    done

    if [ ! -S "/tmp/mpv-socket" ]; then
        show_message "MPV socket not created for $name. Playback may not work properly."
    fi

    # Send notification
    if command -v notify-send > /dev/null; then
        notify-send "Now Streaming" "$name" -i audio-volume-high
    fi

    show_message "Radio station started successfully!\n\nStation: $name"
}

# Now Playing List
show_now_playing_list() {
    local current_playlist="$CURRENT_PLAYLIST"
    local tracks=""
    local playlist_name=""

    # Get tracks from current playlist
    if [ -n "$current_playlist" ] && [ "$current_playlist" != "My Library" ]; then
        tracks=$(sqlite3 "$DATABASE" "
            SELECT t.filepath, t.artist, t.title, t.album, t.duration
            FROM tracks t
            JOIN playlist_tracks pt ON t.id = pt.track_id
            JOIN playlists p ON pt.playlist_id = p.id
            WHERE p.name = '$current_playlist'
            ORDER BY pt.position, t.filepath;
        ")
        playlist_name="$current_playlist"
    else
        # Get all tracks from library
        tracks=$(sqlite3 "$DATABASE" "
            SELECT filepath, artist, title, album, duration
            FROM tracks
            ORDER BY filepath;
        ")
        playlist_name="Music Library"
    fi

    if [ -z "$tracks" ]; then
        show_message "No tracks found in current playlist/library.\n\nPlease scan your library or add tracks to a playlist first."
        return
    fi

    # Create options list
    local options=()
    while IFS='|' read -r filepath artist title album duration; do
        local display_name=""
        local status_indicator=""

        # Format duration
        if [ -n "$duration" ] && [ "$duration" != "N/A" ] && [ "$duration" != "0" ]; then
            local duration_int=$(echo "$duration" | cut -d'.' -f1)
            local minutes=$((duration_int / 60))
            local seconds=$((duration_int % 60))
            local formatted_duration="${minutes}:$(printf "%02d" $seconds)"
        else
            formatted_duration="Unknown"
        fi

        # Check if this is the currently playing track
        if [ "$filepath" = "$CURRENT_TRACK" ]; then
            status_indicator="▶ "
        else
            status_indicator="  "
        fi

        # Create display name
        if [ -n "$artist" ] && [ -n "$title" ]; then
            display_name="${artist} - ${title}"
        elif [ -n "$title" ]; then
            display_name="$title"
        else
            display_name=$(basename "$filepath")
        fi

        # Add album info if available
        if [ -n "$album" ] && [ "$album" != "Unknown" ]; then
            display_name="$display_name [${album}]"
        fi

        # Add duration
        display_name="$display_name (${formatted_duration})"

        options+=("${status_indicator}${display_name}")
    done <<< "$tracks"

    # Add playlist info
    local playlist_info=""
    if [ -n "$CURRENT_TRACK" ]; then
        local current_info=$(sqlite3 "$DATABASE" "SELECT artist, title FROM tracks WHERE filepath = '$CURRENT_TRACK';")
        local current_artist=$(echo "$current_info" | cut -d'|' -f1)
        local current_title=$(echo "$current_info" | cut -d'|' -f2)
        playlist_info="\nCurrently Playing: ${current_artist:-Unknown Artist} - ${current_title:-Unknown Title}"
    fi

    show_menu "Now Playing List - $playlist_name" "${options[@]}"
    local selected=$?
    
    if [ $selected -ne 255 ]; then
        local selected_track=$(echo "$tracks" | sed -n "$((selected+1))p" | cut -d'|' -f1)
        if [ -n "$selected_track" ] && [ -f "$selected_track" ]; then
            play_music "$selected_track"
        else
            show_message "Selected track not found or is not a valid file."
        fi
    fi
}

# Toggle auto-next feature
toggle_auto_next() {
    if [ $AUTO_NEXT -eq 1 ]; then
        AUTO_NEXT=0
        # Kill monitor if running
        if [ -n "$MONITOR_PID" ] && ps -p "$MONITOR_PID" > /dev/null; then
            kill "$MONITOR_PID" 2>/dev/null
            MONITOR_PID=""
        fi
        show_message "Auto Next feature has been turned OFF.\n\nTracks will not automatically advance to the next song."
    else
        AUTO_NEXT=1
        # Start monitor if music is currently playing
        if [ -n "$PLAYER_PID" ] && ps -p "$PLAYER_PID" > /dev/null; then
            start_auto_next_monitor
        fi
        show_message "Auto Next feature has been turned ON.\n\nTracks will automatically advance to the next song when finished."
    fi
}

# Main menu
show_main_menu() {
    local repeat_status
    if [ $REPEAT_MODE -eq 1 ]; then
        repeat_status="ON"
    else
        repeat_status="OFF"
    fi

    local auto_next_status
    if [ $AUTO_NEXT -eq 1 ]; then
        auto_next_status="ON"
    else
        auto_next_status="OFF"
    fi

    local options=(
        "Play/Pause"
        "Next track"
        "Previous track"
        "Browse files"
        "Manage playlists"
        "Show history"
        "Increase volume"
        "Decrease volume"
        "Scan Library"
        "Search Library"
        "Toggle Repeat Mode (Current: $repeat_status)"
        "Favorites"
        "Recently Played"
        "Most Played"
        "Play Queue"
        "Sleep Timer"
        "Play Online URL"
        "Copy Current URL"
        "Saved URLs"
        "Now Playing List"
        "Toggle Auto Next (Current: $auto_next_status)"
        "Exit"
    )

    show_menu "MTSP - Main Menu" "${options[@]}"
    local choice=$?
    
    case $choice in
        0) toggle_playback ;;
        1) next_track ;;
        2) previous_track ;;
        3) browse_files ;;
        4) manage_playlists ;;
        5) show_history ;;
        6) change_volume "+" ;;
        7) change_volume "-" ;;
        8) scan_library ;;
        9) search_library ;;
        10) toggle_repeat_mode ;;
        11) show_favorites ;;
        12) show_recently_played ;;
        13) show_most_played ;;
        14) show_queue ;;
        15) sleep_timer ;;
        16) play_online_url ;;
        17) copy_current_url ;;
        18) show_saved_urls ;;
        19) show_now_playing_list ;;
        20) toggle_auto_next ;;
        21) cleanup_and_exit ;;
        255) cleanup_and_exit ;;
    esac
}

# Start the application
main() {
    check_dependencies
    setup_environment
    trap cleanup_and_exit SIGINT SIGTERM

    while true; do
        show_main_menu
    done
}

main