/*
 * ESP32-C6 RAM image layout: everything, code included, runs from RAM. The image is loaded
 * into RAM by espflash through the ROM's serial loader (or by the 2nd stage bootloader), and
 * nothing is read from flash afterwards.
 */
SECTIONS
{
  .ram.text : ALIGN(16)
  {
    microzig_ram_text_start = .;
    KEEP(*(microzig_ram_start))
    *(.text*)
    KEEP(*(.ram_text))
    KEEP(*(.ram_vectors))

    /* wifi rwtext */
    *( .wifi0iram  .wifi0iram.*)
    *( .wifirxiram  .wifirxiram.*)
    *( .wifislprxiram  .wifislprxiram.*)
    *( .wifislpiram  .wifislpiram.*)
    *( .phyiram  .phyiram.*)
    *( .iram1  .iram1.*)
    *( .wifiextrairam.* )
    *( .coexiram.* )

    /* The CPU prefetches up to 16 bytes past the last instruction. */
    . += 16;
  } > RAM

  .data : ALIGN(16)
  {
    microzig_data_start = .;
    *(.srodata*)
    *(.sdata*)
    *(.rodata*)
    *(.data*)
    /* wifi rodata and data */
    *(.rodata_wlog_*.*)
    *(.dram1 .dram1.*)
    . = ALIGN(16);
    microzig_data_end = .;
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

  /DISCARD/ : { *(.app_desc) }

  PROVIDE(__global_pointer$ = microzig_data_start + 0x800);
}
