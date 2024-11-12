#!/bin/sh

#blkdevparts=mmcblk0:8192K(BOOT),128K(ENV),524288K(ROOTFS),524288K(ROOTFS2),262144K(RESERVED),-(USERDATA);mmcblk0boot0:1M(fip),1M(fip_bak);

MD5_FILE="sg2002_recamera_emmc_md5sum.txt"
ZIP_FILE=""

function exit_burn()
{
    sync
    umount /tmp/tmp.* > /dev/null 2>&1

    # heartbeat
    echo none > /sys/devices/platform/leds/leds/red/trigger
    # mmc0
    echo none > /sys/devices/platform/leds/leds/blue/trigger

    if [ $1 -eq 0 ]; then
        echo "success"
        
        while [ 1 ]; do
            echo 0 > /sys/devices/platform/leds/leds/red/brightness
            echo 0 > /sys/devices/platform/leds/leds/blue/brightness
            sleep 1
            echo 255 > /sys/devices/platform/leds/leds/red/brightness
            echo 255 > /sys/devices/platform/leds/leds/blue/brightness
            sleep 1
        done
    else
        echo "failed"

        echo 255 > /sys/devices/platform/leds/leds/red/brightness
        echo 255 > /sys/devices/platform/leds/leds/blue/brightness
        while [ 1 ]; do
            sleep 1
        done
    fi
}

# mount
function prepare()
{
    let step+=1
    echo "Step$step: check image package"

    echo heartbeat > /sys/devices/platform/leds/leds/red/trigger
    echo mmc0 > /sys/devices/platform/leds/leds/blue/trigger

    IMG_DIR=$(mktemp -d)
    mount -t ext4 /dev/mmcblk1p3 $IMG_DIR
    if [ $? -ne 0 ]; then
        exit_burn 1
    fi
    cd $IMG_DIR

    if [ -f $MD5_FILE ]; then
        ZIP_FILE=$(grep ".*ota.*\.zip" $MD5_FILE | awk '{print $2}')
    fi
    if [ -z "$ZIP_FILE" ]; then
        exit_burn 1
    fi

    read_md5=$(grep ".*ota.*\.zip" $MD5_FILE | awk '{print $1}')
    echo "read_md5: $read_md5"
    if [ -z "$read_md5" ]; then
        exit_burn 1
    fi
    calc_md5=$(md5sum $ZIP_FILE | awk '{print $1}')
    echo "calc_md5: $calc_md5"
    if [ "$read_md5" != "$calc_md5" ]; then
        exit_burn 1
    fi

    echo "ok"
    echo ""
}

# env
function erase()
{
    local target="/dev/mmcblk0"
    local offset=$1
    local size=$2

    let step+=1
    echo "Step$step: erase $target(offset=${offset}K, size=${size}K)"

    dd if=/dev/zero of=$target bs=1024 seek=$offset count=$size status=progress

    echo "ok"
    echo ""
}

function unzip_write()
{
    local offset=$1
    local file="$2"
    local target="/dev/mmcblk0"
    local pack="$ZIP_FILE"

    if [ "$file" = "fip.bin" ]; then
        target="/dev/mmcblk0boot0"
    else
        if [ "$file" = "reserved.img" ]; then
            pack="reserved.zip"
        fi
    fi

    local size_bytes=$(unzip -l "$pack" | grep "$file" | awk '{print $1}')
    local size_1K=$((($size_bytes+1023)/1024))

    let step+=1
    echo "Step$step: write $file(offset=${offset}K,size=${size_1K}K)"

    unzip -p $pack $file | dd of=$target seek=$offset bs=1024 status=progress

    echo "ok"
    echo ""
}

function md5_check()
{
    local offset=$1
    local file="$2"
    local target="/dev/mmcblk0"
    local pack="$ZIP_FILE"

    if [ "$file" = "fip.bin" ]; then
        target="/dev/mmcblk0boot0"
    else
        if [ "$file" = "reserved.img" ]; then
            pack="reserved.zip"
        fi
    fi

    read_md5=$(unzip -p $pack md5sum.txt | grep "$file" | awk '{print $1}')
    size_bytes=$(unzip -l "$pack" | grep "$file" | awk '{print $1}')
    echo "$file: md5=$read_md5 size=${size_bytes}bytes"

    local size_1K=$((($size_bytes+1023)/1024))
    echo offset=${offset}K, size=${size_1K}K

    local calc_md5=$(dd if=$target skip=$offset bs=1024 count=$size_1K | head -c $size_bytes | md5sum | awk '{print $1}')
    echo "calc_md5=$calc_md5"
    if [ "$read_md5" != "$calc_md5" ]; then
        exit_burn 1
    fi

    echo "ok"
    echo ""
}

#prepare
step=0
prepare

# 1K
FIP_OFFSET=0
FIP_SIZE=1024
BOOT_OFFSET=0
BOOT_SIZE=8192
ENV_OFFSET=$(($BOOT_SIZE))
ENV_SIZE=128
ROOTFS_OFFSET=$(($ENV_OFFSET+$ENV_SIZE))
ROOTFS_SIZE=524288
ROOTFS2_OFFSET=$(($ROOTFS_OFFSET+$ROOTFS_SIZE))
ROOTFS2_SIZE=524288
RESERVED_OFFSET=$(($ROOTFS2_OFFSET+$ROOTFS2_SIZE))
RESERVED_SIZE=262144
USERDATA_OFFSET=$(($RESERVED_OFFSET+$RESERVED_SIZE))

# fip
echo 0 > /sys/block/mmcblk0boot0/force_ro
unzip_write $FIP_OFFSET "fip.bin"
echo 1 > /sys/block/mmcblk0boot0/force_ro
# boot
unzip_write $BOOT_OFFSET "boot.emmc"
# env
erase $ENV_OFFSET $ENV_SIZE
# rootfs
unzip_write $ROOTFS_OFFSET "rootfs_ext4.emmc"
# reserved
unzip_write $RESERVED_OFFSET "reserved.img"
# userdata
erase $USERDATA_OFFSET $((100*1024))

echo "write done."
echo ""
echo "checking..."

# check
md5_check $FIP_OFFSET "fip.bin"
md5_check $BOOT_OFFSET "boot.emmc"
md5_check $ROOTFS_OFFSET "rootfs_ext4.emmc"
md5_check $RESERVED_OFFSET "reserved.img"

# end
exit_burn 0
