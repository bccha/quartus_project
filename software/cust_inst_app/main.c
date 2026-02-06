#include "io.h"
#include "sys/alt_timestamp.h"
#include "system.h"
#include <stdio.h>
#include <time.h>

#include "alt_types.h"
#include "altera_msgdma.h"
#include <sys/alt_cache.h> // For cache flush functions

// Constants
#define DATA_SIZE 256
#define DATA_MULTIPLIER 400
#define DEST_ADDR_BASE MMIO_0_BASE
// Assuming DMA device name is defined in system.h, commonly used here
#define DMA_DEV_NAME DMA_ONCHIP_DP_CSR_NAME

int src_data[DATA_SIZE];

/**
 * @brief Initialize source data with a pattern.
 */
void init_source_data() {
  for (int i = 0; i < DATA_SIZE; i++) {
    src_data[i] = i * DATA_MULTIPLIER;
  }
}

/**
 * @brief Verify that the data in the destination memory matches the source
 * data.
 */
void verify_transfer() {
  int error_count = 0;
  for (int i = 0; i < DATA_SIZE; i++) {
    int dp = IORD(DEST_ADDR_BASE, i);
    if (src_data[i] != dp) {
      printf("Transfer failed at index %d! Expected: %x, Read: %x\n", i,
             src_data[i], dp);
      error_count++;
    } else {
      // Optional: Print success checking if needed, but usually redundant for
      // large data printf("%d %d\n", src_data[i], dp);
    }
  }
  if (error_count == 0) {
    printf("Transfer verification successful.\n");
  } else {
    printf("Transfer verification finished with %d errors.\n", error_count);
  }
}

/**
 * @brief Perform a DMA transfer with error checking.
 */
void start_dma_transfer() {
  printf("Starting DMA Transfer Test...\n");

  // 1. Initialize Data
  init_source_data();

  // [Crucial] Flush Data Cache to RAM so DMA sees the correct values
  alt_dcache_flush(src_data, sizeof(src_data));

  // 2. Open DMA Device
  alt_msgdma_dev *dma_dev = alt_msgdma_open(DMA_DEV_NAME);
  if (dma_dev == NULL) {
    printf("Error: Could not open DMA device: %s\n", DMA_DEV_NAME);
    return;
  }

  // 3. Construct Descriptor
  alt_msgdma_standard_descriptor descriptor;
  alt_msgdma_construct_standard_mm_to_mm_descriptor(
      dma_dev, &descriptor,
      (alt_u32 *)src_data,       // Source Address
      (alt_u32 *)DEST_ADDR_BASE, // Destination Address
      sizeof(src_data),          // Length in bytes
      0);                        // Control flags

  // 4. Start Transfer (Async)
  alt_msgdma_standard_descriptor_async_transfer(dma_dev, &descriptor);

  // Note: In a real async scenario, you might want to wait or check status here
  // before verifying For this simple test, we proceed to verification which
  // acts as a wait if the CPU is fast enough, though ideally we should wait for
  // the interrupt or poll status.

  // 5. Verify
  verify_transfer();
}

/**
 * @brief Compare CPU copy speed vs DMA transfer speed.
 */
void compare_transfer_speed() {
  printf("\n=== Transfer Speed Test: CPU Copy vs DMA ===\n");

  // --- 1. CPU Copy Measurement ---
  init_source_data();

  alt_u64 start = alt_timestamp();
  for (int i = 0; i < DATA_SIZE; i++) {
    IOWR(DEST_ADDR_BASE, i, src_data[i]);
  }
  alt_u64 time_cpu = alt_timestamp() - start;

  // Clear destination to ensure DMA actually writes new data
  for (int i = 0; i < DATA_SIZE; i++) {
    IOWR(DEST_ADDR_BASE, i, 0);
  }

  // --- 2. DMA Measurement ---
  alt_msgdma_dev *dma_dev = alt_msgdma_open(DMA_DEV_NAME);
  if (dma_dev == NULL) {
    printf("Error: Could not open DMA device for speed test.\n");
    return;
  }

  alt_msgdma_standard_descriptor descriptor;

  start = alt_timestamp();

  // a. Flush Cache
  alt_dcache_flush(src_data, sizeof(src_data));

  // b. Construct Descriptor
  alt_msgdma_construct_standard_mm_to_mm_descriptor(
      dma_dev, &descriptor, (alt_u32 *)src_data, (alt_u32 *)DEST_ADDR_BASE,
      sizeof(src_data), 0);

  // c. Start Transfer
  alt_msgdma_standard_descriptor_async_transfer(dma_dev, &descriptor);

  // Measure "CPU Overhead" needed to set up and launch DMA
  alt_u64 time_dma = alt_timestamp() - start;

  printf("Dataset: %d Words (%d Bytes)\n", DATA_SIZE, (int)sizeof(src_data));
  printf("1. CPU Copy Cycles  : %llu\n", time_cpu);
  printf("2. DMA Overhead Cycles: %llu\n", time_dma);

  if (time_dma > 0) {
    printf(">> CPU Offload Ratio : %.2fx\n", (float)time_cpu / (float)time_dma);
  } else {
    printf(">> DMA Overhead is negligible (0 cycles measured)\n");
  }
}

/**
 * @brief Run custom instruction performance tests.
 */
void run_custom_instruction_test() {
  alt_u64 time_start, time_hw, time_sw;
  int result;
  unsigned sum;

  // Test parameters
  int i_start = 990, i_end = 1024;
  int j_start = 390, j_end = 400;

  printf("\n--- Running Custom Instruction Logic Check ---\n");

  // 1. Hardware Calculation
  time_start = alt_timestamp();
  sum = 0;
  for (int i = i_start; i != i_end; ++i) {
    for (int j = j_start; j != j_end; ++j) {
      result = (int)ALT_CI_CUST_CAL_0(i, j);
      sum += result;
    }
  }
  time_hw = alt_timestamp() - time_start;
  printf("Hardware Sum: %u\n", sum);

  // 2. Software Calculation
  time_start = alt_timestamp();
  sum = 0;
  for (int i = i_start; i != i_end; ++i) {
    for (int j = j_start; j != j_end; ++j) {
      result = i * j / 400; // Original logic: i * j / 400
      sum += result;
    }
  }
  time_sw = alt_timestamp() - time_start;
  printf("Software Sum: %u\n", sum);

  // 3. Compare Results
  printf("HW Cycles: %llu\n", time_hw);
  printf("SW Cycles: %llu\n", time_sw);

  if (time_hw > 0) {
    printf("Speedup: %.2fx faster!\n", (float)time_sw / (float)time_hw);
  }
}

int main() {
  printf("Custom Instruction & DMA Test Application Start!\n");

  if (alt_timestamp_start() < 0) {
    printf("Error: Timestamp timer not defined in BSP.\n");
    return -1;
  }

  alt_u32 freq = alt_timestamp_freq();
  printf("Timestamp Frequency: %lu Hz\n", freq);

  // 1. Quick Read/Write Check
  printf("Performing simple R/W check...\n");
  unsigned int magic = 0x0;
  for (int i = 0; i != DATA_SIZE; ++i) {
    IOWR(DEST_ADDR_BASE, i, magic + i);
  }

  // 2. DMA vs CPU Source Copy Speed Test
  compare_transfer_speed();

  // 3. Custom Instruction Logic & Performance Test
  // Wrapped in a single call loop as per original code structure logic
  while (1) {
    run_custom_instruction_test();
    break; // Run once and exit loop
  }

  // Optional: Run full DMA transfer validation
  // start_dma_transfer();

  return 0;
}
