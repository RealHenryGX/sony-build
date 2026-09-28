### AnyKernel3 setup
properties() { '
kernel.string=Gravity_Ext 4.9.227-gravity-perf KernelSU+SUSFS (Sony Xperia XZ2 Compact)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=xz2c_dcm
device.name2=apollo
device.name3=xz2c
device.name4=SO-05K
supported.versions=10 - 15
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot;

write_boot;
