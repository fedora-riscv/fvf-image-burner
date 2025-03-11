#!/bin/bash

# Global variables used throughout the script:
# image_path    - Full path to the image file being used
# zip_path      - Path to original compressed file (if any)
# target_device - Device path for writing (e.g., /dev/sda)
# image_option  - 1 for local image, 2 for remote image
# target_option - 1 for device, 2 for file

REQUIRED_COMMANDS=("dd" "wget" "curl" "jq" "unzstd" "gunzip" "parted" "growpart" "e2fsck" "resize2fs" "tune2fs" "uuidgen" "blkid" "tr" "lsblk" "mlabel")
API_URL="https://api.fedoravforce.org/stats/"

RECOMMENDED_SPACE=19327352832 # 18GiB
# GUIDs, see https://en.wikipedia.org/wiki/GUID_Partition_Table
ROOTFS_PART_TYPE="0fc63daf-8483-4772-8e79-3d69d8477de4"
BOOTFS_PART_TYPE="bc13c2ff-59e6-4262-a352-b275fd6f7172"
EFI_PART_TYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

# Map commands to package names
declare -A DNF_PACKAGES=(
    ["growpart"]="cloud-utils-growpart"
    ["mlabel"]="mtools"
    ["unzstd"]="zstd"
    ["e2fsck"]="e2fsprogs"
    ["resize2fs"]="e2fsprogs"
    ["tune2fs"]="e2fsprogs"
    ["blkid"]="util-linux"
    ["tr"]="coreutils"
    ["lsblk"]="util-linux"
)

declare -A APT_PACKAGES=(
    ["growpart"]="cloud-utils"
    ["mlabel"]="mtools"
    ["unzstd"]="zstd"
    ["e2fsck"]="e2fsprogs"
    ["resize2fs"]="e2fsprogs"
    ["tune2fs"]="e2fsprogs"
    ["blkid"]="util-linux"
    ["tr"]="coreutils"
    ["lsblk"]="util-linux"
)

check_dependencies() {
    local missing_commands=()
    local package_manager=""
    local install_cmd=""

    # Detect package manager
    if command -v dnf &>/dev/null; then
        package_manager="dnf"
        install_cmd="sudo dnf install"
    elif command -v apt &>/dev/null; then
        package_manager="apt"
        install_cmd="sudo apt install"
    fi

    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -ne 0 ]; then
        echo "The following commands are missing:"
        printf '%s\n' "${missing_commands[@]}"
        
        if [ -z "$package_manager" ]; then
            echo "Error: Could not detect package manager. Please install the missing packages manually."
            exit 1
        fi

        echo "Would you like to install them using $package_manager? (y/n)"
        read -r confirm
        if [ "$confirm" = "y" ]; then
            echo "Do you want to install them with -y? (y/n)"
            read -r confirm
            if [ "$confirm" = "y" ]; then
                install_cmd="$install_cmd -y"
            fi

            for cmd in "${missing_commands[@]}"; do
                local package_name
                if [ "$package_manager" = "dnf" ]; then
                    if [ -n "${DNF_PACKAGES[$cmd]}" ]; then
                        package_name="${DNF_PACKAGES[$cmd]}"
                    else
                        package_name="$cmd"
                    fi
                elif [ "$package_manager" = "apt" ]; then
                    if [ -n "${APT_PACKAGES[$cmd]}" ]; then
                        package_name="${APT_PACKAGES[$cmd]}"
                    else
                        package_name="$cmd"
                    fi
                fi

                echo "Command to execute:"
                echo "  $install_cmd $package_name"
                if ! $install_cmd "$package_name"; then
                    echo "Error: Failed to install package for $cmd"
                    exit 1
                fi
            done
            echo "All dependencies installed successfully."
        else
            echo "Please install the missing dependencies manually."
            exit 1
        fi
    fi
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

