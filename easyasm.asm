; EasyAsm, an assembler for the MEGA65
; Copyright © 2024  Dan Sanderson
;
; This program is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License
; along with this program.  If not, see <https://www.gnu.org/licenses/>.
;
; ---------------------------------------------------------
; easyasm : The main program
; ---------------------------------------------------------

!cpu m65

kernal_base_page = $00
easyasm_base_page = $1e
execute_user_program = $1e27

; BP map (B = $1E)
; 00 - ?? : EasyAsm dispatch; see easyasm-e.prg

* = $100 - 75

pass            *=*+1  ; $FF=final pass
program_counter *=*+2

asm_flags       *=*+1
; - The PC is defined
F_ASM_PC_DEFINED = %00000001
; - expect_addressing_expr is forcing 16-bit addressing
F_ASM_FORCE_MASK = %00000110
F_ASM_FORCE8     = %00000010
F_ASM_FORCE16    = %00000100
; - expect_addressing_expr subtracts address arg from PC for branching
F_ASM_AREL_MASK  = %00011000
F_ASM_AREL8      = %00001000
F_ASM_AREL16     = %00010000
F_ASM_BITBRANCH  = %00100000
; - assembly generated at least one warning
F_ASM_WARN       = %01000000
F_ASM_SRC_TO_BUF = %10000000

current_segment *=*+4
next_segment_pc *=*+2
next_segment_byte_addr *=*+4
stmt_tokpos     *=*+1
label_pos       *=*+1
label_length    *=*+1

instr_line_pos        *=*+1
instr_mnemonic_id     *=*+1
instr_buf_pos         *=*+1
instr_addr_mode       *=*+2
instr_mode_rec_addr   *=*+2
instr_supported_modes *=*+2

symtbl_next_name *=*+3
last_pc_defined_global_label *=*+2
rellabels_next *=*+3

viewer_line_next *=*+4
viewer_buffer_next *=*+4

current_file    *=*+4
F_FILE_MASK     = %00000011
F_FILE_CBM      = %00000000
F_FILE_PLAIN    = %00000001
F_FILE_RUNNABLE = %00000010

expr_a          *=*+4
expr_b          *=*+4
expr_result     *=*+4
expr_flags      *=*+1
F_EXPR_BRACKET_MASK   = %00000011
F_EXPR_BRACKET_NONE   = %00000000
; - Entire expression surrounded by parentheses
F_EXPR_BRACKET_PAREN  = %00000001
; - Entire expression surrounded by square brackets
F_EXPR_BRACKET_SQUARE = %00000010
; - Entire expression is a char literal
F_EXPR_BRACKET_CHARLIT = %00000011
; - Hex/dec number literal with leading zero, or symbol assigned such a literal with =
F_EXPR_FORCE16   = %00000100
; - Expr contains undefined symbol
F_EXPR_UNDEFINED      = %00001000

tok_pos         *=*+1   ; Offset of tokbuf
line_pos        *=*+1   ; Offset of line_addr
err_code        *=*+1   ; Error code; 0=no error
line_addr       *=*+2   ; Addr of current BASIC line
code_ptr        *=*+2   ; 16-bit pointer, CPU
attic_ptr       *=*+4   ; 32-bit pointer, Attic
bas_ptr         *=*+4   ; 32-bit pointer, bank 0

; Reserve $1eff for easyasm-e.asm and autoboot.bas
prog_mem_dirty  *=*+1

!if * != $100 {
    !error "BP map not aligned to the end : ", *
}

dmajobs       = $58000

; Attic map
; (Make sure this is consistent with easyasm-e.asm.)
attic_start         = $08700000
; (Gap: 0.0000-0.1FFF = 8 KB)
attic_easyasm_stash = attic_start + $2000        ; 0.2000-0.D6FF
; (Gap: 0.D700-1.1FFF = $4900 = 18.25 KB)
attic_source_stash  = attic_start + $12000         ; 1.2000-1.D6FF
attic_symbol_table  = attic_source_stash + $b700   ; 1.D700-1.FFFF (10.25 KB)
attic_symbol_table_end = attic_symbol_table + $2900
   ; If symbol table has to cross a bank boundary, check code for 16-bit addresses. :|
attic_symbol_names  = attic_start + $20000         ; 2.0000-2.5FFF (24 KB)
attic_symbol_names_end = attic_symbol_names + $6000
attic_forced16s     = attic_symbol_names_end       ; 2.6000-2.7FFF (8 KB)
attic_forced16s_end = attic_forced16s + $2000
attic_rellabels     = attic_forced16s_end          ; 2.8000-2.8FFF (4 KB)
attic_rellabels_end = attic_rellabels + $1000
; (Gap: 2.9000-3.0000 = $7000 = 28 KB)
attic_segments      = attic_start + $30000         ; 3.0000-3.FFFF (64 KB)
attic_segments_end  = attic_segments + $10000
attic_viewer_lines = attic_segments_end            ; 4.0000-4.1FFF (8 KB)
attic_viewer_lines_end = attic_viewer_lines + $2000
attic_viewer_buffer = attic_viewer_lines_end       ; 4.2000-4.FFFF (56 KB)
attic_viewer_buffer_end = attic_viewer_buffer + $e000
; Save file cannot cross a bank boundary, limit 64 KB
attic_savefile_start = attic_start + $50000        ; 5.0000-5.FFFF (64 KB)
attic_savefile_max_end = attic_savefile_start + $10000

; - Symbol table entries are 8 bytes: (name_ptr_24, flags_8, value_32)
SYMTBL_ENTRY_SIZE = 8
SYMTBL_MAX_ENTRIES = (attic_symbol_table_end-attic_symbol_table) / SYMTBL_ENTRY_SIZE
; - Symbol is defined in the current pass; value is valid
F_SYMTBL_DEFINED  = %00000001
; - Symbol was assigned a number literal with leading zeroes
F_SYMTBL_LEADZERO = %00000010


; Other memory
source_start = $2000
max_end_of_program = $d6ff

; KERNAL routines
basin = $ffcf
bsout = $ffd2
chkin = $ffc6
ckout = $ffc9
close = $ffc3
close_all = $ff50
clrch = $ffcc
open = $ffc0
primm = $ff7d
readss = $ffb7
setbnk = $ff6b
setlfs = $ffba
setnam = $ffbd
save = $ffd8

; MEGA65 registers
dmaimm   = $d707
dmamb    = $d704
dmaba    = $d702
dmahi    = $d701
dmalo_e  = $d705
mathbusy = $d70f
divrema  = $d768
divquot  = $d76c
multina  = $d770
multinb  = $d774
product  = $d778
asciikey = $d610

; Character constants
chr_cr = 13
chr_spc = 32
chr_shiftspc = 160
chr_tab = 9
chr_uparrow = 94
chr_backarrow = 95
chr_megaat = 164
chr_doublequote = 34
chr_singlequote = 39


; Call a given KERNAL routine
!macro kcall .kaddr {
    pha
    lda #kernal_base_page
    tab
    pla
    jsr .kaddr
    pha
    lda #easyasm_base_page
    tab
    pla
}

; Call KERNAL primm
; Wrap string to print in +kprimm_start and +kprimm_end
!macro kprimm_start {
    pha
    lda #kernal_base_page
    tab
    pla
    jsr primm
}
!macro kprimm_end {
    pha
    lda #easyasm_base_page
    tab
    pla
}

!macro debug_print .msg {
    +kprimm_start
    !pet .msg
    !byte 0
    +kprimm_end
}

!macro debug_print16 .msg, .addr {
    lda #'['
    +kcall bsout
    +debug_print .msg
    lda .addr+1
    jsr print_hex8
    lda .addr
    jsr print_hex8
    lda #']'
    +kcall bsout
}

!macro push32 .addr {
    lda .addr
    pha
    lda .addr+1
    pha
    lda .addr+2
    pha
    lda .addr+3
    pha
}

!macro pull32 .addr {
    pla
    sta .addr+3
    pla
    sta .addr+2
    pla
    sta .addr+1
    pla
    sta .addr
}

!macro cmp16 .a, .b {
    lda .a+1
    cmp .b+1
    bne +
    lda .a
    cmp .b
+
}

; ------------------------------------------------------------
; Dispatch
; ------------------------------------------------------------

* = $2000

    jmp dispatch
id_string:
    !pet "easyasm v0.2",0

; 256-byte buffers for tokens and string processing
tokbuf: !fill $100
strbuf: !fill $100

; Initialize
; - Assume entry conditions (EasyAsm in program memory, B=$1e)
init:
    ; Init pointer banks
    lda #<(attic_easyasm_stash >>> 24)
    sta attic_ptr+3
    lda #^attic_easyasm_stash
    sta attic_ptr+2
    lda #<(attic_source_stash >>> 24)
    sta bas_ptr+3
    lda #^attic_source_stash
    sta bas_ptr+2

    lda #0
    sta asm_flags

    jsr init_symbol_table
    jsr init_segment_table
    jsr init_forced16
    jsr init_rellabel_table
    jsr init_viewer

    rts


; All entry into EasyAsm comes through here.
; MAPL = (E)500  MAPH = (8)300  B = $1Exx
; A = dispatch index (1-indexed)
dispatch:
    pha
    jsr init
    txa
    tay  ; Y = argument
    pla
    ; Continue to invoke_menu_option...

; A = menu option or 0 for menu, Y = argument (reserved)
invoke_menu_option:
    asl
    tax   ; X = A*2
    jmp (dispatch_jump,x)
dispatch_jump:
    !word do_menu
    !word assemble_to_memory_cmd
    !word assemble_to_disk_cmd
    !word view_annotated_source_cmd
    !word view_symbol_list_cmd
    !word dummy_menu_option
    !word dummy_menu_option
    !word dummy_menu_option
    !word run_test_suite_cmd
    !word restore_source_cmd

dummy_menu_option:
    rts

do_banner:
    +kprimm_start
    !pet "                                           ",13
    !pet 172,172,172," ",0
    +kprimm_end
    ldx #<id_string
    ldy #>id_string
    jsr print_cstr
    +kprimm_start
    !pet ", by dddaaannn ",187,187,187,"         ",13,13,0
    +kprimm_end
    rts

do_menu:
    lda #147
    +kcall bsout
    jsr do_banner

    ; Flush keyboard buffer
-   sta asciikey
    lda asciikey
    bne -

    +kprimm_start
    !pet "https://github.com/dansanderson/easyasm65",13,13
    !pet " 1. assemble and test",13
    !pet " 2. assemble to disk",13
    ; !pet " 3. view annotated source",13
    ; !pet " 4. view symbol list",13,13
    !pet 13," 9. restore source",13,13
    !pet " run/stop: close menu",13,13
    !pet " your choice? ",15,166,143,157,0  ; 198 bytes
    +kprimm_end

-   lda asciikey
    beq -
    sta asciikey
    cmp #3  ; Stop key
    beq @exit_menu
    cmp #'1'
    bcc -
    cmp #'9'
    beq +
    ; cmp #'4'+1
    cmp #'2'+1
    bcs -
+
    +kcall bsout
    pha
    lda #chr_cr
    +kcall bsout
    +kcall bsout
    pla
    sec
    sbc #'1'-1
    ldy #0
    jmp invoke_menu_option

@exit_menu
    +kprimm_start
    !pet "stop",13,0
    +kprimm_end
    lda #0
    sta $0091  ; Suppress Break Error (naughty!)
    rts


; ------------------------------------------------------------
; Assemble to Memory command
; ------------------------------------------------------------

; Input: expr_a = ptr to segment entry
do_overlap_error_segment:
    +kprimm_start
    !pet "  $",0
    +kprimm_end
    ldz #0
    ldq [expr_a]
    pha
    txa
    jsr print_hex8
    pla
    jsr print_hex8
    phz
    phy
    +kprimm_start
    !pet ", ",0
    +kprimm_end
    lda #0
    tay
    taz
    pla
    plx
    jsr print_dec32
    +kprimm_start
    !pet " bytes",13,0
    +kprimm_end
    rts

do_overlap_error:
    jsr do_any_segments_overlap
    bcs +
    rts
+   +kprimm_start
    !pet "cannot assemble when segments overlap:",13,0
    +kprimm_end
    ldq current_segment
    stq expr_a
    jsr do_overlap_error_segment
    ldq expr_result
    stq expr_a
    jsr do_overlap_error_segment
    sec
    rts

do_warning_prompt:
    lda asm_flags
    and #F_ASM_WARN
    bne +
    clc
    rts
+   +kprimm_start
    !pet 13,"press a key to run, or run/stop: ",15,166,143,157,0
    +kprimm_end
-   sta asciikey
    lda asciikey
    bne -
-   lda asciikey
    beq -
    sta asciikey
    cmp #3  ; Stop key
    bne +
    +kprimm_start
    !pet "stop",13,13,0
    +kprimm_end
    lda #0
    sta $0091  ; Suppress Break Error (naughty!)
    sec
    rts
+   +kprimm_start
    !pet "ok",13,13,0
    +kprimm_end
    clc
    rts

build_segment_dma_list:
    ; Use attic_ptr to build the job list.
    lda #<(dmajobs >>> 24)
    sta attic_ptr+3
    lda #^dmajobs
    sta attic_ptr+2
    lda #>dmajobs
    sta attic_ptr+1
    lda #<dmajobs
    sta attic_ptr

    sec
    jsr start_segment_traversal
    ; (Caller guarantees at least one segment.)
@loop
    jsr is_end_segment_traversal
    bcc +
    ; Terminate job list.
    sec
    lda attic_ptr
    sbc #install_segments_to_memory_dma_recsize
    sta attic_ptr
    lda attic_ptr+1
    sbc #0
    sta attic_ptr+1
    ldz #6
    lda #0  ; copy, last job
    sta [attic_ptr],z
    rts

+   ldz #0
    ldq [current_segment]
    sta install_segments_to_memory_dma_to
    stx install_segments_to_memory_dma_to+1
    sty install_segments_to_memory_dma_length
    stz install_segments_to_memory_dma_length+1
    lda #0
    sta expr_a+1
    sta expr_a+2
    sta expr_a+3
    lda #4
    sta expr_a
    ldq current_segment
    adcq expr_a
    sta install_segments_to_memory_dma_from
    stx install_segments_to_memory_dma_from+1
    tya
    and #$0f
    sta install_segments_to_memory_dma_from+2

    ; Copy job record to list
    ldx #install_segments_to_memory_dma_recsize-1
    ldz #install_segments_to_memory_dma_recsize-1
-   lda install_segments_to_memory_dma,x
    sta [attic_ptr],z
    dez
    dex
    bpl -

    ; Inc list ptr by record size
    clc
    lda attic_ptr
    adc #install_segments_to_memory_dma_recsize
    sta attic_ptr
    lda attic_ptr+1
    adc #0
    sta attic_ptr+1

    jsr next_segment_traversal_skip_file_markers
    bra @loop

install_segments_to_memory_dma:
!byte $80, <(attic_segments >>> 20)
!byte $81, $00
!byte $0b
!byte $00
!byte $04  ; copy + continue
install_segments_to_memory_dma_length:
!byte $00, $00
install_segments_to_memory_dma_from:
!byte $00, $00, $00
install_segments_to_memory_dma_to:
!byte $00, $00, $00
!byte $00, $00, $00
install_segments_to_memory_dma_end:
install_segments_to_memory_dma_recsize = install_segments_to_memory_dma_end - install_segments_to_memory_dma


assemble_to_memory_cmd:
    +kprimm_start
    !pet "# assembling...",13,13,0
    +kprimm_end

    ; Assemble, abort on assembly error.
    jsr assemble_source
    lda err_code
    beq +
    jsr print_error
    +kprimm_start
    !pet 13,"# assembly encountered an error",13,0
    +kprimm_end
    rts

    ; Error if segments overlap.
+   jsr do_overlap_error
    bcc +
    rts

    ; Error if a segment overlaps EasyAsm memory.
+   lda #$00
    ldx #$1e
    ldy #$00
    ldz #$01
    clc
    jsr does_a_segment_overlap
    bcc +
    +kprimm_start
    !pet "segment overlaps easyasm $1e00-ff, cannot assemble to memory",13,0
    +kprimm_end
    ldq current_segment
    stq expr_a
    jsr do_overlap_error_segment
    rts

    ; If warnings emitted, pause before continuing.
+   jsr do_warning_prompt
    bcc +
    rts

+   sec
    jsr start_segment_traversal
    ldz #0
    ldq [current_segment]
    inz
    ora [current_segment],z
    beq +  ; No assembled instructions? Skip install DMA.
    jsr build_segment_dma_list
    jsr start_segment_traversal
    ldz #0
    ldq [current_segment]
    jsr execute_user_program  ; A/X = PC
+

    +kprimm_start
    !pet 13,"# program returned, source restored",13,0
    +kprimm_end

    rts


; ------------------------------------------------------------
; View Annotated Source command
; ------------------------------------------------------------

view_annotated_source_cmd:
    lda asm_flags
    ora #F_ASM_SRC_TO_BUF
    sta asm_flags

    +kprimm_start
    !pet "# generating annotated source...",13,13,0
    +kprimm_end

    ; Assemble, abort on assembly error.
    jsr assemble_source
    lda err_code
    beq +
    jsr print_error
    +kprimm_start
    !pet 13,"# assembly encountered an error",13,0
    +kprimm_end
    rts

+   jsr activate_viewer

    +kprimm_start
    !pet 13,"# viewer ended",13,0
    +kprimm_end

    rts


; ------------------------------------------------------------
; View Symbols command
; ------------------------------------------------------------

write_symbol_list:
    rts

view_symbol_list_cmd:
    +kprimm_start
    !pet "# generating annotated source...",13,13,0
    +kprimm_end

    ; Assemble, abort on assembly error.
    jsr assemble_source
    lda err_code
    beq +
    jsr print_error
    +kprimm_start
    !pet 13,"# assembly encountered an error",13,0
    +kprimm_end
    rts
+
    jsr write_symbol_list
    jsr activate_viewer

    +kprimm_start
    !pet 13,"# viewer ended",13,0
    +kprimm_end

    rts


; ------------------------------------------------------------
; Assemble to Disk command
; ------------------------------------------------------------

; Inputs: X = tok_pos A, Y = tok_pos B
;   tokbuf at those positions = 32-bit segment addresses
; Output: C=0: A < B; C=1: A >= B
; Uses expr_b, program_counter
compare_segments_for_sort:
    lda tokbuf,x
    sta expr_b
    lda tokbuf+1,x
    sta expr_b+1
    lda tokbuf+2,x
    sta expr_b+2
    lda tokbuf+3,x
    sta expr_b+3
    ldz #0
    lda [expr_b],z
    sta program_counter
    inz
    lda [expr_b],z
    sta program_counter+1

    lda tokbuf,y
    sta expr_b
    lda tokbuf+1,y
    sta expr_b+1
    lda tokbuf+2,y
    sta expr_b+2
    lda tokbuf+3,y
    sta expr_b+3
    ldz #1
    lda program_counter+1
    cmp [expr_b],z
    bne +
    dez
    lda program_counter
    cmp [expr_b],z
+
    rts

; Inputs: X = tok_pos A, Y = tok_pos B
;   tokbuf at those positions = 32-bit segment addresses
; Outputs: entries swapped in tokbuf
; Uses expr_b
swap_segments_for_sort:
    jsr compare_segments_for_sort
    bcs +
    rts
+
    lda tokbuf,x
    sta expr_b
    lda tokbuf+1,x
    sta expr_b+1
    lda tokbuf+2,x
    sta expr_b+2
    lda tokbuf+3,x
    sta expr_b+3

    lda tokbuf,y
    sta tokbuf,x
    lda tokbuf+1,y
    sta tokbuf+1,x
    lda tokbuf+2,y
    sta tokbuf+2,x
    lda tokbuf+3,y
    sta tokbuf+3,x

    lda expr_b
    sta tokbuf,y
    lda expr_b+1
    sta tokbuf+1,y
    lda expr_b+2
    sta tokbuf+2,y
    lda expr_b+3
    sta tokbuf+3,y

    rts

; Inputs: Y=tokbuf pos, line_pos=strbuf pos
; Outputs: strbuf added 4 bytes; line_pos advanced; Y=new tokbuf pos
add_segment_entry_to_strbuf_for_merge:
    ldx line_pos
    ldz #4
-   lda tokbuf,y
    sta strbuf,x
    iny
    inx
    dez
    bne -
    stx line_pos
    rts

; Inputs: A=start A, X=end A+4=start B, Y=end B+4
; Outputs: merges sorted entry ranges in tokbuf
; Uses expr_a, expr_b, strbuf, line_pos
merge_segments_for_sort:
    pha  ; hoo boy, this is for the very end

    sta expr_a    ; expr_a[0] = A list pos
    stx expr_a+1  ; expr_a[1] = B list pos
    stx expr_a+2  ; expr_a[2] = A list end+4
    sty expr_a+3  ; expr_a[3] = B list end+4
    lda #0
    sta line_pos  ; line_pos = strbuf pos

    ; Assumes each list has at least one element.
@merge_loop
    ldx expr_a
    ldy expr_a+1
    jsr compare_segments_for_sort
    bcs +
    ; Consume A
    ldy expr_a
    jsr add_segment_entry_to_strbuf_for_merge
    cpy expr_a+2
    beq @rest_of_b
    sty expr_a
    bra @merge_loop
+   ; Consume B
    ldy expr_a+1
    jsr add_segment_entry_to_strbuf_for_merge
    cpy expr_a+3
    beq @rest_of_a
    sty expr_a+1
    bra @merge_loop

@rest_of_a
    ; Consume rest of A
    ldy expr_a
-   jsr add_segment_entry_to_strbuf_for_merge
    cpy expr_a+2
    bne -
    bra @copy_strbuf_to_tokbuf
@rest_of_b
    ; Consume rest of B
    ldy expr_a+1
-   jsr add_segment_entry_to_strbuf_for_merge
    cpy expr_a+3
    bne -
@copy_strbuf_to_tokbuf
    lda line_pos
    taz
    ldx #0
    pla
    tay
-   lda strbuf,x
    sta tokbuf,y
    inx
    iny
    dez
    bne -
    rts

; Inputs: X = start tok_pos, Y = end tok_pos+1
;   tokbuf in that range = list of 32-bit segment addresses
; Outputs: tokbuf sorted; tok_pos reset to tokbuf length
; Called recursively.
; Uses expr_a[0:1], expr_b internally, protected across recursive calls.
sort_segment_list:
    stx expr_a
    sty expr_a+1
    tya
    sec
    sbc expr_a
    cmp #8
    bcs +
    ; < 2 items
    rts
+   bne ++
    ; = 2 items
    ; (Special-casing 2 entries makes midpoint calculation easier later.)
    lda expr_a
    tax
    inc
    inc
    inc
    inc
    tay
    jsr swap_segments_for_sort
    rts

