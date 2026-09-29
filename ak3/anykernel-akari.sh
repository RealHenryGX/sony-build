### AnyKernel3 setup — Gravity_Ext / akari (Sony Xperia XZ2)
properties() { '
kernel.string=Gravity_Ext 4.9.337-gravity-perf KernelSU+SUSFS (Sony Xperia XZ2)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=akari
device.name2=xz2
device.name3=H8216
device.name4=H8266
device.name5=H8296
device.name6=SO-03K
device.name7=SOV37
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