get_target_option() {
    echo "============================================"
    echo "        Target Selection"
    echo "============================================"
    echo "1. Write to a device (e.g., /dev/sda)"
    echo "2. Write to a file (e.g., image.img)"
    read -p "Enter your choice (1/2): " target_option

    # Validate input
    if [[ ! "$target_option" =~ ^[1-2]$ ]]; then
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

check_mountpoint() {
    # Get all mount points
    mount_points=$(mount | grep "$target_device" | awk '{print $3}')

    # If there are any mount points
    if [ -n "$mount_points" ]; then
        echo "$target_device is mounted at the following locations:"
        echo "$mount_points"
        
        # Loop through each mount point
        for mount_point in $mount_points; do
            read -p "Do you want to unmount $mount_point? (y/n): " choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                # Try to unmount
                sudo umount "$mount_point"
                if [ $? -eq 0 ]; then
                    echo "$mount_point has been successfully unmounted"
                else
                    echo "Failed to unmount $mount_point, exiting the script"
                    exit 1
                fi
            else
                echo "$mount_point is still mounted, operation cannot continue, exiting the script."
                exit 1
            fi
        done
    else
        echo "$target_device is not mounted"
    fi
}


select_file() {
    echo "============================================"
    echo "        Select Image File"
    echo "============================================"
    read -p "Enter output file path (e.g., ./image.img): " file_path
    
    # if not exists, create it
    if [ ! -f "$file_path" ]; then
        read -p "File does not exist, create it? (y/n): " confirm
        if [ "$confirm" != "y" ]; then
            echo "Operation cancelled."
            exit 1
        fi

        while true; do
            read -p "Enter image size (MB): " image_size
            
            # Check available disk space
            target_dir=$(dirname "$file_path")
            available_space=$(($(df -BM "$target_dir" | awk 'NR==2 {print $4}' | sed 's/M//')))
            
            if [ "$image_size" -gt "$available_space" ]; then
                echo "Warning: You might not have enough disk space"
                echo "Required: ${image_size}MB"
                echo "Available: ${available_space}MB"
                read -p "Continue anyway? (y/n): " force_continue
                if [ "$force_continue" != "y" ]; then
                    continue
                fi
            fi

            # Space check passed or forced
            break
        done

        echo "Creating image file of ${image_size}MB..."
        dd if=/dev/zero of="$file_path" bs=1M count="$image_size" status=progress
        if [ $? -ne 0 ]; then
            echo "Error: Failed to create image file."
            exit 1
        fi

        echo "Image file created successfully."
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

            # gzip -l is slow, so
            # check if disk space has at least 18GB
            local target_dir=$(dirname "$base_name")
            local available_space=$(df -B1 "$target_dir" | awk 'NR==2 {print $4}')
            if [ "$available_space" -lt "$RECOMMENDED_SPACE" ]; then
                echo "You might not have enough disk space for decompression"
                echo "Space recommended: $(numfmt --to=iec-i --suffix=B $RECOMMENDED_SPACE)"
                echo "Available space: $(numfmt --to=iec-i --suffix=B $available_space)"
                read -p "Continue anyway? (y/n): " confirm
                if [ "$confirm" != "y" ]; then
                    echo "Operation cancelled."
                    exit 1
                fi
            fi
            
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

    # Check if device has enough space
    local image_size=$(stat -L -c%s "$image_path")
    local device_size=$(lsblk -b -dn -o SIZE "$target_device")
    
    if [ "$image_size" -gt "$device_size" ]; then
        echo "Warning: Image size is larger than device"
        echo "Image size: $(numfmt --to=iec-i --suffix=B $image_size)"
        echo "Device size: $(numfmt --to=iec-i --suffix=B $device_size)"
        read -p "Continue anyway? (y/n): " force_continue
        if [ "$force_continue" != "y" ]; then
            echo "Operation cancelled."
            exit 1
        fi
        echo "Proceeding with write despite size mismatch..."
    fi
    
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
    echo "Burning image to device..."
    if ! sudo dd if="$image_path" of="$target_device" bs=4M status=progress; then
        echo "Write failed. Please check the image or device."
        exit 1
    fi
    echo "Image burned successfully."
    sync  # Ensure all data is written to disk
}

write_image_to_file() {
    echo "============================================"
    echo "           Burn Image to File"
    echo "============================================"
    
    # Check if target file has enough space
    local image_size=$(stat -L -c%s "$image_path")
    local file_size=$(stat -L -c%s "$file_path")
    
    if [ "$image_size" -gt "$file_size" ]; then
        echo "Warning: Image size is larger than target file"
        echo "Image size: $(numfmt --to=iec-i --suffix=B $image_size)"
        echo "File size: $(numfmt --to=iec-i --suffix=B $file_size)"
        read -p "Continue anyway? (y/n): " force_continue
        if [ "$force_continue" != "y" ]; then
            echo "Operation cancelled."
            exit 1
        fi
        echo "Proceeding with write despite size mismatch..."
    fi
    
    if ! sudo dd if="$image_path" of="$file_path" bs=4M status=progress; then
        echo "Write failed. Please check the image or file."
        exit 1
    fi
    echo "Image burned successfully."
    sync  # Ensure all data is written to disk

    # create loop device
    target_device=$(sudo losetup -Pf --show "$file_path")
    echo "Loop device created: $target_device"
    # clean up later
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

    read -p "Do you want to expand a partition? (y/n): " expand_confirm
    if [ "$expand_confirm" != "y" ]; then
        return 0
    fi

    read -p "Enter the partition number to expand: " part_num

    # Get current partition info and disk size
    local disk_end=$(sudo parted -s "$target_device" unit MB print | grep "^Disk" | cut -d' ' -f3 | sed 's/MB//')
    local part_start=$(sudo parted -s "$target_device" unit MB print | grep "^ *${part_num}" | awk '{print $2}' | sed 's/MB//')
    local current_end=$(sudo parted -s "$target_device" unit MB print | grep "^ *${part_num}" | awk '{print $3}' | sed 's/MB//')

    echo
    echo "Current partition:"
    echo "  Start: ${part_start}MB"
    echo "  End: ${current_end}MB"
    echo "Maximum available end point: ${disk_end}MB"
    echo
    echo "How would you like to resize the partition?"
    echo "1. Use all available space (extend to end of disk)"
    echo "2. Specify custom end point in MB"
    read -p "Enter your choice (1/2): " size_choice

    local new_end
    case $size_choice in
        1)
            new_end=$disk_end
            ;;
        2)
            while true; do
                read -p "Enter desired end point in MB (between ${current_end} and ${disk_end}MB): " custom_end
                if [[ "$custom_end" =~ ^[0-9]+$ ]] && [ "$custom_end" -gt "$current_end" ] && [ "$custom_end" -le "$disk_end" ]; then
                    new_end=$custom_end
                    break
                else
                    echo "Invalid end point. Please enter a number between ${current_end} and ${disk_end}"
                fi
            done
            ;;
        *)
            echo "Invalid choice"
            return 1
            ;;
    esac

    echo "This will expand partition $part_num to end at ${new_end}MB on $target_device"
    read -p "Continue? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        return 0
    fi

    echo "Resizing partition..."
    echo "Command to execute:"
    echo "  sudo parted $target_device resizepart $part_num ${new_end}MB"
    if ! sudo parted "$target_device" resizepart "$part_num" "${new_end}MB"; then
        echo "Error: Failed to expand partition"
        return 1
    fi

    # if device name ends with a number, add a 'p' to the partition number
    # sda partition 1 -> sda1
    # nvme0n1 partition 1 -> nvme0n1p1
    local partition
    if [[ "$target_device" =~ [0-9]$ ]]; then
        partition="${target_device}p${part_num}"
    else
        partition="${target_device}${part_num}"
    fi
    
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

