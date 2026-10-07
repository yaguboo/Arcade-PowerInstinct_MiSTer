//============================================================================
//  Power Instinct -- SDRAM ROM map (byte addresses)
//
//  The single source of truth shared with tools/build_rom.py (REGIONS) and the
//  generated .mra.  Change both or neither.
//
//  Every region holds the ROM FILE'S OWN BYTES in file order (DECISIONS D2).
//  The byte order the hardware sees is restored in RTL, per region:
//
//    maincpu  MAME ROM_LOAD16_WORD_SWAP -- the files are little-endian words,
//             so the 68000 word at W is { byte W+1, byte W }.
//             ROM_MEASURED: swapped, SSP = 0x0018F300 and PC = 0x00000208;
//             unswapped they read 0x180000F3 / 0x00000802.
//    sprites  also ROM_LOAD16_WORD_SWAP (second build).
//    others   plain byte ROMs.
//
//  sh_download convention: SDRAM word W = { byte 2W, byte 2W+1 }.
//
//  NO include guard.  These are localparams, scoped to the module that
//  includes the file, and two modules do (pi_top, pi_romarb).  A guard made
//  the second one see nothing -- Verilator lint, 2026-09-15.
//============================================================================

localparam [24:0] PI_MAIN_BASE = 25'h000_0000;   // 93095-3a + 93095-4, 1 MB
localparam [24:0] PI_SND_BASE  = 25'h010_0000;   // 93095-2, 128 KB (Z80 sees 0000-bfff)
localparam [24:0] PI_FG_BASE   = 25'h012_0000;   // 93095-1, 128 KB, 8x8 text
localparam [24:0] PI_PROM_BASE = 25'h014_0000;   // 20.u54 @+0, 21.u71 @+0x100, 22.u81 @+0x200
localparam [24:0] PI_BG_BASE   = 25'h020_0000;   // 93095-5,-6,-7, 2.5 MB
localparam [24:0] PI_OKI1_BASE = 25'h050_0000;   // 93095-10,-11, 2 MB
localparam [24:0] PI_OKI2_BASE = 25'h070_0000;   // 93095-8,-9, 2 MB
localparam [24:0] PI_SPR_BASE  = 25'h090_0000;   // 93095-12..-19, 8 MB
localparam [24:0] PI_ROM_END   = 25'h110_0000;
