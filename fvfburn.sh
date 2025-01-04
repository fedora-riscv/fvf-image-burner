#!/bin/bash

# Global variables used throughout the script:
# image_path    - Full path to the image file being used
# zip_path      - Path to original compressed file (if any)
# target_device - Device path for writing (e.g., /dev/sda)
# image_option  - 1 for local image, 2 for remote image

REQUIRED_COMMANDS=("dd" "wget" "curl" "jq" "unzstd" "gunzip" "parted" "growpart" "e2fsck" "resize2fs")
API_URL="https://api.fedoravforce.org/stats/"

check_dependencies() {
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v $cmd &>/dev/null; then
            echo "Error: $cmd is not installed. Please install it first."
            exit 1
        fi
    done
}

get_image_option() {
    echo "============================================"
    echo "            FVF Image Burner"
    echo "============================================"
    echo "Choose image source:"
    echo "1. Use local image"
    echo "2. Download from images.fedoravforce.com"
    read -p "Enter your choice (1/2): " image_option

    # Validate input
    if [[ ! "$image_option" =~ ^[1-2]$ ]]; then
        echo "Error: Invalid option. Please select 1 or 2."
        exit 1
    fi
}

select_local_image() {
    echo
    echo "Enter the full path to your image file"
    echo "Example: /home/user/images/system.img"
    read -p "Image path: " image_path
    
    if [ ! -f "$image_path" ]; then
        echo "Error: Image file not found at $image_path"
        exit 1
    fi
}

select_device() {
    echo "============================================"
    echo "        Available Storage Devices"
    echo "============================================"
    lsblk -d -o NAME,SIZE,TYPE,RM,MOUNTPOINT | grep -v "loop" | grep -v "rom"
    echo "Note: RM=1 indicates removable device"
    read -p "Enter target device name (e.g., sda): " target_name
    target_device="/dev/${target_name}"
    
    # Verify device exists and is writable
    if [ ! -b "$target_device" ]; then
        echo "Error: $target_device is not a valid block device."
        exit 1
    fi
    
    # Check if device is system disk
    if echo "$target_device" | grep -q "$(mount | grep " / " | cut -d' ' -f1 | sed 's/[0-9]*//g')"; then
        echo "Error: Cannot write to system disk!"
        exit 1
    fi

    echo
    echo "WARNING: This will erase ALL data on $target_device!"
    echo "Device information:"
    lsblk "$target_device"
    echo "Continue writing $image_name to $target_device? (y/n)"
    read -r confirm
    if [ "$confirm" != "y" ]; then
        echo "Operation cancelled."
        exit 1
    fi
}

prepare_image() {
    echo "============================================"
    echo "          Image Preparation"
    echo "============================================"
    local input_path="$image_path"
    
    echo "Checking image format..."
    case "$input_path" in
        *.gz|*.zst)
            local base_name="${input_path%.*}"
            if [[ "$base_name" != *.img && "$base_name" != *.raw ]]; then
                echo "Error: Compressed file must contain a .img or .raw file"
                exit 1
            fi
            
            # Check available space for gzip files only
            # zstd cannot get decompressed size directly
            # TODO: slow
            # if [[ "$input_path" == *.gz ]]; then
            #     local target_dir=$(dirname "$base_name")
            #     local needed_space=$(gzip -l "$input_path" | awk 'NR==2 {print $2}')
            #     local available_space=$(df -B1 "$target_dir" | awk 'NR==2 {print $4}')
                
            #     if [ "$available_space" -lt "$needed_space" ]; then
            #         echo "Warning: Insufficient disk space for decompression"
            #         echo "Space needed: $(numfmt --to=iec-i --suffix=B $needed_space)"
            #         echo "Available space: $(numfmt --to=iec-i --suffix=B $available_space)"
            #         read -p "Continue anyway? (y/n): " confirm
            #         if [ "$confirm" != "y" ]; then
            #             echo "Operation cancelled."
            #             exit 1
            #         fi
            #     fi
            # fi
            
            echo "Decompressing to: $base_name"
            if [[ "$input_path" == *.gz ]]; then
                gunzip -k "$input_path"
            else
                unzstd -k "$input_path"
            fi
            
            if [ $? -ne 0 ]; then
                echo "Error: Failed to decompress image."
                exit 1
            fi
            echo "Decompression complete."
            
            # Update image_path to point to the decompressed file
            image_path="$base_name"
            zip_path="$input_path"
            ;;
        *.img|*.raw)
            ;;
        *)
            echo "Error: Unrecognized image format. Only .img, .raw, .img.gz, .raw.gz, .img.zst, and .raw.zst files are supported."
            exit 1
            ;;
    esac
    echo
}

