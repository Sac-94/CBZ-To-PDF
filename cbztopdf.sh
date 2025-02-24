#!/bin/bash

# CBZ to PDF converter using ImageMagick
# For use in Termux and other Unix-like environments

# Check if ImageMagick is installed
if ! command -v convert &> /dev/null; then
    echo "ImageMagick is not installed. Please install it with:"
    echo "pkg install imagemagick"
    exit 1
fi

# Function to convert a single CBZ file
convert_cbz_to_pdf() {
    local cbz_file="$1"
    local base_name="${cbz_file%.cbz}"
    local pdf_file="${base_name}.pdf"
    local temp_dir="/tmp/cbz2pdf_${RANDOM}"
    
    echo "Converting $cbz_file to $pdf_file..."
    
    # Create temp directory
    mkdir -p "$temp_dir"
    
    # Extract CBZ to temp directory
    unzip -q "$cbz_file" -d "$temp_dir"
    
    # Find all images and sort them
    find "$temp_dir" -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.gif" -o -name "*.webp" \) | sort > "$temp_dir/filelist.txt"
    
    # Count images
    local image_count=$(wc -l < "$temp_dir/filelist.txt")
    echo "Found $image_count images"
    
    if [ "$image_count" -eq 0 ]; then
        echo "No images found in $cbz_file"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Convert all images to PDF
    convert $(cat "$temp_dir/filelist.txt") "$pdf_file"
    
    # Check if conversion was successful
    if [ $? -eq 0 ]; then
        echo "Successfully created $pdf_file"
        rm -rf "$temp_dir"
        return 0
    else
        echo "Error creating $pdf_file"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Function to convert all CBZ files in current directory
convert_all_cbz() {
    local cbz_files=(*.cbz)
    local success_count=0
    local total_count=${#cbz_files[@]}
    
    if [ "$total_count" -eq 0 ] || [ "${cbz_files[0]}" = "*.cbz" ]; then
        echo "No CBZ files found in the current directory."
        return 1
    fi
    
    echo "Found $total_count CBZ files in the current directory."
    
    for cbz_file in "${cbz_files[@]}"; do
        if convert_cbz_to_pdf "$cbz_file"; then
            ((success_count++))
        fi
    done
    
    echo "Conversion complete: $success_count/$total_count files converted successfully."
}

# Parse command line arguments
if [ $# -eq 0 ]; then
    # No arguments, convert all CBZ files in current directory
    convert_all_cbz
elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help       Show this help message"
    echo "  -f, --file FILE  Convert specific CBZ file"
    echo "  -a, --all        Convert all CBZ files in current directory (default)"
    exit 0
elif [ "$1" = "-f" ] || [ "$1" = "--file" ]; then
    # Convert specific file
    if [ -z "$2" ]; then
        echo "Error: No file specified"
        exit 1
    fi
    
    if [ ! -f "$2" ]; then
        echo "Error: File $2 does not exist"
        exit 1
    fi
    
    convert_cbz_to_pdf "$2"
elif [ "$1" = "-a" ] || [ "$1" = "--all" ]; then
    # Convert all files
    convert_all_cbz
else
    # Assume the first argument is a file
    if [ ! -f "$1" ]; then
        echo "Error: File $1 does not exist"
        exit 1
    fi
    
    convert_cbz_to_pdf "$1"
fi