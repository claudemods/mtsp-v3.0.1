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
    check_dependencies
    setup_environment
    trap cleanup_and_exit SIGINT SIGTERM
    
    while true; do
        show_main_menu
        sleep 0.1
    done
}

play_music() {
    local filepath="$1"
    echo "DEBUG: play_music called with $filepath"
    if [ -n "$PLAYER_PID" ] && ps -p "$PLAYER_PID" > /dev/null; then
        echo "DEBUG: Killing previous PLAYER_PID $PLAYER_PID"
        kill "$PLAYER_PID"
    fi
    if [ ! -f "$filepath" ]; then
        dialog --msgbox "Error: File not found - $filepath" 6 40
        return
    fi
    echo "DEBUG: Starting mpv for $filepath"
    mpv --no-terminal --quiet --af=volnorm --input-ipc-server=/tmp/mpv-socket "$filepath" &
    PLAYER_PID=$!
    CURRENT_TRACK="$filepath"
    IS_PLAYING=1
    echo "DEBUG: Inserting playback history for $filepath"
    sqlite3 "$DATABASE" "
        INSERT INTO playback_history (track_id, played_at)
        VALUES (
            (SELECT id FROM tracks WHERE filepath = '$filepath'), 
            datetime('now')
        );
    "
    notify_now_playing "$filepath"
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
    local filter_type="all"
    while true; do
        if [ ! -d "$current_dir" ]; then
            dialog --msgbox "Directory not found: $current_dir" 6 40
            return
        fi
        local file_list=("0" ".. [Go up]")
        local counter=1
        local find_cmd="find \"$current_dir\" -maxdepth 1"
        case "$filter_type" in
            mp3) find_cmd+=" -type f -name '*.mp3'" ;;
            flac) find_cmd+=" -type f -name '*.flac'" ;;
            wav) find_cmd+=" -type f -name '*.wav'" ;;
            ogg) find_cmd+=" -type f -name '*.ogg'" ;;
            m4a) find_cmd+=" -type f -name '*.m4a'" ;;
            all) find_cmd+=" \( -type d -o -type f \)" ;;
        esac
        local items=$(eval $find_cmd | sort)
        while IFS= read -r item; do
            [ "$item" = "$current_dir" ] && continue
            local display_name=$(basename "$item")
            if [ -d "$item" ]; then
                file_list+=("$counter" "📁 $display_name")
            elif [[ "$item" =~ \\.(mp3|flac|wav|ogg|m4a)$ ]]; then
                file_list+=("$counter" "🎵 $display_name")
            else
                file_list+=("$counter" "$display_name")
            fi
            ((counter++))
        done <<< "$items"
        local menu_options=(
            "F" "Filter by type"
            "S" "Search by name"
            "M" "Select multiple files to play"
            "Q" "Return to Main Menu"
        )
        local choice
        choice=$(dialog --title "Browse Music Files" \
                        --menu "Navigate, filter, or select a file/directory:" \
                        22 80 18 \
                        "${file_list[@]}" \
                        "${menu_options[@]}" \
                        2>&1 >/dev/tty)
        if [ $? -ne 0 ]; then
            break
        fi
        if [ "$choice" = "Q" ]; then
            break
        elif [ "$choice" = "F" ]; then
            local filter
            filter=$(dialog --title "Filter Files" \
                            --menu "Choose file type to display:" \
                            12 40 6 \
                            "all" "All" \
                            "mp3" "MP3" \
                            "flac" "FLAC" \
                            "wav" "WAV" \
                            "ogg" "OGG" \
                            "m4a" "M4A" \
                            2>&1 >/dev/tty)
            if [ $? -eq 0 ]; then
                filter_type="$filter"
            fi
            continue
        elif [ "$choice" = "S" ]; then
            local search_term
            search_term=$(dialog --title "Search Files" --inputbox "Enter part of the file name to search:" 8 40 2>&1 >/dev/tty)
            if [ $? -eq 0 ] && [ -n "$search_term" ]; then
                local search_results=()
                local search_counter=1
                while IFS= read -r item; do
                    local display_name=$(basename "$item")
                    if [ -d "$item" ]; then
                        search_results+=("$search_counter" "📁 $display_name")
                    elif [[ "$item" =~ \\.(mp3|flac|wav|ogg|m4a)$ ]]; then
                        search_results+=("$search_counter" "🎵 $display_name")
                    else
                        search_results+=("$search_counter" "$display_name")
                    fi
                    ((search_counter++))
                done < <(find "$current_dir" -maxdepth 1 -iname "*$search_term*" | sort)
                if [ ${#search_results[@]} -eq 0 ]; then
                    dialog --msgbox "No files found matching '$search_term'." 6 40
                else
                    local selected_search
                    selected_search=$(dialog --title "Search Results" \
                                            --menu "Select a file or directory:" \
                                            20 70 15 \
                                            "${search_results[@]}" \
                                            2>&1 >/dev/tty)
                    if [ $? -eq 0 ]; then
                        local selected_item=$(find "$current_dir" -maxdepth 1 -iname "*$search_term*" | sort | sed -n "${selected_search}p")
                        if [ -d "$selected_item" ]; then
                            play_folder "$selected_item"
                        elif [ -f "$selected_item" ]; then
                            show_file_metadata_and_play "$selected_item"
                        fi
                    fi
                fi
            fi
            continue
        elif [ "$choice" = "M" ]; then
            select_multiple_files_to_play "$current_dir"
            continue
        elif [ "$choice" -eq 0 ]; then
            current_dir="$(dirname "$current_dir")"
            continue
        else
            local selected=$(find "$current_dir" -maxdepth 1 | sort | sed -n "$((choice+1))p")
            if [ -d "$selected" ]; then
                local folder_action
                folder_action=$(dialog --title "Folder Options" \
                                      --menu "Choose an action for this folder:" \
                                      12 50 2 \
                                      "B" "Browse this folder" \
                                      "P" "Play all audio files in this folder" \
                                      2>&1 >/dev/tty)
                if [ "$folder_action" = "P" ]; then
                    play_folder "$selected"
                else
                    current_dir="$selected"
                fi
            elif [ -f "$selected" ]; then
                show_file_metadata_and_play "$selected"
            fi
        fi
    done
}

show_file_metadata_and_play() {
    local filepath="$1"
    local info="$(ffprobe -v error -show_entries format=duration:format_tags=title,artist,album -of default=noprint_wrappers=1:nokey=1 \"$filepath\" 2>/dev/null)"
    local title="$(echo "$info" | sed -n '2p')"
    local artist="$(echo "$info" | sed -n '3p')"
    local album="$(echo "$info" | sed -n '4p')"
    local duration="$(echo "$info" | sed -n '1p')"
    local action
    action=$(dialog --title "File Options" \
        --menu "Title: ${title:-Unknown}\nArtist: ${artist:-Unknown}\nAlbum: ${album:-Unknown}\nDuration: ${duration:-Unknown} sec\n\nChoose an action:" \
        16 60 5 \
        "P" "Play this file" \
        "A" "Add to Playlist" \
        "Q" "Add to Queue" \
        "F" "Add to Favorites" \
        "C" "Cancel" \
        2>&1 >/dev/tty)
    case $action in
        P) play_music "$filepath" ;;
        A) add_file_to_playlist_from_browser "$filepath" ;;
        Q) add_to_queue "$filepath" ;;
        F) add_to_favorites "$filepath" ;;
        *) ;; # Cancel
    esac
}