write_image() {
    echo "============================================"
    echo "           Burn Image to Device"
    echo "============================================"
    
    # Show device information again for safety
    echo "Device information:"
    lsblk "$target_device"
    echo
    echo "WARNING: This will ERASE ALL DATA on $target_device!"
    echo "         This operation cannot be undone!"
    echo "--------------------------------------------"
    
    # Step 1: wipefs
    echo "Step 1: Wipe filesystem signatures"
    echo "Command to execute:"
    echo "  sudo wipefs -a $target_device"
    echo
    read -p "Continue with wiping filesystem? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Operation cancelled."
        exit 1
    fi

    echo "Wiping existing filesystem signatures..."
    if ! sudo wipefs -a "$target_device"; then
        read -p "Force wipe with -f? (y/n): " confirm
        if [ "$confirm" != "y" ]; then
            echo "Operation cancelled."
            exit 1
        fi
        echo "Force wiping existing filesystem signatures..."
        if ! sudo wipefs -af "$target_device"; then
            echo "Error: Failed to wipe filesystem signatures."
            exit 1
        fi
    fi
    echo "Device wiped successfully."
    
    # Step 2: burn image
    echo
    echo "Command to execute:"
    echo "  sudo dd if=$image_path of=$target_device bs=4M status=progress"
    echo
    read -p "Continue with burning image? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Operation cancelled."
        exit 1
    fi

    echo "Burning image to device..."
    if ! sudo dd if="$image_path" of="$target_device" bs=4M status=progress; then
        echo "Write failed. Please check the image or device."
        exit 1
    fi
    echo "Image burned successfully."
    sync  # Ensure all data is written to disk
}

expand_partition() {
    echo "============================================"
    echo "          Partition Expansion"
    echo "============================================"
    
    echo "Current partition layout:"
    if ! sudo parted -s "$target_device" print free; then
        echo "Error: Failed to read partition table"
        return 1
    fi

    read -p "Do you want to expand a partition to use all of the space? (y/n): " expand_confirm
    if [ "$expand_confirm" != "y" ]; then
        return 0
    fi

    read -p "Enter the partition number to expand: " part_num

    echo "This will expand partition $part_num on $target_device"
    read -p "Continue? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        return 0
    fi

    echo "Expanding partition..."
    echo "Command to execute:"
    echo "  sudo growpart $target_device $part_num"
    if ! sudo growpart "$target_device" "$part_num"; then
        echo "Error: Failed to expand partition"
        return 1
    fi

    local partition="${target_device}${part_num}"
    echo "Checking filesystem..."
    echo "Command to execute:"
    echo "  sudo e2fsck -f $partition"
    if ! sudo e2fsck -f "$partition"; then
        echo "Error: Filesystem check failed"
        return 1
    fi

    echo "Resizing filesystem..."
    echo "Command to execute:"
    echo "  sudo resize2fs $partition"
    if ! sudo resize2fs "$partition"; then
        echo "Error: Failed to resize filesystem"
        return 1
    fi

    echo "Partition expanded successfully"
}