++  ; > 2 items
    asr
    asr  ; A = # of items
    asr  ; A = floor(# of items / 2)
    asl
    asl  ; A = tokbuf offset from X to midpoint entry
    adc expr_a  ; A = start + midpoint offset

    ; sort_segment_list(expr_a[0], A)
    tay
    pha
    lda expr_a
    pha
    lda expr_a+1
    pha
    ldx expr_a
    jsr sort_segment_list
    pla
    sta expr_a+1
    pla
    sta expr_a
    pla

    ; sort_segment_list(A, expr_a[1])
    tax
    pha
    lda expr_a
    pha
    lda expr_a+1
    pha
    tay
    jsr sort_segment_list
    pla
    sta expr_a+1
    pla
    sta expr_a
    pla

    ; merge [expr_a[0],A) and [A, expr_a[1])
    ; (Clobbers expr_a, but that's ok)
    tax
    lda expr_a
    ldy expr_a+1
    jsr merge_segments_for_sort
    rts


; Inputs: current_file; current_segment = first segment; assembled segments
; Outputs:
;   current_segment advanced to next file marker or null terminator
;   segment table entry addresses to tokbuf
;   tok_pos is index beyond list; number of segments = tok_pos/4
;   C=1: too many segments (max 64), result invalid
generate_segment_list_for_file:
    lda #0
    sta tok_pos

@loop
    ldx tok_pos
    lda current_segment
    sta tokbuf,x
    inx
    lda current_segment+1
    sta tokbuf,x
    inx
    lda current_segment+2
    sta tokbuf,x
    inx
    lda current_segment+3
    sta tokbuf,x
    inx
    stx tok_pos

    cpx #0
    bne +
    sec
    rts
+

    jsr next_segment_traversal
    jsr is_end_segment_traversal
    bcc +
    bra @end
+   jsr is_file_marker_segment_traversal
    lbcc @loop
@end

    ; Sort tokbuf by segment PC
    ldx #0
    ldy tok_pos
    jsr sort_segment_list

    clc
    rts


; Input: current_file = file marker
print_current_filename:
    ldz #4
    ldq [current_file]
    sta line_addr
    stx line_addr+1
    sty bas_ptr+2
    stz bas_ptr+3
    ldz #8
    lda [current_file],z
    tay
    ldx #0
    jsr print_bas_str
    rts

; Input: current_file = file marker
print_current_filetype:
    ldz #9
    lda [current_file],z
    and #F_FILE_MASK
    cmp #F_FILE_CBM
    bne +
    ldx #<kw_cbm
    ldy #>kw_cbm
    bra ++
+   cmp #F_FILE_PLAIN
    bne +
    ldx #<kw_plain
    ldy #>kw_plain
    bra ++
+   ldx #<kw_runnable
    ldy #>kw_runnable
++  jsr print_cstr
    rts


; Input: current_segment -> segment header
; Output:
;   program_counter = segment PC
;   expr_a = size
get_header_for_current_segment:
    ldz #0
    lda [current_segment],z
    sta program_counter
    inz
    lda [current_segment],z
    sta program_counter+1  ; program_counter = segment PC
    inz
    lda [current_segment],z
    sta expr_a
    inz
    lda [current_segment],z
    sta expr_a+1
    lda #0
    sta expr_a+2
    sta expr_a+3  ; expr_a = size
    rts

; Inputs:
;   program_counter = PC of last file
;   expr_b = size of last file
;   current_segment -> current segment header
; Outputs:
;   expr_a = size of zero fill
calculate_zero_fill:
    ; this PC - prev PC - expr_b = size of zero fill
    ldz #0
    lda [current_segment],z
    sec
    sbc program_counter
    sta expr_a
    inz
    lda [current_segment],z
    sbc program_counter+1
    sta expr_a+1
    lda #0
    sta expr_a+2
    sta expr_a+3  ; expr_a = this PC - prev PC
    ldq expr_a
    sec
    sbcq expr_b
    stq expr_a    ; expr_a = size of zero fill
    rts

append_zero_fill_dma:
!byte $81, <(attic_savefile_start >> 20)
!byte $0b, $00
!byte $03
append_zero_fill_length: !byte $00, $00
!byte $00, $00, $00
append_zero_fill_dest: !byte $00, $00, $00
!byte $00, $00, $00

; Input: expr_a = number of zeroes to write
;   attic_ptr = dest
; Outputs: attic_ptr advanced
append_zero_fill:
    lda attic_ptr
    sta append_zero_fill_dest
    lda attic_ptr+1
    sta append_zero_fill_dest+1
    lda attic_ptr+2
    and #$0f
    sta append_zero_fill_dest+2

    lda expr_a
    sta append_zero_fill_length
    lda expr_a+1
    sta append_zero_fill_length+1

    lda #$00
    sta dmaba
    sta dmamb
    lda #>append_zero_fill_dma
    sta dmahi
    lda #<append_zero_fill_dma
    sta dmalo_e

    ldq expr_a
    clc
    adcq attic_ptr
    stq attic_ptr
    rts

append_to_save_file_dma:
!byte $80
append_to_save_file_source_mb: !byte $00
!byte $81, <(attic_savefile_start >> 20)
!byte $0b, $00
!byte $00
append_to_save_file_length: !byte $00, $00
append_to_save_file_source: !byte $00, $00, $00
append_to_save_file_dest: !byte $00, $00, $00
!byte $00, $00, $00

; Inputs: expr_result = start addr (32-bit); expr_a = length (16-bit)
;   attic_ptr = dest
; Outputs: attic_ptr advanced
append_to_save_file:
    ; Start address: $0abcdefg
    ; append_to_save_file_source_mb = $ab
    ; append_to_save_file_source = $fg $de $0c
    lda expr_result+3
    asl
    asl
    asl
    asl
    sta expr_result+3  ; (corrupt expr_result+3)
    lda expr_result+2
    lsr
    lsr
    lsr
    lsr
    ora expr_result+3
    sta append_to_save_file_source_mb
    lda expr_result+2
    and #$0f
    sta append_to_save_file_source+2
    lda expr_result+1
    sta append_to_save_file_source+1
    lda expr_result
    sta append_to_save_file_source

    lda expr_a
    sta append_to_save_file_length
    lda expr_a+1
    sta append_to_save_file_length+1

    lda attic_ptr
    sta append_to_save_file_dest
    lda attic_ptr+1
    sta append_to_save_file_dest+1
    lda attic_ptr+2
    and #$0f
    sta append_to_save_file_dest+2

    lda #$00
    sta dmaba
    sta dmamb
    lda #>append_to_save_file_dma
    sta dmahi
    lda #<append_to_save_file_dma
    sta dmalo_e

    ldq expr_a
    clc
    adcq attic_ptr
    stq attic_ptr
    rts

; Inputs: program_counter = PC, expr_a = size
print_segment_msg:
    ; Print segment msg
    +kprimm_start
    !pet "  $",0
    +kprimm_end
    lda program_counter+1
    jsr print_hex8
    lda program_counter
    jsr print_hex8
    +kprimm_start
    !pet ", ",0
    +kprimm_end
    ldq expr_a
    jsr print_dec32
    +kprimm_start
    !pet " bytes",13,0
    +kprimm_end
    rts

; Writes formatted file to attic_savefile_start
; Input: current_file; tokbuf, tok_pos=end with sorted segments
write_file_to_attic:
    ; Stash current_segment so we can reuse some routines.
    ldq current_segment
    stq bas_ptr

    ldq tokbuf
    stq current_segment
    jsr get_header_for_current_segment

    lda #^attic_savefile_start
    sta attic_ptr+2
    lda #<(attic_savefile_start >>> 24)
    sta attic_ptr+3

    ldz #9
    lda [current_file],z
    and #F_FILE_MASK
    cmp #F_FILE_RUNNABLE
    beq @start_runnable

    ; Set Attic memory start position to align with PC
    ; (required for SAVE later to get the PC correct)
    lda program_counter
    sta attic_ptr
    inz
    lda program_counter+1
    sta attic_ptr+1
    bra @start_segment_loop

@start_runnable
    ; Set Attic memory start position to source_start + 1.
    lda #<(source_start+1)
    sta attic_ptr
    lda #>(source_start+1)
    sta attic_ptr+1

    ; Write the runnable bootstrap.
    lda #<bootstrap_basic_preamble
    ldx #>bootstrap_basic_preamble
    ldy #$00
    ldz #$00
    stq expr_result
    lda #<(bootstrap_basic_preamble_end-bootstrap_basic_preamble)
    ldx #>(bootstrap_basic_preamble_end-bootstrap_basic_preamble)
    ldy #$00
    ldz #$00
    stq expr_a
    jsr append_to_save_file

@start_segment_loop

    ldy #0  ; token list position
@segment_loop
    cpy tok_pos
    lbeq @end_segment_loop
    phy  ; Stash segment list position

    ; current_segment = this segment's address (from segment list)
    lda tokbuf,y
    sta current_segment
    lda tokbuf+1,y
    sta current_segment+1
    lda tokbuf+2,y
    sta current_segment+2
    lda tokbuf+3,y
    sta current_segment+3

    cpy #0
    beq +
    ; Not first segment, fill with zeroes
    ; Expects program_counter and expr_b=size from previous loop
    jsr calculate_zero_fill
    jsr append_zero_fill
+

    jsr get_header_for_current_segment
    ; program_counter = PC, expr_a = size
    ldq expr_a
    stq expr_b  ; Remember size for zero fill later

    jsr print_segment_msg
    lda #0
    tax
    tay
    taz
    lda #4  ; Q = 4
    clc
    adcq current_segment
    stq expr_result
    ; expr_result = start = current_segment + 4
    jsr append_to_save_file

    ply  ; Advance segment list position
    iny
    iny
    iny
    iny
    lbra @segment_loop

@end_segment_loop
    ; Restore outer file loop's current_segment
    ldq bas_ptr
    stq current_segment
    rts


; Input: assembled segment table with file markers
; Output: err_code>0 fatal error, abort
create_files_for_segments:
    clc
    jsr start_segment_traversal

    ; No segments at all? Say so, exit ok.
    jsr is_end_segment_traversal
    bcc +
    +kprimm_start
    !pet "nothing to do",13,0
    +kprimm_end
    rts
+
    ; First segment not a file marker? Error.
    jsr is_file_marker_segment_traversal
    bcs +
    lda #err_segment_without_a_file
    sta err_code
    lda #$00
    sta line_addr
    sta line_addr+1
    rts
+

@file_loop
    ; current_segment is a file marker.
    ldq current_segment
    stq current_file
    jsr next_segment_traversal
    lda #chr_doublequote
    +kcall bsout
    jsr print_current_filename
    +kprimm_start
    !pet "\", ",0
    +kprimm_end
    jsr print_current_filetype

    ; Check for empty file states.
    jsr is_end_segment_traversal
    bcs +
    jsr is_file_marker_segment_traversal
    bcc ++
+   +kprimm_start
    !pet ": no segments for file, skipping",13,0
    +kprimm_end
    jsr is_file_marker_segment_traversal
    bcs @file_loop
    ; Early end of segments.
    rts
++  lda #':'
    +kcall bsout
    lda #chr_cr
    +kcall bsout

    ; Generate segment list for file on tokbuf, sorted by PC.
    ; This advances current_segment to the next file marker,
    ; for the end of the file loop to test.
    jsr generate_segment_list_for_file
    bcc +
    lda #err_out_of_memory
    sta err_code
    lda #$00
    sta line_addr
    sta line_addr+1
    rts
+
    ; Confirm runnable type only has one segment at bootstrap location
    ldz #9
    lda [current_file],z
    and #F_FILE_MASK
    cmp #F_FILE_RUNNABLE
    bne ++
    lda tok_pos
    cmp #4
    bne +
    ldq tokbuf
    stq expr_a
    ldz #0
    lda [expr_a],z
    cmp #<bootstrap_ml_start
    bne +
    inz
    lda [expr_a],z
    cmp #>bootstrap_ml_start
    beq ++
+   lda #err_runnable_wrong_segments
    sta err_code
    lda #$00
    sta line_addr
    sta line_addr+1
    rts
++

    jsr write_file_to_attic
    lda attic_ptr+2
    cmp #^attic_savefile_start
    beq +
    ; Total file size exceeds 64 KB, abort with error
    lda #err_out_of_memory
    sta err_code
    lda #$00
    sta line_addr
    sta line_addr+1
    rts
+

    ; Copy "@:" and filename to strbuf, use it for filename
    lda #'@'
    sta strbuf
    lda #':'
    sta strbuf+1
    ldz #4
    ldq [current_file]  ; Q = address of filename
    stq expr_a
    ldz #8
    lda [current_file],z  ; A = filename length
    tay     ; Y = length
    ldx #2  ; strbuf pos
    ldz #0  ; data pos
-   lda [expr_a],z
    sta strbuf,x
    inx
    inz
    dey
    bne -

    ; Set up the file
    lda #($80 | <(attic_savefile_start >>> 24)); file MB
    ldy #^attic_savefile_start
    ldx #$00
    +kcall setbnk
    ldx #<strbuf
    ldy #>strbuf
    ldz #8
    lda [current_file],z  ; A = filename length
    inc
    inc  ; For "@:" prefix
    +kcall setnam
    lda #2    ; logical address 2
    ldx #1    ; default device
    ldy #2    ; disks want a secondary address
    +kcall setlfs

    ; Determine the starting address for SAVE
    ldz #9
    lda [current_file],z
    and #F_FILE_MASK
    cmp #F_FILE_RUNNABLE
    beq +
    ; cbm starts at first PC
    ldy #0
    ldq tokbuf,y
    stq expr_b
    ldz #0
    lda [expr_b],z
    sta $00fe
    inz
    lda [expr_b],z
    sta $00ff
    bra ++
+   ; Runnable starts at source_start+1
    lda #<(source_start+1)
    sta $00fe
    lda #>(source_start+1)
    sta $00ff

    ; X/Y = 16-bit end address + 1
++  ldx attic_ptr
    ldy attic_ptr+1
    +kcall save
    bcs @kernal_disk_error

    ; There might be a drive error at this point. Reading it would require
    ; more dispatch code to open the command channel, so I'm going to leave it
    ; for now and let the user type the @ command to test disk status.

    ; (current_segment advanced to next file marker or end by
    ; generate_segment_list_for_file earlier. Preserved by
    ; write_file_to_attic.)
    jsr is_end_segment_traversal
    lbcc @file_loop
    rts

@kernal_disk_error
    ; A = error code
    pha
    +kcall clrch
    pla
    dec
    asl
    tax
    lda kernal_error_messages+1,x
    tay
    lda kernal_error_messages,x
    tax
    jsr print_cstr
    lda #','
    +kcall bsout
    lda #' '
    +kcall bsout
    lda #err_disk_error
    sta err_code
    lda #$00
    sta line_addr
    sta line_addr+1
    rts


assemble_to_disk_cmd:
    +kprimm_start
    !pet "# assembling to disk...",13,13,0
    +kprimm_end

    ; Assemble, abort on assembly error.
    jsr assemble_source
    lda err_code
    lbne @assemble_to_disk_error

    ; Error if segments overlap.
    jsr do_overlap_error
    lbcs @assemble_to_disk_error_no_pos

    ; If warnings emitted, pause before continuing.
    jsr do_warning_prompt
    bcc +
    rts
+

    jsr create_files_for_segments
    lda err_code
    bne @assemble_to_disk_error_no_pos

    +kprimm_start
    !pet 13,13,"# assemble to disk complete",13,0
    +kprimm_end
    rts

@assemble_to_disk_error_no_pos
    lda #$ff
    sta line_pos
@assemble_to_disk_error
    jsr print_error
    +kprimm_start
    !pet 13,13,"# assemble to disk aborted due to error",13,13,0
    +kprimm_end
    rts


; ------------------------------------------------------------
; Restore Source command
; ------------------------------------------------------------

restore_source_cmd:
    ; Actually do nothing. Allow 1e00 dispatch to restore source.

    +kprimm_start
    !pet 13,"# source restored",13,0
    +kprimm_end

    rts


; ------------------------------------------------------------
; Utilities
; ------------------------------------------------------------

; Print a C-style string
; Input: X/Y address (bank 0)
print_cstr:
    ; Manage B manually, for speed
    lda #kernal_base_page
    tab

    stx $fc   ; B=0
    sty $fd
    lda #$00
    sta $fe
    sta $ff

-   ldz #0
    lda [$fc],z
    beq +
    jsr bsout
    inw $fc
    bra -
+
    ; Restore B
    lda #easyasm_base_page
    tab
    rts


; Print a string from a source line
; Input: line_addr, X=line pos, Y=length; bas_ptr bank and megabyte
print_bas_str:
    lda line_addr
    sta $00fc
    lda line_addr+1
    sta $00fd
    lda bas_ptr+2
    sta $00fe
    lda bas_ptr+3
    sta $00ff

    ; Manage B manually, for speed
    lda #kernal_base_page
    tab

    txa
    taz
-   lda [$fc],z
    jsr bsout
    inz
    dey
    bne -

    ; Restore B
    lda #easyasm_base_page
    tab
    rts


; Input:
;   Q = 32-bit value (ZYXA)
;   C: 0=unsigned, 1=signed
print_dec32:
    ; Use strbuf like so:
    ; $00: negative sign or null
    ; $01-$0B: 10 final characters, null terminated
    ; $0C-$10: 5 BCD bytes
    ; $11-$14: 4 binary bytes
    sta strbuf+$11
    stx strbuf+$12
    sty strbuf+$13
    stz strbuf+$14
    ldx #$10
    lda #0
-   sta strbuf,x
    dex
    bpl -

    bcc @unsigned_continue
    tza
    bpl @unsigned_continue
    lda #$ff       ; Negate value
    tax
    tay
    taz
    eorq strbuf+$11
    inq
    stq strbuf+$11
    lda #'-'       ; Put negative sign in string buffer
    sta strbuf
@unsigned_continue

    ; Using BCD mode, double-with-carry each binary digit of $11-$14 into
    ; $0C-$10. Do 16 bits at a time.
    sed
    ldx #16
-   row strbuf+$13
    ldy #5
--  lda strbuf+$0c-1,y
    adc strbuf+$0c-1,y
    sta strbuf+$0c-1,y
    dey
    bne --
    dex
    bne -
    ldx #16
-   row strbuf+$11
    ldy #5
--  lda strbuf+$0c-1,y
    adc strbuf+$0c-1,y
    sta strbuf+$0c-1,y
    dey
    bne --
    dex
    bne -
    cld

    ; Convert BCD in $0C-$10 to PETSCII digits in $01-$0B.
    ldx #4
-   txa
    asl
    tay   ; Y = 2*x
    lda strbuf+$0c,x
    lsr
    lsr
    lsr
    lsr
    clc
    adc #'0'
    sta strbuf+$01,y
    lda strbuf+$0c,x
    and #$0f
    clc
    adc #'0'
    sta strbuf+$02,y
    dex
    bpl -

    ; Slide PETSCII digits left to eliminate leading zeroes.
-   lda strbuf+$01
    cmp #'0'
    bne @written_continue
    ldx #$02
--  lda strbuf,x
    sta strbuf-1,x
    inx
    cpx #$0b
    bne --
    lda #0
    sta strbuf-1,x
    bra -

@written_continue
    lda #0
    sta strbuf+$0c
    lda strbuf+$01  ; Edge case: 0
    bne +
    lda #'0'
    sta strbuf+$01
+
    ; Test for negative sign, and either print from sign or from first digit.
    ldx #<strbuf
    ldy #>strbuf
    lda strbuf
    bne +
    inx      ; (assume doesn't cross a page boundary)
+   jsr print_cstr
    rts


; Input: A = 8-bit value
print_hex8:
    jsr hex_az
    pha
    tza
    +kcall bsout
    pla
    +kcall bsout
    rts

; Input: A = byte
; Output: A/Z = hex digits
hex_az:
    pha
    lsr
    lsr
    lsr
    lsr
    jsr hex_nyb
    taz
    pla

hex_nyb:
    and #15
    cmp #10
    bcc +
    adc #6
+   adc #'0'
    rts

; Input: err_code, line_pos, line_addr
; - If line_pos = $FF, don't print line
; - If line_addr = $0000, don't print line number
print_error:
    lda err_code
    bne +        ; zero = no error
    rts
+

    dec
    asl
    tax
    lda err_message_tbl+1,x
    tay
    lda err_message_tbl,x
    tax
    jsr print_cstr

    lda line_addr
    ora line_addr+1
    bne +
    lda #chr_cr
    +kcall bsout
    rts
+

    +kprimm_start
    !pet " in line ",0
    +kprimm_end

    lda line_addr
    sta bas_ptr
    lda line_addr+1
    sta bas_ptr+1
    ldz #3
    lda [bas_ptr],z        ; line number high
    tax
    dez
    lda [bas_ptr],z        ; line number low
    ldy #0
    ldz #0
    clc                    ; request unsigned
    pha
    phx
    jsr print_dec32
    lda #chr_cr
    +kcall bsout

    ; Skip printing line if line_pos = $ff
    lda line_pos
    cmp #$ff
    bne +
    pla
    pla
    rts

    ; Print line number again.
+   lda #chr_cr
    +kcall bsout
    plx
    pla
    ldy #0
    ldz #0
    clc                    ; request unsigned
    jsr print_dec32
    ; Sneak a peek at strbuf to get the line number length + 1
    ldx #0
-   inx
    lda strbuf,x
    bne -
    phx

    ; Print the source code line
    lda #chr_spc
    +kcall bsout
    inw bas_ptr
    inw bas_ptr
    inw bas_ptr
    inw bas_ptr
    ldz #0
    ldx #0
-   lda [bas_ptr],z
    sta strbuf,x
    beq +
    inz
    inx
    bra -
+   ldx #<strbuf
    ldy #>strbuf
    jsr print_cstr
    lda #chr_cr
    +kcall bsout

    ; Print an error position marker
    plx           ; Indent by width of line number + 1
-   lda #chr_spc
    +kcall bsout
    dex
    bne -
    ldx line_pos   ; Indent by line_pos - 4
    dex
    dex
    dex
    dex
    beq +
-   lda #chr_spc
    +kcall bsout
    dex
    bne -
+   lda #chr_uparrow
    +kcall bsout
    lda #chr_cr
    +kcall bsout

    rts


; (Used by print_warning and do_warn)
; Inits bas_ptr=line_addr for caller to use
print_warning_line_number:
    +kprimm_start
    !pet "line ",0
    +kprimm_end
    lda line_addr
    sta bas_ptr
    lda line_addr+1
    sta bas_ptr+1
    ldz #3
    lda [bas_ptr],z        ; line number high
    tax
    dez
    lda [bas_ptr],z        ; line number low
    ldy #0
    ldz #0
    clc                    ; request unsigned
    jsr print_dec32
    +kprimm_start
    !pet ": ",0
    +kprimm_end
    rts


; Input: A=warning ID
; Output: prints message with line number, sets F_ASM_WARN
print_warning:
    pha
    jsr print_warning_line_number
    pla
    dec
    asl
    tax
    lda warn_message_tbl+1,x
    tay
    lda warn_message_tbl,x
    tax
    jsr print_cstr

    lda #chr_cr
    +kcall bsout

    lda asm_flags
    ora #F_ASM_WARN
    sta asm_flags
    rts


; Test whether A is a letter
; Input: A=char
; Output: C: 0=no 1=yes
is_letter:
    ; I'm leaving Acme's converstion table set to "raw" so I'm forced to
    ; understand this explicitly. PETSCII has two sets of uppercase letters.
    cmp #'A'     ; $41 = PETSCII lower A
    bcc ++
    cmp #'Z'+1   ; $5A = PETSCII lower Z
    bcc +
    cmp #'a'     ; $61 = PETSCII upper A
    bcc ++
    cmp #'z'+1   ; $7A = PETSCII upper A
    bcc +
    cmp #193     ; $C1 = PETSCII Shift-A
    bcc ++
    cmp #218+1   ; $DA = PETSCII Shift-Z
    bcc +
    clc
    rts
+   sec
++  rts


; Test whether A is a secondary identifier character
; Input: A=char
; Output: C: 0=no 1=yes
is_secondary_ident_char:
    cmp #'0'
    bcc +
    cmp #'9'+1
    bcc ++
+   cmp #chr_backarrow
    beq ++
    cmp #chr_megaat
    beq ++
    cmp #'.'
    bne +++
++  sec
    rts
+++ jmp is_letter

; Test whether A is whitespace on a line
; (Does not include CR.)
; Input: A=char
; Output: C: 0=no 1=yes
is_space:
    cmp #chr_spc
    beq +
    cmp #chr_shiftspc
    beq +
    cmp #chr_tab
    beq +
    clc
    bra ++
+   sec
++  rts

; Input: A=char
; Output: A=lowercase letter, or original char if not letter
to_lowercase:
    jsr is_letter
    bcc +
    cmp #'Z'+1
    bcc +           ; already lower
    sec
    sbc #'a'-'A'
    cmp #193-('a'-'A')
    bcc +           ; lowered from first upper bank
    sec
    sbc #193-'a'    ; lowered from second upper bank
+   rts


; Input: strbuf contains null-terminated string
; Output: letters of strbuf changed to lowercase
strbuf_to_lowercase:
    ldx #0
-   lda strbuf,x
    beq +
    jsr to_lowercase
    sta strbuf,x
    inx
    bra -
+   rts


; Input: strbuf, code_ptr; X=strbuf start pos, Z=max length
; Output:
;   strbuf < code_ptr: A=$ff
;   strbuf = code_ptr: A=$00
;   strbuf > code_ptr; A=$01
;   X=strbuf last pos
strbuf_cmp_code_ptr:
    ldy #0
-   cpz #0
    beq @is_equal
    lda strbuf,x
    cmp (code_ptr),y
    bcc @is_less_than
    bne @is_greater_than
    lda strbuf,x
    beq @is_equal  ; null term before max length
    inx
    iny
    dez
    bra -

@is_less_than:
    lda #$ff
    rts
@is_equal:
    lda #$00
    rts
@is_greater_than:
    lda #$01
    rts


; ------------------------------------------------------------
; Viewer
; ------------------------------------------------------------
; attic_viewer_lines: (addr16) = lower 16 of viewer buffer address
; attic_viewer_buffer: 0-terminated lines
init_viewer:
    lda #<attic_viewer_lines
    sta viewer_line_next
    lda #>attic_viewer_lines
    sta viewer_line_next+1
    lda #^attic_viewer_lines
    sta viewer_line_next+2
    lda #<(attic_viewer_lines >>> 24)
    sta viewer_line_next+3

    ldz #0
    lda #<attic_viewer_buffer
    sta viewer_buffer_next
    sta [viewer_line_next],z
    inz
    lda #>attic_viewer_buffer
    sta viewer_buffer_next+1
    sta [viewer_line_next],z
    lda #^attic_viewer_buffer
    sta viewer_buffer_next+2
    lda #<(attic_viewer_buffer >>> 24)
    sta viewer_buffer_next+3

    inw viewer_line_next
    inw viewer_line_next
    rts

; Inputs: A=char to print
; Outputs:
;   C=0 success
;   C=1 out of memory
bufprint_chr:
    ; (Assumes 0 < high byte <= $ff within buffer.)
    ldx viewer_buffer_next+1
    bne +
    sec
    rts
+
    ; Convert carriage returns to null terminators.
    cmp #chr_cr
    bne +
    lda #0
+
    ldz #0
    sta [viewer_buffer_next],z
    inw viewer_buffer_next

    ; Null terminator adds a line record.
    cmp #0
    bne +
    lda viewer_buffer_next
    sta [viewer_line_next],z
    inz
    lda viewer_buffer_next+1
    sta [viewer_line_next],z
    inw viewer_line_next
    inw viewer_line_next
+

    clc
    rts

; Macro to print a PETSCII string literal to the view buffer
; Automatically null-terminates, so the argument doesn't have to.
; String must be < 255 characters
!macro bufprint_strlit .str {
    lda #<.data
    sta code_ptr
    lda #>.data
    sta code_ptr+1
    ldy #0
-   lda (code_ptr),y
    phy
    jsr bufprint_chr
    ply
    lda (code_ptr),y
    bne -
    bra +
.data !pet .str,0
+
}

; Input: A=value whose hex value to write to the buffer
bufprint_hex8:
    jsr hex_az
    pha
    tza
    jsr bufprint_chr
    pla
    jsr bufprint_chr
    rts

; Input: bas_ptr = start of text of source line
bufprint_line:
    ldz #0
    ldx #0
-   lda [bas_ptr],z
    beq +
    phx : phz
    jsr bufprint_chr
    plz : plx
    inz
    inx
    bra -
+
    lda #0
    jsr bufprint_chr
    rts


activate_viewer:
    rts


; ------------------------------------------------------------
; Tokenizer
; ------------------------------------------------------------

; Skip over whitespace, and also a line comment if found after whitespace
; Input: bas_ptr = line_addr, line_pos
; Output: line_pos advanced maybe; A=last read, Zero flag if zero
accept_whitespace_and_comment:
    lda line_pos
    taz
-   lda [bas_ptr],z
    tax
    jsr is_space
    bcc +
    inz
    bra -
+   cmp #';'   ; Traditional line comments
    beq @do_comment
    cmp #'/'   ; C-style line comments
    bne ++
    inz
    lda [bas_ptr],z
    dez
    cmp #'/'
    bne ++
@do_comment
-   inz            ; Ignore comment to end of line
    lda [bas_ptr],z
    tax
    bne -

++  stz line_pos
    txa   ; Set flags
    rts


; Consume identifier
; Input:
;   bas_ptr = line_addr
;   Z = line_pos
;   C: 0=must start with letter, 1=allow non-letter start
; Output:
;   If found, C=1, Z advanced (line_pos not)
;   If not found, C=0, Z = unchanged
accept_ident:
    bcs +
    ; Must start with letter
    lda [bas_ptr],z
    jsr is_letter
    bcs +
    clc
    rts
+
    ; Can be followed by letter, number, back-arrow, Mega+@
-   inz
    lda [bas_ptr],z
    jsr is_secondary_ident_char
    bcs -
    sec
    rts


; Input: expr_result
; Output: expr_result = expr_result * 10
;   Overwrites expr_a
;   Preserves Z
expr_times_ten:
    phz
    ldq expr_result
    rolq
    stq expr_a
    rolq
    rolq
    adcq expr_a
    stq expr_result
    plz
    rts

; Accept a number/char literal
; Input: bas_ptr=line_addr, line_pos
; Output:
;  C: 0=not found, line_pos unchanged
;  C: 1=found; expr_result=value; line_pos advanced
;  expr_flags F_EXPR_FORCE16 bit set if hex or dec literal has a leading zero
accept_literal:
    ; Init expr zero flag to 0.
    lda expr_flags
    and #!F_EXPR_FORCE16
    sta expr_flags

    lda line_pos
    taz

    lda #0
    sta expr_result
    sta expr_result+1
    sta expr_result+2
    sta expr_result+3

    lda [bas_ptr],z
    cmp #chr_singlequote
    bne ++
    ; Char literal
    inz
    lda [bas_ptr],z
    tax
    inz
    lda [bas_ptr],z
    cmp #chr_singlequote
    lbne @not_found
    stx expr_result
    inz
    lbra @found

++  ldx #0
    stx expr_b+1
    stx expr_b+2
    stx expr_b+3

    cmp #'$'
    lbeq @do_hex_literal
    cmp #'%'
    lbeq @do_binary_literal
    cmp #'0'
    lbcc @not_found
    cmp #'9'+1
    lbcc @do_decimal_literal

@not_found
    lda line_pos
    taz
    clc
    rts

@do_decimal_literal
    cmp #'0'
    bne +
    pha
    lda expr_flags
    ora #F_EXPR_FORCE16
    sta expr_flags
    pla
+
@do_decimal_literal_loop
    cmp #'0'
    lbcc @found
    cmp #'9'+1
    lbcs @found
    jsr expr_times_ten
    lda [bas_ptr],z
    sec
    sbc #'0'
    sta expr_b
    phz
    ldq expr_b
    clc
    adcq expr_result
    stq expr_result
    plz
    inz
    lda [bas_ptr],z
    lbra @do_decimal_literal_loop

@do_hex_literal
    ; Set up first digit, confirm it's a hex digit
    inz
    lda [bas_ptr],z
    cmp #'0'
    lbcc @not_found
    bne +
    pha
    lda expr_flags
    ora #F_EXPR_FORCE16
    sta expr_flags
    pla
+   cmp #'9'+1
    bcc +
    jsr to_lowercase
    cmp #'A'
    lbcc @not_found
    cmp #'F'+1
    lbcs @not_found
+

@do_hex_literal_loop
    cmp #'0'
    lbcc @found
    cmp #'9'+1
    bcs +
    ; 0-9
    sec
    sbc #'0'
    bra +++

+   jsr to_lowercase
    cmp #'A'
    lbcc @found
    cmp #'F'+1
    lbcs @found
    ; A-F
    sec
    sbc #'A'-10

+++ sta expr_b
    phz
    clc
    ldq expr_result
    rolq
    rolq
    rolq
    rolq
    adcq expr_b
    stq expr_result
    plz
    inz
    lda [bas_ptr],z
    bra @do_hex_literal_loop

@do_binary_literal
    ; Set up first digit, confirm it's a binary digit
    inz
    lda [bas_ptr],z
    cmp #'0'
    beq +
    cmp #'.'
    beq +
    cmp #'1'
    beq +
    cmp #'#'
    lbne @not_found

+
--- cmp #'1'
    beq ++
    cmp #'#'
    beq ++
    cmp #'0'
    beq +
    cmp #'.'
    lbne @found
+   ; 0
    clc
    bra +++
++  ; 1
    sec
+++ rolq expr_result
    inz
    lda [bas_ptr],z
    bra ---

@found
    stz line_pos
    sec
    rts


; Locate a substring of strbuf in a null-terminated list of null-terminated lowercase strings
; Input:
;   strbuf
;   A=starting count position
;   X=strbuf start pos
;   code_ptr = first char of first item in match list
;   C: 0=no restrictions; 1=next cannot be ident char
; Output:
;   If found, C=1, Y=entry number counted from zero, X=strbuf pos of next char
;   If not found, C=0
find_item_count = expr_a
find_start_pos = expr_a+1
find_item_length = expr_a+2
find_word_boundary = expr_a+3
find_in_token_list:
    sta find_item_count
    stx find_start_pos
    lda #0
    bcc +
    inc
+   sta find_word_boundary

@next_item
    ldz #0
    lda (code_ptr),z
    beq @find_fail
    ; Z = item length
-   inz
    lda (code_ptr),z
    bne -
    stz find_item_length

    ldx find_start_pos
    jsr strbuf_cmp_code_ptr
    bne +
    ; Item of length N has matched N characters in strbuf.
    ; Word boundary not requested? Accept prefix.
    lda find_word_boundary
    beq @find_success
    ; Word boundary requested, next strbuf char must be non-word char.
    lda strbuf,x
    jsr is_secondary_ident_char
    bcc @find_success
    ; strbuf has more word chars, so this is not a match.
+

    clc
    lda find_item_length
    inc  ; null terminator
    adc code_ptr
    sta code_ptr
    lda #0
    adc code_ptr+1
    sta code_ptr+1
    inc find_item_count
    bra @next_item

@find_success
    sec
    ldy find_item_count
    rts

@find_fail
    clc
    rts


; Tokenize mnemonic.
; Input: strbuf = lowercase line, line_pos at first char
; Output:
;   If found, C=1, X=token number, Y=flags, line_pos advanced
;   If not found, C=0, line_pos unchanged
tokenize_mnemonic:
    ldx line_pos
    lda #<mnemonics
    sta code_ptr
    lda #>mnemonics
    sta code_ptr+1
    sec  ; Must not immediately precede an identifier character.
    lda #1  ; Start counting mnemonics at 1
    jsr find_in_token_list
    bcc @end
    stx line_pos  ; new line_pos
    ; X = line_pos, Y = mnemonic ID, Z = flags
    ; (Final: X = mnemonic ID, Y = flags)

    ; Check for +1/+2 suffix
    ldz #0
    lda strbuf,x
    cmp #'+'
    bne @end_ok
    inx
    lda strbuf,x
    cmp #'1'
    bne +
    ldz #F_ASM_FORCE8
    bra @end_forcewidth
+   cmp #'2'
    bne @end_ok
    ldz #F_ASM_FORCE16
@end_forcewidth
    inx
    lda strbuf,x
    jsr is_secondary_ident_char
    bcs @end_ok  ; Roll back to previous line_pos
    stx line_pos
@end_ok
    sec  ; C = 1
    tya
    tax  ; X = mnemonic ID
    tza
    tay  ; Y = flags
@end
    rts


; Tokenize pseudoop.
; Input: strbuf = lowercase line, line_pos at first char
; Output:
;   If found, C=1, X=token number, line_pos advanced
;   If not found, C=0, line_pos unchanged
tokenize_pseudoop:
    ldx line_pos
    lda strbuf,x
    cmp #'!'
    bne @not_found
    inx
    lda #<pseudoops
    sta code_ptr
    lda #>pseudoops
    sta code_ptr+1
    sec  ; Must not immediately precede an identifier character.
    lda #0  ; list starting pos
    jsr find_in_token_list
    bcc @not_found
    stx line_pos  ; new line pos
    tya
    clc
    adc #tokid_after_mnemonics  ; Y+tokid_after_mnemonics = pseudoop token ID
    tax
    sec
    rts
@not_found
    clc
    rts


; Tokenize pluses and minuses.
; Input: strbuf = lowercase line, line_pos at first char
; Output:
;   If found, C=1, tokbuf written, tok_pos and line_pos advanced
;      (tk_pluses, pos, len) or (tk_minuses, pos, len)
;   If not found, C=0, tok_pos and line_pos unchanged
;
; Note: This matches plus/minus operators as well as relative labels. The
; parser needs to handle this.
tokenize_pluses_and_minuses:
    ldx line_pos
    lda strbuf,x
    cmp #'+'
    bne @maybe_minus
    ldy #0  ; length
-   iny
    inx
    beq +
    lda strbuf,x
    cmp #'+'
    beq -
+
    lda #tk_pluses
    bra @found

@maybe_minus
    cmp #'-'
    beq +
    ; Neither + nor -
    clc
    rts
+
    ldy #0  ; length
-   iny
    inx
    beq +
    lda strbuf,x
    cmp #'-'
    beq -
+
    lda #tk_minuses

@found
    ; A=tok type, Y=len, line_pos=pos
    ldx tok_pos
    sta tokbuf,x
    inx
    lda line_pos
    sta tokbuf,x
    inx
    tya
    sta tokbuf,x
    inx
    clc
    adc line_pos
    sta line_pos  ; line_pos += length
    txa
    sta tok_pos   ; tok_pos += 3
    sec
    rts


; Tokenize punctuation tokens.
; Input: strbuf = lowercase line, line_pos at first char
; Output:
;   If found, C=1, X=token number, line_pos advanced
;   If not found, C=0, line_pos unchanged
;
; Note: Tokens spelled with letters that can also be labels are lexed as
; labels (xor, div, runnable, cbm, raw, x, y, z, sp).
tokenize_other:
    ldx line_pos
    lda #<other_tokens
    sta code_ptr
    lda #>other_tokens
    sta code_ptr+1
    clc  ; Allow an identifier character immediately after.
    lda #0  ; list starting pos
    jsr find_in_token_list
    bcc @end
    stx line_pos  ; new line pos
    tya
    clc
    adc #last_po  ; Y+last_po = non-keyword token ID
    tax
    sec
@end
    rts


; Load a full source line into strbuf, lowercased.
;
; This leaves the first four bytes of strbuf untouched to maintain an index
; correspondence with line_addr, so line_pos can index into both of them.
; Tokens are stored with line locations based on line_pos.
;
; Input: line_addr
; Output: line_addr copied to strbuf, lowercased
load_line_to_strbuf:
    lda line_addr
    sta bas_ptr
    lda line_addr+1
    sta bas_ptr+1
    ldy #4
    ldz #4
-   lda [bas_ptr],z
    beq +
    jsr to_lowercase
    sta strbuf,y
    iny
    inz
    bra -
+   sta strbuf,y  ; store null terminator in strbuf too
    rts


; Tokenize a full line.
;
; This populates tokbuf with tokens, null-terminated. Tokens are variable width.
; * String literal: tk_string_literal, line_pos, length
; * Number literal: tk_number_literal, line_pos, expr_result (4 bytes)
; * Relative label: tk_pluses or tk_minuses, line_pos, length
; * Label or register: tk_label_or_reg, line_pos, length
; * Mnemonic, pseudoop, keyword, non-keyword token: token ID, line_pos
;
; Input: line_addr
; Output:
;   On success, err_code=0, tokbuf populated.
;   On failure, err_code=syntax error, line_pos set to error.
tokenize:
    jsr load_line_to_strbuf
    ldy #0
    sty err_code
    sty tok_pos
    ldz #4
    stz line_pos

@tokenize_loop
    jsr accept_whitespace_and_comment
    cmp #0
    lbeq @success

    ; String literal
    cmp #chr_doublequote
    bne +
    lda line_pos
    taz
-   inz
    lda [bas_ptr],z
    cmp #chr_doublequote
    bne -
    ; Push tk_string_literal, line_pos, length (z-line_pos)
    ldx tok_pos
    lda #tk_string_literal
    sta tokbuf,x
    inx
    lda line_pos
    sta tokbuf,x
    inx
    tza
    sec
    sbc line_pos
    dec
    sta tokbuf,x
    inx
    stx tok_pos
    inz
    stz line_pos
    bra @tokenize_loop

+   ; Numeric literal
    phz
    jsr accept_literal
    plz
    bcc +++
    ; Push tk_number_literal, line_pos, expr_result (4 bytes)
    lda expr_flags
    and #F_EXPR_FORCE16
    beq +
    lda #tk_number_literal_leading_zero
    bra ++
+   lda #tk_number_literal
++  ldx tok_pos
    sta tokbuf,x
    inx
    stz tokbuf,x
    inx
    lda expr_result
    sta tokbuf,x
    inx
    lda expr_result+1
    sta tokbuf,x
    inx
    lda expr_result+2
    sta tokbuf,x
    inx
    lda expr_result+3
    sta tokbuf,x
    inx
    stx tok_pos
    bra @tokenize_loop

+++ ; Mnemonic
    phz
    jsr tokenize_mnemonic
    plz
    bcc +++
    ; Push mnemonic ID (X), line_pos, flags (Y)
    txa
    ldx tok_pos
    sta tokbuf,x
    inx
    stz tokbuf,x
    inx
    sty tokbuf,x
    lda line_pos
    taz
    inx
    stx tok_pos
    lbra @tokenize_loop

    ; Pseudoop
+++ phz
    jsr tokenize_pseudoop
    plz
    bcs @push_tok_pos_then_continue

    ; Tokenize relative labels, and +/- operators
    phz
    jsr tokenize_pluses_and_minuses
    plz
    lbcs @tokenize_loop

    ; Punctuation token
    phz
    jsr tokenize_other
    plz
    bcs @push_tok_pos_then_continue

    ; Label
    lda [bas_ptr],z
    cmp #'@'
    bne +
    inz
    sec
    bra ++
+   clc
++  jsr accept_ident
    bcc @syntax_error
    ; Push tk_label_or_reg, line_pos, length (z-line_pos)
    ldx tok_pos
    lda #tk_label_or_reg
    sta tokbuf,x
    inx
    lda line_pos
    sta tokbuf,x
    inx
    tza
    sec
    sbc line_pos
    sta tokbuf,x
    inx
    stx tok_pos
    stz line_pos
    lbra @tokenize_loop

@push_tok_pos_then_continue
    ; Push X, line_pos
    txa
    ldx tok_pos
    sta tokbuf,x
    inx
    stz tokbuf,x
    lda line_pos
    taz
    inx
    stx tok_pos
    lbra @tokenize_loop

@syntax_error
    lda #err_syntax
    sta err_code
    stz line_pos
    rts

@success
    ; Null terminate tokbuf: 0, $ff (line_pos=$ff -> don't print error location)
    lda #0
    ldx tok_pos
    sta tokbuf,x
    inx
    lda #$ff
    sta tokbuf,x
    rts


; ------------------------------------------------------------
; Symbol table
; ------------------------------------------------------------
; Record, 8 bytes: (name_ptr_24, flags_8, value_32)
; - 1023 symbols maximum (8KB of entries + list terminator)
; - Average name length of 23 for all 1023 symbols (24KB of names)
;
; For comparison, the BASIC 65 source file has 3301 symbols with an average
; name length of 15. The source file is 521,778 bytes long, which is >11x the
; maximum size of an EasyAsm source file. So 32KB of symbol data for EasyAsm
; is probably overkill.

init_symbol_table:
    ; Set first symbol table entry to null terminator
    lda #<attic_symbol_table
    ldx #>attic_symbol_table
    ldy #^attic_symbol_table
    ldz #$08
    stq attic_ptr
    dez
    lda #0
-   sta [attic_ptr],z
    dez
    bpl -

    ; Set name pointer to beginning of names region
    lda #<attic_symbol_names
    sta symtbl_next_name
    lda #>attic_symbol_names
    sta symtbl_next_name+1
    lda #^attic_symbol_names
    sta symtbl_next_name+2

    lda #0
    sta last_pc_defined_global_label
    sta last_pc_defined_global_label+1

    rts


; Find a symbol table entry for a name
; Input: bas_ptr=name, X=length (< 254)
; Output:
; - C=0 found, attic_ptr=entry address
; - C=1 not found, attic_ptr=next available table entry
; - bas_ptr and X preserved
find_symbol:
    phx
    lda #<attic_symbol_table
    ldx #>attic_symbol_table
    ldy #^attic_symbol_table
    ldz #$08
    stq attic_ptr
    plx

@symbol_find_loop
    ; attic_ptr = current entry
    ; Byte 2 is always $7x if value, $00 if terminator
    ldz #2
    lda [attic_ptr],z
    beq @not_found

    ; expr_a = current name ptr
    sta expr_a+2
    dez
    lda [attic_ptr],z
    sta expr_a+1
    dez
    lda [attic_ptr],z
    sta expr_a
    lda #$08
    sta expr_a+3

    ; Compare (expr_a) == (bas_ptr) up to length X
    txa
    taz
    dez
-   lda [expr_a],z
    cmp [bas_ptr],z
    bne @next_symbol
    dez
    bpl -
    ; (expr_a+length) == 0
    txa
    taz
    lda [expr_a],z
    bne @next_symbol
    ; Found.
    clc
    rts

@next_symbol
    phx
    lda #8
    ldx #0
    ldy #0
    ldz #0
    clc
    adcq attic_ptr
    stq attic_ptr
    plx
    bra @symbol_find_loop

@not_found
    sec
    rts


; Find or add a symbol table entry for a name
; Input: bas_ptr=name, X=length (< 254)
; Output:
; - C=0 found or added, attic_ptr=entry address
; - C=1 out of memory error
; - Uses expr_a
find_or_add_symbol:
    jsr find_symbol
    bcs +
    rts
+   ; attic_ptr is the null terminator in the symbol list
    ; Is there room for another symbol table entry here?
    phx
    lda #<(attic_symbol_table_end-SYMTBL_ENTRY_SIZE)
    ldx #>(attic_symbol_table_end-SYMTBL_ENTRY_SIZE)
    ldy #^(attic_symbol_table_end-SYMTBL_ENTRY_SIZE)
    ldz #$08
    cpq attic_ptr
    bne +
    ; Out of memory: no more symbol table entries.
    plx
    sec
    rts
+   plx
    phx
    ; Test for attic_symbol_names_end >= (symtbl_next_name + X + 1)
    lda symtbl_next_name
    sta expr_a
    lda symtbl_next_name+1
    sta expr_a+1
    lda symtbl_next_name+2
    sta expr_a+2
    lda #$08
    sta expr_a+3
    lda #0
    tay
    taz
    txa
    ldx #0
    inc
    adcq expr_a
    stq expr_a
    lda #<attic_symbol_names_end
    ldx #>attic_symbol_names_end
    ldy #^attic_symbol_names_end
    ldz #$08
    cpq expr_a
    bcs +
    ; Out of memory: not enough room for symbol name.
    plx
    sec
    rts
+
    ; (Name length is on the stack.)

    ; Create new table entry, and null terminator.
    ldz #0
    lda symtbl_next_name
    sta [attic_ptr],z
    inz
    lda symtbl_next_name+1
    sta [attic_ptr],z
    inz
    lda symtbl_next_name+2
    sta [attic_ptr],z
    inz
    ldx #13  ; Zero flags, value, and all of next entry (null terminator).
    lda #0
-   sta [attic_ptr],z
    inz
    dex
    bne -

    ; Copy name from bas_ptr, length X, to symtbl_next_name.
    plx
    lda symtbl_next_name
    sta expr_a
    lda symtbl_next_name+1
    sta expr_a+1
    lda symtbl_next_name+2
    sta expr_a+2
    txa
    taz
    dez
-   lda [bas_ptr],z
    sta [expr_a],z
    dez
    bpl -
    txa
    taz
    lda #0
    sta [expr_a],z

    ; Store new symtbl_next_name.
    tay
    taz
    txa
    ldx #0
    inc    ; Q = name length + 1
    clc
    adcq expr_a
    sta symtbl_next_name
    stx symtbl_next_name+1
    sty symtbl_next_name+2
    ; (symtbl_next_name is 24 bits.)

    ; Success.
    clc
    rts


; Gets a symbol's 32-bit value
; Input: attic_ptr=symbol table entry
; Output:
;   C=0 defined, Q=value
;   C=1 undefined
get_symbol_value:
    ldz #3
    lda [attic_ptr],z
    and #F_SYMTBL_DEFINED
    bne +
    ; Undefined.
    sec
    rts
+   lda #0
    tax
    tay
    taz
    lda #4
    clc
    adcq attic_ptr
    stq expr_a      ; expr_a = attic_ptr + 4
    ldz #0
    ldq [expr_a]
    clc
    rts


; Gets a symbol's 32-bit value
; Input: attic_ptr=symbol table entry, Q=value
; Output: entry value (attic_ptr+4)=Q, entry DEFINED flag set
; This does not validate inputs.
set_symbol_value:
    pha
    phx
    phy
    phz
    lda #0
    tax
    tay
    taz
    lda #4
    adcq attic_ptr
    stq expr_a
    plz
    ply
    plx
    pla
    stq [expr_a]
    ldz #3
    lda #F_SYMTBL_DEFINED
    sta [attic_ptr],z
    rts


; ------------------------------------------------------------
; Segment table
; ------------------------------------------------------------
; Segment:         (pc16,  size16, data...)
; File marker:     ($0000, $FFFF,  fnameaddr32, fnamelen8, flags)
; Null terminator: ($0000, $0000)

; Initializes the segment table.
init_segment_table:
    ; (next_segment_byte_addr inits to top of table, for creation of first
    ; segment in assemble_bytes.)
    lda #<attic_segments
    sta current_segment
    sta next_segment_byte_addr
    lda #>attic_segments
    sta current_segment+1
    sta next_segment_byte_addr+1
    lda #^attic_segments
    sta current_segment+2
    sta next_segment_byte_addr+2
    lda #<(attic_segments >>> 24)
    sta current_segment+3
    sta next_segment_byte_addr+3

    lda #0
    sta next_segment_pc
    sta next_segment_pc+1
    ldz #0
    sta [current_segment],z
    inz
    sta [current_segment],z
    inz
    sta [current_segment],z
    inz
    sta [current_segment],z

    rts

; Initializes an assembly pass.
init_pass:
    lda #0
    sta program_counter
    sta program_counter+1

    ; Reset all asm_flags except src_to_buf
    lda asm_flags
    and #F_ASM_SRC_TO_BUF
    sta asm_flags

    rts


; Gets the program counter, or fails if not defined.
; Input: program_counter, asm_flags
; Output:
;   C=0 ok, X/Y=PC
;   C=1 not defined
get_pc:
    lda asm_flags
    and #F_ASM_PC_DEFINED
    bne +
    sec
    rts
+   ldx program_counter
    ldy program_counter+1
    clc
    rts


; Sets the program counter.
; Input: X/Y=PC
; Output: program_counter, asm_flags
set_pc:
    stx program_counter
    sty program_counter+1
    lda asm_flags
    ora #F_ASM_PC_DEFINED
    sta asm_flags
    rts


; Inputs:
;   strbuf = assembled bytes
;   expr_a = length
;   line_addr = source line
;   program_counter = PC at beginning of line
bufprint_assembly_and_source_line:
    ; Print $addr as hex
    lda #'$'
    jsr bufprint_chr
    lda program_counter+1
    jsr bufprint_hex8
    lda program_counter
    jsr bufprint_hex8
    lda #chr_spc
    jsr bufprint_chr

    ; Print up to six assembled bytes as hex
    ; If six, also print ".."
    ; If < six, fill with spaces
    ldy expr_a
    cpy #6
    bcc +
    ldy #6
+   ldx #0
-   lda strbuf,x
    jsr bufprint_hex8
    inx
    dey
    bne -
    lda expr_a
    cmp #6
    bcc +
    lda #'.'
    jsr bufprint_chr
    jsr bufprint_chr
    bra ++
+   lda #6
    sec
    sbc expr_a
    bmi ++
    inc
    asl
    tax
-   lda #' '
    phx
    jsr bufprint_chr
    plx
    dex
    bpl -
++

    ; (Print line number?)

    ; Print the source line
    lda line_addr
    sta bas_ptr
    lda line_addr+1
    sta bas_ptr+1
    inw bas_ptr
    inw bas_ptr
    inw bas_ptr
    inw bas_ptr
    jsr bufprint_line
    rts


; Assembles bytes to a segment.
; Input: Bytes in beginning of strbuf, X=length; init'd segment table
; Output:
;   C=0 ok; table state updated
;   C=1 fail:
;     err_code set; caller can react appropriately (err_pc_undef on pass 0 is ok)
;   Uses expr_a
assemble_bytes:
    cpx #0  ; Edge case: X = 0
    bne +
    clc
    rts
+
    ; expr_a = length
    stx expr_a
    lda #0
    sta expr_a+1
    sta expr_a+2
    sta expr_a+3

    ; If PC not defined, error.
    lda asm_flags
    and #F_ASM_PC_DEFINED
    bne +
    lda #err_pc_undef
    sta err_code
    lda #$ff
    sta line_pos
    sec
    rts
+

    ; If this isn't the final pass, simply increment the PC and don't do
    ; anything else.
    bit pass
    lbpl @increment_pc

    ; Write source line to view buffer, if requested.
    lda asm_flags
    and #F_ASM_SRC_TO_BUF
    beq +
    jsr bufprint_assembly_and_source_line
+

    ; If next_segment_byte_addr+len is beyond maximum segment table address, out
    ; of memory error.
    lda #<attic_segments_end
    ldx #>attic_segments_end
    ldy #^attic_segments_end
    ldz #<(attic_segments_end >>> 24)
    sec
    sbcq expr_a
    sec
    sbcq next_segment_byte_addr
    bpl +
    lda #err_out_of_memory
    sta err_code
    lda #$00
    sta line_addr
    sta line_addr+1
    sec
    rts
+
    ; If current segment has empty header or program_counter != next_segment_pc,
    ; create a new segment header.
    ; (segment_pc_16, length_16)
    ldz #0
    lda [current_segment],z
    inz
    ora [current_segment],z
    beq +
    lda program_counter
    cmp next_segment_pc
    bne +
    lda program_counter+1
    cmp next_segment_pc+1
    bne +
    bra ++
+   ldz #0
    lda program_counter
    sta [next_segment_byte_addr],z
    sta next_segment_pc
    inz
    lda program_counter+1
    sta [next_segment_byte_addr],z
    sta next_segment_pc+1
    inz
    lda #0
    sta [next_segment_byte_addr],z
    inz
    sta [next_segment_byte_addr],z
    ldq next_segment_byte_addr
    stq current_segment

    lda #0
    tax
    tay
    taz
    lda #4
    clc
    adcq next_segment_byte_addr
    stq next_segment_byte_addr

++  ; Write bytes to segment.
    lda expr_a
    tax  ; X counts down from length to 1, inclusive.
    dec
    taz  ; Z counts down from length-1 to 0, inclusive.
-   lda strbuf-1,x
    sta [next_segment_byte_addr],z
    dez
    dex
    ; (Can't use bpl here because we need to support unsigned counts up to 255.)
    bne -

    ; Add length to segment length.
    ldz #2
    lda [current_segment],z
    clc
    adc expr_a
    sta [current_segment],z
    inz
    lda [current_segment],z
    adc expr_a+1
    sta [current_segment],z

    ; Add length to next_segment_byte_addr.
    ldq expr_a
    clc
    adcq next_segment_byte_addr
    stq next_segment_byte_addr

    ; Null terminate the segment list
    ldz #0
    lda #0
    sta [next_segment_byte_addr],z
    inz
    sta [next_segment_byte_addr],z
    inz
    sta [next_segment_byte_addr],z
    inz
    sta [next_segment_byte_addr],z

@increment_pc:
    ; Add length program_counter and next_segment_pc.
    lda expr_a
    clc
    adc program_counter
    sta program_counter
    sta next_segment_pc
    lda expr_a+1
    adc program_counter+1
    sta program_counter+1
    sta next_segment_pc+1
    bcc +
    lda #err_pc_overflow
    sta err_code
    lda #$ff
    sta line_pos
+   rts


; Input: completed assembly
;   C=1: skip file markers
; Output: current_segment = ptr to first segment, or to null segment if table emtpy
start_segment_traversal:
    lda #<attic_segments
    sta current_segment
    lda #>attic_segments
    sta current_segment+1
    lda #^attic_segments
    sta current_segment+2
    lda #<(attic_segments >>> 24)
    sta current_segment+3

    bcc +
    jsr is_file_marker_segment_traversal
    bcc +
    jsr next_segment_traversal_skip_file_markers

+   rts


; Input: completed assembly; current_segment points to an entry or to null terminator
; Output: If current_segment not null, advanced.
next_segment_traversal:
    jsr is_end_segment_traversal
    bcc +
    ; Do nothing if current segment is already the end.
    rts

+   jsr is_file_marker_segment_traversal
    bcc +
    ; Advance across one file marker.
    lda #0
    tax
    tay
    taz
    lda #$0a
    bra ++

+   ; Advance across a data segment.
    ldz #2
    clc
    lda [current_segment],z
    adc #4
    tay
    inz
    lda [current_segment],z
    adc #0
    tax
    tya
    ldy #0
    ldz #0  ; Q = length + 4

++  clc
    adcq current_segment
    stq current_segment  ; current_segment += length + 4
    rts

skip_file_markers:
    ; Skip zero or more file markers.
-   jsr is_file_marker_segment_traversal
    bcc +
    ; Skip file marker
    lda #0
    tax
    tay
    taz
    lda #$0a
    clc
    adcq current_segment
    stq current_segment
    bra -
+   rts

next_segment_traversal_skip_file_markers:
    jsr next_segment_traversal
    jsr skip_file_markers
    rts


; Input: completed assembly; current_segment points to an entry or to null terminator
; Output:
;   C=1: current_segment points to end of list.
is_end_segment_traversal:
    ldz #0
    lda [current_segment],z
    inz
    ora [current_segment],z
    inz
    ora [current_segment],z
    inz
    ora [current_segment],z
    bne +
    sec
    rts
+   clc
    rts

; Input: completed assembly; current_segment points to an entry or to null terminator
; Output:
;   C=1: current_segment points to end of list.
is_file_marker_segment_traversal:
    ldz #0
    lda [current_segment],z
    cmp #$00
    bne +
    inz
    lda [current_segment],z
    cmp #$00
    bne +
    inz
    lda [current_segment],z
    cmp #$ff
    bne +
    inz
    lda [current_segment],z
    cmp #$ff
    bne +
    sec
    rts
+   clc
    rts


; Tests whether a segment overlaps a region
; Input: A/X=start addr, Y/Z=length; completed assembly
;   C=1 skip an entry if expr_result = current_segment (entry addresses)
; Output:
;   C=0 no overlap
;   C=1 yes overlap; current_segment=ptr to first overlapping segment entry
; Uses expr_a, expr_b, and asm_flags.
does_a_segment_overlap:
    stq expr_a
    lda asm_flags  ; Borrow flag for "skip entry enable"
    bcc +
    ora #F_ASM_SRC_TO_BUF
    bra ++
+   and #F_ASM_SRC_TO_BUF
++  sta asm_flags

    ldq expr_a
    clc
    adc expr_a+2
    sta expr_a+2
    lda expr_a+1
    adc expr_a+3
    sta expr_a+3  ; expr_a.0-1: start, expr_a.2-3: end+1

    sec
    jsr start_segment_traversal

@search_loop:
    jsr is_end_segment_traversal
    bcc +
    clc
    rts
+

    ; If requested, skip the segment if address in expr_result.
    ; (For do_any_segments_overlap.)
    bit asm_flags
    bpl +
    ldq expr_result
    cpq current_segment
    lbeq @next
+

    ldz #0
    ldq [current_segment]
    stq expr_b
    clc
    adc expr_b+2
    sta expr_b+2
    lda expr_b+1
    adc expr_b+3
    sta expr_b+3  ; expr_b.0-1: cur start, expr_b.2-3: cur end+1

    ; A start <= B start < A end+1
    ;   AAAA      AAAAA
    ;     BBBB     BBB
    +cmp16 expr_b, expr_a
    bcc ++  ; C=0: B start < A start
    +cmp16 expr_b, expr_a+2
    bcs ++  ; C=1: B start >= A end
    sec
    rts

++  ; A start <= B end < A end+1
    ;     AAAA    AAAAA
    ;   BBBB       BBB
    +cmp16 expr_b+2, expr_a
    bcc ++  ; C=0: B end < A start
    +cmp16 expr_b+2, expr_a+2
    bcs ++  ; C=1: B end >= A end
    sec
    rts

++  ; B start < A start && A end+1 <= B end+1
    ;    AAA
    ;   BBBBB
    +cmp16 expr_b, expr_a
    bcs ++  ; C=1: B start >= A start
    +cmp16 expr_b+2, expr_a+2
    bcc ++  ; C=0: B end < A end
    sec
    rts
++

@next
    ; No overlap. Next segment...
    jsr next_segment_traversal_skip_file_markers
    lbra @search_loop


; Output:
;   C=0 no overlap between any two segments
;   C=1 yes overlap;
;      current_segment and expr_result are pointers to overlapping entries
; Uses expr_result.
do_any_segments_overlap:
    sec
    jsr start_segment_traversal
@outer_loop
    jsr is_end_segment_traversal
    bcc +
    clc
    rts
+   ldq current_segment
    stq expr_result

    ldz #0
    ldq [current_segment]
    sec
    jsr does_a_segment_overlap
    bcc +
    rts
+   ldq expr_result
    stq current_segment
    jsr next_segment_traversal_skip_file_markers
    lbra @outer_loop


; ------------------------------------------------------------
; Forced 16's list
; ------------------------------------------------------------
; Record, 2 bytes: (pc16)
; This is a null-terminated list of 16-bit program counter values
; whose addresses are forced to 16-bit widths by the first pass.
; Specifically, an undefined operand expression forces 16 bits
; in the first pass, even when defined to a value < 256 in a later
; pass.

set_attic_ptr_to_forced16:
    lda #<attic_forced16s
    sta attic_ptr
    lda #>attic_forced16s
    sta attic_ptr+1
    lda #^attic_forced16s
    sta attic_ptr+2
    lda #<(attic_forced16s >>> 24)
    sta attic_ptr+3
    rts

init_forced16:
    jsr set_attic_ptr_to_forced16
    lda #0
    ldz #0
    sta [attic_ptr],z
    inz
    sta [attic_ptr],z
    rts

; Input: program_counter
; Output: C=1 if PC is in the list
;   attic_ptr at PC entry or end of list
find_forced16:
    jsr set_attic_ptr_to_forced16

    ; Report an undefined PC as "not found"
    lda asm_flags
    and #F_ASM_PC_DEFINED
    beq @not_found

    ldx program_counter
    ldy program_counter+1
-   ldz #0
    txa
    cmp [attic_ptr],z
    bne +
    tya
    inz
    cmp [attic_ptr],z
    beq @found
    dez
+   lda [attic_ptr],z
    inz
    ora [attic_ptr],z
    bne +
    bra @not_found

+   ; next
    lda #2
    clc
    adc attic_ptr
    sta attic_ptr
    lda #0
    adc attic_ptr+1
    sta attic_ptr+1
    lda #0
    adc attic_ptr+2
    sta attic_ptr+2
    lda #0
    adc attic_ptr+3
    sta attic_ptr+3
    bra -

@found
    sec
    rts
@not_found
    clc
    rts


; Add the program counter to the forced-16's list
; Input: program_counter
add_forced16:
    jsr find_forced16
    bcc +
    rts   ; already in the list
+
    ; Don't add an undefined PC
    lda asm_flags
    and #F_ASM_PC_DEFINED
    beq +

    ldz #0
    lda program_counter
    sta [attic_ptr],z
    inz
    lda program_counter+1
    sta [attic_ptr],z
    inz
    lda #0
    sta [attic_ptr],z
    inz
    sta [attic_ptr],z
+   rts


; ------------------------------------------------------------
; Relative label table
; ------------------------------------------------------------
; Terminator (on both ends): (00, 00, 00)
; Record: (tok_type[7] : len[0:6], pc16)
;   tok_type: 0=plus 1=minus

start_rellabel_table:
    lda #<attic_rellabels
    sta attic_ptr
    lda #>attic_rellabels
    sta attic_ptr+1
    lda #^attic_rellabels
    sta attic_ptr+2
    lda #$08
    sta attic_ptr+3
    rts

; Z flag=1 yes, Z flag=0 no
rellabel_on_terminator:
    ldz #0
    lda [attic_ptr],z
    inz
    ora [attic_ptr],z
    inz
    ora [attic_ptr],z
    cmp #0
    rts

next_rellabel:
    inq attic_ptr
    inq attic_ptr
    inq attic_ptr
    rts

prev_rellabel:
    deq attic_ptr
    deq attic_ptr
    deq attic_ptr
    rts

init_rellabel_table:
    jsr start_rellabel_table
    ldz #5
    lda #0
-   sta [attic_ptr],z
    dez
    bpl -

    lda #<(attic_rellabels+3)
    sta rellabels_next
    lda #>(attic_rellabels+3)
    sta rellabels_next+1
    lda #^(attic_rellabels+3)
    sta rellabels_next+2
    rts

; Inputs:
;    C=0 plus, C=1 minus
;    A=len; X/Y=PC
;    rellabels_next=address of ending terminator
; Outputs:
;    C=1 out of memory
; Uses attic_ptr
add_rellabel:
    bcc +
    ora #$80
+   pha

    ; attic_ptr = rellabels_next
    lda rellabels_next
    sta attic_ptr
    lda rellabels_next+1
    sta attic_ptr+1
    lda rellabels_next+2
    sta attic_ptr+2
    lda #$08
    sta attic_ptr+3

    ; Write the new entry
    ldz #0
    pla
    sta [attic_ptr],z
    inz
    txa
    sta [attic_ptr],z
    inz
    tya
    sta [attic_ptr],z

    ; Write new list terminator
    inz
    lda #0
    sta [attic_ptr],z
    inz
    lda #0
    sta [attic_ptr],z
    inz
    lda #0
    sta [attic_ptr],z

    ; Increment rellabels_next and attic_ptr
    lda rellabels_next
    clc
    adc #3
    sta rellabels_next
    sta attic_ptr
    lda rellabels_next+1
    adc #0
    sta rellabels_next+1
    sta attic_ptr+1
    lda rellabels_next+2
    adc #0
    sta rellabels_next+2
    sta attic_ptr+2

    ; Test for out of memory
    lda #<attic_rellabels_end
    ldx #>attic_rellabels_end
    ldy #^attic_rellabels_end
    ldz #$08
    cpq attic_ptr
    bcs +
    sec  ; out of memory
    rts
+   clc
    rts

; Inputs:
;    C=0 plus, C=1 minus
;    A=len; X/Y=current PC
; Outputs:
;    C=0 not found
;    C=1 found; X/Y=label definition
; Uses expr_a, attic_ptr
eval_rellabel:
    bcc +
    ora #$80
+   sta expr_a
    stx expr_a+1
    sty expr_a+2
    jsr start_rellabel_table
    jsr next_rellabel

    ; Entry table ordered by PC ascending.
    ; Scan forward to target_PC <= entry_pc, or to end of table
@pc_scan_loop
    jsr rellabel_on_terminator
    beq +++
    ldz #2
    lda expr_a+2
    cmp [attic_ptr],z
    beq +   ; target_PC_high = entry_pc_high
    bcc +++ ; target_PC_high < entry_pc_high
    bra ++  ; target_PC_high > entry_pc_high
+   dez
    lda expr_a+1
    cmp [attic_ptr],z
    beq +++  ; target_PC = entry_pc
    bcc +++  ; target_PC < entry_pc
++  ; Continue scan
    jsr next_rellabel
    bra @pc_scan_loop
+++

    ; If current PC = this entry's PC and direction is positive,
    ; go ahead one. (Accept: - bra -; Reject: + bra +)
    ldz #1
    lda [attic_ptr],z
    cmp expr_a+1
    bne +
    inz
    lda [attic_ptr],z
    cmp expr_a+2
    bne +
    bit expr_a
    bmi +
    jsr next_rellabel
+

    ; If current PC < this entry's PC or on end terminator and direction is
    ; minus, go back one.
    bit expr_a
    bpl ++
    jsr rellabel_on_terminator
    beq +
    lda expr_a+2
    ldz #2
    cmp [attic_ptr],z
    bcc +
    lda expr_a+1
    ldz #1
    cmp [attic_ptr],z
    bcs ++
+   jsr prev_rellabel
++

    ; Scan in label direction to dir+len, or to end/beginning of table
@label_scan_loop
    jsr rellabel_on_terminator
    bne +
    ; Not found
    clc
    rts

+   ldz #0
    lda [attic_ptr],z
    cmp expr_a
    bne +
    ; Found
    ldz #1
    lda [attic_ptr],z
    tax
    inz
    lda [attic_ptr],z
    tay
    sec
    rts

    ; Next
+   bit expr_a
    bmi +
    jsr next_rellabel
    bra @label_scan_loop
+   jsr prev_rellabel
    bra @label_scan_loop


; ------------------------------------------------------------
; Parser primitives
; ------------------------------------------------------------

; Input: A=token; tokbuf, tok_pos
; Output:
;   C=0 ok, tok_pos advanced
;   C=1 not found, tok_pos preserved
expect_token:
    ldx tok_pos
    cmp tokbuf,x
    bne @fail
    inx
    inx
    stx tok_pos
    clc
    bra @end
@fail
    sec
@end
    rts


; Input: tokbuf, tok_pos
; Output:
;   C=0 ok, tok_pos advanced; A=tk_pluses or tk_minuses, Y=length
;   C=1 not found, tok_pos preserved
expect_pluses_or_minuses:
    ldx tok_pos
    lda tokbuf,x
    cmp #tk_pluses
    beq @succeed
    cmp #tk_minuses
    beq @succeed
    sec
    rts
@succeed
    taz
    inx
    inx
    lda tokbuf,x
    inx
    tay
    tza
    stx tok_pos
    clc
    rts

; Input: tokbuf, tok_pos
; Output:
;   C=0 ok, tok_pos advanced; A=tk_pluses or tk_minuses
;   C=1 not found, tok_pos preserved
expect_single_plus_or_minus:
    ldx tok_pos
    phx
    jsr expect_pluses_or_minuses
    cpy #1
    beq @succeed
    plx
    stx tok_pos
    sec
    rts
@succeed
    plx
    clc
    rts

; Input: tokbuf, tok_pos
; Output:
;   C=0 ok, tok_pos advanced
;   C=1 not found, tok_pos preserved
expect_single_minus:
    ldx tok_pos
    phx
    jsr expect_single_plus_or_minus
    bcs @fail
    cmp #tk_minuses
    beq @succeed
@fail
    plx
    stx tok_pos
    sec
    rts
@succeed
    plx
    clc
    rts


; Input: tokbuf, tok_pos
; Output:
;   C=0 ok, tok_pos advanced; X=line_pos, Y=length
;   C=1 not found, tok_pos preserved
expect_label:
    ldx tok_pos
    lda tokbuf,x
    cmp #tk_label_or_reg
    bne @fail
    inx
    lda tokbuf,x
    inx
    ldy tokbuf,x  ; Y = label token length
    inx
    stx tok_pos
    tax   ; X = label token line pos
    clc
    bra @end
@fail
    sec
@end
    rts

; Input: X/Y=code address of expected keyword; line_addr, tokbuf, tok_pos
; Output:
;   C=0 matched, tok_pos advanced
;   C=1 not found, tok_pos preserved
expect_keyword:
    stx code_ptr
    sty code_ptr+1
    ldx tok_pos
    phx
    jsr expect_label
    bcs @fail
    txa
    taz
    ldx #0
    lda line_addr
    sta bas_ptr
    lda line_addr+1
    sta bas_ptr+1
-   lda [bas_ptr],z
    sta strbuf,x
    inz
    inx
    dey
    bne -
    lda #0
    sta strbuf,x
    jsr strbuf_to_lowercase
    ldx #0
    jsr strbuf_cmp_code_ptr
    beq @succeed
@fail
    plx
    stx tok_pos
    sec
    bra @end
@succeed
    plx
    clc
@end
    rts


; Input: tokbuf, tok_pos
; Output:
;   C=0 ok, A=token ID, Y=flags, tok_pos advanced
;   C=1 not found, tok_pos preserved
expect_opcode:
    ldx tok_pos
    lda tokbuf,x
    beq @fail
    cmp #tokid_after_mnemonics
    bcs @fail
    inx
    inx
    ldy tokbuf,x
    inx
    stx tok_pos
    clc
    bra @end
@fail
    sec
@end
    rts


; Input: tokbuf, tok_pos
; Output:
;   C=0 ok, A=token ID, tok_pos advanced
;   C=1 not found, tok_pos preserved
expect_pseudoop:
    ldx tok_pos
    lda tokbuf,x
    cmp #po_to
    bcc @fail
    cmp #last_po+1
    bcs @fail
    inx
    inx
    stx tok_pos
    clc
    bra @end
@fail
    sec
@end
    rts


; Input: tokbuf, tok_pos
; Output:
;   C=0 ok, tok_pos advanced; expr_result, expr_flags
;   C=1 not found, tok_pos preserved
expect_literal:
    ldx tok_pos
    lda tokbuf+1,x
    taz
    lda line_addr
    sta bas_ptr
    lda line_addr+1
    sta bas_ptr+1
    lda [bas_ptr],z
    cmp #chr_singlequote
    bne +
    lda expr_flags
    ora #F_EXPR_BRACKET_CHARLIT
    sta expr_flags
+

    ldx tok_pos
    lda tokbuf,x
    cmp #tk_number_literal_leading_zero
    bne +
    lda expr_flags
    ora #F_EXPR_FORCE16
    sta expr_flags
    bra ++
+   cmp #tk_number_literal
    bne @fail
++  lda tokbuf+2,x
    sta expr_result
    lda tokbuf+3,x
    sta expr_result+1
    lda tokbuf+4,x
    sta expr_result+2
    lda tokbuf+5,x
    sta expr_result+3
    lda #6
    clc
    adc tok_pos
    sta tok_pos
    lda #0
    adc tok_pos+1
    sta tok_pos+1
    clc
    bra @end
@fail
    sec
@end
    rts


; ------------------------------------------------------------
; Expressions
; ------------------------------------------------------------

; Input: expr_result
; Output:
;   C=1 if:
;     high word = ffff and low word >= 8000, or
;     high word = 0000 and low word < 8000
;   Else, C=0
is_expr_word:
    lda expr_result+3
    and expr_result+2
    cmp #$ff
    bne +
    lda expr_result+1
    and #$80
    bne @yes
    bra @no
+   lda expr_result+3
    ora expr_result+2
    beq @yes
@no
    clc
    rts
@yes
    sec
    rts

; Input: expr_result
; Output:
;   C=1 if:
;     high word+byte = ffffff and LSB >= 80, or
;     high word+byte = 000000
;   Else, C=0
is_expr_byte:
    lda expr_result+3
    and expr_result+2
    and expr_result+1
    cmp #$ff
    bne +
    lda expr_result
    and #$80
    bne @yes
    bra @no
+   lda expr_result+3
    ora expr_result+2
    ora expr_result+1
    beq @yes
@no
    clc
    rts
@yes
    sec
    rts


; Expression grammar:
;   primary   ::= * | <label> | <literal> | "(" expr ")" | "[" expr "]"
;   inversion ::= (!)? primary
;   power     ::= inversion (^ inversion)*
;   negate    ::= (-)? power
;   factor    ::= negate ((* DIV / %) negate)*
;   term      ::= factor ((+ -) factor)*
;   shift     ::= term ((<< >> >>>) term)*
;   bytesel   ::= (< > ^ ^^)? shift
;   expr      ::= bytesel ((& XOR |) bytesel)*
;
; All "expect_" routines rely on global tokbuf and line_addr, and manipulate
; global tok_pos. Each returns a result as follows:
;   C=0 ok, tok_pos advanced; result in expr_result, expr_flags
;   C=1 not found, tok_pos preserved
;     err_code>0, line_pos: report error in expression
;
; Any C=0 return with expr_flags & F_EXPR_UNDEFINED should propagate
; F_EXPR_UNDEFINED and not bother to set expr_result.
;
; Bracket flags propagate if the rule matches the higher precedence rule
; without applying an operation.
;
; Intermediate results are kept on the stack, and unwound within each
; subroutine.

; primary   ::= * | <label> | <literal> | "(" expr ")" | "[" expr "]"
expect_primary:
    lda expr_flags
    and #!F_EXPR_BRACKET_MASK
    sta expr_flags

    ldx tok_pos
    phx

    lda tokbuf,x
    lbeq @fail

    ; "(" expr ")"
    lda #tk_lparen
    jsr expect_token
    bcs +++
    jsr expect_expr
    lbcs @fail
    lda #tk_rparen
    jsr expect_token
    lbcs @fail
    lda expr_flags
    and #!F_EXPR_BRACKET_MASK
    ora #F_EXPR_BRACKET_PAREN
    sta expr_flags
    lbra @succeed

    ; "[" <expr> "]"
+++ lda #tk_lbracket
    jsr expect_token
    bcs +++
    jsr expect_expr
    lbcs @fail
    lda #tk_rbracket
    jsr expect_token
    lbcs @fail
    lda expr_flags
    and #!F_EXPR_BRACKET_MASK
    ora #F_EXPR_BRACKET_SQUARE
    sta expr_flags
    lbra @succeed

    ; Program counter (*)
+++ lda #tk_multiply
    jsr expect_token
    bcs +++
    lda program_counter
    sta expr_result
    lda program_counter+1
    sta expr_result+1
    lda #0
    sta expr_result+2
    sta expr_result+3
    lda asm_flags
    and #F_ASM_PC_DEFINED
    bne +
    lda expr_flags
    ora #F_EXPR_UNDEFINED
    sta expr_flags
+   lbra @succeed

    ; Relative label
+++ jsr expect_pluses_or_minuses
    lbcs +++
    ; C=0 plus, C=1 minus
    ; A=len; X/Y=current PC
    cmp #tk_pluses
    beq +
    sec
    bra ++
+   clc
++
    tya
    ldx program_counter
    ldy program_counter+1
    jsr eval_rellabel
    lbcc @undefined_label
+   stx expr_result
    sty expr_result+1
    lda #0
    sta expr_result+2
    sta expr_result+3
    lbra @succeed

    ; <label>
+++ jsr expect_label
    lbcs +++
    jsr find_or_add_label
    jsr get_symbol_value
    bcs @undefined_label
    stq expr_result
    ldz #3
    lda expr_flags
    and #!F_EXPR_FORCE16
    sta expr_flags
    lda [attic_ptr],z  ; flags
    and #F_SYMTBL_LEADZERO
    beq +
    lda expr_flags
    ora #F_EXPR_FORCE16
    sta expr_flags
+   bra @succeed

@undefined_label
++  lda expr_flags
    ora #F_EXPR_UNDEFINED
    sta expr_flags
    bit pass           ; undefined label is an error in final pass
    bpl @succeed
    lda #err_undefined
    sta err_code
    ldx tok_pos
    lda tokbuf-2,x     ; back up to the label's line_pos
    sta line_pos
    bra @fail

    ; <literal>
+++ ; Test whether this is a char literal, to flag it for !scr.
    jsr expect_literal
    bcs @fail
    bra @succeed

@fail
    plx
    stx tok_pos
    sec
    rts
@succeed
    plx
    clc
    rts


; inversion ::= (!)* primary
expect_inversion:
    ldz #0
-   lda #tk_complement
    jsr expect_token
    bcs +
    inz
    bra -
+   phz
    jsr expect_primary
    plz
    bcs @end
    cpz #0
    beq @ok  ; 0 inversions, preserve flags
    lda expr_flags  ; at least one inversion, reset flags
    and #!F_EXPR_BRACKET_MASK
    sta expr_flags
    tza
    and #1
    beq @ok  ; even number of inversions, no value change
    lda expr_result
    eor #$ff
    sta expr_result
    lda expr_result+1
    eor #$ff
    sta expr_result+1
    lda expr_result+2
    eor #$ff
    sta expr_result+2
    lda expr_result+3
    eor #$ff
    sta expr_result+3
@ok
    clc
@end
    rts

; power     ::= inversion (^ inversion)*
expect_power:
    jsr expect_inversion
    lbcs @end  ; Missing first operand.
    lda #tk_power
    jsr expect_token
    lbcs @ok   ; Passthru

    ; For right associative, push all expressions parsed, then evaluate while
    ; unwinding.
    +push32 expr_result
    ldz #1
-   phz
    jsr expect_inversion
    plz
    lbcs @drop_stack_and_err  ; Power operator missing operand after operator.
    +push32 expr_result
    inz
    lda #tk_power
    phz
    jsr expect_token
    plz
    bcc -

    ; Clear bracket flags.
    lda expr_flags
    and #!F_EXPR_BRACKET_MASK
    sta expr_flags

    ; expr_b = 1, used twice later
    lda #1
    sta expr_b
    lda #0
    sta expr_b+1
    sta expr_b+2
    sta expr_b+3

    ; There are Z > 1 values on the stack. Last operand is first exponent.
    +pull32 expr_result
    dez  ; Z = Z - 1

    ; Z times, pull an operand, and take it to the previous result's power.
@power_loop
    ; If a power is negative (bit 31 is set), abort with error.
    bit expr_result+3
    bpl +
    lda #err_exponent_negative
    sta err_code
    lbra @drop_stack_and_err
+
    ; Pull the base.
    +pull32 expr_a

    ; Stash operand count during the exp_loop.
    phz

    ; Take expr_a to the expr_result power. Put final answer in expr_result.
    ; Edge case: power = 0
    ldq expr_result
    bne +
    lda #1
    sta expr_result
    bra @continue_power_loop
+

    ldq expr_a
    stq multina
    ldq expr_b  ; Start with A * 1
@exp_loop
    stq multinb
    ldq expr_result
    sec
    sbcq expr_b
    stq expr_result  ; expr_result = expr_result - 1
    beq +
    ldq product
    bra @exp_loop

+   ldq product
    stq expr_result

@continue_power_loop
    ; Restore Z = operand count. Proceed to next operand.
    plz
    dez
    bne @power_loop
    bra @ok

@drop_stack_and_err
-   cpz #0
    beq +
    pla
    pla
    pla
    pla
    dez
    bra -
+   sec
    rts
@ok
    clc
@end
    rts


; negate    ::= (-)? power
expect_negate:
    jsr expect_single_minus
    bcc +
    jsr expect_power  ; Passthru
    lbra @end

+   jsr expect_power
    bcc +
    ; Not a negate expression. Interpret single-minus as relative label.
    lda tok_pos
    sec
    sbc #3
    sta tok_pos
    jsr expect_power
    lbra @end

+
    ; Negate expr_result (XOR $FFFFFFFF + 1)
    clc
    lda expr_result
    eor #$ff
    adc #1
    sta expr_result
    lda expr_result+1
    eor #$ff
    adc #0
    sta expr_result+1
    lda expr_result+2
    eor #$ff
    adc #0
    sta expr_result+2
    lda expr_result+3
    eor #$ff
    adc #0
    sta expr_result+3

    lda expr_flags
    and #!F_EXPR_BRACKET_MASK
    sta expr_flags

@ok
    clc
@end
    rts


; factor    ::= negate ((* DIV / %) negate)*
expect_factor:
    jsr expect_negate
    lbcs @end

    ; Special error message for unsupported fraction operator
    lda #tk_fraction
    jsr expect_token
    bcs +
    lda #err_fraction_not_supported
    sta err_code
    sec
    lbra @end
+

@factor_loop
    lda #tk_multiply
    jsr expect_token
    bcc +
    lda #tk_remainder
    jsr expect_token
    bcc +
    lda #0
    ldx #<kw_div
    ldy #>kw_div
    jsr expect_keyword
    lbcs @ok

    ; A = tk_multiply, tk_remainder, or 0 = DIV
+   pha
    ldq expr_result
    stq multina
    jsr expect_negate
    pla
    sta expr_a
    lbcs @end  ; Operator but no term, fail
    ldq expr_result
    stq multinb
    lda expr_a

    cmp #tk_multiply
    bne +
    ldq product
    bra ++
+   ; DIV and remainder need to wait for DIVBUSY bit
-   ldx mathbusy
    bmi -
    cmp #tk_remainder
    bne +

    ; x % y = x - (x DIV y) * y
    ; We don't use divrema fractional part of the division because frac * y
    ; will have rounding issues.
    ldq multina   ; Rip x right out of the math register!
    stq expr_result
    ldq divquot   ; x DIV y
    stq multina   ; product = (x DIV y) * y
    ldq expr_result
    sec
    sbcq product  ; Q = x - (x DIV y) * y
    bra ++

+   ldq multinb
    bne +
    lda #err_division_by_zero
    sta err_code
    sec
    lbra @end
+   ldq divquot
++  stq expr_result
    lbra @factor_loop

@ok
    clc
@end
    rts


; term      ::= factor ((+ -) factor)*
expect_term:
    jsr expect_factor
    lbcs @end

@term_loop
    jsr expect_single_plus_or_minus
    lbcs @ok
+   pha
    +push32 expr_result
    jsr expect_factor
    +pull32 expr_b
    pla
    lbcs @end  ; Operator but no term, fail
    ; A=tk_pluses or tk_minuses
    cmp #tk_pluses
    bne +
    ; expr_result = expr_b + expr_result
    ldq expr_b
    clc
    adcq expr_result
    bra ++
+   ; expr_result = expr_b - expr_result
    ldq expr_b
    sec
    sbcq expr_result
++  stq expr_result
    lbra @term_loop

@ok
    clc
@end
    rts


; shift     ::= term ((<< >> >>>) term)*
expect_shift:
    jsr expect_term
    lbcs @end

@shift_loop
    lda #tk_asl
    jsr expect_token
    bcc +
    lda #tk_asr
    jsr expect_token
    bcc +
    lda #tk_lsr
    jsr expect_token
    lbcs @ok

+   pha
    +push32 expr_result
    jsr expect_term
    +pull32 expr_b
    pla
    lbcs @end  ; Operator but no term, fail

    taz
    ; Z = tk_asl, tk_asr, or tk_lsr
    ; Perform operation on expr_b, expr_result times. Store result in expr_result.
@count_loop
    lda expr_result+3
    ora expr_result+2
    ora expr_result+1
    ora expr_result
    lbeq @finish_count_loop

    clc
    cpz #tk_asl
    bne +
    ; asl
    asl expr_b
    rol expr_b+1
    rol expr_b+2
    rol expr_b+3
    bra +++
+   cpz #tk_asr
    bne +
    ; asr
    asr expr_b+3
    bra ++
+   ; lsr
    lsr expr_b+3
++  ror expr_b+2
    ror expr_b+1
    ror expr_b
+++

    sec
    lda expr_result
    sbc #1
    sta expr_result
    lda expr_result+1
    sbc #0
    sta expr_result+1
    lda expr_result+2
    sbc #0
    sta expr_result+2
    lda expr_result+3
    sbc #0
    sta expr_result+3
    lbra @count_loop

@finish_count_loop
    ldq expr_b
    stq expr_result
    lbra @shift_loop

@ok
    clc
@end
    rts


; bytesel   ::= (< > ^ ^^)? shift
expect_bytesel:
    lda #tk_lt
    jsr expect_token
    bcc +
    lda #tk_gt
    jsr expect_token
    bcc +
    lda #tk_power
    jsr expect_token
    bcc +
    lda #tk_megabyte
    jsr expect_token
    bcc +
    jsr expect_shift  ; Passthru
    lbra @end

+   pha
    jsr expect_shift
    pla
    lbcs @end  ; Operator but no term, fail
    ldx #0
    cmp #tk_lt
    beq +++
    cmp #tk_gt
    beq ++
    cmp #tk_power
    beq +
    inx  ; tk_megabyte
+   inx
++  inx
+++ lda expr_result,x
    sta expr_result
    lda #0
    sta expr_result+1
    sta expr_result+2
    sta expr_result+3

@ok
    clc
@end
    rts


; expr      ::= bytesel ((& XOR |) bytesel)*
expect_expr:
    jsr expect_bytesel
    lbcs @end

@bitop_loop
    lda #tk_ampersand
    jsr expect_token
    bcc +
    lda #tk_pipe
    jsr expect_token
    bcc +
    lda #tk_pipe2
    jsr expect_token
    bcc +
    lda #0
    ldx #<kw_xor
    ldy #>kw_xor
    jsr expect_keyword
    bcs @ok

+   pha
    +push32 expr_result
    jsr expect_bytesel
    +pull32 expr_b
    pla
    lbcs @end  ; Operator but no term, fail

    taz
    ; Z = tk_ampersand, tk_pipe, or 0 for XOR
    ; expr_result = expr_b <op> expr_result
    cpz #tk_ampersand
    bne +
    ; expr_b & expr_result
    lda expr_b
    and expr_result
    sta expr_result
    lda expr_b+1
    and expr_result+1
    sta expr_result+1
    lda expr_b+2
    and expr_result+2
    sta expr_result+2
    lda expr_b+3
    and expr_result+3
    sta expr_result+3
    lbra @bitop_loop

+   cpz #tk_pipe
    beq +
    cpz #tk_pipe2
    bne ++
    ; expr_b | expr_result
+   lda expr_b
    ora expr_result
    sta expr_result
    lda expr_b+1
    ora expr_result+1
    sta expr_result+1
    lda expr_b+2
    ora expr_result+2
    sta expr_result+2
    lda expr_b+3
    ora expr_result+3
    sta expr_result+3
    lbra @bitop_loop

++  ; expr_b XOR expr_result
    lda expr_b
    eor expr_result
    sta expr_result
    lda expr_b+1
    eor expr_result+1
    sta expr_result+1
    lda expr_b+2
    eor expr_result+2
    sta expr_result+2
    lda expr_b+3
    eor expr_result+3
    sta expr_result+3
    lbra @bitop_loop

@ok
    clc
@end
    rts


; ------------------------------------------------------------
; PC assignment
; ------------------------------------------------------------

; Input: tokbuf, tok_pos
; Output:
;   C=0 success, PC updated, tok_pos advanced
;   C=1 fail
;     err_code=0 not a PC assign statement, tok_pos not advanced
;     err_code>0 fatal error with line_pos set
assemble_pc_assign:
    ; "*" "=" expr
    lda #tk_multiply
    jsr expect_token
    lbcs statement_err_exit
    lda #tk_equal
    jsr expect_token
    lbcs statement_err_exit
    ldx tok_pos
    lda tokbuf+1,x  ; expr line_pos
    pha
    lda #0
    sta expr_flags
    jsr expect_expr
    plz             ; Z = expr line_pos
    lbcs statement_err_exit

    lda expr_flags
    and #F_EXPR_UNDEFINED
    beq +
    ; PC expression must be defined in first pass
    stz line_pos
    lda #err_pc_undef
    sta err_code
    lbra statement_err_exit

+   ; Value must be in address range
    lda expr_result+2
    ora expr_result+3
    beq +
    stz line_pos
    lda #err_value_out_of_range
    sta err_code
    lbra statement_err_exit

+   ; Set PC
    ldx expr_result
    ldy expr_result+1
    jsr set_pc
    lbra statement_ok_exit


; ------------------------------------------------------------
; Label assignment
; ------------------------------------------------------------

; Input: line_addr, X=label_pos
; Output:
;   X=0 global
;   X=1 cheap local
;   X=2 relative +
;   X=3 relative -
lbl_global = 0
lbl_cheaplocal = 1
lbl_relplus = 2
lbl_relminus = 3
determine_label_type:
    lda line_addr
    sta bas_ptr
    lda line_addr+1
    sta bas_ptr+1
    txa  ; label pos
    taz
    lda [bas_ptr],z
    cmp #'@'
    bne +
    ldx #lbl_cheaplocal
    rts
+   cmp #'+'
    bne +
    ldx #lbl_relplus
    rts
+   cmp #'-'
    bne +
    ldx #lbl_relminus
    rts
+   ldx #lbl_global
    rts


; Input: line_addr, X=label line pos, Y=label length
; Output:
; - C=0 found or added, attic_ptr=entry address
; - C=1 out of memory error
; Uses strbuf, expr_a.
find_or_add_label:
    phx
    phy

    ; Detect cheap local, rewrite name
    ; (X=label pos)
    jsr determine_label_type
    cpx #lbl_cheaplocal
    bne ++
    ldx #0  ; strbuf position
    ; Copy last-seen global name to strbuf
    lda last_pc_defined_global_label
    ora last_pc_defined_global_label+1
    beq +++  ; Never seen a global, no cheap local prefix
    lda last_pc_defined_global_label
    sta attic_ptr
    lda last_pc_defined_global_label+1
    sta attic_ptr+1
    lda #^attic_symbol_table
    sta attic_ptr+2
    lda #$08
    sta attic_ptr+3
    sta expr_a+3
    ldz #0
    lda [attic_ptr],z
    sta expr_a
    inz
    lda [attic_ptr],z
    sta expr_a+1
    inz
    lda [attic_ptr],z
    sta expr_a+2       ; expr_a = name of last seen global
    ldx #0
    ldz #0             ; Copy global name to strbuf
-   lda [expr_a],z
    beq +++
    sta strbuf,x
    inx
    inz
    bra -

++  ldx #0  ; strbuf position
+++

    ; Copy label text to strbuf.
    ply  ; Y = length
    plz  ; Z = line pos
    lda line_addr
    sta bas_ptr
    lda line_addr+1
    sta bas_ptr+1
    ; X is current strbuf position, from above
-   lda [bas_ptr],z
    sta strbuf,x
    inx
    inz
    dey
    bne -

    ; bas_ptr = strbuf; call find_or_add_symbol
    lda #<strbuf
    sta bas_ptr
    lda #>strbuf
    sta bas_ptr+1
    lda bas_ptr+2
    pha
    lda bas_ptr+3
    pha
    lda #0
    sta bas_ptr+2
    sta bas_ptr+3
    ; X = new length (text added to strbuf)
    jsr find_or_add_symbol
    pla
    sta bas_ptr+3  ; Important! restore bas_ptr
    pla
    sta bas_ptr+2
    rts


; Input: tokbuf, tok_pos
; Output:
;   C=0 success; label assigned, tok_pos advanced
;     Z = 0: was equal-assign, end statement
;     Z = 1: was PC assign, accept instruction or directive
;   C=1 fail
;     err_code=0 not a pc assign statement, tok_pos not advanced
;     err_code>0 fatal error with line_pos set
assemble_label:

    jsr expect_pluses_or_minuses
    lbcc @relative_label

    ; <label> ["=" expr]
    jsr expect_label
    lbcs statement_err_exit
    stx label_pos      ; line_pos
    sty label_length   ; length
    lda #tk_equal
    jsr expect_token
    lbcs @label_without_equal
    lda #0
    sta expr_flags
    jsr expect_expr
    lbcc @label_with_equal
    lda err_code
    lbne statement_err_exit
    lda label_pos
    sta line_pos
    lda #err_syntax  ; expr required after "="
    sta err_code
    lbra statement_err_exit

; (This is jsr'd.)
@find_or_add_symbol_to_define:
    ldx label_pos
    ldy label_length
    jsr find_or_add_label
    bcc +
    lda #err_out_of_memory
    sta err_code
    pla  ; pop caller address, go straight to exit
    pla
    lbra statement_err_exit
+
    ldz #3           ; Error if symbol is already defined in first pass
    lda [attic_ptr],z
    and #F_SYMTBL_DEFINED
    beq +
    bit pass
    bmi +
    lda label_pos
    sta line_pos
    lda #err_already_defined
    sta err_code
    pla  ; pop caller address, go straight to exit
    pla
    lbra statement_err_exit
+   rts

@label_with_equal:
    ; Only global-type labels can be assigned with =
    ldx label_pos
    jsr determine_label_type
    cpx #lbl_global
    beq +
    lda #err_label_assign_global_only
    sta err_code
    lbra statement_err_exit
+

    ; Set label to expr, possibly undefined
    jsr @find_or_add_symbol_to_define
    lda expr_flags
    and #F_EXPR_UNDEFINED
    beq +
    ldz #0  ; Return value
    lbra statement_ok_exit  ; label expr is undefined; leave symbol undefined
+
    ; label expr is defined, use value; propagate zero flag
    ldq expr_result
    jsr set_symbol_value
    lda expr_flags
    and #F_EXPR_FORCE16
    beq +
    ldz #3
    lda [attic_ptr],z
    ora #F_SYMTBL_LEADZERO
    sta [attic_ptr],z
+   ldz #0  ; Return value
    lbra statement_ok_exit

@label_without_equal
    ; Label without "=", set label to PC
    jsr @find_or_add_symbol_to_define
    ; PC undefined is an error
    jsr get_pc
    bcc +
    lda label_pos
    sta line_pos
    lda #err_pc_undef
    sta err_code
    lbra statement_err_exit
+   ; Move X/Y (from get_pc) to Q
    stx expr_result
    sty expr_result+1
    lda #0
    sta expr_result+2
    sta expr_result+3
    ldq expr_result
    jsr set_symbol_value

    ; Remember last seen PC-assigned global label
    ldx label_pos
    jsr determine_label_type
    cpx #lbl_global
    bne +
    lda attic_ptr
    sta last_pc_defined_global_label
    lda attic_ptr+1
    sta last_pc_defined_global_label+1
+

    ldz #1  ; Return value
    lbra statement_ok_exit

@relative_label
    ; Only add to rellabel table during first pass.
    ; (If we go multi-pass, this needs to be reconsidered.)
    bit pass
    bmi +++

    ; A=tk_pluses or tk_minuses, Y=length
    sta expr_a
    sty expr_a+1

    ; PC undefined is an error
    jsr get_pc
    bcc +
    ldx tok_pos
    lda tokbuf-2,x
    sta line_pos
    lda #err_pc_undef
    sta err_code
    lbra statement_err_exit
+
    lda expr_a
    cmp #tk_pluses
    bne +
    clc      ; C=0: plus
    bra ++
+   sec      ; C=1: minus
++  lda expr_a+1  ; A = len
    ; X/Y = PC (from get_pc)
    jsr add_rellabel

+++
    ldz #1  ; Return value
    lbra statement_ok_exit


; ------------------------------------------------------------
; Instructions
; ------------------------------------------------------------

; Input: expr_result, expr_flags
; Output: C=1 if expr is > 256 or is forced to 16-bit with leading zero
;   Also honors F_ASM_FORCE8/16 assembly flags.
is_expr_16bit:
    lda asm_flags
    and #F_ASM_FORCE_MASK
    cmp #F_ASM_FORCE16
    beq @yes_16
    cmp #F_ASM_FORCE8
    beq @no_16
    lda expr_flags
    and #F_EXPR_FORCE16
    bne @yes_16
    lda expr_result+1
    ora expr_result+2
    ora expr_result+3
    bne @yes_16
@no_16
    clc
    rts
@yes_16
    sec
    rts


!macro expect_addresing_expr_rts .mode {
    ldx #<.mode
    ldy #>.mode
    clc
    rts
}


force16_if_expr_undefined:
    lda asm_flags
    and #F_ASM_FORCE_MASK
    bne +  ; Undefined doesn't override other forces
    lda expr_flags
    and #F_EXPR_UNDEFINED
    beq +
    jsr add_forced16
    lda asm_flags
    and #!F_ASM_FORCE_MASK
    ora #F_ASM_FORCE16
    sta asm_flags
+   rts


; Input: expr_result, program_counter
; Output:
;   expr_result = expr_result - (program_counter + 2)
make_operand_rel:
    lda expr_flags
    and #F_EXPR_UNDEFINED
    beq +
    rts
+
    lda program_counter
    clc
    adc #2
    tay
    lda program_counter+1
    adc #0
    tax
    tya
    ldy #0
    ldz #0
    stq expr_a  ; expr_a = program_counter + 2
    ldq expr_result
    sec
    sbcq expr_a
    stq expr_result  ; expr_result = expr_result - expr_a
    rts


; Input: tokbuf, tok_pos, asm_flags
; Output:
;   C=0 ok, X/Y=addr mode flags (LSB/MSB), expr_result, expr_flags, tok_pos advanced
;   C=1 fail
;     err_code>0 fatal error with line_pos set
expect_addressing_expr:
    lda #0
    sta expr_result
    sta expr_result+1
    sta expr_result+2
    sta expr_result+3
    sta expr_flags
    sta err_code

    ; ":" or end of line: Implicit
    ldx tok_pos
    lda tokbuf,x
    beq +
    cmp #tk_colon
    beq +
    bra @try_immediate
+   +expect_addresing_expr_rts MODE_IMPLIED

@try_immediate
    ; "#" <expr>: Immediate
    lda #tk_hash
    jsr expect_token
    bcs @try_modes_with_leading_expr
    jsr expect_expr
    lbcs @addr_error
    ; Caller will coerce type to MODE_IMMEDIATE_WORD as needed.
    +expect_addresing_expr_rts MODE_IMMEDIATE

@try_modes_with_leading_expr
    ; Check if the current PC is on the "forced16" list.
    lda asm_flags
    and #F_ASM_FORCE16
    bne +  ; skip if already forced
    jsr find_forced16
    bcc +
    lda asm_flags
    and #!F_ASM_FORCE_MASK
    ora #F_ASM_FORCE16
    sta asm_flags
+

    ; Make the operand a relative address for branch instructions.
    ; (Leave it to assemble_instruction to range check.)
    jsr expect_expr
    lbcs @try_modes_without_leading_expr
    lda asm_flags
    and #F_ASM_AREL8
    beq +
    lda asm_flags   ; force16 for long branches
    and #!F_ASM_AREL_MASK
    ora #F_ASM_FORCE8
    sta asm_flags
    jsr make_operand_rel
    bra ++
+   lda asm_flags
    and #F_ASM_AREL16
    beq ++
    lda asm_flags   ; force16 for long branches
    and #!F_ASM_FORCE_MASK
    ora #F_ASM_FORCE16
    sta asm_flags
    jsr make_operand_rel
++

    jsr force16_if_expr_undefined
    ; Addressing modes that start with expressions:
    lda expr_flags
    and #F_EXPR_BRACKET_MASK
    cmp #F_EXPR_BRACKET_NONE
    lbne +++
    ; - Non-brackets:
    jsr is_expr_16bit
    bcs ++
    ;    <expr-8> ["," ("x" | "y")]
    lda #tk_comma
    jsr expect_token
    bcc +
    +expect_addresing_expr_rts MODE_BASE_PAGE
+   ldx #<kw_x
    ldy #>kw_x
    jsr expect_keyword
    bcs +
    +expect_addresing_expr_rts MODE_BASE_PAGE_X
+   ldx #<kw_y
    ldy #>kw_y
    jsr expect_keyword
    bcs +
    +expect_addresing_expr_rts MODE_BASE_PAGE_Y
+   lda asm_flags
    and #F_ASM_BITBRANCH
    beq +
    ldq expr_result
    stq expr_b
    jsr expect_expr
    bcs +
    ; <expr-8> "," <expr> (for bit branches)
    ; expr_b = ZP, expr_result = Rel
    jsr make_operand_rel
    ; Account for bit-branch instructions having a two-wide operand:
    ;   expr_result = expr_result - 1
    lda expr_result
    sec
    sbc #1
    sta expr_result
    lda expr_result+1
    sbc #0
    sta expr_result+1
    lda expr_result+2
    sbc #0
    sta expr_result+2
    lda expr_result+3
    sbc #0
    sta expr_result+3
    +expect_addresing_expr_rts MODE_BASE_PAGE
+   ; Syntax error: <expr-8> "," non-x/y
    lbra @addr_error

++  ; <expr-16> ["," ("x" | "y")]
    lda #tk_comma
    jsr expect_token
    bcc +
    +expect_addresing_expr_rts MODE_ABSOLUTE
+   ldx #<kw_x
    ldy #>kw_x
    jsr expect_keyword
    bcs +
    +expect_addresing_expr_rts MODE_ABSOLUTE_X
+   ldx #<kw_y
    ldy #>kw_y
    jsr expect_keyword
    bcs +
    +expect_addresing_expr_rts MODE_ABSOLUTE_Y
+   ; Syntax error: <expr-16> "," non-x/y
    lbra @addr_error

+++ cmp #F_EXPR_BRACKET_PAREN
    bne +++
    ; - Parens:
    jsr is_expr_16bit
    bcs ++
    ; "(" <expr-8> ")" ["," ("y" | "z")]
    lda #tk_comma
    jsr expect_token
    bcc +
    ; (Base page indirect no register implies "Z".)
    +expect_addresing_expr_rts MODE_BASE_PAGE_IND_Z
+   ldx #<kw_y
    ldy #>kw_y
    jsr expect_keyword
    bcs +
    +expect_addresing_expr_rts MODE_BASE_PAGE_IND_Y
+   ldx #<kw_z
    ldy #>kw_z
    jsr expect_keyword
    bcs +
    +expect_addresing_expr_rts MODE_BASE_PAGE_IND_Z
+   ; Syntax error: "(" <expr-8> ")" "," non-y/z
    lbra @addr_error

++  ; "(" <expr-16> ")"
    +expect_addresing_expr_rts MODE_ABSOLUTE_IND

+++ ; - Brackets:
    ;    "[" <expr-8> "]" ["," "z"]
    jsr is_expr_16bit
    bcc +
    ; Error: Argument out of range
    lda tok_pos  ; position error at beginning of expression
    sec
    sbc #8
    sta tok_pos
    tax
    lda tokbuf+1,x
    sta line_pos
    lda #err_value_out_of_range
    sta err_code
    lbra @addr_error

+   lda #tk_comma
    jsr expect_token
    bcs +  ; ,z is optional
    ldx #<kw_z
    ldy #>kw_z
    jsr expect_keyword
    bcc +  ; z is required if , is provided
    ; Syntax error: "[" <expr-8> "]" "," non-z
    lbra @addr_error
+   +expect_addresing_expr_rts MODE_32BIT_IND

@try_modes_without_leading_expr
    ; Addressing modes that don't start with expressions:
    lda #tk_lparen
    jsr expect_token
    bcc +
    lbra @addr_error
+   jsr expect_expr
    bcc +
    lbra @addr_error
+   jsr force16_if_expr_undefined
    lda #tk_comma
    jsr expect_token
    bcc +
    lbra @addr_error
+   ldx #<kw_sp
    ldy #>kw_sp
    jsr expect_keyword
    bcc +++
    ; (<expr-8>,x)
    ; (<expr-16>,x)
    ldx #<kw_x
    ldy #>kw_x
    jsr expect_keyword
    bcc +
    lbra @addr_error
+   lda #tk_rparen
    jsr expect_token
    bcc +
    lbra @addr_error
+   jsr is_expr_16bit
    bcs +
    +expect_addresing_expr_rts MODE_BASE_PAGE_IND_X
+   +expect_addresing_expr_rts MODE_ABSOLUTE_IND_X

+++ ; (<expr>,sp),y
    lda #tk_rparen
    jsr expect_token
    bcc +
    lbra @addr_error
+   lda #tk_comma
    jsr expect_token
    bcc +
    lbra @addr_error
+   ldx #<kw_y
    ldy #>kw_y
    jsr expect_keyword
    bcc +
    lbra @addr_error
+   +expect_addresing_expr_rts MODE_STACK_REL

@addr_error
    lda err_code
    bne +
    lda #err_syntax
    sta err_code
    ldx tok_pos
    lda tokbuf+1,x
    sta line_pos
+   sec
    rts


; Input: A=mnemonic ID
; Output: C=1 yes is branch
is_bitbranch_mnemonic:
    ; Relies on bbr0 to bbs7 being alphabetically consecutive
    cmp #mnemonic_bbr0
    bcc ++
    cmp #mnemonic_bbs7+1
    bcs +
    sec
    bra ++
+   clc
++  rts


; Input: A=mnemonic ID
; Output: C=1 yes is branch
is_branch_mnemonic:
    ; Relies on bbr7 to bvs being alphabetically consecutive
    ; Omits "b" instructions that aren't branches
    cmp #mnemonic_bbs7+1
    bcc ++
    cmp #mnemonic_bvs+1
    bcs +
    cmp #mnemonic_bit
    beq +
    cmp #mnemonic_bitq
    beq +
    cmp #mnemonic_brk
    beq +
    sec
    bra ++
+   clc
++  rts


; Input: A=mnemonic ID
; Output: C=1 yes is branch
is_long_branch_mnemonic:
    ; Relies on lbcc to lbvs being alphabetically consecutive
    cmp #mnemonic_lbcc
    bcc ++
    cmp #mnemonic_lbvs+1
    bcs +
    sec
    bra ++
+   clc
++  rts


; Inputs: instr_addr_mode, instr_mode_rec_addr
; Outputs: Upgrades an 8-bit mode to a 16-bit mode if the instruction supports
;   the latter but not the former; updates instr_addr_mode
coerce_8_to_16:
    ldx #0
@mode_loop
    ; Terminate loop if not found
    lda mode16_coercion,x
    ora mode16_coercion+1,x
    lbeq @end

    ; Identified mode is current before-coerce type?
    lda mode16_coercion,x
    cmp instr_addr_mode
    bne @next
    lda mode16_coercion+1,x
    cmp instr_addr_mode+1
    bne @next

    ; Identified instruction does not support before-coerce type?
    ldy #0
    lda (instr_mode_rec_addr),y
    and mode16_coercion,x
    bne @next
    iny
    lda (instr_mode_rec_addr),y
    and mode16_coercion+1,x
    bne @next

    ; Identified instruction supports after-coerce type?
    ldy #0
    lda (instr_mode_rec_addr),y
    and mode16_coercion+2,x
    bne @coerce
    iny
    lda (instr_mode_rec_addr),y
    and mode16_coercion+3,x
    bne @coerce

@next
    inx
    inx
    inx
    inx
    bra @mode_loop

@coerce
    lda mode16_coercion+2,x
    sta instr_addr_mode
    lda mode16_coercion+3,x
    sta instr_addr_mode+1

@end
    rts

; Input: tokbuf, tok_pos
; Output:
;   C=0 ok, tok_pos advanced, instruction bytes assembled to segment
;   C=1 fail
;     err_code>0 fatal error with line_pos set
assemble_instruction:

    ; <opcode> <addr-expr>
    lda tokbuf+1,x
    sta instr_line_pos  ; stash line_pos for errors
    jsr expect_opcode
    lbcs statement_err_exit
    sta instr_mnemonic_id
    ; Reset instruction flags
    lda asm_flags
    and #!(F_ASM_FORCE_MASK | F_ASM_AREL_MASK | F_ASM_BITBRANCH)
    sta asm_flags
    ; Propagate flags from tokenizer: 8-bit if +1, 16-bit if +2
    tya
    ora asm_flags
    sta asm_flags

    ; Locate addressing mode record for mnemonic
    lda instr_mnemonic_id
    sta instr_mode_rec_addr
    lda #0
    sta instr_mode_rec_addr+1
    clc
    row (easyasm_base_page << 8) + instr_mode_rec_addr
    row (easyasm_base_page << 8) + instr_mode_rec_addr  ; instr_mode_rec_addr = ID*4
    lda #<addressing_modes
    clc
    adc instr_mode_rec_addr
    sta instr_mode_rec_addr
    lda #>addressing_modes
    adc instr_mode_rec_addr+1
    sta instr_mode_rec_addr+1  ; instr_mode_rec_addr = address of mode record for mnemonic

    ; Set AREL8/AREL16 for branch/long branch instructions
    lda instr_mnemonic_id
    jsr is_branch_mnemonic
    bcc +
    lda asm_flags
    and #!F_ASM_AREL_MASK
    ora #F_ASM_AREL8
    sta asm_flags
    bra ++
+   jsr is_long_branch_mnemonic
    bcc ++
    lda asm_flags
    and #!F_ASM_AREL_MASK
    ora #F_ASM_AREL16
    sta asm_flags
++

    ; Set BITBRANCH for bit branch instructions
    ; Allows two-operand syntax
    lda instr_mnemonic_id
    jsr is_bitbranch_mnemonic
    bcc +
    lda asm_flags
    ora #F_ASM_BITBRANCH
    sta asm_flags
+

    ; Process the addressing mode expression
    jsr expect_addressing_expr
    lbcs statement_err_exit
    stx instr_addr_mode
    sty instr_addr_mode+1

    jsr coerce_8_to_16

    ; Match addressing mode to opcode; error if not supported
    ldy #0
    lda instr_addr_mode
    and (instr_mode_rec_addr),y
    sta instr_addr_mode
    iny
    lda instr_addr_mode+1
    and (instr_mode_rec_addr),y
    ora instr_addr_mode
    bne +
    ; Mode not supported.
    ; (detected mode = A/X)
    lda instr_line_pos
    sta line_pos
    lda #err_unsupported_addr_mode
    sta err_code
    lbra statement_err_exit

+   ; Start at beginning of strbuf.
    lda #0
    sta instr_buf_pos

    ; Assemble Q prefix
    ;   q_mnemonics : 0-term'd list of mnemonic IDs
    ;   Emit $42 $42
    ldx #0
-   lda q_mnemonics,x
    beq ++
    cmp instr_mnemonic_id  ; mnemonic ID
    beq +
    inx
    bra -
+   ; Is a Q instruction, emit $42 $42
    ldx instr_buf_pos
    lda #$42
    sta strbuf,x
    inx
    sta strbuf,x
    inx
    stx instr_buf_pos

++  ; Assemble 32-bit indirect prefix
    ;   MODE_32BIT_IND
    ;   Emit $EA
    lda instr_addr_mode
    and #<MODE_32BIT_IND
    beq ++
    ; Is 32-bit indirect, emit $EA
    ldx instr_buf_pos
    lda #$ea
    sta strbuf,x
    inx
    stx instr_buf_pos

++  ; Assemble instruction (mnemonic + mode) encoding
    ;   addressing_modes: (mode_bits_16, enc_addr_16)
    ;   Rotate mode_bits left, count Carry; index into enc_addr
    ;   Emit encoding byte
    lda instr_addr_mode
    pha
    lda instr_addr_mode+1
    pha
    ldy #0
    lda (instr_mode_rec_addr),y
    sta instr_supported_modes
    iny
    lda (instr_mode_rec_addr),y
    sta instr_supported_modes+1
    ldx #0
-   row (easyasm_base_page << 8) + instr_supported_modes
    bcc +
    inx
+   row (easyasm_base_page << 8) + instr_addr_mode
    bcc -
    pla
    sta instr_addr_mode+1
    pla
    sta instr_addr_mode
    ; X = index into enc_addr + 1
    dex  ; X = X - 1
    ldy #2
    lda (instr_mode_rec_addr),y
    sta code_ptr
    iny
    lda (instr_mode_rec_addr),y
    sta code_ptr+1
    txa
    tay
    lda (code_ptr),y  ; A = the instruction encoding byte
    ldx instr_buf_pos
    sta strbuf,x
    inx
    stx instr_buf_pos

    ; Assemble operand
    ;   MODES_NO_OPERAND
    ;   MODES_BYTE_OPERAND
    ;   MODES_WORD_OPERAND
    lda instr_addr_mode
    and #<MODES_WORD_OPERAND
    sta instr_supported_modes ; (clobbers instr_supported_modes)
    lda instr_addr_mode+1
    and #>MODES_WORD_OPERAND
    ora instr_supported_modes
    beq @maybe_byte_operand
    ; Word operand: emit two expr_result bytes
    ; Range check
    lda instr_mnemonic_id
    jsr is_long_branch_mnemonic  ; C=1: signed operand
    jsr is_expr_word
    bcs +
    lda #err_value_out_of_range
    sta err_code
    lbra statement_err_exit
+   ldx instr_buf_pos
    lda expr_result
    sta strbuf,x
    inx
    lda expr_result+1
    sta strbuf,x
    inx
    stx instr_buf_pos
    bra @add_bytes

@maybe_byte_operand
    lda instr_addr_mode
    and #<MODES_BYTE_OPERAND
    sta instr_supported_modes
    lda instr_addr_mode+1
    and #>MODES_BYTE_OPERAND
    ora instr_supported_modes
    beq @add_bytes  ; No operand, emit no more bytes
    ; For bit branch instructions, range-check and emit ZP (expr_b).
    ; Rest will emit the Rel8 (expr_result).
    lda asm_flags
    and #F_ASM_BITBRANCH
    beq +++
    ldq expr_result
    stq expr_a
    ldq expr_b
    stq expr_result
    jsr is_expr_byte
    bcs +
    lda #err_value_out_of_range
    sta err_code
    lbra statement_err_exit
+   ldx instr_buf_pos
    lda expr_result
    sta strbuf,x
    inx
    stx instr_buf_pos
    ldq expr_a
    stq expr_result
    clc
    bra +
+++
    ; Byte operand: emit one expr_result byte
    jsr is_branch_mnemonic  ; C=1: signed operand
+   jsr is_expr_byte
    bcs +
    lda #err_value_out_of_range
    sta err_code
    lbra statement_err_exit
+   ldx instr_buf_pos
    lda expr_result
    sta strbuf,x
    inx
    stx instr_buf_pos

@add_bytes
    ; Add bytes to segment
    ldx instr_buf_pos
    jsr assemble_bytes
    bcc ++
    bit pass
    bmi +
    lda err_code
    cmp #err_pc_undef
    bne +
    ; PC undef on pass 0 is ok
    lda #0
    sta err_code
    bra ++
+   lbra statement_err_exit
++  lbra statement_ok_exit


; ------------------------------------------------------------
; Directives
; ------------------------------------------------------------

; Input: tokbuf, tok_pos, line_addr
; Output:
;  C=0 ok, tok_pos advanced; X=line pos, Y=length
;  C=1 not found, tok_pos preserved
;    err_code>0, line_pos: report error in expression
expect_string_arg:
    ldx tok_pos
    lda tokbuf,x
    cmp #tk_string_literal
    beq +
    sec
    rts
+   inx
    lda tokbuf,x
    taz
    inx
    ldy tokbuf,x
    inx
    stx tok_pos
    tza
    tax
    inx  ; Starting quote not included
    clc
    rts

; Directives that process arg lists of arbitrary length use the
; process_arg_list macro and a handler routine with the following API:
;
; Input:
;   A==arg_type_string: string arg, X=line pos, Y=length
;   A==arg_type_expr: expression arg, expr_result
; Output:
;   err_code>0 : abort with error
arg_type_string = 1
arg_type_expr = 2
!macro process_arg_list .handler {
.loop
    jsr expect_string_arg
    bcs +
    lda #arg_type_string
    jsr .handler
    bra ++
+   lda #0
    sta expr_flags
    jsr expect_expr
    bcs +
    lda #arg_type_expr
    jsr .handler
    bra ++
+   lda err_code
    bne +
    lda #err_syntax
    sta err_code
+   lbra statement_err_exit
++  lda err_code
    lbne statement_err_exit
    lda #tk_comma
    jsr expect_token
    lbcc .loop
}


; General handler for byte/word/lword
; Input: A=arg type, etc.; Z=width (1, 2, 4)
do_assemble_bytes:
    cmp #arg_type_string
    bne +
    lda #err_invalid_arg
    sta err_code
    rts
+   ldx #0
    lda expr_result
    sta strbuf,x
    inx
    cpz #2
    bcc @end
    lda expr_result+1
    sta strbuf,x
    inx
    cpz #4
    bcc @end
    lda expr_result+2
    sta strbuf,x
    inx
    lda expr_result+3
    sta strbuf,x
    inx
@end
    jsr assemble_bytes
    rts

; !byte ...
; !8 ...
; Assembles byte values.
do_byte:
    ldz #1
    lbra do_assemble_bytes
assemble_dir_byte:
    +process_arg_list do_byte
    lbra statement_ok_exit

; !byte ...
; !8 ...
; Assembles word values, little-endian.
do_word:
    ldz #2
    lbra do_assemble_bytes
assemble_dir_word:
    +process_arg_list do_word
    lbra statement_ok_exit

; !32 ...
; Assembles long word values, little-endian.
do_lword:
    ldz #4
    lbra do_assemble_bytes
assemble_dir_lword:
    +process_arg_list do_lword
    lbra statement_ok_exit


; !warn ...
; Prints "Line #: " followed by one or more arguments.
; Value arguments print: "<dec> ($<hex>) "
; String arguments print their contents.
do_warn:
    taz

    bit pass
    bmi +
    rts
+

    cpz #arg_type_string
    bne +
    jsr print_bas_str
    rts

+   ldq expr_result
    jsr print_dec32
    +kprimm_start
    !pet " ($",0
    +kprimm_end

    ; Print expr_result as hex, adjusting for leading zeroes (32, 16, or 8 bit)
    lda expr_result+3
    ora expr_result+2
    ora expr_result+1
    beq ++
    lda expr_result+3
    ora expr_result+2
    beq +
    lda expr_result+3
    jsr print_hex8
    lda expr_result+2
    jsr print_hex8
+   lda expr_result+1
    jsr print_hex8
++  lda expr_result
    jsr print_hex8

    +kprimm_start
    !pet ") ",0
    +kprimm_end
    rts

assemble_dir_warn:
    ; Only print warnings on final pass.
    ; (Acme prints on every pass. Will I regret this?)
    bit pass
    bpl +
    jsr print_warning_line_number
+
    +process_arg_list do_warn

    bit pass
    bpl +
    lda #chr_cr
    +kcall bsout
+
    lda asm_flags
    ora #F_ASM_WARN
    sta asm_flags
    lbra statement_ok_exit


; !fill <count> [, <val>]
assemble_dir_fill:
    lda #0
    sta expr_flags
    jsr expect_expr
    bcc ++
    lda err_code
    bne +
    lda #err_missing_arg
    sta err_code
+   lbra statement_err_exit
++  ldq expr_result
    stq expr_b  ; expr_b = count
    lda #0      ; default fill value is 0
    sta expr_result
    sta expr_result+1
    sta expr_result+2
    sta expr_result+3
    lda #tk_comma
    jsr expect_token
    bcs @start_fill
    lda #0
    sta expr_flags
    jsr expect_expr
    bcc ++
    lda err_code
    bne +
    lda #err_missing_arg
    sta err_code
+   lbra statement_err_exit
++  lda expr_result+3  ; custom fill byte must be <256
    ora expr_result+2
    ora expr_result+1
    beq @start_fill
    lda #err_value_out_of_range
    sta err_code
    lbra statement_err_exit

    ; expr_result = fill byte
    ; expr_a = fill count
@start_fill
    ; Completely fill strbuf with the fill byte.
    lda expr_result  ; fill byte
    ldx #$00
-   sta strbuf,x
    inx
    bne -

    lda #0
    tax
    tay
    taz
    lda #$ff
    sta expr_result  ; expr_result = 255

@fill_loop
    ldq expr_result
    cpq expr_b
    bcs ++  ; count < 255, less than a block remaining
    ldx #$ff
    jsr assemble_bytes  ; assemble 255 fill bytes (uses expr_a)
    ldq expr_b
    sec
    sbcq expr_result
    stq expr_b  ; expr_b = expr_b - 255
    bra @fill_loop
++  ldx expr_b  ; remaining (< 255)
    jsr assemble_bytes  ; (does nothing if X=0)
    lbra statement_ok_exit


do_petscr:
    ; expr_a=0 for pet, expr_a=$ff for scr
    stz expr_a

    cmp #arg_type_string
    beq @do_petscr_string

    ; Emit expression.
    lda expr_result+3
    ora expr_result+2
    ora expr_result+1
    beq +
    lda #err_value_out_of_range
    sta err_code
    rts
+   ; Convert char literal expressions.
    bit expr_a
    bpl +
    lda expr_flags
    and #F_EXPR_BRACKET_CHARLIT
    cmp #F_EXPR_BRACKET_CHARLIT
    bne +
    ldx expr_result
    lda scr_table,x
    bra ++
+   lda expr_result
++  ldx #0
    sta strbuf,x
    inx
    lda #0
    sta strbuf,x
    ldx #1
    jsr assemble_bytes
    rts

@do_petscr_string
    ; X=line pos Y=len Z=scr
    cpy #0
    bne +
    rts
+
    txa
    clc
    adc line_addr
    sta bas_ptr
    lda #0
    adc line_addr+1
    sta bas_ptr+1
    ; bas_ptr = beginning of string
    ldx #0

    ; Y = length > 0
    ; X = strbuf pos
    ; Z = string pos
    ; expr_a = $ff if scr
    ldx #0
    ldz #0
-   lda [bas_ptr],z
    bit expr_a
    bpl +
    phx
    tax
    lda scr_table,x
    plx
+   sta strbuf,x
    inx
    inz
    dey
    bne -
    ; X = length
    jsr assemble_bytes
    rts


do_pet:
    ldz #0
    lbra do_petscr
assemble_dir_pet:
    +process_arg_list do_pet
    lbra statement_ok_exit
do_scr:
    ldz #$ff
    lbra do_petscr
assemble_dir_scr:
    +process_arg_list do_scr
    lbra statement_ok_exit


; !to "<fname>", <mode>
assemble_dir_to:
    jsr expect_string_arg
    bcc +
    lda #err_missing_arg
    sta err_code
    lbra statement_err_exit
+   stx expr_a    ; expr_a = string pos
    sty expr_a+1  ; expr_a+1 = length
    lda #tk_comma
    jsr expect_token
    bcc +
    lda #err_syntax
    sta err_code
    lbra statement_err_exit
+   ldx #<kw_cbm
    ldy #>kw_cbm
    jsr expect_keyword
    bcs +
    lda #F_FILE_CBM
    bra @to_parsed
+   ldx #<kw_plain
    ldy #>kw_plain
    jsr expect_keyword
    bcs +
    ; "plain" file type is not supported yet because I'm using KERNAL SAVE for
    ; now, which doesn't support it. Keeping the parsing just in case I change
    lda #err_unimplemented
    sta err_code
    lbra statement_err_exit
    ;lda #F_FILE_PLAIN
    ;bra @to_parsed
+   ldx #<kw_runnable
    ldy #>kw_runnable
    jsr expect_keyword
    bcs +
    lda #F_FILE_RUNNABLE
    bra @to_parsed
+   ; Wrong or missing keyword
    lda #err_syntax
    sta err_code
    lbra statement_err_exit

@to_parsed
    pha  ; mode flag

    ; Runnable sets PC; other modes un-set PC
    cmp #F_FILE_RUNNABLE
    bne +
    ldx #<bootstrap_ml_start
    ldy #>bootstrap_ml_start
    jsr set_pc
    bra ++
+   lda asm_flags
    and #!F_ASM_PC_DEFINED
    sta asm_flags
++

    bit pass
    bmi +
    pla
    lbra statement_ok_exit
+

    lda expr_a+1
    pha  ; filename length

    ; Add a file marker to the segment table.
    ; ($0000, $FFFF, fnameaddr32, fnamelen8, flags8)
    ldz #0
    lda #0
    sta [next_segment_byte_addr],z
    inz
    sta [next_segment_byte_addr],z
    inz
    lda #$ff
    sta [next_segment_byte_addr],z
    inz
    sta [next_segment_byte_addr],z
    inz

    ; expr_a = filename pos
    ; expr_a = filename address = line_addr + filename pos
    lda #0
    sta expr_a+1
    sta expr_a+2
    sta expr_a+3
    lda line_addr
    sta bas_ptr
    lda line_addr+1
    sta bas_ptr+1
    phz
    ldq bas_ptr    ; Adopt whatever bas_ptr's high bytes are
    clc
    adcq expr_a  ; Q = filename address
    stq expr_a
    plz
    lda expr_a
    sta [next_segment_byte_addr],z
    inz
    lda expr_a+1
    sta [next_segment_byte_addr],z
    inz
    lda expr_a+2
    sta [next_segment_byte_addr],z
    inz
    lda expr_a+3
    sta [next_segment_byte_addr],z
    inz

    pla  ; length
    sta [next_segment_byte_addr],z
    inz
    pla  ; flags
    sta [next_segment_byte_addr],z
    inz

    ; Advance next_segment_byte_addr and current_segment to this location.
    tza
    clc
    adc next_segment_byte_addr
    sta next_segment_byte_addr
    lda #0
    adc next_segment_byte_addr+1
    sta next_segment_byte_addr+1
    lda #0
    adc next_segment_byte_addr+2
    sta next_segment_byte_addr+2
    lda #0
    adc next_segment_byte_addr+3
    sta next_segment_byte_addr+3
    ldq next_segment_byte_addr
    stq current_segment

    ; Write new null terminator
    ldz #7
    lda #0
-   sta [next_segment_byte_addr],z
    dez
    bpl -

    lbra statement_ok_exit


; !cpu m65
; EasyAsm only supports the "m65" CPU. This directive exists to ignore "!cpu
; m65" and report an error for any other !cpu value, to make it easier to port
; Acme programs to EasyAsm.
assemble_dir_cpu:
    ldx #<kw_m65
    ldy #>kw_m65
    jsr expect_keyword
    bcs +
    lbra statement_ok_exit
+   lda #err_unsupported_cpu_mode
    sta err_code
    lbra statement_err_exit


assemble_dir_source:
assemble_dir_binary:
    lda #err_unimplemented
    sta err_code
    lbra statement_err_exit


directive_jump_table:
; Sorted by token ID
!word assemble_dir_to
!word assemble_dir_byte, assemble_dir_byte
!word assemble_dir_word, assemble_dir_word
!word assemble_dir_lword
!word assemble_dir_fill
!word assemble_dir_pet
!word assemble_dir_scr
!word assemble_dir_source
!word assemble_dir_binary
!word assemble_dir_warn
!word assemble_dir_cpu

assemble_directive:
    ; <pseudoop> arglist
    jsr expect_pseudoop
    lbcs statement_err_exit
    ; A=token ID
    sec
    sbc #tokid_after_mnemonics
    asl
    tax
    jmp (directive_jump_table,x)


; ------------------------------------------------------------
; Assembler
; ------------------------------------------------------------


statement_err_exit
    ldx stmt_tokpos
    stx tok_pos
    sec
    rts

statement_ok_exit
    clc
    rts


; Input: line_addr
; Output: err_code, line_pos
;  C=0 success, continue
;  C=1 stop assembly (err_code=0 end of program, other on error)
assemble_line:
    lda #0
    sta err_code

    lda line_addr
    sta bas_ptr
    lda line_addr+1
    sta bas_ptr+1

    ldz #0
    lda [bas_ptr],z
    inz
    ora [bas_ptr],z
    bne +
    ; End of program
    sec
    rts
+
    jsr tokenize
    lda err_code
    beq +
    ; Error return
    sec
    rts
+
    ldx #0
    stx tok_pos

@tokbuf_loop
    ldx tok_pos
    lda tokbuf,x
    lbeq @end_tokbuf
    stx stmt_tokpos

    jsr assemble_pc_assign
    lbcc @next_statement
    lda err_code
    lbne @err_exit

    jsr assemble_label
    bcs +
    cpz #0
    lbeq @next_statement
    ldx tok_pos
    lda tokbuf,x
    lbeq @end_tokbuf  ; label at end of line
    cmp #tk_colon
    beq @next_statement  ; colon follows label
    bra ++  ; label without equal not end of line or statement,
            ; must precede an instruction or directive
+   lda err_code
    lbne @err_exit

++
    jsr assemble_instruction
    bcc @next_statement
    lda err_code
    lbne @err_exit

    jsr assemble_directive
    bcc @next_statement
    lda err_code
    lbne @err_exit

    ; No statement patterns match. Syntax error.
    ldx tok_pos
    lda tokbuf+1,x
    sta line_pos
    lda #err_syntax
    sta err_code
    bra @err_exit

@next_statement
    ; If colon, try another statement.
    ; (This covers <label> ":" also.)
    lda #tk_colon
    jsr expect_token
    lbcc @tokbuf_loop

@must_end
    ldx tok_pos
    lda tokbuf,x
    beq @end_tokbuf
    lda #err_syntax
    sta err_code
    lda tokbuf+1,x
    sta line_pos
@err_exit
    sec
    rts
@end_tokbuf
    clc
    rts


; Input: pass
; Output:
;   err_code = 0: one full assembly pass
;   err_code > 0: error result
do_assemble_pass:
    lda #<(source_start+1)
    sta line_addr
    lda #>(source_start+1)
    sta line_addr+1

@line_loop
    jsr assemble_line
    bcs @end
    lda line_addr
    sta bas_ptr
    lda line_addr+1
    sta bas_ptr+1
    ldz #0
    lda [bas_ptr],z
    sta line_addr
    inz
    lda [bas_ptr],z
    sta line_addr+1
    bra @line_loop
@end
    rts


; Input: source in BASIC region
; Output:
;   err_code = 0: segment table built successfully
;   err_code > 0: error result
assemble_source:
    ; Do two assembly passes ($00, $FF), aborting for errors.
    lda #0
-   sta pass
    jsr init_pass
    jsr do_assemble_pass
    lda err_code
    bne @done
    bit pass
    bmi @done
    lda #$ff
    bra -
@done
    rts


; ------------------------------------------------------------
; Data
; ------------------------------------------------------------

; ---------------------------------------------------------
; Error message strings

err_message_tbl:
!word e01,e02,e03,e04,e05,e06,e07,e08,e09,e10,e11,e12,e13,e14,e15
!word e16,e17,e18,e19,e20

err_messages:
err_syntax = 1
e01: !pet "syntax error",0
err_pc_undef = 2
e02: !pet "program counter undefined",0
err_value_out_of_range = 3
e03: !pet "value out of range",0
err_unsupported_addr_mode = 4
e04: !pet "unsupported addressing mode for instruction",0
err_already_defined = 5
e05: !pet "symbol already defined",0
err_out_of_memory = 6
e06: !pet "out of memory",0
err_undefined = 7
e07: !pet "symbol undefined",0
err_pc_overflow = 8
e08: !pet "program counter overflowed $ffff",0
err_label_assign_global_only = 9
e09: !pet "only global labels can be assigned with =",0
err_unimplemented = 10
e10: !pet "unimplemented feature",0
err_exponent_negative = 11
e11: !pet "exponent cannot be negative",0
err_fraction_not_supported = 12
e12: !pet "fraction operator not supported",0
err_invalid_arg = 13
e13: !pet "argument not allowed",0
err_missing_arg = 14
e14: !pet "missing argument",0
err_division_by_zero = 15
e15: !pet "division by zero",0
err_unsupported_cpu_mode = 16
e16: !pet "unsupported cpu mode",0
err_segment_without_a_file = 17
e17: !pet "segment without a file, missing !to",0
err_disk_error = 18
e18: !pet "kernal disk error",0
err_device_not_present = 19
e19: !pet "disk device not present; to set device, use: set def #",0
err_runnable_wrong_segments = 20
e20: !pet "runnable file only supports one segment at default pc",0

warn_message_tbl:
!word w01
warn_messages:
warn_ldz_range = 1
w01: !pet "ldz with address $00-$FF behaves as $0000-$00FF (ldz+2 to silence)"

kernal_error_messages:
!word ke01,ke02,ke03,ke04,ke05,ke06,ke07,ke08,ke09
ke01: !pet "too many files are open",0
ke02: !pet "file already open",0
ke03: !pet "file not open",0
ke04: !pet "file not found",0
ke05: !pet "device not present",0
ke06: !pet "not input file",0
ke07: !pet "not output file",0
ke08: !pet "missing filename",0
ke09: !pet "illegal device number",0

; ---------------------------------------------------------
; Mnemonics token list
mnemonics:
!pet "adc",0   ; $01
mnemonic_adc = $01
!pet "adcq",0  ; $02
mnemonic_adcq = $02
!pet "and",0   ; $03
!pet "andq",0  ; $04
mnemonic_andq = $04
!pet "asl",0   ; $05
!pet "aslq",0  ; $06
mnemonic_aslq = $06
!pet "asr",0   ; $07
!pet "asrq",0  ; $08
mnemonic_asrq = $08
!pet "asw",0   ; $09
!pet "bbr0",0  ; $0A
mnemonic_bbr0 = $0A
!pet "bbr1",0  ; $0B
!pet "bbr2",0  ; $0C
!pet "bbr3",0  ; $0D
!pet "bbr4",0  ; $0E
!pet "bbr5",0  ; $0F
!pet "bbr6",0  ; $10
!pet "bbr7",0  ; $11
!pet "bbs0",0  ; $12
!pet "bbs1",0  ; $13
!pet "bbs2",0  ; $14
!pet "bbs3",0  ; $15
!pet "bbs4",0  ; $16
!pet "bbs5",0  ; $17
!pet "bbs6",0  ; $18
!pet "bbs7",0  ; $19
mnemonic_bbs7 = $19
!pet "bcc",0   ; $1A
!pet "bcs",0   ; $1B
!pet "beq",0   ; $1C
!pet "bit",0   ; $1D
mnemonic_bit = $1D
!pet "bitq",0  ; $1E
mnemonic_bitq = $1E
!pet "bmi",0   ; $1F
!pet "bne",0   ; $20
!pet "bpl",0   ; $21
!pet "bra",0   ; $22
!pet "brk",0   ; $23
mnemonic_brk = $23
!pet "bsr",0   ; $24
!pet "bvc",0   ; $25
!pet "bvs",0   ; $26
mnemonic_bvs = $26
!pet "clc",0   ; $27
!pet "cld",0   ; $28
!pet "cle",0   ; $29
!pet "cli",0   ; $2A
!pet "clv",0   ; $2B
!pet "cmp",0   ; $2C
!pet "cmpq",0  ; $2D
mnemonic_cmpq = $2D
!pet "cpq",0   ; $2E
mnemonic_cpq = $2E
!pet "cpx",0   ; $2F
!pet "cpy",0   ; $30
!pet "cpz",0   ; $31
!pet "dec",0   ; $32
!pet "deq",0   ; $33
mnemonic_deq = $33
!pet "dew",0   ; $34
!pet "dex",0   ; $35
!pet "dey",0   ; $36
!pet "dez",0   ; $37
!pet "eom",0   ; $38
!pet "eor",0   ; $39
!pet "eorq",0  ; $3A
mnemonic_eorq = $3A
!pet "inc",0   ; $3B
!pet "inq",0   ; $3C
mnemonic_inq = $3C
!pet "inw",0   ; $3D
!pet "inx",0   ; $3E
!pet "iny",0   ; $3F
!pet "inz",0   ; $40
!pet "jmp",0   ; $41
!pet "jsr",0   ; $42
!pet "lbcc",0  ; $43
mnemonic_lbcc = $43
!pet "lbcs",0  ; $44
!pet "lbeq",0  ; $45
!pet "lbmi",0  ; $46
!pet "lbne",0  ; $47
!pet "lbpl",0  ; $48
!pet "lbra",0  ; $49
!pet "lbvc",0  ; $4A
!pet "lbvs",0  ; $4B
mnemonic_lbvs = $4B
!pet "lda",0   ; $4C
mnemonic_lda = $4C
!pet "ldq",0   ; $4D
mnemonic_ldq = $4D
!pet "ldx",0   ; $4E
!pet "ldy",0   ; $4F
!pet "ldz",0   ; $50
mnemonic_ldz = $50
!pet "lsr",0   ; $51
!pet "lsrq",0  ; $52
mnemonic_lsrq = $52
!pet "map",0   ; $53
!pet "neg",0   ; $54
!pet "ora",0   ; $55
!pet "orq",0   ; $56
mnemonic_orq = $56
!pet "pha",0   ; $57
!pet "php",0   ; $58
!pet "phw",0   ; $59
mnemonic_phw = $59
!pet "phx",0   ; $5A
!pet "phy",0   ; $5B
!pet "phz",0   ; $5C
!pet "pla",0   ; $5D
!pet "plp",0   ; $5E
!pet "plx",0   ; $5F
!pet "ply",0   ; $60
!pet "plz",0   ; $61
!pet "rmb0",0  ; $62
!pet "rmb1",0  ; $63
!pet "rmb2",0  ; $64
!pet "rmb3",0  ; $65
!pet "rmb4",0  ; $66
!pet "rmb5",0  ; $67
!pet "rmb6",0  ; $68
!pet "rmb7",0  ; $69
!pet "rol",0   ; $6A
!pet "rolq",0  ; $6B
mnemonic_rolq = $6B
!pet "ror",0   ; $6C
!pet "rorq",0  ; $6D
mnemonic_rorq = $6D
!pet "row",0   ; $6E
!pet "rti",0   ; $6F
!pet "rtn",0   ; $70
!pet "rts",0   ; $71
!pet "sbc",0   ; $72
!pet "sbcq",0  ; $73
mnemonic_sbcq = $73
!pet "sec",0   ; $74
!pet "sed",0   ; $75
!pet "see",0   ; $76
!pet "sei",0   ; $77
!pet "smb0",0  ; $78
!pet "smb1",0  ; $79
!pet "smb2",0  ; $7A
!pet "smb3",0  ; $7B
!pet "smb4",0  ; $7C
!pet "smb5",0  ; $7D
!pet "smb6",0  ; $7E
!pet "smb7",0  ; $7F
!pet "sta",0   ; $80
!pet "stq",0   ; $81
mnemonic_stq = $81
!pet "stx",0   ; $82
!pet "sty",0   ; $83
!pet "stz",0   ; $84
!pet "tab",0   ; $85
!pet "tax",0   ; $86
!pet "tay",0   ; $87
!pet "taz",0   ; $88
!pet "tba",0   ; $89
!pet "trb",0   ; $8A
!pet "tsb",0   ; $8B
!pet "tsx",0   ; $8C
!pet "tsy",0   ; $8D
!pet "txa",0   ; $8E
!pet "txs",0   ; $8F
!pet "tya",0   ; $90
!pet "tys",0   ; $91
!pet "tza",0   ; $92
mnemonic_tza = $92
!byte 0
tokid_after_mnemonics = $93

; Token IDs for the Q mnemonics, which all use a $42 $42 encoding prefix
q_mnemonics:
!byte mnemonic_adcq, mnemonic_andq, mnemonic_aslq, mnemonic_asrq, mnemonic_bitq
!byte mnemonic_cmpq, mnemonic_cpq,  mnemonic_deq,  mnemonic_eorq, mnemonic_inq
!byte mnemonic_ldq,  mnemonic_lsrq, mnemonic_orq,  mnemonic_rolq, mnemonic_rorq
!byte mnemonic_sbcq, mnemonic_stq
!byte 0

; Pseudo-op table
; These tokens are preceded with a "!" character.
pseudoops:
po_to = tokid_after_mnemonics + 0
!pet "to",0
po_byte = tokid_after_mnemonics + 1
!pet "byte",0
po_8 = tokid_after_mnemonics + 2
!pet "8",0
po_word = tokid_after_mnemonics + 3
!pet "word",0
po_16 = tokid_after_mnemonics + 4
!pet "16",0
po_32 = tokid_after_mnemonics + 5
!pet "32",0
po_fill = tokid_after_mnemonics + 6
!pet "fill",0
po_pet = tokid_after_mnemonics + 7
!pet "pet",0
po_scr = tokid_after_mnemonics + 8
!pet "scr",0
po_source = tokid_after_mnemonics + 9
!pet "source",0
po_binary = tokid_after_mnemonics + 10
!pet "binary",0
po_warn = tokid_after_mnemonics + 11
!pet "warn",0
po_cpu = tokid_after_mnemonics + 12
!pet "cpu",0
!byte 0
last_po = po_cpu + 1

; Other tokens table
; These tokens are lexed up to their length, in order, with no delimiters.
; Note: + and - are tokenized separately.
other_tokens:
tk_complement = last_po + 0
!pet "!",0
tk_megabyte = last_po + 1
!pet "^^",0
tk_power = last_po + 2
!pet "^",0
tk_multiply = last_po + 3
!pet "*",0
tk_remainder = last_po + 4
!pet "%",0
tk_lsr = last_po + 5
!pet ">>>",0
tk_asr = last_po + 6
!pet ">>",0
tk_asl = last_po + 7
!pet "<<",0
tk_lt = last_po + 8
!pet "<",0
tk_gt = last_po + 9
!pet ">",0
tk_ampersand = last_po + 10
!pet "&",0
tk_pipe = last_po + 11
!pet 220,0  ; Typed by Mega + period or Mega + minus
tk_comma = last_po + 12
!pet ",",0
tk_hash = last_po + 13
!pet "#",0
tk_colon = last_po + 14
!pet ":",0
tk_equal = last_po + 15
!pet "=",0
tk_lparen = last_po + 16
!pet "(",0
tk_rparen = last_po + 17
!pet ")",0
tk_lbracket = last_po + 18
!pet "[",0
tk_rbracket = last_po + 19
!pet "]",0
tk_fraction = last_po + 20  ; (Not supported, but special error message)
!pet "/",0
tk_pipe2 = last_po + 21
!pet "|",0  ; The other PETSCII "pipe" character, just in case.
!byte 0
last_tk = tk_pipe2 + 1

; Other token IDs
tk_number_literal = last_tk + 0
tk_number_literal_leading_zero = last_tk + 1
tk_string_literal = last_tk + 2
tk_label_or_reg = last_tk + 3
tk_pluses = last_tk + 4
tk_minuses = last_tk + 5

; Keywords
; Tokenized as tk_label_or_reg. Case insensitive.
kw_x: !pet "x",0
kw_y: !pet "y",0
kw_z: !pet "z",0
kw_sp: !pet "sp",0
kw_div: !pet "div",0
kw_xor: !pet "xor",0
kw_cbm: !pet "cbm",0
kw_plain: !pet "plain",0
kw_runnable: !pet "runnable",0
kw_m65: !pet "m65",0


; ------------------------------------------------------------
; Instruction encodings
;
; The addressing_modes table consists of one entry per instruction mnemonic,
; four bytes per entry, in token ID order.
;
; The first two bytes are an addressing mode bitmask, one bit set for each
; addressing mode supported by the instruction.
;
; The last two bytes are the code address for the encoding list. (See below,
; starting with enc_adc.)
;
; The bit branch instructions, which take two operands, are not uniquely
; represented by this data structure. expect_addressing_expr will return the
; "base page" mode and leave the token position on the comma for further
; processing.
;
;     %11111111,
;      ^ Implied (parameterless, or A/Q)
;       ^ Immediate
;        ^ Immedate word
;         ^ Base-Page, branch relative, bit-test branch relative
;          ^ Base-Page X-Indexed
;           ^ Base-Page Y-Indexed
;            ^ Absolute, 16-bit branch relative
;             ^ Absolute X-Indexed
;               %11111111
;                ^ Absolute Y-Indexed
;                 ^ Absolute Indirect
;                  ^ Absolute Indirect X-Indexed
;                   ^ Base-Page Indirect X-Indexed
;                    ^ Base-Page Indirect Y-Indexed
;                     ^ Base-Page Indirect Z-Indexed (or no index)
;                      ^ 32-bit Base-Page Indirect Z-Indexed (or no index)
;                       ^ Stack Relative Indirect, Y-Indexed
MODES_NO_OPERAND     = %1000000000000000
MODES_BYTE_OPERAND   = %0101110000011111
MODES_WORD_OPERAND   = %0010001111100000
MODE_IMPLIED         = %1000000000000000
MODE_IMMEDIATE       = %0100000000000000
MODE_IMMEDIATE_WORD  = %0010000000000000
MODE_BASE_PAGE       = %0001000000000000
MODE_BASE_PAGE_X     = %0000100000000000
MODE_BASE_PAGE_Y     = %0000010000000000
MODE_ABSOLUTE        = %0000001000000000
MODE_ABSOLUTE_X      = %0000000100000000
MODE_ABSOLUTE_Y      = %0000000010000000
MODE_ABSOLUTE_IND    = %0000000001000000
MODE_ABSOLUTE_IND_X  = %0000000000100000
MODE_BASE_PAGE_IND_X = %0000000000010000
MODE_BASE_PAGE_IND_Y = %0000000000001000
MODE_BASE_PAGE_IND_Z = %0000000000000100
MODE_32BIT_IND       = %0000000000000010
MODE_STACK_REL       = %0000000000000001

; If addr mode identified as 8-bit, but instruction only supports the 16-bit
; equivalent, coerce the mode to 16-bit. From A to B:
mode16_coercion:
!word MODE_IMMEDIATE, MODE_IMMEDIATE_WORD
!word MODE_BASE_PAGE, MODE_ABSOLUTE
!word MODE_BASE_PAGE_X, MODE_ABSOLUTE_X
!word MODE_BASE_PAGE_Y, MODE_ABSOLUTE_Y
!word 0,0

addressing_modes:
!word 0,0 ; dummy entry "0" (tok IDs start at 1)
!word %0101101110011110  ; adc
!word enc_adc
!word %0001001000000110  ; adcq
!word enc_adcq
!word %0101101110011110  ; and
!word enc_and
!word %0001001000000110  ; andq
!word enc_andq
!word %1001101100000000  ; asl
!word enc_asl
!word %1001101100000000  ; aslq
!word enc_aslq
!word %1001100000000000  ; asr
!word enc_asr
!word %1001100000000000  ; asrq
!word enc_asrq
!word %0000001000000000  ; asw
!word enc_asw
!word %0001000000000000  ; bbr0
!word enc_bbr0
!word %0001000000000000  ; bbr1
!word enc_bbr1
!word %0001000000000000  ; bbr2
!word enc_bbr2
!word %0001000000000000  ; bbr3
!word enc_bbr3
!word %0001000000000000  ; bbr4
!word enc_bbr4
!word %0001000000000000  ; bbr5
!word enc_bbr5
!word %0001000000000000  ; bbr6
!word enc_bbr6
!word %0001000000000000  ; bbr7
!word enc_bbr7
!word %0001000000000000  ; bbs0
!word enc_bbs0
!word %0001000000000000  ; bbs1
!word enc_bbs1
!word %0001000000000000  ; bbs2
!word enc_bbs2
!word %0001000000000000  ; bbs3
!word enc_bbs3
!word %0001000000000000  ; bbs4
!word enc_bbs4
!word %0001000000000000  ; bbs5
!word enc_bbs5
!word %0001000000000000  ; bbs6
!word enc_bbs6
!word %0001000000000000  ; bbs7
!word enc_bbs7
!word %0001000000000000  ; bcc
!word enc_bcc
!word %0001000000000000  ; bcs
!word enc_bcs
!word %0001000000000000  ; beq
!word enc_beq
!word %0101101100000000  ; bit
!word enc_bit
!word %0001001000000000  ; bitq
!word enc_bitq
!word %0001000000000000  ; bmi
!word enc_bmi
!word %0001000000000000  ; bne
!word enc_bne
!word %0001000000000000  ; bpl
!word enc_bpl
!word %0001000000000000  ; bra
!word enc_bra
!word %1000000000000000  ; brk
!word enc_brk
!word %0000001000000000  ; bsr
!word enc_bsr
!word %0001000000000000  ; bvc
!word enc_bvc
!word %0001000000000000  ; bvs
!word enc_bvs
!word %1000000000000000  ; clc
!word enc_clc
!word %1000000000000000  ; cld
!word enc_cld
!word %1000000000000000  ; cle
!word enc_cle
!word %1000000000000000  ; cli
!word enc_cli
!word %1000000000000000  ; clv
!word enc_clv
!word %0101101110011110  ; cmp
!word enc_cmp
!word %0001001000000110  ; cmpq
!word enc_cmpq
!word %0001001000000110  ; cpq
!word enc_cmpq
!word %0101001000000000  ; cpx
!word enc_cpx
!word %0101001000000000  ; cpy
!word enc_cpy
!word %0101001000000000  ; cpz
!word enc_cpz
!word %1001101100000000  ; dec
!word enc_dec
!word %1001101100000000  ; deq
!word enc_deq
!word %0001000000000000  ; dew
!word enc_dew
!word %1000000000000000  ; dex
!word enc_dex
!word %1000000000000000  ; dey
!word enc_dey
!word %1000000000000000  ; dez
!word enc_dez
!word %1000000000000000  ; eom
!word enc_eom
!word %0101101110011110  ; eor
!word enc_eor
!word %0001001000000110  ; eorq
!word enc_eorq
!word %1001101100000000  ; inc
!word enc_inc
!word %1001101100000000  ; inq
!word enc_inq
!word %0001000000000000  ; inw
!word enc_inw
!word %1000000000000000  ; inx
!word enc_inx
!word %1000000000000000  ; iny
!word enc_iny
!word %1000000000000000  ; inz
!word enc_inz
!word %0000001001100000  ; jmp
!word enc_jmp
!word %0000001001100000  ; jsr
!word enc_jsr
!word %0000001000000000  ; lbcc
!word enc_lbcc
!word %0000001000000000  ; lbcs
!word enc_lbcs
!word %0000001000000000  ; lbeq
!word enc_lbeq
!word %0000001000000000  ; lbmi
!word enc_lbmi
!word %0000001000000000  ; lbne
!word enc_lbne
!word %0000001000000000  ; lbpl
!word enc_lbpl
!word %0000001000000000  ; lbra
!word enc_lbra
!word %0000001000000000  ; lbvc
!word enc_lbvc
!word %0000001000000000  ; lbvs
!word enc_lbvs
!word %0101101110011111  ; lda
!word enc_lda
!word %0001001000000110  ; ldq
!word enc_ldq
!word %0101011010000000  ; ldx
!word enc_ldx
!word %0101101100000000  ; ldy
!word enc_ldy
!word %0100001100000000  ; ldz
!word enc_ldz
!word %1001101100000000  ; lsr
!word enc_lsr
!word %1001101100000000  ; lsrq
!word enc_lsrq
!word %1000000000000000  ; map
!word enc_map
!word %1000000000000000  ; neg
!word enc_neg
!word %0101101110011110  ; ora
!word enc_ora
!word %0001001000000110  ; orq
!word enc_orq
!word %1000000000000000  ; pha
!word enc_pha
!word %1000000000000000  ; php
!word enc_php
!word %0010001000000000  ; phw
!word enc_phw
!word %1000000000000000  ; phx
!word enc_phx
!word %1000000000000000  ; phy
!word enc_phy
!word %1000000000000000  ; phz
!word enc_phz
!word %1000000000000000  ; pla
!word enc_pla
!word %1000000000000000  ; plp
!word enc_plp
!word %1000000000000000  ; plx
!word enc_plx
!word %1000000000000000  ; ply
!word enc_ply
!word %1000000000000000  ; plz
!word enc_plz
!word %0001000000000000  ; rmb0
!word enc_rmb0
!word %0001000000000000  ; rmb1
!word enc_rmb1
!word %0001000000000000  ; rmb2
!word enc_rmb2
!word %0001000000000000  ; rmb3
!word enc_rmb3
!word %0001000000000000  ; rmb4
!word enc_rmb4
!word %0001000000000000  ; rmb5
!word enc_rmb5
!word %0001000000000000  ; rmb6
!word enc_rmb6
!word %0001000000000000  ; rmb7
!word enc_rmb7
!word %1001101100000000  ; rol
!word enc_rol
!word %1001101100000000  ; rolq
!word enc_rolq
!word %1001101100000000  ; ror
!word enc_ror
!word %1001101100000000  ; rorq
!word enc_rorq
!word %0000001000000000  ; row
!word enc_row
!word %1000000000000000  ; rti
!word enc_rti
!word %0100000000000000  ; rtn
!word enc_rtn
!word %1100000000000000  ; rts
!word enc_rts
!word %0101101110011110  ; sbc
!word enc_sbc
!word %0001001000000110  ; sbcq
!word enc_sbcq
!word %1000000000000000  ; sec
!word enc_sec
!word %1000000000000000  ; sed
!word enc_sed
!word %1000000000000000  ; see
!word enc_see
!word %1000000000000000  ; sei
!word enc_sei
!word %0001000000000000  ; smb0
!word enc_smb0
!word %0001000000000000  ; smb1
!word enc_smb1
!word %0001000000000000  ; smb2
!word enc_smb2
!word %0001000000000000  ; smb3
!word enc_smb3
!word %0001000000000000  ; smb4
!word enc_smb4
!word %0001000000000000  ; smb5
!word enc_smb5
!word %0001000000000000  ; smb6
!word enc_smb6
!word %0001000000000000  ; smb7
!word enc_smb7
!word %0001101110011111  ; sta
!word enc_sta
!word %0001001000000110  ; stq
!word enc_stq
!word %0001011010000000  ; stx
!word enc_stx
!word %0001101100000000  ; sty
!word enc_sty
!word %0001101100000000  ; stz
!word enc_stz
!word %1000000000000000  ; tab
!word enc_tab
!word %1000000000000000  ; tax
!word enc_tax
!word %1000000000000000  ; tay
!word enc_tay
!word %1000000000000000  ; taz
!word enc_taz
!word %1000000000000000  ; tba
!word enc_tba
!word %0001001000000000  ; trb
!word enc_trb
!word %0001001000000000  ; tsb
!word enc_tsb
!word %1000000000000000  ; tsx
!word enc_tsx
!word %1000000000000000  ; tsy
!word enc_tsy
!word %1000000000000000  ; txa
!word enc_txa
!word %1000000000000000  ; txs
!word enc_txs
!word %1000000000000000  ; tya
!word enc_tya
!word %1000000000000000  ; tys
!word enc_tys
!word %1000000000000000  ; tza
!word enc_tza

; ------------------------------------------------------------
; Encoding lists
; Single-byte encodings for each supported addressing mode, msb to lsb in the bitfield
; Quad prefix $42 $42 and 32-bit Indirect prefix $ea are added in code.
; Example:
;   "adc",0,%01011011,%10011110
;             ^ Immediate = $69
;               ^ Base page = $65
;                ^ Base page, X-indexed = $75
;                  ^ Absolute = $6d
;                   ^ Absolute, X-indexed = $7d
;                      ^ Absolute, Y-indexed = $79
;                         ^ Base-Page Indirect X-Indexed = $61
;                          ^ Base-Page Indirect Y-Indexed = $71
;                           ^ Base-Page Indirect Z-Indexed = $72
;                            ^ 32-bit Base-Page Indirect Z-Indexed = ($EA) $72
enc_adc : !byte $69, $65, $75, $6d, $7d, $79, $61, $71, $72, $72
enc_adcq: !byte $65, $6d, $72, $72
enc_and : !byte $29, $25, $35, $2d, $3d, $39, $21, $31, $32, $32
enc_andq: !byte $25, $2d, $32, $32
enc_asl : !byte $0a, $06, $16, $0e, $1e
enc_aslq: !byte $0a, $06, $16, $0e, $1e
enc_asr : !byte $43, $44, $54
enc_asrq: !byte $43, $44, $54
enc_asw : !byte $cb
enc_bbr0: !byte $0f
enc_bbr1: !byte $1f
enc_bbr2: !byte $2f
enc_bbr3: !byte $3f
enc_bbr4: !byte $4f
enc_bbr5: !byte $5f
enc_bbr6: !byte $6f
enc_bbr7: !byte $7f
enc_bbs0: !byte $8f
enc_bbs1: !byte $9f
enc_bbs2: !byte $af
enc_bbs3: !byte $bf
enc_bbs4: !byte $cf
enc_bbs5: !byte $df
enc_bbs6: !byte $ef
enc_bbs7: !byte $ff
enc_bcc : !byte $90
enc_bcs : !byte $b0
enc_beq : !byte $f0
enc_bit : !byte $89, $24, $34, $2c, $3c
enc_bitq: !byte $24, $2c
enc_bmi : !byte $30
enc_bne : !byte $d0
enc_bpl : !byte $10
enc_bra : !byte $80
enc_brk : !byte $00
enc_bsr : !byte $63
enc_bvc : !byte $50
enc_bvs : !byte $70
enc_clc : !byte $18
enc_cld : !byte $d8
enc_cle : !byte $02
enc_cli : !byte $58
enc_clv : !byte $b8
enc_cmp : !byte $c9, $c5, $d5, $cd, $dd, $d9, $c1, $d1, $d2, $d2
enc_cmpq: !byte $c5, $cd, $d2, $d2
enc_cpx : !byte $e0, $e4, $ec
enc_cpy : !byte $c0, $c4, $cc
enc_cpz : !byte $c2, $d4, $dc
enc_dec : !byte $3a, $c6, $d6, $ce, $de
enc_deq : !byte $3a, $c6, $d6, $ce, $de
enc_dew : !byte $c3
enc_dex : !byte $ca
enc_dey : !byte $88
enc_dez : !byte $3b
enc_eom : !byte $ea
enc_eor : !byte $49, $45, $55, $4d, $5d, $59, $41, $51, $52, $52
enc_eorq: !byte $45, $4d, $52, $52
enc_inc : !byte $1a, $e6, $f6, $ee, $fe
enc_inq : !byte $1a, $e6, $f6, $ee, $fe
enc_inw : !byte $e3
enc_inx : !byte $e8
enc_iny : !byte $c8
enc_inz : !byte $1b
enc_jmp : !byte $4c, $6c, $7c
enc_jsr : !byte $20, $22, $23
enc_lbcc : !byte $93
enc_lbcs : !byte $b3
enc_lbeq : !byte $f3
enc_lbmi : !byte $33
enc_lbne : !byte $d3
enc_lbpl : !byte $13
enc_lbra : !byte $83
enc_lbvc : !byte $53
enc_lbvs : !byte $73
enc_lda : !byte $a9, $a5, $b5, $ad, $bd, $b9, $a1, $b1, $b2, $b2, $e2
enc_ldq : !byte $a5, $ad, $b2, $b2
enc_ldx : !byte $a2, $a6, $b6, $ae, $be
enc_ldy : !byte $a0, $a4, $b4, $ac, $bc
enc_ldz : !byte $a3, $ab, $bb
enc_lsr : !byte $4a, $46, $56, $4e, $5e
enc_lsrq: !byte $4a, $46, $56, $4e, $5e
enc_map : !byte $5c
enc_neg : !byte $42
enc_ora : !byte $09, $05, $15, $0d, $1d, $19, $01, $11, $12, $12
enc_orq : !byte $05, $0d, $12, $12
enc_pha : !byte $48
enc_php : !byte $08
enc_phw : !byte $f4, $fc
enc_phx : !byte $da
enc_phy : !byte $5a
enc_phz : !byte $db
enc_pla : !byte $68
enc_plp : !byte $28
enc_plx : !byte $fa
enc_ply : !byte $7a
enc_plz : !byte $fb
enc_rmb0: !byte $07
enc_rmb1: !byte $17
enc_rmb2: !byte $27
enc_rmb3: !byte $37
enc_rmb4: !byte $47
enc_rmb5: !byte $57
enc_rmb6: !byte $67
enc_rmb7: !byte $77
enc_rol : !byte $2a, $26, $36, $2e, $3e
enc_rolq: !byte $2a, $26, $36, $2e, $3e
enc_ror : !byte $6a, $66, $76, $6e, $7e
enc_rorq: !byte $6a, $66, $76, $6e, $7e
enc_row : !byte $eb
enc_rti : !byte $40
enc_rtn : !byte $62
enc_rts : !byte $60, $62
enc_sbc : !byte $e9, $e5, $f5, $ed, $fd, $f9, $e1, $f1, $f2, $f2
enc_sbcq: !byte $e5, $ed, $f2, $f2
enc_sec : !byte $38
enc_sed : !byte $f8
enc_see : !byte $03
enc_sei : !byte $78
enc_smb0: !byte $87
enc_smb1: !byte $97
enc_smb2: !byte $a7
enc_smb3: !byte $b7
enc_smb4: !byte $c7
enc_smb5: !byte $d7
enc_smb6: !byte $e7
enc_smb7: !byte $f7
enc_sta : !byte $85, $95, $8d, $9d, $99, $81, $91, $92, $92, $82
enc_stq : !byte $85, $8d, $92, $92
enc_stx : !byte $86, $96, $8e, $9b
enc_sty : !byte $84, $94, $8c, $8b
enc_stz : !byte $64, $74, $9c, $9e
enc_tab : !byte $5b
enc_tax : !byte $aa
enc_tay : !byte $a8
enc_taz : !byte $4b
enc_tba : !byte $7b
enc_trb : !byte $14, $1c
enc_tsb : !byte $04, $0c
enc_tsx : !byte $ba
enc_tsy : !byte $0b
enc_txa : !byte $8a
enc_txs : !byte $9a
enc_tya : !byte $98
enc_tys : !byte $2b
enc_tza : !byte $6b


; ------------------------------------------------------------
; Screen code translation table
; Index: PETSCII code, value: screen code
; Untranslatable characters become spaces.
scr_table:
!scr $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20
!scr $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20
!scr ' ', '!', $22, '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/'
!scr '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', ':', ';', '<', '=', '>', '?'
!scr '@', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o'
!scr 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '[', $1c, ']', $1e, $1f
!scr $40, 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O'
!scr 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', $5b, $5c, $5d, $5e, $5f
!scr $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20
!scr $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20, $20
!scr $60, $61, $62, $63, $64, $65, $66, $67, $68, $69, $6a, $6b, $6c, $6d, $6e, $6f
!scr $70, $71, $72, $73, $74, $75, $76, $77, $78, $79, $7a, $7b, $7c, $7d, $7e, $7f
!scr $40, 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O'
!scr 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', $5b, $5c, $5d, $5e, $5f
!scr $60, $61, $62, $63, $64, $65, $66, $67, $68, $69, $6a, $6b, $6c, $6d, $6e, $6f
!scr $70, $71, $72, $73, $74, $75, $76, $77, $78, $79, $7a, $7b, $7c, $7d, $7e, $7f


; ------------------------------------------------------------
; Bootstrap

bootstrap_basic_preamble:
!8 $12,$20,$0a,$00,$fe,$02,$20,$30,$3a,$9e,$20
!pet "$"
!byte '0' + ((bootstrap_ml_start >> 12) & $0f)
!byte '0' + ((bootstrap_ml_start >> 8) & $0f)
!byte '0' + ((bootstrap_ml_start >> 4) & $0f)
!byte '0' + (bootstrap_ml_start & $0f)
!8 $00,$00,$00
bootstrap_basic_preamble_end:
; (Acme needs this below the preamble so it is defined in the first pass.)
bootstrap_ml_start = source_start + 1 + bootstrap_basic_preamble_end - bootstrap_basic_preamble


; ---------------------------------------------------------
; Tests
; ---------------------------------------------------------

; A test suite provides run_test_suite_cmd, run with: SYS $1E04,8

!if TEST_SUITE > 0 {
    !warn "Adding test suite ", TEST_SUITE
    !source "test_common.asm"
    !if TEST_SUITE = 1 {
        !source "test_suite_1.asm"
    } else if TEST_SUITE = 2 {
        !source "test_suite_2.asm"
    } else if TEST_SUITE = 3 {
        !source "test_suite_3.asm"
    } else {
        !error "Invalid TEST_SUITE; check Makefile"
    }
} else {
    !warn "No TEST_SUITE requested"
run_test_suite_cmd: rts
}

; ---------------------------------------------------------

!warn "EasyAsm remaining code space: ", max_end_of_program - *
!if * >= max_end_of_program {
    !error "EasyAsm code is too large, * = ", *
}