add_file_to_playlist_from_browser() {
    local filepath="$1"
    echo "DEBUG: add_file_to_playlist_from_browser called with $filepath"
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists;")
    if [ -z "$playlists" ]; then
        dialog --msgbox "No playlists found. Please create a playlist first." 6 40
        return
    fi
    local options=()
    local counter=1
    while IFS= read -r playlist; do
        options+=("$counter" "$playlist")
        ((counter++))
    done <<< "$playlists"
    local selected
    selected=$(dialog --title "Add to Playlist" --menu "Select a playlist:" 20 70 15 "${options[@]}" 2>&1 >/dev/tty)
    if [ $? -eq 0 ]; then
        local playlist_name=$(echo "$playlists" | sed -n "${selected}p")
        echo "DEBUG: Adding $filepath to playlist $playlist_name"
        sqlite3 "$DATABASE" "INSERT OR IGNORE INTO playlist_tracks (playlist_id, track_id) VALUES ((SELECT id FROM playlists WHERE name = '$playlist_name'), (SELECT id FROM tracks WHERE filepath = '$filepath'));"
        dialog --msgbox "Track added to playlist '$playlist_name' successfully!" 6 40
    fi
}

# --- Smooth File Browsing and Adding in Playlist Management ---
browse_and_select_files_for_playlist() {
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists;")
    if [ -z "$playlists" ]; then
        dialog --msgbox "No playlists found. Please create a playlist first." 6 40
        return
    fi
    local options=()
    local counter=1
    while IFS= read -r playlist; do
        options+=("$counter" "$playlist")
        ((counter++))
    done <<< "$playlists"
    local selected
    selected=$(dialog --title "Select Playlist" --menu "Choose a playlist to add files:" 20 70 15 "${options[@]}" 2>&1 >/dev/tty)
    if [ $? -ne 0 ]; then
        return
    fi
    local playlist_name=$(echo "$playlists" | sed -n "${selected}p")
    local current_dir="$MUSIC_DIR"
    while true; do
        if [ ! -d "$current_dir" ]; then
            dialog --msgbox "Directory not found: $current_dir" 6 40
            return
        fi
        local files=( )
        local options=( )
        local counter=1
        while IFS= read -r file; do
            if [ -f "$file" ] && [[ "$file" =~ \.(mp3|flac|wav|ogg|m4a)$ ]]; then
                files+=("$file")
                local display_name=$(basename "$file")
                options+=("$counter" "$display_name" "off")
                ((counter++))
            fi
        done < <(find "$current_dir" -maxdepth 1 -type f \( -iname "*.mp3" -o -iname "*.flac" -o -iname "*.wav" -o -iname "*.ogg" -o -iname "*.m4a" \) | sort)
        local folders=( )
        local folder_options=( )
        local folder_counter=1
        while IFS= read -r folder; do
            if [ "$folder" != "$current_dir" ]; then
                folders+=("$folder")
                local display_name=$(basename "$folder")
                folder_options+=("$folder_counter" "📁 $display_name")
                ((folder_counter++))
            fi
        done < <(find "$current_dir" -maxdepth 1 -type d | sort)
        local menu_options=( )
        for ((i=0; i<${#folder_options[@]}; i+=2)); do
            menu_options+=(${folder_options[i]} ${folder_options[i+1]})
        done
        menu_options+=("F" "Select audio files in this folder")
        menu_options+=("Q" "Return to Playlist Menu")
        local choice
        choice=$(dialog --title "Browse and Add Files to Playlist: $playlist_name" \
                        --menu "Browse folders or select files to add:" \
                        22 80 18 \
                        "${menu_options[@]}" \
                        2>&1 >/dev/tty)
        if [ $? -ne 0 ] || [ "$choice" = "Q" ]; then
            break
        fi
        if [ "$choice" = "F" ]; then
            if [ ${#files[@]} -eq 0 ]; then
                dialog --msgbox "No audio files found in this directory." 6 40
                continue
            fi
            local selected_files
            selected_files=$(dialog --title "Select Tracks" \
                                    --checklist "Choose tracks to add to $playlist_name:" \
                                    20 70 15 \
                                    "${options[@]}" \
                                    2>&1 >/dev/tty)
            if [ $? -eq 0 ] && [ -n "$selected_files" ]; then
                for index in $selected_files; do
                    local idx=$(echo $index | tr -d '"')
                    local file_to_add="${files[$((idx-1))]}"
                    sqlite3 "$DATABASE" "INSERT OR IGNORE INTO playlist_tracks (playlist_id, track_id) VALUES ((SELECT id FROM playlists WHERE name = '$playlist_name'), (SELECT id FROM tracks WHERE filepath = '$file_to_add'));"
                done
                dialog --msgbox "Selected tracks have been added to the playlist successfully!" 6 40
            fi
        else
            local idx=$((choice-1))
            current_dir="${folders[$idx]}"
        fi
    done
}

# --- تحديث إدارة القوائم لاستخدام المتصفح الجديد ---
manage_playlists() {
    while true; do
        local playlist_options=(
            "1" "Create New Playlist"
            "2" "View Playlists"
            "3" "Add Tracks to Playlist (Browse Files)"
            "4" "Remove Tracks from Playlist"
            "5" "Rename Playlist"
            "6" "Delete Playlist"
            "7" "Return to Main Menu"
        )
        local choice
        choice=$(dialog --title "Playlist Management" \
                        --menu "Choose an option:" \
                        20 60 7 \
                        "${playlist_options[@]}" \
                        2>&1 >/dev/tty)
        case $choice in
            1) create_playlist ;;
            2) view_playlists ;;
            3) browse_and_select_files_for_playlist ;;
            4) remove_tracks_from_playlist ;;
            5) rename_playlist ;;
            6) delete_playlist ;;
            7) break ;;
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
        "SELECT t.filepath, t.artist, t.title, t.album 
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
    while IFS='|' read -r filepath artist title album; do
        local display="${artist:-Unknown Artist} - ${title:-Unknown Title} [${album:-Unknown Album}]"
        options+=("$counter" "$display")
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

