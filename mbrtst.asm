;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                                                          ;;
;;                   MBR tester by Alexey Frunze (c) 2023                   ;;
;;                           2-clause BSD license.                          ;;
;;                                                                          ;;
;;                                                                          ;;
;;                              How to Compile:                             ;;
;;                              ~~~~~~~~~~~~~~~                             ;;
;; nasm mbrtst.asm -f bin -o mbrtst.bin                                     ;;
;;                                                                          ;;
;;                                                                          ;;
;;                                 Features:                                ;;
;;                                 ~~~~~~~~~                                ;;
;; - can replace the code of standard FAT12/16 and FAT32 VBRs and be        ;;
;;   booted by a generic MBR (not just MBiRa) to show what information      ;;
;;   is passed from the MBR to the VBR                                      ;;
;;                                                                          ;;
;; - prints BIOS geometry/params (CHS dimensions) for the boot drive        ;;
;;   and the product of Cylinders, Heads and Sectors, which gives the disk  ;;
;;   size in sectors (capped by some 16 million or 8GB)                     ;;
;;                                                                          ;;
;; - prints start values of important registers: dx, si, bp, sp, seg regs   ;;
;;                                                                          ;;
;; - prints partition entry's File System ID/type, start CHS & LBA, size,   ;;
;;                            active flag / boot drive (again)              ;;
;;                                                                          ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


BITS 16

CPU 8086

ORG 7C00h

        ; Fill FAT12/16 and FAT32 BPB areas with NOPs
        ; (3Eh and 5Ah bytes respectively), so it won't matter at
        ; which point this code will start execution, 3Eh or 5Ah.
        times (5Ah-($-$$)) nop

        ; prepare to be popped and printed one by one
        push    sp
        push    ss
        push    es
        push    ds
        push    cs
        push    bp
        push    si
        push    dx

        ; save ds:si away to es:di
        push    ds
        pop     es
        mov     di, si

        jmp     0:main
main:
        cld

        ; cs=ds=0
        push    cs
        pop     ds


        ; Get disk geometry/drive params according to BIOS

        mov     ah, 8
        int     13h
        jc      .0

        call    printl
        db      "Geo", 0
        mov     bp, 1
        call    printCHS

        call    printl
        db      "=", 0
        call    printdec32
        call    printl
        db      " sect", 13, 10, 10, 0

.0:


        ; Partition entry: active/drive;
        ; Start reg values

        mov     al, [es:di]
        mov     ah, 0
        push    ax

        call    printl
        db      "drv  dx   si   bp   cs   ds   es   ss   sp", 13, 10, 0
        mov     cx, 9
.1:
        pop     ax
        call    printhex
        mov     al, ' '
        call    printc
        loop    .1


        ; Partition entry: File System ID/Type

        call    printl
        db      13, 10, 10, "FS=", 0
        mov     al, [es:di+4]
        mov     ah, 0
        call    printdec


        ; Partition entry: Start CHS

        mov     dh, [es:di+1]
        mov     cx, [es:di+2]
        xor     bp, bp
        call    printCHS


        ; Partition entry: Start LBA

        call    printl
        db      " LBA=", 0
        mov     ax, [es:di+8]
        mov     dx, [es:di+10]
        call    printdec32


        ; Partition entry: Size, MB

        call    printl
        db      " Sz,MB=", 0
        mov     ax, [es:di+12]
        mov     dx, [es:di+14]
        mov     cx, 11
.2:
        shr     dx, 1
        rcr     ax, 1
        loop    .2
        call    printdec32


        call    printl
        db      13, 10, 0

Halt:
        hlt 
        jmp     short Halt


; prints CHS packed in DH:CX as in int 13h functions 2 and 8,
; adds bp (can be 0 or 1) to head and cylinder,
; returns product in dx:ax.
printCHS:
        push    bx

        call    printl
        db      " CHS=", 0

        ; cylinder
        push    cx
        mov     al, ch
        mov     ah, cl
        mov     cl, 6
        shr     ah, cl
        add     ax, bp
        pop     cx
        call    printdec

        mov     bx, ax

        mov     al, ','
        call    printc

        ; head
        mov     al, dh
        mov     ah, 0
        add     ax, bp
        call    printdec

        mov     dx, ax

        mov     al, ','
        call    printc

        ; sector
        mov     ax, cx
        and     ax, 63
        call    printdec

        xchg    bx, dx
        mul     dx
        mul     bx

        pop     bx
        ret


; Print char from AL
printc:
        push    ax
        push    bx
        push    bp

        mov     ah, 0Eh
        mov     bx, 7
        int     10h

        pop     bp
        pop     bx
        pop     ax
        ret


prints_inner:
        push    ax

        cld
.1:
        lodsb
        test    al, al
        jz      .2
        call    printc
        jmp     short .1

.2:
        pop     ax
        ret


%if 0
; Print ASCIIZ string at SI
prints:
        push    si
        call    prints_inner
        pop     si
        ret
%endif


; Print ASCIIZ string immediately following the call to this subroutine
printl:
        pop     si
        call    prints_inner
        push    si
        ret


; Print AX in hexadecimal
printhex:
        push    ax
        push    cx
        push    dx
        push    si

        mov     dx, ax
        mov     si, 4
        mov     cx, si

.1:
        rol     dx, cl
        mov     al, dl
        and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     .2
        add     al, 'A' - '0' - 10
.2:
        call    printc
        dec     si
        jnz     .1

        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret


%if 0
; Print DX:AX in hexadecimal
printhex32:
        xchg    ax, dx
        call    printhex
        xchg    ax, dx
        jmp     printhex
%endif


printdec32_inner:
        push    ax
        push    cx
        push    dx
        push    si
        push    di
        push    bp

        mov     si, cx
        mov     di, 10

.1:
        xchg    ax, bp
        xchg    ax, dx
        xor     dx, dx
        div     di

        xchg    ax, bp
        div     di

        xchg    dx, bp
        push    bp
        loop    .1

        mov     cx, si

.2:
        pop     ax
        add     al, '0'
        call    printc
        loop    .2

        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret


; Print AX in decimal
printdec:
        push    cx
        push    dx
        xor     dx, dx
        mov     cx, 5
        call    printdec32_inner
        pop     dx
        pop     cx
        ret


; Print DX:AX in decimal
printdec32:
        push    cx
        mov     cx, 10
        call    printdec32_inner
        pop     cx
        ret


                times (1FEh-($-$$)) db 40h

;;;;;;;;;;;;;;;;;;;;
;; Boot sector ID ;;
;;;;;;;;;;;;;;;;;;;;

                dw      0AA55h          ; BIOS checks for this ID
