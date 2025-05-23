#!/bin/bash

# CBZ to PDF converter using ImageMagick
# For use in Termux and other Unix-like environments

# Check if ImageMagick is installed
if ! command -v magick &> /dev/null; then
    echo "ImageMagick is not installed. Please install it with:" >&2
    echo "pkg install imagemagick" >&2
    exit 1
fi

# Check if unzip is installed
if ! command -v unzip &> /dev/null; then
    echo "unzip is not installed. Please install it with your package manager (e.g., pkg install unzip or sudo apt-get install unzip)" >&2
    exit 1
fi

# Function to convert a single CBZ file
convert_cbz_to_pdf() {
    local cbz_file="$1"
    local base_name="${cbz_file%.cbz}"
    local pdf_file="${base_name}.pdf"
    local temp_dir
    temp_dir=$(mktemp -d)
    if [ -z "$temp_dir" ] || [ ! -d "$temp_dir" ]; then
        echo "Failed to create temporary directory" >&2
        return 1
    fi
    
    echo "Converting $cbz_file to $pdf_file..."
    
    # Extract CBZ to temp directory
    unzip -q "$cbz_file" -d "$temp_dir"
    
    # Find all images and sort them
    find "$temp_dir" -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.gif" -o -name "*.webp" \) | sort > "$temp_dir/filelist.txt"
    
    # Count images
    local image_count=$(wc -l < "$temp_dir/filelist.txt")
    echo "Found $image_count images"
    
    if [ "$image_count" -eq 0 ]; then
        echo "No images found in $cbz_file" >&2
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Convert all images to PDF
    magick $(cat "$temp_dir/filelist.txt") "$pdf_file"
    
    # Check if conversion was successful
    if [ $? -eq 0 ]; then
        echo "Successfully created $pdf_file"
        rm -rf "$temp_dir"
        return 0
    else
        echo "Error creating $pdf_file" >&2
        rm -rf "$temp_dir"
        return 1
    fi
}

# Function to convert all CBZ files in current directory
convert_all_cbz() {
    local cbz_files=(*.cbz)
    local total_count=${#cbz_files[@]}

    if [ "$total_count" -eq 0 ] || [ "${cbz_files[0]}" = "*.cbz" ]; then
        echo "No CBZ files found in the current directory." >&2
        return 1
    fi

    echo "Found $total_count CBZ files. Starting conversion with parallel processing..."

    local num_jobs=$(nproc --all 2>/dev/null || echo 2) # Default to 2 jobs if nproc fails
    local active_jobs=0

    for cbz_file in "${cbz_files[@]}"; do
        convert_cbz_to_pdf "$cbz_file" &
        ((active_jobs++))
        if [ "$active_jobs" -ge "$num_jobs" ]; then
            wait -n # Wait for any job to finish
            ((active_jobs--))
        fi
    done

    wait # Wait for all remaining jobs to finish

    echo "All conversion tasks launched. Check individual file messages for success or errors."
}

# Parse command line arguments
if [ $# -eq 0 ]; then
    convert_all_cbz
    exit 0
fi

case "$1" in
    -h|--help)
        echo "Usage: $0 [options] [file]"
        echo "Options:"
        echo "  -h, --help       Show this help message"
        echo "  -f, --file FILE  Convert specific CBZ file"
        echo "  -a, --all        Convert all CBZ files in current directory"
        echo "If no options are provided and a file is given, it will be converted."
        echo "If no options or file are provided, all CBZ files in the current directory will be converted."
        exit 0
        ;;
    -f|--file)
        if [ -z "$2" ]; then
            echo "Error: No file specified for -f/--file option." >&2
            exit 1
        fi
        if [ ! -f "$2" ]; then
            echo "Error: File $2 does not exist" >&2
            exit 1
        fi
        convert_cbz_to_pdf "$2"
        ;;
    -a|--all)
        convert_all_cbz
        ;;
    *)
        # Default case: assume argument is a file, or handle error
        if [ $# -eq 1 ]; then # Expecting only one argument if it's a file
            if [ ! -f "$1" ]; then
                echo "Error: File $1 does not exist or invalid option." >&2
                exit 1
            fi
            # Check if the file is likely a cbz before attempting conversion
            if [[ "$1" == *.cbz ]]; then
                convert_cbz_to_pdf "$1"
            else
                echo "Error: File '$1' is not a .cbz file." >&2
                echo "Usage: $0 [options] [file]" >&2
                exit 1
            fi
        else
            echo "Error: Invalid arguments or too many arguments." >&2
            echo "Usage: $0 [options] [file]" >&2
            exit 1
        fi
        ;;
esac