rename_playlist() {
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists WHERE name != 'My Library';")
    if [ -z "$playlists" ]; then
        dialog --msgbox "No playlists to rename." 6 40
        return
    fi
    local playlist_options=()
    local counter=1
    while IFS= read -r playlist; do
        playlist_options+=("$counter" "$playlist")
        ((counter++))
    done <<< "$playlists"
    local selected_playlist
    selected_playlist=$(dialog --title "Rename Playlist" \
                                --menu "Choose a playlist to rename:" \
                                20 70 15 \
                                "${playlist_options[@]}" \
                                2>&1 >/dev/tty)
    if [ $? -eq 0 ]; then
        local old_name=$(echo "$playlists" | sed -n "${selected_playlist}p")
        local new_name
        new_name=$(dialog --title "Rename Playlist" \
                          --inputbox "Enter new name for playlist '$old_name':" \
                          8 40 \
                          2>&1 >/dev/tty)
        if [ $? -eq 0 ] && [ -n "$new_name" ]; then
            local exists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists WHERE name = '$new_name';")
            if [ -z "$exists" ]; then
                sqlite3 "$DATABASE" "UPDATE playlists SET name = '$new_name' WHERE name = '$old_name';"
                dialog --msgbox "Playlist renamed successfully!" 6 40
            else
                dialog --msgbox "A playlist with this name already exists." 6 40
            fi
        fi
    fi
}

