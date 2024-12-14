#!/bin/bash

# MTSP - Music Terminal Shell Player
# Variables and Setup
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

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

# Core Functions
main() {
    setup_environment
    trap cleanup_and_exit SIGINT SIGTERM
    
    while true; do
        show_main_menu
        sleep 0.1
    done
}

play_music() {
    local filepath="$1"
    
    if [ -n "$PLAYER_PID" ] && ps -p "$PLAYER_PID" > /dev/null; then
        kill "$PLAYER_PID"
    fi
    
    if [ ! -f "$filepath" ]; then
        dialog --msgbox "Error: File not found - $filepath" 6 40
        return
    fi
    
    mpv --no-terminal --quiet --input-ipc-server=/tmp/mpv-socket "$filepath" >/dev/null 2>&1 &
    PLAYER_PID=$!
    CURRENT_TRACK="$filepath"
    IS_PLAYING=1
    
    sqlite3 "$DATABASE" "
        INSERT INTO playback_history (track_id, played_at)
        VALUES (
            (SELECT id FROM tracks WHERE filepath = '$filepath'), 
            datetime('now')
        );
    "
}

change_volume() {
    local direction="$1"
    local current_volume
    
    if [ -z "$PLAYER_PID" ] || ! ps -p "$PLAYER_PID" > /dev/null; then
        dialog --msgbox "No music is currently playing" 6 40
        return
    fi
    
    if [ "$direction" = "+" ]; then
        VOLUME=$((VOLUME + 10))
        [ $VOLUME -gt 100 ] && VOLUME=100
    elif [ "$direction" = "-" ]; then
        VOLUME=$((VOLUME - 10))
        [ $VOLUME -lt 0 ] && VOLUME=0
    else
        dialog --msgbox "Invalid volume direction" 6 40
        return
    fi
    
    echo '{ "command": ["set_property", "volume", '"$VOLUME"'] }' | socat - /tmp/mpv-socket
    dialog --msgbox "Volume: $VOLUME%" 6 40
}
# File and Playlist Management Functions
browse_files() {
    local current_dir="${1:-$MUSIC_DIR}"
    
    if [ ! -d "$current_dir" ]; then
        dialog --msgbox "Directory not found: $current_dir" 6 40
        return
    fi
    
    local file_list=()
    local counter=1
    
    if [ "$current_dir" != "$MUSIC_DIR" ]; then
        file_list+=("0" "..")
    fi
    
    while IFS= read -r item; do
        local display_name=$(basename "$item")
        if [ -d "$item" ]; then
            file_list+=("$counter" "📁 $display_name")
        elif [[ "$item" =~ \.(mp3|flac|wav|ogg|m4a)$ ]]; then
            file_list+=("$counter" "🎵 $display_name")
        fi
        ((counter++))
    done < <(find "$current_dir" -maxdepth 1 -type d \( ! -name . \) -print0 | sort -z | xargs -0 -I {} basename {}; 
             find "$current_dir" -maxdepth 1 -type f \( -name "*.mp3" -o -name "*.flac" -o -name "*.wav" -o -name "*.ogg" -o -name "*.m4a" \) -print0 | sort -z | xargs -0 -I {} basename {})
    
    local choice
    choice=$(dialog --title "Browse Music Files" \
                    --menu "Navigate or Select a file/directory:" \
                    20 70 15 \
                    "${file_list[@]}" \
                    2>&1 >/dev/tty)
    
    if [ $? -eq 0 ]; then
        if [ "$choice" -eq 0 ]; then
            browse_files "$(dirname "$current_dir")"
        else
            local selected
            if [ "$choice" -eq 0 ]; then
                selected=".."
            else
                selected=$(find "$current_dir" -maxdepth 1 \( -type d -o \( -type f \( -name "*.mp3" -o -name "*.flac" -o -name "*.wav" -o -name "*.ogg" -o -name "*.m4a" \) \) -print0 | sort -z | xargs -0 -I {} basename {} | sed -n "${choice}p")
            fi
            
            local full_path="$current_dir/$selected"
            
            if [ -d "$full_path" ]; then
                browse_files "$full_path"
            elif [ -f "$full_path" ]; then
                play_music "$full_path"
            fi
        fi
    fi
}

manage_playlists() {
    while true; do
        local playlist_options=(
            "1" "Create New Playlist"
            "2" "View Playlists"
            "3" "Add Tracks to Playlist"
            "4" "Remove Tracks from Playlist"
            "5" "Delete Playlist"
            "6" "Return to Main Menu"
        )
        
        local choice
        choice=$(dialog --title "Playlist Management" \
                        --menu "Choose an option:" \
                        15 60 6 \
                        "${playlist_options[@]}" \
                        2>&1 >/dev/tty)
        
        case $choice in
            1) create_playlist ;;
            2) view_playlists ;;
            3) add_tracks_to_playlist ;;
            4) remove_tracks_from_playlist ;;
            5) delete_playlist ;;
            6) break ;;
        esac
    done
}
# Playlist Management Functions
create_playlist() {
    local playlist_name
    playlist_name=$(dialog --title "Create Playlist" \
                            --inputbox "Enter playlist name:" \
                            8 40 \
                            2>&1 >/dev/tty)
    
    if [ $? -eq 0 ] && [ -n "$playlist_name" ]; then
        local existing=$(sqlite3 "$DATABASE" "SELECT name FROM playlists WHERE name = '$playlist_name';")
        if [ -z "$existing" ]; then
            sqlite3 "$DATABASE" "INSERT INTO playlists (name) VALUES ('$playlist_name');"
            dialog --msgbox "Playlist '$playlist_name' created successfully!" 6 40
        else
            dialog --msgbox "A playlist with this name already exists." 6 40
        fi
    fi
}

