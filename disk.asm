    DEVICE ZXSPECTRUM128
    EMPTYTRD "fzx-viewer.trd","FZXVIEW"

    ORG $6000
basic:
    db 0,10
    dw line20-line10
line10:
    db $fd,$b0,'"32767"',13               ; CLEAR VAL "32767"
line20:
    db 0,20
    dw line30-line20_body
line20_body:
    db $f9,$c0,$b0,'"15619":',$ea,':'     ; RANDOMIZE USR VAL "15619": REM :
    db $ef,'"VIEWER"',$af,13             ; LOAD "VIEWER" CODE via TR-DOS
line30:
    db 0,30
    dw basic_end-line30_body
line30_body:
    db $f9,$c0,$b0,'"32768"',13           ; RANDOMIZE USR VAL "32768"
basic_end:
    SAVETRD "fzx-viewer.trd","boot.B",basic,basic_end-basic,10

    ORG $8000
viewer:
    INCBIN "viewer.bin"
    SAVETRD "fzx-viewer.trd","VIEWER.C",viewer,$-viewer

    INCLUDE "packs.inc"