remove_tracks_from_playlist() {
    local playlists=$(sqlite3 "$DATABASE" "SELECT name FROM playlists;")
    local playlist_options=()
    local counter=1
    while IFS= read -r playlist; do
        playlist_options+=("$counter" "$playlist")
        ((counter++))
    done <<< "$playlists"
    local selected_playlist
    selected_playlist=$(dialog --title "Select Playlist" \
                                --menu "Choose a playlist to remove tracks from:" \
                                20 70 15 \
                                "${playlist_options[@]}" \
                                2>&1 >/dev/tty)
    if [ $? -eq 0 ]; then
        local playlist_name=$(echo "$playlists" | sed -n "${selected_playlist}p")
        local tracks=$(sqlite3 "$DATABASE" "SELECT t.filepath, t.artist, t.title FROM tracks t JOIN playlist_tracks pt ON t.id = pt.track_id JOIN playlists p ON pt.playlist_id = p.id WHERE p.name = '$playlist_name';")
        if [ -z "$tracks" ]; then
            dialog --msgbox "No tracks in this playlist." 6 40
            return
        fi
        local track_options=()
        local counter=1
        while IFS='|' read -r filepath artist title; do
            local display="${artist:-Unknown Artist} - ${title:-Unknown Title}"
            track_options+=("$counter" "$display" "off")
            ((counter++))
        done <<< "$tracks"
        local selected_tracks
        selected_tracks=$(dialog --title "Select Tracks to Remove" \
                                 --checklist "Choose tracks to remove from $playlist_name:" \
                                 20 70 15 \
                                 "${track_options[@]}" \
                                 2>&1 >/dev/tty)
        if [ $? -eq 0 ] && [ -n "$selected_tracks" ]; then
            for index in $selected_tracks; do
                local track_filepath=$(echo "$tracks" | sed -n "${index}p" | cut -d'|' -f1)
                sqlite3 "$DATABASE" "DELETE FROM playlist_tracks WHERE playlist_id = (SELECT id FROM playlists WHERE name = '$playlist_name') AND track_id = (SELECT id FROM tracks WHERE filepath = '$track_filepath');"
            done
            dialog --msgbox "Track(s) removed from playlist." 6 40
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
}

cleanup_and_exit() {
    if [ -n "$PLAYER_PID" ] && ps -p "$PLAYER_PID" > /dev/null; then
        kill "$PLAYER_PID"
        sleep 0.5
        if ps -p "$PLAYER_PID" > /dev/null; then
            kill -9 "$PLAYER_PID"
        fi
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
        "12" "Favorites"
        "13" "Recently Played"
        "14" "Most Played"
        "15" "Play Queue"
        "16" "Sleep Timer"
        "17" "Play Online URL"
        "18" "Exit"
    )
    
    local choice
    choice=$(dialog --title "MTSP - Main Menu" \
                   --menu "Choose an operation:" \
                   22 60 18 \
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
        12) show_favorites ;;
        13) show_recently_played ;;
        14) show_most_played ;;
        15) show_queue ;;
        16) sleep_timer ;;
        17) play_online_url ;;
        18) cleanup_and_exit ;;
    esac
}