view_playlists() {
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists;")
    
    if [ -z "$playlists" ]; then
        dialog --msgbox "No playlists found." 6 40
        return
    fi
    
    local options=()
    local counter=1
    while IFS= read -r playlist; do
        options+=("$counter" "$playlist")
        ((counter++))
    done <<< "$playlists"
    
    local selected
    selected=$(dialog --title "Your Playlists" \
                      --menu "Select a playlist to view tracks:" \
                      20 70 15 \
                      "${options[@]}" \
                      2>&1 >/dev/tty)
    
    if [ $? -eq 0 ]; then
        local selected_playlist=$(echo "$playlists" | sed -n "${selected}p")
        view_playlist_tracks "$selected_playlist"
    fi
}

view_playlist_tracks() {
    local playlist_name="$1"
    local tracks=$(sqlite3 "$DATABASE" \
        "SELECT t.filepath, t.artist, t.title 
         FROM tracks t
         JOIN playlist_tracks pt ON t.id = pt.track_id
         JOIN playlists p ON pt.playlist_id = p.id
         WHERE p.name = '$playlist_name';")
    
    if [ -z "$tracks" ]; then
        dialog --msgbox "No tracks in this playlist." 6 40
        return
    fi
    
    local options=()
    local counter=1
    while IFS='|' read -r filepath artist title; do
        options+=("$counter" "$artist - $title")
        ((counter++))
    done <<< "$tracks"
    
    local selected
    selected=$(dialog --title "Playlist Tracks: $playlist_name" \
                      --menu "Select a track to play:" \
                      20 70 15 \
                      "${options[@]}" \
                      2>&1 >/dev/tty)
    
    if [ $? -eq 0 ]; then
        local selected_track=$(echo "$tracks" | sed -n "${selected}p" | cut -d'|' -f1)
        play_music "$selected_track"
    fi
}
# Playback Control Functions
add_tracks_to_playlist() {
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists;")
    
    local playlist_options=()
    local counter=1
    while IFS= read -r playlist; do
        playlist_options+=("$counter" "$playlist")
        ((counter++))
    done <<< "$playlists"
    
    local selected_playlist
    selected_playlist=$(dialog --title "Select Playlist" \
                                --menu "Choose a playlist to add tracks:" \
                                20 70 15 \
                                "${playlist_options[@]}" \
                                2>&1 >/dev/tty)
    
    if [ $? -eq 0 ]; then
        local playlist_name=$(echo "$playlists" | sed -n "${selected_playlist}p")
        local tracks=$(sqlite3 "$DATABASE" "SELECT filepath, artist, title FROM tracks;")
        local track_options=()
        local counter=1
        
        while IFS='|' read -r filepath artist title; do
            track_options+=("$counter" "$artist - $title" "off")
            ((counter++))
        done <<< "$tracks"
        
        local selected_tracks
        selected_tracks=$(dialog --title "Select Tracks" \
                                 --checklist "Choose tracks to add to $playlist_name:" \
                                 20 70 15 \
                                 "${track_options[@]}" \
                                 2>&1 >/dev/tty)
        
        if [ $? -eq 0 ]; then
            for index in $selected_tracks; do
                local track_filepath=$(echo "$tracks" | sed -n "${index}p" | cut -d'|' -f1)
                sqlite3 "$DATABASE" "
                    INSERT OR IGNORE INTO playlist_tracks (playlist_id, track_id)
                    VALUES (
                        (SELECT id FROM playlists WHERE name = '$playlist_name'),
                        (SELECT id FROM tracks WHERE filepath = '$track_filepath')
                    );
                "
            done
            
            dialog --msgbox "Tracks added to $playlist_name successfully!" 6 40
        fi
    fi
}

delete_playlist() {
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists WHERE name != 'My Library';")
    
    if [ -z "$playlists" ]; then
        dialog --msgbox "No playlists to delete." 6 40
        return
    fi
    
    local playlist_options=()
    local counter=1
    while IFS= read -r playlist; do
        playlist_options+=("$counter" "$playlist")
        ((counter++))
    done <<< "$playlists"
    
    local selected_playlist
    selected_playlist=$(dialog --title "Delete Playlist" \
                                --menu "Choose a playlist to delete:" \
                                20 70 15 \
                                "${playlist_options[@]}" \
                                2>&1 >/dev/tty)
    
    if [ $? -eq 0 ]; then
        local playlist_name=$(echo "$playlists" | sed -n "${selected_playlist}p")
        
        dialog --yesno "Are you sure you want to delete the playlist '$playlist_name'?" 8 40
        
        if [ $? -eq 0 ]; then
            sqlite3 "$DATABASE" "
                DELETE FROM playlist_tracks 
                WHERE playlist_id = (SELECT id FROM playlists WHERE name = '$playlist_name');
                DELETE FROM playlists 
                WHERE name = '$playlist_name';
            "
            dialog --msgbox "Playlist '$playlist_name' deleted successfully!" 6 40
        fi
    fi
}
# Playback Control and Navigation Functions
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
        dialog --msgbox "Repeat Mode: ON" 6 20
    else
        REPEAT_MODE=0
        dialog --msgbox "Repeat Mode: OFF" 6 20
    fi
}