cleanup_loop_device() {
    echo "============================================"
    echo "              Cleanup Loop Device"
    echo "============================================"
    
    sudo losetup -d "$target_device"
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

# helper function
is_fat32() {
    local device="$1"
    local fstype=$(lsblk -o FSTYPE "$device" -npl | head -n1)
    if [ "$fstype" = "fat32" ] || [ "$fstype" = "vfat" ]; then
        return 0
    else
        return 1
    fi
}

# helper function
is_ext4() {
    local device="$1"
    local fstype=$(lsblk -o FSTYPE "$device" -npl | head -n1)
    if [ "$fstype" = "ext4" ]; then
        return 0
    else
        return 1
    fi
}

# helper function, called by regenerate_uuid
# generate 32-bit UUID for fat32
# and use uuidgen for ext4
generate_uuid() {
    local device="$1"
    if is_fat32 "$device"; then
        uuid=$(hexdump -n 4 -e '1/4 "%08x"' /dev/urandom | tr 'a-f' 'A-F')
        echo "$uuid"
    elif is_ext4 "$device"; then
        uuid=$(uuidgen)
        echo "$uuid"
    else
        fstype=$(lsblk -o FSTYPE "$device" -npl | head -n1)
        echo "Error: Unsupported filesystem type: $fstype"
        return 1
    fi
}

regenerate_uuid() {
    echo "============================================"
    echo "          UUID Regeneration"
    echo "============================================"
    
    echo "Detecting partitions..."

    partition_table_type=$(sudo lsblk -o PTTYPE "$target_device" -npl | head -n1)
    echo "Partition table type: $partition_table_type"
    
    # Find bootfs and rootfs partitions
    if [ "$partition_table_type" = "gpt" ]; then
        # Search for the last partition matching the GUID (PARTTYPE)
        bootfs_part=$(sudo lsblk "${target_device}" -o NAME,PARTTYPE -npl | grep "$BOOTFS_PART_TYPE" | tail -n1 | cut -d' ' -f1)
        rootfs_part=$(sudo lsblk "${target_device}" -o NAME,PARTTYPE -npl | grep "$ROOTFS_PART_TYPE" | tail -n1 | cut -d' ' -f1)
        efi_part=$(sudo lsblk "${target_device}" -o NAME,PARTTYPE -npl | grep "$EFI_PART_TYPE" | tail -n1 | cut -d' ' -f1)
    else # msdos(mbr)
        # See if label contains "boot" or "root"
        bootfs_part=$(sudo lsblk "${target_device}" -o NAME,LABEL -npl | grep "boot" | cut -d' ' -f1)
        rootfs_part=$(sudo lsblk "${target_device}" -o NAME,LABEL -npl | grep "root" | cut -d' ' -f1)
    fi

    if [ -z "$bootfs_part" ]; then
        echo "Error: bootfs partition not found"
        return 1
    fi
    echo "bootfs partition: $(sudo lsblk "${bootfs_part}" -o NAME,LABEL -pP)"
    bootfs_uuid_old=$(sudo blkid -s UUID "$bootfs_part" | cut -d'"' -f2)
    
    if [ -z "$rootfs_part" ]; then
        echo "Error: rootfs partition not found"
        return 1
    fi
    echo "rootfs partition: $(sudo lsblk "${rootfs_part}" -o NAME,LABEL -pP)"
    rootfs_uuid_old=$(sudo blkid -s UUID "$rootfs_part" | cut -d'"' -f2)

    bootfs_uuid_new=$(generate_uuid "$bootfs_part")
    if [ $? -eq 1 ]; then
        echo "Error: Failed to generate UUID for bootfs partition"
        return 1
    fi
    rootfs_uuid_new=$(generate_uuid "$rootfs_part")
    if [ $? -eq 1 ]; then
        echo "Error: Failed to generate UUID for rootfs partition"
        return 1
    fi

    echo "Current UUIDs:"
    echo "bootfs: $bootfs_uuid_old"
    echo "rootfs: $rootfs_uuid_old"
    echo
    echo "New UUIDs:"
    echo "bootfs: $bootfs_uuid_new"
    echo "rootfs: $rootfs_uuid_new"
    echo
    
    tmp_boot=$(mktemp -d)
    tmp_root=$(mktemp -d)
    
    echo "Mounting bootfs partition..."
    if ! sudo mount "$bootfs_part" "$tmp_boot"; then
        echo "Error: Failed to mount bootfs partition"
        rm -rf "$tmp_boot" "$tmp_root"
        return 1
    fi

    echo "Mounting rootfs partition..."
    if ! sudo mount "$rootfs_part" "$tmp_root"; then
        echo "Error: Failed to mount rootfs partition"
        sudo umount "$tmp_boot"
        rm -rf "$tmp_boot" "$tmp_root"
        return 1
    fi

    if [ -n "$efi_part" ]; then
        efi_uuid_old=$(sudo blkid -s UUID "$efi_part" | cut -d'"' -f2)
        efi_uuid_new=$(generate_uuid "$efi_part")
        echo "EFI Part Found!"
        echo "EFI Current UUID: $efi_uuid_old"
        echo "EFI New UUID: $efi_uuid_new"
        tmp_efi=$(mktemp -d)
        if ! sudo mount "$efi_part" "$tmp_efi"; then
            echo "Error: Failed to mount bootfs partition"
            rm -rf "$tmp_boot" "$tmp_root" "$tmp_efi"
            return 1
        fi

        if [ -f "$tmp_efi/EFI/fedora/grub.cfg" ]; then
            echo "Updating grub.cfg..."
            sudo sed -i "s/$bootfs_uuid_old/$bootfs_uuid_new/g" "$tmp_efi/EFI/fedora/grub.cfg"
            sudo sed -i "s/$rootfs_uuid_old/$rootfs_uuid_new/g" "$tmp_efi/EFI/fedora/grub.cfg"
            sudo sed -i "s/$efi_uuid_old/${efi_uuid_new:0:4}-${efi_uuid_new:4}/g" "$tmp_efi/EFI/fedora/grub.cfg"
        fi

        sudo umount "$tmp_efi"
        rm -rf "$tmp_efi"

        echo "Setting EFI Partition UUID..."
        echo "Command to execute:"
        echo "  sudo mlabel -i $efi_part -N $efi_uuid_new"
        sudo mlabel -i "$efi_part" -N "$efi_uuid_new"
    fi
    
    # Update /boot/extlinux/extlinux.conf
    if [ -f "$tmp_boot/extlinux/extlinux.conf" ]; then
        echo "Updating extlinux.conf..."
        sudo sed -i "s/$bootfs_uuid_old/$bootfs_uuid_new/g" "$tmp_boot/extlinux/extlinux.conf"
        sudo sed -i "s/$rootfs_uuid_old/$rootfs_uuid_new/g" "$tmp_boot/extlinux/extlinux.conf"
    fi
    
    # Update grub config in /boot/loader/entries/
    if [ -d "$tmp_boot/loader/entries" ]; then
        grub_conf_file=$(sudo find "$tmp_boot/loader/entries/" -maxdepth 1 -name "*.conf" 2>/dev/null | head -n1)
        if [ -n "$grub_conf_file" ]; then
            echo "Updating grub config..."
            sudo sed -i "s/$bootfs_uuid_old/$bootfs_uuid_new/g" "$grub_conf_file"
            sudo sed -i "s/$rootfs_uuid_old/$rootfs_uuid_new/g" "$grub_conf_file"
        fi
    fi
    
    # Update /etc/fstab
    if [ -f "$tmp_root/etc/fstab" ]; then
        echo "Updating fstab..."
        sudo sed -i "s/$bootfs_uuid_old/$bootfs_uuid_new/g" "$tmp_root/etc/fstab"
        sudo sed -i "s/$rootfs_uuid_old/$rootfs_uuid_new/g" "$tmp_root/etc/fstab"
        
        # if efi part exist
        if [ -n "$efi_part" ]; then
            sudo sed -i "s/$efi_uuid_old/${efi_uuid_new:0:4}-${efi_uuid_new:4}/g" "$tmp_root/etc/fstab"
        fi

    fi
    
    echo "Setting new UUIDs..."
    echo "Command to execute:"
    echo "  sudo tune2fs -U $bootfs_uuid_new $bootfs_part"
    sudo tune2fs -U "$bootfs_uuid_new" "$bootfs_part"

    echo "Command to execute:"
    echo "  sudo tune2fs -U $rootfs_uuid_new $rootfs_part"
    sudo tune2fs -U "$rootfs_uuid_new" "$rootfs_part"
    
    echo "Cleaning up..."
    sudo umount "$tmp_boot"
    sudo umount "$tmp_root"
    rm -rf "$tmp_boot" "$tmp_root"

    echo "UUID regeneration complete"
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
    get_target_option
    case $target_option in
        1)
            select_device
            check_mountpoint
            write_image
            ;;
        2)
            select_file
            write_image_to_file
            ;;
    esac
    regenerate_uuid
    expand_partition
    cleanup_files
    if [ "$target_option" = "2" ]; then
        cleanup_loop_device
    fi
    echo "Done."
}
main

