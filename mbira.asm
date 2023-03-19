;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                          ;;
;;           "MBiRa" Boot Manager v 0.9 by Alexey Frunze (c) 2023           ;;
;;                           2-clause BSD license.                          ;;
;;                                                                          ;;
;;                                                                          ;;
;;                              How to Compile:                             ;;
;;                              ~~~~~~~~~~~~~~~                             ;;
;; nasm mbira.asm -f bin -o mbira.bin                                       ;;
;;                                                                          ;;
;;                                                                          ;;
;;                                 Features:                                ;;
;;                                 ~~~~~~~~~                                ;;
;; - MBiRa implements most of what's known as "modern standard MBR"         ;;
;;   (see https://en.wikipedia.org/wiki/Master_boot_record)                 ;;
;;                                                                          ;;
;; - space reserved/available for the Disk Timestamp (6 bytes at offset     ;;
;;   0DAh) and Disk Signature (6 bytes at offset 1B8h)                      ;;
;;                                                                          ;;
;; - active partition boots automatically upon 5-second timeout             ;;
;;                                                                          ;;
;; - keyboard keys 0, 1, 2, 3 boot the respective partition                 ;;
;;                                                                          ;;
;; - the choice of active partition is saved back to the MBR just before    ;;
;;   the active partition is read from and booted                           ;;
;;                                                                          ;;
;; - LBA support (int 13h's function 42h for reads)                         ;;
;;                                                                          ;;
;; - CHS using BIOS-provided HDD geometry (int 13h's function 8)            ;;
;;                                                                          ;;
;; - On entry to the VBR:                                                   ;;
;;   - CS:IP = 0:7C00h                                                      ;;
;;   - DL = BIOS boot drive (80h, 81h, etc)                                 ;;
;;   - DS = 0                                                               ;;
;;   - DS:SI=DS:BP = address of the active/selected partition entry (first  ;;
;;     byte of which equals DL, that is, the boot drive, 80h, 81h, etc)     ;;
;;                                                                          ;;
;; - Sample screen:                                                         ;;
;;                                                                          ;;
;;    MBiRa                                                                 ;;
;;    Hit #:                                                                ;;
;;    #  Type Size,MB                                                       ;;
;;    0   011 0007000                                                       ;;
;;    1   014 0002000                                                       ;;
;;    2 a 012 0010000                                                       ;;
;;    3   015 1888695                                                       ;;
;;    _                                                                     ;;
;;                                                                          ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


BITS 16

CPU 8086

%ifndef TIMEOUT
  %define TIMEOUT 5
%endif
%ifnum TIMEOUT
%else
  %error "TIMEOUT isn't a number"
%endif
%if TIMEOUT > 14
  %error "TIMEOUT must be <= 14"
%endif
Timeout                 equ     TIMEOUT

CopySeg                 equ     100h
CopyAbs                 equ     (CopySeg*16)

ORG CopyAbs

        cld

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Move the stack to lower memory ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

bpbSectorsPerTrack:                     ; 2 bytes overwritten with data here
        xor     di, di
        cli                             ; ss:sp change protection for 8088
bpbHeadsPerCylinder:                    ; 2 bytes overwritten with data here
        mov     ss, di
        mov     sp, 7C00h               ; ss:sp=0:7C00h
        sti

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Copy ourselves to lower memory.             ;;
;;                                             ;;
;; The working/executing copy at CopySeg:0     ;;
;; (or 0:CopyAbs) is going to be self-modified ;;
;; because some variables and state reside in  ;;
;; or overlap with code or simply are mutable  ;;
;; global variables.                           ;;
;;                                             ;;
;; The pristine copy of MBR at 0:7C00h is also ;;
;; going to be modified, but only in the four  ;;
;; bytes containing partition active flags /   ;;
;; BIOS boot drives. This copy is going to be  ;;
;; written back to the MBR to reflect the      ;;
;; user's choice of active partition and make  ;;
;; it persist. Many OSes do check that they're ;;
;; booted from active partitions.              ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

        mov     ds, di
        mov     si, sp                  ; ds:si=0:7C00h

        mov     cx, CopySeg
        mov     es, cx                  ; es:di=CopySeg:0

%if CopySeg != 100h
%error "CopySeg must be 100h!"
%endif
        rep     movsw

        mov     es, cx                  ; es=0

;;;;;;;;;;;;;;;;;;;;;;
;; Jump to the copy ;;
;;;;;;;;;;;;;;;;;;;;;;

      ; jmp     0:main
        db      0EAh
        dw      main
bsActiveEntryOfs:               ; 2 bytes (0-init) overwritten with data here
        dw      0

main:
        ; cs=ds=es=ss=0, sp=7C00h

;;;;;;;;;;;;;;;;;;
;; Some prep... ;;
;;;;;;;;;;;;;;;;;;

        push    dx                      ; save BIOS boot drive number

        mov     si, MsgHeader
        call    PrintStr

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Check for int 13h extensions for LBA reads ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

        mov     ah, 41h                 ; clobbers AX,BX,CX,DH
        mov     bx, 55AAh
        int     13h
%ifndef TESTNOINT13EXT
        jc      NoExtensions
        sub     bx, 0AA55h
        jnz     NoExtensions
        shr     cx, 1
        jnc     NoExtensions
%else
        jmp     short NoExtensions
%endif
        mov     byte [ReadSector+1], bl
                ; patch "jmp short ReadSectorNonExt" to "jmp short $+2"

        jmp     short PrintMenu

NoExtensions:

;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Get drive parameters ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;

        mov     ah, 8                   ; clobbers AX,BL,CX,DX,ES:DI
        int     13h
        jnc     GotGeometry
        jmp     Error

GotGeometry:
        and     cx, 63
        mov     [bpbSectorsPerTrack], cx

        mov     ax, cx

        mov     cl, dh
        inc     cx
        mov     [bpbHeadsPerCylinder], cx

        mul     cx

PrintMenu:

        ; If execution reaches here from the LBA code above,
        ; it's only to set cx=1024.
        mov     cx, 1024                ; max cylinder count = 1024
        mul     cx
        pop     di                      ; BIOS boot drive number
        push    dx
        push    ax
                ; bpbSectorsPerTrack * bpbHeadsPerCylinder * 1024 on stack
        push    di                      ; BIOS boot drive number on stack

;;;;;;;;;;;;;;;;;;;;
;; Print the menu ;;
;;;;;;;;;;;;;;;;;;;;

        mov     di, FirstPartitionEntry
        push    di

        xchg    cl, ch                  ; cx=4 (was 1024, see above)
PrintMenuNext:
        push    cx
        call    PrintPartitionEntry
        mov     si, MsgNewLine
        call    PrintStr
        pop     cx
        add     di, 16
        loop    PrintMenuNext           ; cx=0

        pop     di                      ; di=FirstPartitionEntry

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Wait until the timeout to boot the active partition or  ;;
;; for a key (0 through 3) to select and boot a partition, ;;
;; whichever happens first                                 ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

WaitForKeyOrTimeoutStart:
        mov     cl, Timeout * 18        ; down counter of 55ms ticks

WaitForKeyOrTimeoutLoop:
        mov     si, 46ch
        mov     ax, [si]                ; get current tick count's low 16 bits

WaitForTick:
        hlt
        cmp     ax, [si]
        je      WaitForTick             ; loop until next 55ms tick

        mov     ah, 1                   ; clobbers AX
        int     16h                     ; any key pressed?
        jz      NoKey                   ; jump if no key pressed

        mov     ah, 0                   ; clobbers AX
        int     16h                     ; get the key's ASCII code

        sub     al, '0'
        cmp     al, 4
        jae     WaitForKeyOrTimeoutStart
                ; reset down counter if not key 0 through 3

        mov     ah, 16
        mul     ah
        add     di, ax                  ; ds:di -> selected partition entry
        jmp     short PartitionSelected

NoKey:
        loop    WaitForKeyOrTimeoutLoop

        mov     cx, [bsActiveEntryOfs]
        jcxz    WaitForKeyOrTimeoutStart
                ; reset down counter if no active partition

        mov     di, cx                  ; ds:di -> active partition entry

PartitionSelected:

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Read partition's 1st sector (VBR)               ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Input: DS:DI -> active/selected partition entry ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

        mov     bx, 7C00h               ; es:bx=0:7C00h

        cmp     [di+4], bl
        je      Error                   ; error if zero File System ID/type

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; But just before reading, mark the active/selected ;;
;; partition entry as active (this is done in the    ;;
;; pristine MBiRa at 0:7C00h, not in the currently   ;;
;; executing MBiRa at 0:CopyAbs) and write the MBR   ;;
;; back                                              ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Input: DS:DI -> active/selected partition entry   ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        pop     dx                      ; dl = BIOS boot drive number
        mov     dh, 0                   ; head=0
        mov     cx, 1                   ; cylinder=0, sector=1
        mov     ax, 301h                ; clobbers AX
                                        ; al = sector count = 1
                                        ; ah = 3 = write function no.

        ; Update the active flag / BIOS boot drive in the partition entry,
        ; in both copies of MBiRa.
        mov     [di], dl                ; will be passed to VBR
        mov     [di+7C00h-CopyAbs], dl  ; will be stored on disk
        int     13h
        jc      Error                   ; CF = 0 if no error

        mov     cx, [di+8]
        mov     ax, [di+10]     ; ax:cx=LBA of partition's 1st sector (VBR)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Reads a sector using BIOS Int 13h fn 2 or 42h    ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Input:  AX:CX = LBA                              ;;
;;         ES:BX -> buffer address                  ;;
;;         dword [SP] = bpbSectorsPerTrack *        ;;
;;                      bpbHeadsPerCylinder * 1024  ;;
;;         DL    = boot drive number                ;;
;;         DS:DI -> active/selected partition entry ;;
;; Output: DL    = boot drive number                ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

ReadSector:
        jmp     short ReadSectorNonExt  ; possibly patched to "jmp short $+2"
                ; off to CHS-based read if no LBA support

        push    ds ; LBA 48...63: 0
        push    ds ; LBA 32...47: 0
        push    ax ; LBA 16...31
        push    cx ; LBA  0...15
        push    es
        push    bx
        ; If we're here, that is, with BIOS int 13h LBA extensions supported,
        ; we must have an i80386 CPU...
        ; IOW, we should be able to use a shorter i80186 instruction here.
      ; push    byte 1 ; sector count word = 1
        db      6Ah, 1
      ; push    byte 16 ; packet size byte = 16, reserved byte = 0
        db      6Ah, 10h

        mov     ah, 42h                 ; clobbers AX
                                        ; ah = 42h = read function no.

        mov     si, sp                  ; ds:si -> packet for fn 42h

        jmp     short ReadSectorCommon


MsgNumAct       db "/ "                 ; 2 bytes, next 2 bytes overwritten


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Fill free space, if any ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

        times (0DAh-($-$$)) db 40h

;;;;;;;;;;;;;;;;;;;;
;; Disk timestamp ;;
;;;;;;;;;;;;;;;;;;;;

DiskTimestamp   times 6 db 0


ReadSectorNonExt:
        ; Divide 32-bit LBA in ax:cx by 16-bit bpbSectorsPerTrack
        ; with 32-bit quotient and 16-bit remainder.
        ; This avoids division overflows with large LBAs and
        ; supports disks up to 8 GB in size (the BIOS int 13h read
        ; function (ah = 2) takes cylinder:head:sector (AKA CHS)
        ; that's at most 24-bit, IOW, the function takes LBAs up to
        ; ~16 million, which with 512-byte sectors gives 8GB).

        ; Before the divisions, though, check that they wouldn't
        ; yield cylinder no. >= 1024, possibly causing #DE in the
        ; process. LBA must be strictly less than
        ; bpbSectorsPerTrack * bpbHeadsPerCylinder * 1024.
        pop     si
        pop     dx
        sub     si, cx
        sbb     dx, ax
        jc      Error
        or      dx, si
        jz      Error

        ; Cylinder no. will be 1023 or less. If that's still too large,
        ; we rely on the BIOS to catch it and fail the read.
        ; N.B. LBA in ax:cx now definitely fits into 24 bits.
        cwd                             ; will first divide LBA's hi word
        mov     si, bpbSectorsPerTrack
        div     word [si]
                ; ax = (LBA / 65536) / SPT = (LBA / SPT) / 65536
                ; dx = (LBA / 65536) % SPT
        xchg    ax, cx                  ; will next divide LBA's low word
        div     word [si]
                ; cx:ax = LBA / SPT
                ; dx = LBA % SPT         = sector - 1

        xchg    cx, dx
        inc     cx
                ; cx = sector no.

        div     word [si+(bpbHeadsPerCylinder-bpbSectorsPerTrack)]
                ; ax = (LBA / SPT) / HPC = cylinder
                ; dx = (LBA / SPT) % HPC = head

        mov     ch, al
                ; ch = LSB 0...7 of cylinder no.
        ror     ah, 1
        ror     ah, 1 ; excess bits of cylinder no. must be 0 anyway
        or      cl, ah
                ; cl = MSB 8...9 of cylinder no. + sector no.

        mov     dh, dl
                ; dh = head no.

        mov     ax, 201h                ; clobbers AX
                                        ; al = sector count = 1
                                        ; ah = 2 = read function no.

        mov     dl, [di]
                ; dl = drive no.

ReadSectorCommon:
        int     13h                     ; read sectors

        jc      Error                   ; CF = 0 if no error

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Jump to the loaded sector (VBR) ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

        cmp     word [7C00h+512-2], 0AA55h
        jne     Error
                ; first make sure it has the proper 0AA55h signature at its end

        mov     si, di
        mov     bp, di
                ; ds:si=ds:bp -> active/selected partition entry

        push    es
        push    bx
        retf                            ; done


; 9 bytes
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Prints an error message and halts ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
Error:
        mov     si, MsgError
        call    PrintStr

Halt:
        hlt
        jmp     short Halt


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Prints a partition entry and checks if it's active; ;;
;; advances MsgNumAct's partition #;                   ;;
;; clears/zeroes entry's active flag / drive, making   ;;
;; it inactive (this is done in the pristine MBiRa at  ;;
;; 0:7C00h, not in the currently executing MBiRa at    ;;
;; 0:CopyAbs)                                          ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Input:  DS:DI -> partition entry                    ;;
;; Output: CX = 0                                      ;;
;; Clobbers: AX, BX, DX, SI, BP                        ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
PrintPartitionEntry:
        ; Partition # and Active indicator
        mov     si, MsgNumAct
        inc     byte [si]
        shl     byte [di], 1    ; corrupted active/drive will be updated
        mov     al, ' '
        jnc     PrintInactive
        mov     al, 'a'
        mov     [bsActiveEntryOfs], di  ; record the active entry
PrintInactive:
        cbw                             ; zero-terminate MsgNumAct
        mov     [si+2], ax
        call    PrintStr

        ; File System ID/Type: 000 to 255
        mov     bl, [di+4]
        mov     bh, 0
        xor     ax, ax
                ; bl zero-extended to all of ax:bx
        mov     cx, 3                   ; 3 decimal digits
        call    PrintSpaceAndDec32      ; cx=0

        ; Mark entry as inactive
        mov     [di+7C00h-CopyAbs], cl

        ; Size, in MB
        mov     bx, [di+12]
        mov     ax, [di+14]

        ; Shift a 32-bit LBA value 11 positions right
        ; and print the remaining 21 bits as a 7-digit
        ; decimal number prefixed with a space char
        ; (since the LBA is in 512-byte units, the shift
        ; reduces it to 1MB units)
        mov     cl, 11
LBAMB:
        shr     ax, 1
        rcr     bx, 1
        loop    LBAMB
        mov     cl, 7                   ; 7 decimal digits
        ; tail call

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Prints a 32-bit integer as decimal           ;;
;; (right-justified by zeroes on the left)      ;;
;; prefixed with a space char                   ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Input: AX:BX = 32-bit unsigned integer       ;;
;;        CX = how many decimal digits to print ;;
;; Output: CX = 0                               ;;
;; Clobbers: AX, BX, DX, SI, BP                 ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
PrintSpaceAndDec32:
        mov     si, cx
        mov     bp, 10

PrintDecNext:
        xor     dx, dx
        div     bp

        xchg    ax, bx
        div     bp

        xchg    ax, bx
        push    dx
        loop    PrintDecNext

        mov     al, ' '
        call    PrintChar

        mov     cx, si

PrintDecNext2:
        pop     ax
        add     al, '0'
        call    PrintChar
        loop    PrintDecNext2
        ret


; 8 bytes
;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Prints a character   ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Input: AL = char     ;;
;; Clobbers: AH, BX, BP ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;
PrintChar:
        mov     ah, 0Eh         ; clobbers BP (on some systems/conditions)
        mov     bx, 7
        int     10h
        ret


; 9 bytes
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Prints an ASCIIZ string  ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Input: DS:SI -> string   ;;
;; Output: AL = 0           ;;
;; Clobbers: AH, BX, SI, BP ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
PrintStrContinue:
        call    PrintChar
PrintStr:
        lodsb
        test    al, al
        jnz     PrintStrContinue
        ret


MsgHeader       db "MBiRa", 13, 10              ; continues below
                db "Hit #:", 13, 10             ; continues below
                db "#  Type Size,MB"            ; continues below
MsgNewLine      db 13, 10, 0                    ; 33 bytes
MsgError        db "Error", 0                   ; 6 bytes

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Fill free space, if any ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

                times (1B8h-($-$$)) db 40h

;;;;;;;;;;;;;;;;;;;;
;; Disk signature ;;
;;;;;;;;;;;;;;;;;;;;

DiskSignature   times 6 db 0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 4 16-byte partition entries ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

FirstPartitionEntry:
                times (4*16) db 0

;;;;;;;;;;;;;;;;;;;;
;; Boot sector ID ;;
;;;;;;;;;;;;;;;;;;;;

                dw      0AA55h          ; BIOS checks for this ID
