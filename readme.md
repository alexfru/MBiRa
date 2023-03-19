# MBiRa Boot Manager

## What it is

This is a boot manager that can be installed in the first sector of an HDD
(the sector is known as the Master Boot Record or MBR) that can automatically
boot an OS (like MS-DOS, FreeDOS, Windows 9x/Me/2000/XP) from one of the four
disk partitions or let the user intervene and manually choose which partition
to boot from.

MBiRa implements most of what's known as "modern standard MBR" in
[Master boot record](https://en.wikipedia.org/wiki/Master_boot_record).

Why this? Why now, some 25 years too late? Well, it turns out, some are still
using old technology and even my [BootProg](https://github.com/alexfru/BootProg)
boot loader, which is also single-sector. In order to fix some bugs and
limitations in BootProg and be able to test the changes quickly I needed
something like MBiRa and so I wrote it (the one existing similar boot manager
I'd tried before, [mbrbm](https://sourceforge.net/projects/mbrbm/), hadn't
quite cut it (no [LBA](https://en.wikipedia.org/wiki/Logical_block_addressing)
support, no update of the active partition in the MBR, somewhat confusing UI)).
It's also a fun coding exercise.

## Features

* a boot manager entirely contained in a single 512-byte sector (Master Boot
  Record sector (AKA MBR), that is)
  * space reserved/available for the Disk Timestamp (6 bytes at offset 0DAh)
    and Disk Signature (6 bytes at offset 1B8h)
* shows every partition's:
  * number (0 through 3)
  * active indicator as "a" (based on bit 7 of the byte, not on byte = 80h)
  * file system [ID/type](https://en.wikipedia.org/wiki/Partition_type) (0
    through 255)
  * size (in MB)
* the active partition boots automatically upon 5-second timeout
  * if there are two or more active partitions (which is an error that shouldn't
    happen, btw), the one that's numbered highest boots
* nothing boots if there's no active partition, selection from keyboard
  expected
* keyboard keys 0, 1, 2, 3 boot the respective partition
  * any other key (except ctrl, alt, shift) delays booting for another 5 seconds
  * the choice of active partition is saved back to the MBR, so you don't need
    to repeat yourself next time and also because many OSes (e.g. FreeDOS) do
    check that they're indeed booted from active partitions (the choice is saved
    just before the active partition is read from and booted)
* "Error" is printed in the following situations:
  1. neither BIOS int 13h extensions (e.g. function 42h, AKA LBA read)
     supported nor HDD geometry available (via int 13h's function 8);
     if this at all happens, it happens early, when none of the partition
     table entries has been printed to the screen yet
  2. the file system ID/type in the active/selected partition is 0
  3. BIOS int 13h extensions (AKA LBA) aren't supported while the partition is
     too far away from HDD's start (e.g. beyond 8GB) for CHS-based reads to
     reach the partition
  4. a disk read or write error
  5. the active/selected partition's first sector (VBR) does not have at its
     end the signature bytes 55h, 0AAh
* i8086/i8088 code
* LBA support (int 13h's function 42h for reads)
* CHS using BIOS-provided HDD geometry (int 13h's function 8)
* on entry to the VBR:  
  CS:IP = 0:7C00h  
  DL = BIOS boot drive (80h, 81h, etc)  
  DS = 0  
  DS:SI=DS:BP = address of the active/selected partition entry (first byte of
  which equals DL, that is, the boot drive, 80h, 81h, etc)

## Sample screen

When MBiRa starts, you can see something like this on the screen:

    MBiRa
    Hit #:
    #  Type Size,MB
    0   011 0007000
    1   014 0002000
    2 a 012 0010000
    3   015 1888695
    _

This shows a partition table for a 2TB disk that has four valid partitions,
the third of them being active (that is, automatically bootable by default).
The Type column lists the
[file system/partition IDs/types](https://en.wikipedia.org/wiki/Partition_type)
of these partitions and those correspond to a FAT32 with CHS addressing
(11=0Bh), a FAT16 with LBA (14=0Eh), a FAT32 with LBA (12=0Ch) and an extended
partition with LBA (15=0Fh) respectively.

With mbrtst.bin installed on the active partition shown above and booted
on a test PC I get this additional output under the above partition table:

    Geo CHS=01023,00255,00063=0016434495 sect
    
    drv  dx   si   bp   cs   ds   es   ss   sp
    0080 0080 11DE 11DE 0000 0000 0000 0000 7BEC
    
    FS=00012 CHS=01023,00254,00063 LBA=0018434048 Sz,MB=0000010000
    _

This shows that the BIOS boot drive is 80h (in the partition entry (under
"drv") and the DL register), confirms the file system ID/type of 12 and
the size of 10000MB.

The partition entry lists its start LBA (0018434048) and start CHS
(01023,00254,00063). The start CHS is invalid because it's outside of the
number of Cylinders, Heads and Sectors listed as the BIOS disk geometry shown
at the top. Specifically, with 1023 cylinders reported by the BIOS, the valid
cylinder numbers are 0 through 1022 while we got 1023. This situation is
because the partition starts more than 8GB away from the HDD's start as can be
seen from both the cumulative size of the preceding partitions (7000MB +
2000MB > approx. 8000MB) and the start LBA (18434048 > 16777215, the maximum
24-bit LBA value that the BIOS can accept in CHS-based reads). This partition
will only boot when LBA is supported.

## Requirements

There aren't that many requirements, probably.

You need an IBM PC-compatible computer with 64KB of RAM or better with an HDD
(it can be a VM just as well), but "better" is limited. It can't be a modern
PC that can only boot using [(U)EFI](https://en.wikipedia.org/wiki/UEFI).
It'll have to have the Compatibility Support Module (CSM) in order to boot
MBiRa.

The HDD where you intend to install MBiRa should have installed only OSes that
can be booted by the MBR loading the first sector from the OS's HDD partition
and transferring control there, that is, by very simple and standard MBRs.
The following is a very incomplete list of such OSes: MS-DOS, FreeDOS, Windows
9x/Me/2000/XP. If there's a newer version of Windows (e.g. Vista, 7 through 11)
or a Linux system that boots using [GRUB](https://www.gnu.org/software/grub/),
installing MBiRa there will break booting of those systems.

The HDD (specifically, its 1st sector, MBR) must not be write-protected or
MBiRa won't boot any OS.

## Compilation

You'll need [NASM](https://nasm.us/) 2.10 or newer.

Then just

    $ nasm mbira.asm -f bin -o mbira.bin

## Installation and uninstallation

First, make sure you have mbira.bin compiled (see above).

### FreeDOS

Here's how to install mbira.bin on the first HDD using
[FreeDOS](https://freedos.org/) 1.3...

First, save the existing MBR to the hdd1_old.mbr file:

    > fdisk /SMBR 1
    > copy boot.mbr hdd1_old.mbr

**BACKUP THE hdd1_old.mbr FILE TO BE ABLE TO RESTORE THE ORIGINAL MBR!**

Now install MBiRa as the new MBR on the first HDD:

    > copy mbira.bin boot.mbr
    > fdisk /AMBR 1

To uninstall MBiRa from the first HDD using the previously saved file
hdd1_old.mbr:

    > copy hdd1_old.mbr boot.mbr
    > fdisk /AMBR 1

### Linux

Here's how to install mbira.bin on /dev/sda using Linux...  
(If needed, substitute /dev/hda and such)

First, save the existing MBR to the sda_old.mbr file:

    $ sudo dd if=/dev/sda of=sda_old.mbr bs=1b count=1

**BACKUP THE sda_old.mbr FILE TO BE ABLE TO RESTORE THE ORIGINAL MBR!**

Now install MBiRa as the new MBR on /dev/sda:

    $ sudo cp sda_old.mbr sda.mbr
    $ sudo dd if=mbira.bin of=sda.mbr bs=1 count=440 conv=notrunc
    $ sudo dd if=sda.mbr of=/dev/sda bs=1b count=1

Essentially, this overwrites the first 440 bytes of the MBR with the first
440 bytes of mbira.bin while keeping the last 72 bytes containing the
partition table among a few other things.

To uninstall MBiRa from /dev/sda using the previously saved file
sda_old.mbr:

    $ sudo dd if=sda_old.mbr of=/dev/sda bs=1b count=1

## Troubleshooting

* If you get an "Error" message as mentioned in the [Features](#features)
  section, you should be able to narrow down the problem:
  1. If there's no partition table on the screen, and "Error" follows
     immediately under "#  Type Size,MB", your PC must be too old or weird.
  2. You mistakenly tried to boot the partition whose file system ID/type is 0.
  3. Your PC is old and doesn't support BIOS int 13h extensions (AKA LBA)
     while the partition you chose starts more than 8GB away from HDD's start
     (this can often be determined by seeing that the cumulative size of
     the preceding partitions is high, about 8GB or more).
  4. Disk read/write errors occur rarely. So, unless there are any other signs
     of the HDD dying, it's likely something else. But make sure the HDD
     (specifically, its 1st sector, MBR) is not write-protected or MBiRa won't
     boot any OS.
  5. It is possible that the OS installed on the partition you chose to boot
     has a more complex or an unconventional way of booting.

## Resources, links

*   [Master boot record](https://en.wikipedia.org/wiki/Master_boot_record)
*   [Partition type](https://en.wikipedia.org/wiki/Partition_type)
*   [UEFI](https://en.wikipedia.org/wiki/UEFI)
*   [Logical block addressing](https://en.wikipedia.org/wiki/Logical_block_addressing)
*   [Cylinder-head-sector](https://en.wikipedia.org/wiki/Cylinder-head-sector)
*   [FreeDOS](https://freedos.org/)
*   [mbrbm](https://sourceforge.net/projects/mbrbm/)
*   [GRUB](https://www.gnu.org/software/grub/)
*   [BootProg](https://github.com/alexfru/BootProg)
*   [NASM](https://nasm.us/)
*   [Ralf Brown's Interrupt List](http://www.delorie.com/djgpp/doc/rbinter/)
