/*
 * ESP32-C6 image boot layout.
 *
 * Differences from the C3:
 *  - Instruction and data SRAM are a single region (RAM at 0x4080_0000), so there
 *    is no IRAM/DRAM alias offsetting.
 *  - Flash is a unified I/D MMU window starting at 0x4200_0000 (SOC_MMU_DI_VADDR_SHARED).
 *    The bootloader rejects anything outside SOC_IROM_LOW..SOC_IROM_HIGH, so rodata and
 *    text share one region instead of the C3's separate DROM/IROM windows.
 *  - With shared vaddrs the bootloader treats the first flash segment as DROM (it must
 *    start with the app desc). Rodata is therefore placed first, and text starts on the
 *    next MMU page, so address order already gives the segment order elf2image needs.
 */
SECTIONS
{
  .flash_rodata_offset (NOLOAD) :
  {
    /* Skip 0x20 bytes for the esp image format mapping header. */
    . += 0x20;
  } > FLASH

  /* Keep section name used by esp-idf. This must be the first thing in the image. */
  .flash.appdesc : ALIGN(0x10)
  {
    KEEP(*(.app_desc))
    . = ALIGN(ALIGNOF(.flash.rodata));
  } > FLASH

  .flash.rodata : ALIGN(0x10)
  {
    *(.rodata*)
    *(.srodata*)

    . = ALIGN(ALIGNOF(.flash.rodata.wifi));
  } > FLASH

  .flash.rodata.wifi : ALIGN(0x10)
  {
    *(.rodata_wlog_*.*)
  } > FLASH

  /* Start text on a new MMU page so (flash offset % 64KiB) == (vaddr % 64KiB). */
  .flash_text_dummy (NOLOAD) :
  {
    /* MMU page size + 0x20 bytes for the mapping header. */
    . = ALIGN(0x10000) + 0x20;
  } > FLASH

  .flash.text :
  {
    KEEP(*(microzig_flash_start))
    *(.text*)

    /* The CPU prefetches up to 16 bytes past the last instruction. */
    . += 16;
  } > FLASH

  /* Align the section start, not just its contents: the bootloader copies RAM
     segments with word stores, so a segment must not start unaligned. */
  .ram.text : ALIGN(16)
  {
    KEEP(*(.ram_text))
    KEEP(*(.ram_vectors))
  } > RAM

  .ram.text.wifi : ALIGN(16)
  {
    *( .wifi0iram  .wifi0iram.*)
    *( .wifirxiram  .wifirxiram.*)
    *( .wifislprxiram  .wifislprxiram.*)
    *( .wifislpiram  .wifislpiram.*)
    *( .phyiram  .phyiram.*)
    *( .iram1  .iram1.*)
    *( .wifiextrairam.* )
    *( .coexiram.* )
  } > RAM

  .data : ALIGN(16)
  {
    microzig_data_start = .;
    *(.sdata*)
    *(.data*)
    . = ALIGN(16);
    microzig_data_end = .;
  } > RAM

  .data.wifi : ALIGN(16)
  {
    *(.dram1*)
  } > RAM

  .bss (NOLOAD) :
  {
    . = ALIGN(16);
    microzig_bss_start = .;
    *(.sbss*)
    *(.bss*)
    . = ALIGN(16);
    microzig_bss_end = .;
  } > RAM

  .heap (NOLOAD) :
  {
    microzig_heap_start = .;
    . = ORIGIN(RAM) + LENGTH(RAM);
    microzig_heap_end   = .;
  } > RAM

  PROVIDE(__global_pointer$ = microzig_data_start + 0x800);
}
