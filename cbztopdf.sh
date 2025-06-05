#!/bin/bash

# CBZ to PDF converter using ImageMagick
# For use in Termux and other Unix-like environments

set -euo pipefail # Exit on error, treat unset variables as errors, and propagate pipeline errors

# --- Configuration ---
DEFAULT_NUM_JOBS=2 # Default parallel jobs if nproc is not available or fails

# --- Global Variables (Populated by argument parsing) ---
OUTPUT_DIR="."
FORCE_OVERWRITE=false
RECURSIVE_SEARCH=false

# --- Dependency Checks ---
check_dependencies() {
    if ! command -v magick &> /dev/null; then
        echo "Error: ImageMagick is not installed. Please install it (e.g., 'pkg install imagemagick' or 'sudo apt-get install imagemagick')." >&2
        exit 1
    fi

    if ! command -v unzip &> /dev/null; then
        echo "Error: unzip is not installed. Please install it (e.g., 'pkg install unzip' or 'sudo apt-get install unzip')." >&2
        exit 1
    fi
}

# --- Helper Functions ---
# Cleans up the temporary directory
cleanup() {
    if [ -n "${temp_dir:-}" ] && [ -d "$temp_dir" ]; then
        echo "Cleaning up temporary directory: $temp_dir" >&2
        rm -rf "$temp_dir"
    fi
}

# --- Core Conversion Logic ---
convert_cbz_to_pdf() {
    local cbz_file="$1"
    local base_name
    base_name=$(basename "${cbz_file%.cbz}") # Get filename without extension or path
    local pdf_file="${OUTPUT_DIR}/${base_name}.pdf"
    local temp_dir_path_prefix # For mktemp -p

    # Ensure output directory exists
    if [ ! -d "$OUTPUT_DIR" ]; then
        echo "Creating output directory: $OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR"
    fi

    if [ -f "$pdf_file" ] && [ "$FORCE_OVERWRITE" = false ]; then
        echo "Skipping $cbz_file: $pdf_file already exists. Use --force to overwrite." >&2
        return 2 # Special return code for skipped
    fi

    # Create a temporary directory; handle potential mktemp issues
    # Some mktemp versions might not support -p for parent dir, so we try a simpler one if it fails.
    if ! temp_dir=$(mktemp -d -p "${TMPDIR:-/tmp}" "cbz_convert.XXXXXX"); then
        if ! temp_dir=$(mktemp -d "cbz_convert.XXXXXX"); then
            echo "Error: Failed to create temporary directory." >&2
            return 1
        fi
    fi
    trap cleanup EXIT # Register cleanup function to run on script exit (normal or error)

    echo "Processing '$cbz_file'..."
    echo "  Temporary directory: $temp_dir"
    echo "  Output PDF: $pdf_file"

    # Extract CBZ to temp directory
    echo "  Extracting images..."
    if ! unzip -q "$cbz_file" -d "$temp_dir"; then
        echo "Error: Failed to unzip '$cbz_file'." >&2
        cleanup # Explicit cleanup before returning
        return 1
    fi

    # Find all images and sort them naturally
    local filelist_path="$temp_dir/filelist.txt"
    # Search for common image types, case-insensitively, then sort naturally
    find "$temp_dir" -type f \( \
        -iname "*.jpg" -o -iname "*.jpeg" -o \
        -iname "*.png" -o -iname "*.gif" -o \
        -iname "*.webp" -o -iname "*.bmp" -o \
        -iname "*.tif" -o -iname "*.tiff" \
    \) | sort -V > "$filelist_path"

    local image_count
    image_count=$(wc -l < "$filelist_path")
    echo "  Found $image_count images."

    if [ "$image_count" -eq 0 ]; then
        echo "Warning: No images found in '$cbz_file'. Skipping PDF creation." >&2
        cleanup
        return 1 # Indicate failure due to no images
    fi

    # Convert all images to PDF
    echo "  Converting images to PDF..."
    # Using xargs is generally safer for many files than `cat filelist | command`
    # However, magick convert should handle a list of files from stdin directly with @filelist
    if ! magick @"$filelist_path" "$pdf_file"; then
        echo "Error: ImageMagick failed to create '$pdf_file'." >&2
        cleanup
        return 1
    fi

    echo "Successfully created '$pdf_file'."
    cleanup # Clean up successful conversion's temp dir
    return 0
}

