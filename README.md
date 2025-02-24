<function_calls>
<invoke name="artifacts">
<parameter name="id">cbz-to-pdf-readme</parameter>
<parameter name="type">text/markdown</parameter>
<parameter name="title">README.md for CBZ to PDF Converter</parameter>
<parameter name="command">create</parameter>
<parameter name="content"># CBZ to PDF Converter

A simple bash script to convert CBZ (Comic Book ZIP) files to PDF format using ImageMagick.

## Overview

This tool allows you to quickly convert comic book archives (.cbz files) to PDF format. It works in any Unix-like environment and is specifically tested in Termux on Android. The script uses ImageMagick to handle the conversion process, making it efficient and reliable.

## Features

- Convert a single CBZ file or batch convert all CBZ files in the current directory
- Automatically sorts images to maintain correct page order
- Preserves image quality
- Simple command-line interface
- Works on Termux and other Unix-like environments

## Requirements

- Bash shell
- ImageMagick (`convert` command)
- unzip

## Installation

### On Termux

1. Install required packages:
   ```
   pkg update
   pkg install imagemagick unzip git
   ```

2. Clone this repository:
   ```
   git clone https://github.com/Sac-94/CBZ-To-PDF.git
   ```

3. Navigate to the directory:
   ```
   cd CBZ-To-PDF
   ```

4. Make the script executable:
   ```
   chmod +x cbz2pdf.sh
   ```

### On other Linux systems

1. Install required packages:
   ```
   sudo apt update
   sudo apt install imagemagick unzip git
   ```
   (Use your distribution's package manager if not using apt)

2. Follow steps 2-4 from the Termux instructions above.

## Usage

### Convert all CBZ files in the current directory

```
./cbz2pdf.sh
```

### Convert a specific CBZ file

```
./cbz2pdf.sh -f comic.cbz
```

### Show help

```
./cbz2pdf.sh -h
```

## Options

- `-h, --help`: Show help message
- `-f, --file FILE`: Convert a specific CBZ file
- `-a, --all`: Convert all CBZ files in the current directory (default behavior)

## How it Works

1. The script creates a temporary directory
2. It extracts the CBZ file (which is just a ZIP file containing images)
3. Images are sorted to maintain the correct page order
4. ImageMagick converts the images to a single PDF file
5. The temporary directory is cleaned up

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Issues and Feature Requests

If you encounter any problems or have suggestions for improvements, please open an issue on GitHub.
</parameter>
</invoke>
