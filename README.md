                                                  
     ███╗   ███╗████████╗███████╗██████╗"     
     ████╗ ████║╚══██╔══╝██╔════╝██╔══██╗"     
     ██╔████╔██║   ██║   ███████╗██████╔╝"     
     ██║╚██╔╝██║   ██║   ╚════██║██╔═══╝"     
     ██║ ╚═╝ ██║   ██║   ███████║██║"          
     ╚═╝     ╚═╝   ╚═╝   ╚══════╝╚═╝"          
                       


# MTSP - Music Terminal Shell Player 🎵🖥️

## Overview

MTSP is a powerful, lightweight, and feature-rich terminal-based music player for Linux systems. Built entirely in Bash, it provides an intuitive command-line interface for managing and enjoying your music library with advanced playlist and playback features.

## 🌟 Features

- **File Browser**: Seamlessly navigate and play music files
- **Playlist Management**:
  - Create, view, and delete custom playlists
  - Add/remove tracks from playlists
- **Playback Controls**:
  - Play/Pause
  - Next/Previous track
  - Volume control
  - Repeat mode
- **Library Management**:
  - Automatic library scanning
  - Track metadata tracking
  - Playback history
- **Search Functionality**: Find tracks quickly in your library
- **Supported Audio Formats**: MP3, FLAC, WAV, OGG, M4A

## 📋 System Requirements

### Dependencies
- Bash 4.0+
- SQLite3
- MPV
- Dialog
- Socat

### Supported Linux Distributions
- Ubuntu (20.04+)
- Debian (10+)
- Fedora (32+)
- Arch Linux
- Linux Mint
- PopOS
- Elementary OS

### Hardware Requirements
- Minimum RAM: 512 MB
- Processor: Any modern x86/x64 CPU
- Storage: Minimal (for application and music library)

## 🚀 Installation

### Prerequisites
```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install bash sqlite3 mpv dialog socat

# Fedora
sudo dnf install bash sqlite mpv dialog socat

# Arch Linux
sudo pacman -S bash sqlite mpv dialog socat
```

### Installation Steps
```bash
# Clone the repository
git clone https://github.com/almezali/mtsp.git
cd mtsp

# Make the script executable
chmod +x mtsp-v3.0.1.sh

# Optional: Create a symlink for system-wide access
sudo ln -s $(pwd)/mtsp-v3.0.1.sh /usr/local/bin/mtsp
```

## 🎮 Usage

### Basic Commands
- Run the player: `./mtsp-v3.0.1.sh` or `mtsp`
- Navigate using the dialog-based menu
- Use number keys to select options

### Keyboard Shortcuts
- Play/Pause: Option 1
- Next Track: Option 2
- Previous Track: Option 3
- Browse Files: Option 4
- Manage Playlists: Option 5

## 📸 Screenshots

### Main Menu
![MTSP Main Menu](https://github.com/almezali/mtsp-v3.0.1/raw/main/Scr_1.png)

### File Browser
![MTSP File Browser](https://github.com/almezali/mtsp-v3.0.1/raw/main/Scr_1.png)

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📄 License

[FREE].

## 📧 Contact

Your Name - [mzmcsmzm@gmail.com]


---

**Enjoy your music, terminal style! 🎧**