# --- Batch Processing ---
convert_all_cbz() {
    local search_path="."
    local find_depth_arg=""
    if [ "$RECURSIVE_SEARCH" = false ]; then
        find_depth_arg="-maxdepth 1"
    fi

    echo "Searching for CBZ files in '$search_path' (Recursive: $RECURSIVE_SEARCH)..."
    # Store find results in an array, handles spaces in filenames
    mapfile -t cbz_files < <(find "$search_path" $find_depth_arg -type f -iname "*.cbz" | sort)

    local total_count=${#cbz_files[@]}

    if [ "$total_count" -eq 0 ]; then
        echo "No CBZ files found." >&2
        return 1
    fi

    echo "Found $total_count CBZ file(s). Starting conversion..."

    local num_jobs
    num_jobs=$(nproc --all 2>/dev/null || echo "$DEFAULT_NUM_JOBS")
    echo "Using up to $num_jobs parallel jobs."

    local active_jobs=0
    local Succeeded=0
    local Failed=0
    local Skipped=0
    local pids=() # Array to store PIDs of background jobs

    for cbz_file in "${cbz_files[@]}"; do
        convert_cbz_to_pdf "$cbz_file" &
        pids+=($!) # Store PID of the background job
        ((active_jobs++))
        if [ "$active_jobs" -ge "$num_jobs" ]; then
            # Wait for the oldest job to finish
            if wait -p child_pid "${pids[0]}"; then
                Succeeded=$((Succeeded + 1))
            else
                # Check exit code to differentiate skipped from failed
                exit_status=$?
                if [ "$exit_status" -eq 2 ]; then
                    Skipped=$((Skipped + 1))
                else
                    Failed=$((Failed + 1))
                fi
            fi
            pids=("${pids[@]:1}") # Remove the PID of the completed job
            ((active_jobs--))
        fi
    done

    # Wait for all remaining jobs
    for pid in "${pids[@]}"; do
        if wait "$pid"; then
            Succeeded=$((Succeeded + 1))
        else
            exit_status=$?
            if [ "$exit_status" -eq 2 ]; then
                Skipped=$((Skipped + 1))
            else
                Failed=$((Failed + 1))
            fi
        fi
    done

    echo "----------------------------------------"
    echo "Conversion Summary:"
    echo "  Successfully converted: $Succeeded"
    echo "  Failed conversions:   $Failed"
    echo "  Skipped (already exist): $Skipped"
    echo "----------------------------------------"

    if [ "$Failed" -gt 0 ]; then
        return 1
    fi
    return 0
}

# --- Usage Information ---
show_help() {
    cat << EOF
Usage: $(basename "$0") [options] [file.cbz ...]

Converts CBZ comic book archive files to PDF using ImageMagick.

Options:
  -h, --help             Show this help message and exit.
  -f, --file FILE        (DEPRECATED: Just pass files as arguments) Convert specific CBZ file(s).
                         You can list multiple files after other options or as standalone arguments.
  -a, --all              Convert all CBZ files in the current directory (or specified by --output-dir if different).
                         This is the default action if no files are specified.
  -R, --recursive        When used with --all, search for CBZ files recursively in subdirectories.
  -o, --output-dir DIR   Specify the directory where PDF files will be saved. Defaults to current directory.
      --force            Overwrite existing PDF files without asking.
      --jobs N           (Not yet implemented) Number of parallel jobs for --all. Uses nproc or $DEFAULT_NUM_JOBS.

Examples:
  $(basename "$0") mycomic.cbz another.cbz                 # Convert specific files
  $(basename "$0")                                          # Convert all CBZ in current directory
  $(basename "$0") --all                                    # Same as above
  $(basename "$0") --all --recursive                       # Convert all CBZ in current dir and subdirs
  $(basename "$0") --output-dir ./PDFs mycomic.cbz          # Convert mycomic.cbz, save to ./PDFs
  $(basename "$0") --all --output-dir ./Converted --force   # Convert all, save to ./Converted, overwrite
EOF
}

# --- Main Script Logic ---
main() {
    check_dependencies

    local files_to_process=()
    local action="all" # Default action

    # Parse arguments with getopts
    # Note: getopts doesn't support long options directly. We'll handle them in the case.
    # For more complex long options, a loop or a library might be needed.
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -f|--file)
                echo "Warning: -f/--file is deprecated. Simply list files as arguments." >&2
                # This option used to expect a file as $2, now we just shift and let the loop catch files.
                shift # Consume -f
                if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
                    if [ ! -f "$1" ]; then
                        echo "Error: File '$1' specified with -f does not exist." >&2
                        exit 1
                    fi
                     if [[ "$1" != *.cbz ]] && [[ "$1" != *.CBZ ]]; then
                        echo "Error: File '$1' specified with -f is not a .cbz file." >&2
                        exit 1
                    fi
                    files_to_process+=("$1")
                    action="specific_files"
                else
                    echo "Error: -f/--file requires a filename argument." >&2
                    show_help
                    exit 1
                fi
                shift # Consume filename
                ;;
            -a|--all)
                action="all"
                shift # Consume -a
                ;;
            -R|--recursive)
                RECURSIVE_SEARCH=true
                shift # Consume -R
                ;;
            -o|--output-dir)
                if [ -n "${2:-}" ] && [[ "$2" != -* ]]; then
                    OUTPUT_DIR="$2"
                    shift 2 # Consume -o and its argument
                else
                    echo "Error: --output-dir requires a directory argument." >&2
                    show_help
                    exit 1
                fi
                ;;
            --force)
                FORCE_OVERWRITE=true
                shift # Consume --force
                ;;
            -*) # Unknown option
                echo "Error: Unknown option '$1'" >&2
                show_help
                exit 1
                ;;
            *) # Argument is a file
                if [ ! -f "$1" ]; then
                    echo "Error: File '$1' does not exist." >&2
                    exit 1
                fi
                if [[ "$1" != *.cbz ]] && [[ "$1" != *.CBZ ]]; then
                    echo "Error: File '$1' is not a .cbz file." >&2
                    exit 1
                fi
                files_to_process+=("$1")
                action="specific_files"
                shift # Consume file argument
                ;;
        esac
    done


    # Determine action based on parsed arguments
    if [ "$action" = "specific_files" ] && [ ${#files_to_process[@]} -gt 0 ]; then
        local Succeeded=0
        local Failed=0
        local Skipped=0
        for file in "${files_to_process[@]}"; do
            convert_cbz_to_pdf "$file"
            exit_status=$?
            if [ "$exit_status" -eq 0 ]; then
                Succeeded=$((Succeeded + 1))
            elif [ "$exit_status" -eq 2 ]; then # Skipped
                Skipped=$((Skipped + 1))
            else
                Failed=$((Failed + 1))
            fi
        done
        echo "----------------------------------------"
        echo "Individual File Conversion Summary:"
        echo "  Successfully converted: $Succeeded"
        echo "  Failed conversions:   $Failed"
        echo "  Skipped (already exist): $Skipped"
        echo "----------------------------------------"
        if [ "$Failed" -gt 0 ]; then
            exit 1
        fi
    elif [ "$action" = "all" ]; then
        convert_all_cbz
    else # Should not happen if logic is correct, but as a fallback
        echo "No files specified and --all not used. Performing default action: convert all in current directory."
        convert_all_cbz
    fi

    exit 0
}

# --- Script Entry Point ---
main "$@"
