#!/bin/bash

this_dir=$(dirname $(realpath "$0"))
sd_zip_path=$(find $this_dir -maxdepth 1 -name "*emmc_sd_compat.zip")
if [ -z $sd_zip_path ]; then
    echo "Failed: no *emmc_sd_compat.zip!"
    exit 1
fi
sd_zip=$(basename $sd_zip_path)

ota_zip_path=$(find $this_dir -maxdepth 1 -name "*emmc_ota.zip")
if [ -z $ota_zip_path ]; then
    echo "Failed: no *emmc_ota.zip!"
    exit 1
fi
ota_zip=$(basename $ota_zip_path)

md5_txt_path=$(find $this_dir -maxdepth 1 -name "sg2002_recamera_emmc_md5sum.txt")
if [ -z $md5_txt_path ]; then
    echo "Failed: no sg2002_recamera_emmc_md5sum.txt"
    exit 0
fi
md5_txt=$(basename $md5_txt_path)

pushd "$this_dir" > /dev/null

# userdata
USER_DATA="userdata"
rm -rfv $USER_DATA
mkdir -p $USER_DATA

cat > $USER_DATA/mk_reserved.sh << 'EOF'
#!/bin/bash

set -e

# sudo apt install e2fsprogs e2tools
if [ ! command -v e2cp &> /dev/null ]; then
    echo "Install e2tools first: sudo apt install e2tools"
    exit 1
fi

this_dir=$(dirname $(realpath "$0"))
pushd "$this_dir" > /dev/null

MD5_FILE="sg2002_recamera_emmc_md5sum.txt"
ZIP_FILE=$(grep ".*ota.*\.zip" "$MD5_FILE" | awk '{print $2}')

out_file="reserved"
img_file=$out_file.img
zip_file=$out_file.zip
md5_file="md5sum.txt"
rm -rfv ${md5_file} ${out_file}*

# gen img
dd if=/dev/zero of="$img_file" bs=1M count=256
mkfs.ext4 "$img_file"

# copy files
e2cp -a "$MD5_FILE" "$ZIP_FILE" -d "${img_file}:/"
# calc md5sum
md5sum "$img_file" > "$md5_file"
# zip
zip -j "$zip_file" "$md5_file" "$img_file"
# clean
rm -rfv "$md5_file" "$img_file"

popd > /dev/null
echo "done"
EOF

# fill userdata dir
cp -rfv $ota_zip $USER_DATA
cp -rfv $md5_txt $USER_DATA
chmod +x $USER_DATA/mk_reserved.sh
$USER_DATA/mk_reserved.sh

# gen userdata.img
USER_IMAGE="userdata.img"
dd if=/dev/zero of=${USER_IMAGE} bs=1M count=256 status=progress
mkfs.ext4 $USER_IMAGE
e2cp -pv ${USER_DATA}/* "${USER_IMAGE}:/"
rm -rf ${USER_DATA}

# create factory img
sd_img=${sd_zip%.*}.img
factory_img=$(echo "$sd_img" | sed 's/compat/factory/')

rm -rfv $sd_img $factory_img
unzip $sd_zip
dd if=/dev/zero of=${factory_img} bs=1M count=800

# Create the disk image
(
    echo "label: dos"
    echo "label-id: 0x48617373"
    echo "unit: sectors"
    echo "boot  : start=2048, size=16384, type=c, bootable" #create the boot partition
    echo "rootfs: start=18432, size=1048576, type=83"       #Make a rootfs partition
    echo "userdata: start=1067008, size=571390, type=83"    #Make a userdata partition
) | sfdisk --force -uS ${factory_img}

# boot
dd if=$sd_img of=${factory_img} bs=512 skip=2048 seek=2048 count=16384 conv=notrunc,sparse status=progress
# rootfs
dd if=rootfs.img of=${factory_img} bs=512 seek=18432 conv=notrunc,sparse status=progress
# userdata
dd if=${USER_IMAGE} of=${factory_img} bs=512 seek=1067008 conv=notrunc,sparse status=progress

zip -j ${factory_img%.*}.zip ${factory_img}

# clean
rm -rfv $USER_IMAGE
rm -rfv $sd_img

popd > /dev/null
echo "done"