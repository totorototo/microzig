/*
 * ESP32-C6 direct boot layout: no 2nd stage bootloader, the binary is written at flash
 * offset 0.
 *
 * The ROM recognises the two magic words at the start of flash, maps the flash to the unified
 * I/D window at 0x4200_0000 (4 MiB), and jumps to 0x4200_0008, right after them. Address and
 * flash offset are the same thing here (vaddr = 0x4200_0000 + offset), so text and rodata run
 * in place. Code and data that live in RAM are kept in one output section, so the startup
 * code copies them with a single copy from `microzig_data_load_start`.
 */
SECTIONS
{
  .flash.text ORIGIN(FLASH) : AT(ORIGIN(FLASH))
  {
    /* Magic words, then `_start`. */
    KEEP(*(microzig_flash_start))
    *(.text*)

    /* The CPU prefetches up to 16 bytes past the last instruction. */
    . += 16;
    . = ALIGN(16);
  } > FLASH

  .flash.rodata : ALIGN(16)
  {
    *(.rodata*)
    *(.srodata*)
    /* wifi rodata */
    *(.rodata_wlog_*.*)
    . = ALIGN(16);
  } > FLASH

  /* RAM code and initialised data, loaded from flash right after rodata. */
  .ram : ALIGN(16)
  {
    microzig_data_start = .;
    KEEP(*(.ram_text))
    KEEP(*(.ram_vectors))

    . = ALIGN(16);
    /* wifi rwtext */
    *( .wifi0iram  .wifi0iram.*)
    *( .wifirxiram  .wifirxiram.*)
    *( .wifislprxiram  .wifislprxiram.*)
    *( .wifislpiram  .wifislpiram.*)
    *( .phyiram  .phyiram.*)
    *( .iram1  .iram1.*)
    *( .wifiextrairam.* )
    *( .coexiram.* )

    . = ALIGN(16);
    *(.sdata*)
    *(.data*)
    /* wifi data */
    *(.dram1*)
    . = ALIGN(16);
    microzig_data_end = .;
  } > RAM AT > FLASH

  microzig_data_load_start = LOADADDR(.ram);

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

  /* Only the 2nd stage bootloader reads the app descriptor. */
  /DISCARD/ : { *(.app_desc) }

  PROVIDE(__global_pointer$ = microzig_data_start + 0x800);

  ASSERT(LOADADDR(.ram) + SIZEOF(.ram) <= ORIGIN(FLASH) + 0x400000,
         "direct boot: the ROM maps only the first 4 MiB of flash")
}