toggle_playback() {
    if [ -z "$PLAYER_PID" ] || ! ps -p "$PLAYER_PID" > /dev/null; then
        if [ -z "$CURRENT_TRACK" ]; then
            CURRENT_TRACK=$(sqlite3 "$DATABASE" "
                SELECT t.filepath 
                FROM tracks t
                JOIN playlist_tracks pt ON t.id = pt.track_id
                JOIN playlists p ON pt.playlist_id = p.id
                WHERE p.name = '$CURRENT_PLAYLIST'
                ORDER BY t.filepath
                LIMIT 1;
            ")
        fi

        if [ -n "$CURRENT_TRACK" ]; then
            play_music "$CURRENT_TRACK"
        else
            dialog --msgbox "No tracks available in library or playlist" 6 40
        fi
    else
        kill -SIGINT "$PLAYER_PID"
        
        if [ $IS_PLAYING -eq 1 ]; then
            IS_PLAYING=0
        else
            IS_PLAYING=1
        fi
    fi
}
# Utility Functions
setup_environment() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$PLAYLISTS_DIR"
    
    sqlite3 "$DATABASE" "
        CREATE TABLE IF NOT EXISTS tracks (
            id INTEGER PRIMARY KEY,
            filepath TEXT UNIQUE,
            title TEXT,
            artist TEXT,
            album TEXT
        );
        
        CREATE TABLE IF NOT EXISTS playlists (
            id INTEGER PRIMARY KEY,
            name TEXT UNIQUE
        );
        
        CREATE TABLE IF NOT EXISTS playlist_tracks (
            playlist_id INTEGER,
            track_id INTEGER,
            FOREIGN KEY(playlist_id) REFERENCES playlists(id),
            FOREIGN KEY(track_id) REFERENCES tracks(id),
            UNIQUE(playlist_id, track_id)
        );
        
        CREATE TABLE IF NOT EXISTS playback_history (
            id INTEGER PRIMARY KEY,
            track_id INTEGER,
            played_at DATETIME,
            FOREIGN KEY(track_id) REFERENCES tracks(id)
        );
        
        INSERT OR IGNORE INTO playlists (name) VALUES ('$DEFAULT_PLAYLIST');
    "
}

cleanup_and_exit() {
    if [ -n "$PLAYER_PID" ] && ps -p "$PLAYER_PID" > /dev/null; then
        kill "$PLAYER_PID"
    fi
    
    if [ -S "/tmp/mpv-socket" ]; then
        rm /tmp/mpv-socket
    fi
    
    clear
    echo "MTSP Music Player terminated."
    exit 0
}

show_main_menu() {
    local repeat_status
    if [ $REPEAT_MODE -eq 1 ]; then
        repeat_status="ON"
    else
        repeat_status="OFF"
    fi
    
    local options=(
        "1" "Play/Pause"
        "2" "Next track"
        "3" "Previous track"
        "4" "Browse files"
        "5" "Manage playlists"
        "6" "Show history"
        "7" "Increase volume"
        "8" "Decrease volume"
        "9" "Scan Library"
        "10" "Search Library"
        "11" "Toggle Repeat Mode (Current: $repeat_status)"
        "12" "Exit"
    )
    
    local choice
    choice=$(dialog --title "MTSP - Main Menu" \
                   --menu "Choose an operation:" \
                   15 60 12 \
                   "${options[@]}" \
                   2>&1 >/dev/tty)
    
    case $choice in
        1) toggle_playback ;;
        2) next_track ;;
        3) previous_track ;;
        4) browse_files ;;
        5) manage_playlists ;;
        6) show_history ;;
        7) change_volume "+" ;;
        8) change_volume "-" ;;
        9) scan_library ;;
        10) search_library ;;
        11) toggle_repeat_mode ;;
        12) cleanup_and_exit ;;
    esac
}

# Start the application
main