check_dependencies() {
    for cmd in dialog mpv socat sqlite3; do
        if ! command -v $cmd &> /dev/null; then
            echo "Error: $cmd is not installed. Please install it and try again."
            exit 1
        fi
    done
}

play_folder() {
    local folder="$1"
    local files=( )
    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$folder" -maxdepth 1 -type f \( -iname "*.mp3" -o -iname "*.flac" -o -iname "*.wav" -o -iname "*.ogg" -o -iname "*.m4a" \) | sort)
    if [ ${#files[@]} -eq 0 ]; then
        dialog --msgbox "No audio files found in this folder." 6 40
        return
    fi
    for file in "${files[@]}"; do
        play_music "$file"
    done
}

select_multiple_files_to_play() {
    local dir="$1"
    local files=( )
    local options=( )
    local counter=1
    while IFS= read -r file; do
        files+=("$file")
        local display_name=$(basename "$file")
        options+=("$counter" "$display_name" "off")
        ((counter++))
    done < <(find "$dir" -maxdepth 1 -type f \( -iname "*.mp3" -o -iname "*.flac" -o -iname "*.wav" -o -iname "*.ogg" -o -iname "*.m4a" \) | sort)
    if [ ${#files[@]} -eq 0 ]; then
        dialog --msgbox "No audio files found in this directory." 6 40
        return
    fi
    local selected
    selected=$(dialog --title "Select Multiple Files" \
                     --checklist "Choose files to play (they will play in order):" \
                     20 70 15 \
                     "${options[@]}" \
                     2>&1 >/dev/tty)
    if [ $? -eq 0 ] && [ -n "$selected" ]; then
        for index in $selected; do
            local idx=$(echo $index | tr -d '"')
            play_music "${files[$((idx-1))]}"
        done
    fi
}

# --- FAVORITES SYSTEM ---
add_to_favorites() {
    local filepath="$1"
    echo "DEBUG: add_to_favorites called with $filepath"
    sqlite3 "$DATABASE" "INSERT OR IGNORE INTO favorites (track_id) VALUES ((SELECT id FROM tracks WHERE filepath = '$filepath'));"
    dialog --msgbox "Track added to Favorites!" 6 40
}
remove_from_favorites() {
    local filepath="$1"
    sqlite3 "$DATABASE" "DELETE FROM favorites WHERE track_id = (SELECT id FROM tracks WHERE filepath = '$filepath');"
    dialog --msgbox "Track removed from Favorites!" 6 40
}
show_favorites() {
    local tracks=$(sqlite3 "$DATABASE" "SELECT t.filepath, t.artist, t.title FROM tracks t JOIN favorites f ON t.id = f.track_id;")
    if [ -z "$tracks" ]; then
        dialog --msgbox "No favorite tracks found." 6 40
        return
    fi
    local options=()
    local counter=1
    while IFS='|' read -r filepath artist title; do
        options+=("$counter" "${artist:-Unknown Artist} - ${title:-Unknown Title}")
        ((counter++))
    done <<< "$tracks"
    local selected
    selected=$(dialog --title "Favorites" --menu "Select a track to play:" 20 70 15 "${options[@]}" 2>&1 >/dev/tty)
    if [ $? -eq 0 ]; then
        local selected_track=$(echo "$tracks" | sed -n "${selected}p" | cut -d'|' -f1)
        play_music "$selected_track"
    fi
}

# --- RECENTLY PLAYED & MOST PLAYED ---
show_recently_played() {
    local tracks=$(sqlite3 "$DATABASE" "SELECT t.filepath, t.artist, t.title, MAX(ph.played_at) FROM tracks t JOIN playback_history ph ON t.id = ph.track_id GROUP BY t.filepath ORDER BY MAX(ph.played_at) DESC LIMIT 20;")
    if [ -z "$tracks" ]; then
        dialog --msgbox "No recently played tracks found." 6 40
        return
    fi
    local options=()
    local counter=1
    while IFS='|' read -r filepath artist title _; do
        options+=("$counter" "${artist:-Unknown Artist} - ${title:-Unknown Title}")
        ((counter++))
    done <<< "$tracks"
    local selected
    selected=$(dialog --title "Recently Played" --menu "Select a track to play:" 20 70 15 "${options[@]}" 2>&1 >/dev/tty)
    if [ $? -eq 0 ]; then
        local selected_track=$(echo "$tracks" | sed -n "${selected}p" | cut -d'|' -f1)
        play_music "$selected_track"
    fi
}
show_most_played() {
    local tracks=$(sqlite3 "$DATABASE" "SELECT t.filepath, t.artist, t.title, COUNT(ph.id) as play_count FROM tracks t JOIN playback_history ph ON t.id = ph.track_id GROUP BY t.filepath ORDER BY play_count DESC LIMIT 20;")
    if [ -z "$tracks" ]; then
        dialog --msgbox "No most played tracks found." 6 40
        return
    fi
    local options=()
    local counter=1
    while IFS='|' read -r filepath artist title _; do
        options+=("$counter" "${artist:-Unknown Artist} - ${title:-Unknown Title}")
        ((counter++))
    done <<< "$tracks"
    local selected
    selected=$(dialog --title "Most Played" --menu "Select a track to play:" 20 70 15 "${options[@]}" 2>&1 >/dev/tty)
    if [ $? -eq 0 ]; then
        local selected_track=$(echo "$tracks" | sed -n "${selected}p" | cut -d'|' -f1)
        play_music "$selected_track"
    fi
}

# --- QUEUE SYSTEM ---
add_to_queue() {
    local filepath="$1"
    echo "DEBUG: add_to_queue called with $filepath"
    sqlite3 "$DATABASE" "INSERT INTO queue (track_id) VALUES ((SELECT id FROM tracks WHERE filepath = '$filepath'));"
    dialog --msgbox "Track added to queue!" 6 40
}
show_queue() {
    local tracks=$(sqlite3 "$DATABASE" "SELECT t.filepath, t.artist, t.title FROM tracks t JOIN queue q ON t.id = q.track_id ORDER BY q.id;")
    if [ -z "$tracks" ]; then
        dialog --msgbox "Queue is empty." 6 40
        return
    fi
    local options=()
    local counter=1
    while IFS='|' read -r filepath artist title; do
        options+=("$counter" "${artist:-Unknown Artist} - ${title:-Unknown Title}")
        ((counter++))
    done <<< "$tracks"
    local selected
    selected=$(dialog --title "Play Queue" --menu "Select a track to play or clear queue:" 20 70 15 "${options[@]}" 2>&1 >/dev/tty)
    if [ $? -eq 0 ]; then
        local selected_track=$(echo "$tracks" | sed -n "${selected}p" | cut -d'|' -f1)
        play_music "$selected_track"
    fi
}
clear_queue() {
    sqlite3 "$DATABASE" "DELETE FROM queue;"
    dialog --msgbox "Queue cleared!" 6 40
}

# --- SLEEP TIMER ---
sleep_timer() {
    local minutes
    minutes=$(dialog --title "Sleep Timer" --inputbox "Enter minutes until stop playback:" 8 40 2>&1 >/dev/tty)
    if [ $? -eq 0 ] && [ -n "$minutes" ]; then
        (sleep $((minutes*60)); cleanup_and_exit) &
        dialog --msgbox "Sleep timer set for $minutes minutes." 6 40
    fi
}

# --- NOTIFICATIONS (notify-send) ---
notify_now_playing() {
    local filepath="$1"
    local info=$(sqlite3 "$DATABASE" "SELECT artist, title FROM tracks WHERE filepath = '$filepath';")
    local artist=$(echo "$info" | cut -d'|' -f1)
    local title=$(echo "$info" | cut -d'|' -f2)
    notify-send "Now Playing" "${artist:-Unknown Artist} - ${title:-Unknown Title}"
}

# --- Play Online URL ---
play_online_url() {
    local url
    url=$(dialog --title "Play Online URL" --inputbox "Enter the direct audio/video URL (YouTube, mp3, etc.):" 8 60 2>&1 >/dev/tty)
    if [ $? -eq 0 ] && [ -n "$url" ]; then
        echo "DEBUG: play_online_url called with $url"
        mpv --no-terminal --quiet --af=volnorm --input-ipc-server=/tmp/mpv-socket "$url" &
        PLAYER_PID=$!
        CURRENT_TRACK="$url"
        IS_PLAYING=1
        notify-send "Now Streaming" "$url"
    fi
}

# Start the application
main