cleanup_files() {
    echo "============================================"
    echo "              Cleanup"
    echo "============================================"
    
    if [ -n "$zip_path" ]; then
        read -p "Remove compressed file ($zip_path)? (y/n): " remove_zip
        if [ "$remove_zip" = "y" ]; then
            rm "$zip_path"
            echo "Compressed file removed."
        fi
    fi
    
    read -p "Remove image file ($image_path)? (y/n): " remove_img
    if [ "$remove_img" = "y" ]; then
        rm "$image_path"
        echo "Image file removed."
    fi
}

# Helper function, called by fetch_remote_images
download_image() {
    local image_url="$1"
    
    # Get the actual filename from the URL
    local image_name=$(basename "$image_url")
    
    # Get file size using curl
    echo "Checking image details..."
    local content_length=$(curl -sI "$image_url" | grep -i content-length | awk '{print $2}' | tr -d '\r')
    if [ -z "$content_length" ]; then
        echo "Warning: Could not determine file size"
        local size="unknown"
    else
        local size=$(printf "%.1f GB" $(echo "$content_length/1024/1024/1024" | bc -l))
    fi
    
    echo
    echo "Image details:"
    echo "Name: $image_name"
    echo "Size: $size"
    echo "URL:  $image_url"
    echo
    read -p "Do you want to download this image? (y/n): " confirm
    
    if [ "$confirm" != "y" ]; then
        echo "Download cancelled."
        exit 1
    fi
    
    # Ask for download location
    current_dir=$(pwd)
    read -p "Enter download path [default: $current_dir]: " download_path
    download_path="${download_path:-$current_dir}"

    # Verify the path exists and is writable
    if [ ! -d "$download_path" ]; then
        echo "Error: Directory $download_path does not exist."
        exit 1
    fi
    if [ ! -w "$download_path" ]; then
        echo "Error: Directory $download_path is not writable."
        exit 1
    fi
    
    # Download the image
    echo "Downloading $image_name to $download_path..."
    wget "$image_url" -P "$download_path"
    if [ $? -ne 0 ]; then
        echo "Download failed. Please check your network connection or image name."
        exit 1
    fi
    echo "Download complete."
    
    # Set the global image_path variable
    image_path="$download_path/$image_name"
}

fetch_remote_images() {
    echo "============================================"
    echo "        Available Remote Images"
    echo "============================================"
    
    # Get images list
    response=$(curl -s "$API_URL")
    if [ $? -ne 0 ]; then
        echo "Error: Failed to fetch image list from server"
        exit 1
    fi

    # initialize links array
    declare -a links

    # Parse and display available images
    echo "Available images:"
    echo "--------------------------------------------"
    printf "%-5s %-15s %-20s %-20s\n" "No." "Vendor" "Board" "Image"
    printf "%s\n" "--------------------------------------------"
    
    # store all the data in a temporary array
    mapfile -t data < <(echo "$response" | jq -r '.result[] | select(.name != "") | 
        .soc[] | select(.boards != null) | 
        .boards[] | select(.images != null) | 
        (.vendor) as $vendor | (.name) as $board | 
        .images[] | "\($vendor)|\($board)|\(.name)|\(.link)"' | sort)
    
    # print image details and store links in an array
    for line in "${data[@]}"; do
        IFS='|' read -r vendor board image link <<< "$line"
        printf "%-5s %-15s %-20s %-20s\n" "$((++i))" "$vendor" "$board" "$image"
        links[$i]="$link"
    done

    echo
    read -p "Enter the number of the image to download: " image_number

    # Get the selected URL from links array
    if [ "$image_number" -gt 0 ] && [ "$image_number" -le ${#links[@]} ]; then
        image_url="${links[$image_number]}"
        
        download_image "$image_url"
    else
        echo "Error: Invalid selection. Please choose a number between 1 and ${#links[@]}"
        exit 1
    fi
}

main() {
    check_dependencies
    get_image_option
    case $image_option in
        1)
            select_local_image
            ;;
        2)
            fetch_remote_images
            ;;
    esac
    prepare_image
    select_device
    write_image
    expand_partition
    cleanup_files
    echo "Done."
}
main

