#include "io.h"
#include "sys/alt_timestamp.h"
#include "system.h"
#include <stdio.h>
#include <time.h>

#include "alt_types.h"
#include "altera_msgdma.h"
#include "altera_msgdma_csr_regs.h" // For busy bit polling
#include <stdlib.h>                 // For abs()
#include <sys/alt_cache.h>          // For cache flush functions

// Constants
#define DATA_SIZE 256
#define DATA_MULTIPLIER 900
#define DEST_ADDR_BASE MMIO_0_BASE
// Assuming DMA device name is defined in system.h, commonly used here
#define DMA_DEV_NAME DMA_ONCHIP_DP_CSR_NAME

int src_data[DATA_SIZE];

/**
 * @brief Initialize source data with a pattern.
 */
void init_source_data() {
  for (int i = 0; i < DATA_SIZE; i++) {
    src_data[i] = DATA_MULTIPLIER + i;
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

  // Measure "Launch Overhead" (Time to set up and start DMA)
  alt_u64 time_launch = alt_timestamp() - start;

  // d. Wait for Transfer to Complete (Busy polling)
  while (IORD_ALTERA_MSGDMA_CSR_STATUS(dma_dev->csr_base) &
         ALTERA_MSGDMA_CSR_BUSY_MASK)
    ;

  // Measure Total Time (Setup + Launch + Wait)
  alt_u64 time_total = alt_timestamp() - start;

  // e. Verify Data (Using the verify_transfer function)
  printf("   [Verifying DMA Data...]\n");
  verify_transfer();

  printf("Dataset: %d Words (%d Bytes)\n", DATA_SIZE, (int)sizeof(src_data));
  printf("1. CPU Copy Cycles    : %llu\n", time_cpu);
  printf("2. DMA Launch Overhead: %llu\n", time_launch);
  printf("3. DMA Total Cycles   : %llu\n", time_total);

  if (time_total > 0) {
    printf(">> CPU Offload Ratio (Total) : %.2fx\n",
           (float)time_cpu / (float)time_total);
  }
}

/**
 * @brief Run the stream processor test (Memory -> mSGDMA Read -> Stream
 * Processor -> mSGDMA Write -> Memory).
 */
void run_stream_processor_test(int coeff_a) {
  printf("\n--- Starting Stream Processor Test (Modular SGDMA) ---\n");
  printf("Setting Stream Processor Coeff A = %d\n", coeff_a);

// 1. Set Stream Processor Coefficient (Offset 0)
// Ensure we use the correct base address definition from system.h
#ifdef STREAM_MULTDIV_BASE
  IOWR(STREAM_MULTDIV_BASE, 0, coeff_a);
  printf("coeff written %d\n", IORD(STREAM_MULTDIV_BASE, 0));

  // Note: bypass mode is set by caller (don't overwrite it here)
  // IOWR(STREAM_MULTDIV_BASE, 1, 0);
  int bypass = IORD(STREAM_MULTDIV_BASE, 1);
  printf("bypass mode: %d (0=multiply, 1=passthrough)\n", bypass);
#else
  printf("Error: STREAM_MULTDIV_BASE not defined!\n");
  return;
#endif

  // 2. Initialize Data
  init_source_data();

  // DEBUG: Clear destination with unique pattern to verify DMA path
  printf("DEBUG: Initializing DPRAM with 0xDEAD0000 pattern...\n");
  for (int i = 0; i < DATA_SIZE; i++) {
    IOWR(DEST_ADDR_BASE, i, 0xDEAD0000 + i);
  }
  printf("DEBUG: First 3 values in DPRAM: 0x%X, 0x%X, 0x%X\n",
         IORD(DEST_ADDR_BASE, 0), IORD(DEST_ADDR_BASE, 1),
         IORD(DEST_ADDR_BASE, 2));

  // [Crucial] Flush Data Cache to RAM so DMA sees the correct values
  alt_dcache_flush(src_data, sizeof(src_data));
  // If destination is in cacheable memory, we should also flush or invalidate
  // it, but for on-chip memory (if tight coupled) it might be okay. Good
  // practice to flush destination range from cache if it was written by CPU.
  alt_dcache_flush((void *)DEST_ADDR_BASE, sizeof(src_data));

  // 3. Open DMA Devices
  alt_msgdma_dev *dma_read = alt_msgdma_open(MSGDMA_READ_CSR_NAME);
  alt_msgdma_dev *dma_write = alt_msgdma_open(MSGDMA_WRITE_CSR_NAME);

  if (dma_read == NULL || dma_write == NULL) {
    printf("Error: Could not open DMA devices.\n");
    if (!dma_read)
      printf("  Failed: %s\n", MSGDMA_READ_CSR_NAME);
    if (!dma_write)
      printf("  Failed: %s\n", MSGDMA_WRITE_CSR_NAME);
    return;
  }

  // 4. Construct Descriptors
  alt_msgdma_standard_descriptor desc_read, desc_write;

  // Read: Memory to Stream
  alt_msgdma_construct_standard_mm_to_st_descriptor(
      dma_read, &desc_read, (alt_u32 *)src_data, sizeof(src_data), 0);

  // Write: Stream to Memory
  alt_msgdma_construct_standard_st_to_mm_descriptor(
      dma_write, &desc_write, (alt_u32 *)DEST_ADDR_BASE, sizeof(src_data), 0);

  alt_u64 start = alt_timestamp();

  // 5. Start Transfers
  // Important: Start the WRITE (Sink) first so it's ready to receive data.
  alt_msgdma_standard_descriptor_async_transfer(dma_write, &desc_write);
  // Then start the READ (Source) to push data into the stream.
  alt_msgdma_standard_descriptor_async_transfer(dma_read, &desc_read);

  // 6. Wait for completion
  // We poll the WRITE dispatcher to know when all data has been written to
  // memory.
  while (IORD_ALTERA_MSGDMA_CSR_STATUS(dma_write->csr_base) &
         ALTERA_MSGDMA_CSR_BUSY_MASK)
    ;

  alt_u64 total_time = alt_timestamp() - start;
  alt_u32 freq = alt_timestamp_freq();
  printf("Stream Processing Done. Cycles: %lu (Time: %lu us)\n",
         (unsigned long)total_time,
         (unsigned long)(total_time * 1000000 / freq));

// 7. Diagnostic Readback
#ifdef STREAM_MULTDIV_BASE
  int hw_coeff = IORD(STREAM_MULTDIV_BASE, 0);
  int hw_bypass = IORD(STREAM_MULTDIV_BASE, 1);
  int asi_valid_cnt = IORD(STREAM_MULTDIV_BASE, 2);   // DEBUG
  int last_input_data = IORD(STREAM_MULTDIV_BASE, 3); // DEBUG: Last Input Data

  printf("Hardware Diagnostics -> Coeff: %d, Bypass: %d\n", hw_coeff,
         hw_bypass & 1);
  printf("DEBUG -> asi_valid_count: %d, Last Input Data Seen: 0x%X\n",
         asi_valid_cnt, last_input_data);
#endif

  // 8. Verify Data
  printf("   [Verifying Stream Data...]\n");
  // verify_transfer(); // Old: Check Copy

  // New: Check Arithmetic Result
  int error_count = 0;
  for (int i = 0; i < DATA_SIZE; i++) {
    int input = src_data[i];
    // DEBUG: Testing with constant addition
    // DEBUG: Calculate expected value based on mode
    int expected;
    // Reciprocal Multiplication for / 400 (Software uses ideal division)
    if (bypass) {
      expected = input;
    } else {
      expected = (input * coeff_a) / 400;
    }
    int actual = IORD(DEST_ADDR_BASE, i);

    // Allow margin of error +/- 1
    if (abs(actual - expected) > 1) {
      if (error_count < 10) { // Limit error prints
        printf("Mismatch at %d: In=%d, Expected=%d, Actual=%d (diff=%d)\n", i,
               input, expected, actual, actual - expected);
      }
      error_count++;
    }
  }

  if (error_count == 0) {
    printf("   [Stream Data Verification: PASS]\n");
  } else {
    printf("   [Stream Data Verification: FAIL - %d errors]\n", error_count);
  }

  // 9. CPU Benchmark (Software Calculation Speed Test)
  printf("\n   [Running CPU Benchmark...]\n");

  // Clear destination again just to be sure we are writing fresh
  for (int i = 0; i < DATA_SIZE; i++) {
    IOWR(DEST_ADDR_BASE, i, 0);
  }

  alt_u64 start_cpu = alt_timestamp();
  for (int i = 0; i < DATA_SIZE; i++) {
    int input = src_data[i];
    int result = input;
    if (!bypass)
      result *= (coeff_a / 400);
    IOWR(DEST_ADDR_BASE, i, result);
  }
  alt_u64 total_cpu = alt_timestamp() - start_cpu;

  printf("   [CPU Benchmark Done]\n");
  printf("   - Hardware Cycles: %lu (%lu us)\n", (unsigned long)total_time,
         (unsigned long)(total_time * 1000000 / freq));
  printf("   - Software Cycles: %lu (%lu us)\n", (unsigned long)total_cpu,
         (unsigned long)(total_cpu * 1000000 / freq));

  if (total_time > 0) {
    printf("   >> Speedup: %lu.%02lux faster!\n",
           (unsigned long)(total_cpu / total_time),
           (unsigned long)((total_cpu * 100 / total_time) % 100));
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
  alt_u32 freq = alt_timestamp_freq();
  printf("HW Cycles: %lu (%lu us)\n", (unsigned long)time_hw,
         (unsigned long)(time_hw * 1000000 / freq));
  printf("SW Cycles: %lu (%lu us)\n", (unsigned long)time_sw,
         (unsigned long)(time_sw * 1000000 / freq));

  if (time_hw > 0) {
    printf("Speedup: %lu.%02lux faster!\n", (unsigned long)(time_sw / time_hw),
           (unsigned long)((time_sw * 100 / time_hw) % 100));
  }
}

int main() {
  printf("Custom Instruction & DMA Test Application Start!\n");

  // Check for timestamp timer (optional - continue without it)
  if (alt_timestamp_start() < 0) {
    printf("Warning: Timestamp timer not defined in BSP. Performance "
           "measurements disabled.\n");
  } else {
    alt_u32 freq = alt_timestamp_freq();
    printf("Timestamp Frequency: %lu Hz\n", freq);
  }

  // Quick Hardware Version Check
  printf("\n=== Hardware Version Check ===\n");
#ifdef STREAM_MULTDIV_BASE
  int hw_version = IORD(STREAM_MULTDIV_BASE, 0);
  printf("Hardware Version: 0x%X (%d)\n", hw_version, hw_version);
  printf("Expected: 0x103 (259) for latest version\n");
  if (hw_version == 0x103) {
    printf(">>> Hardware is UP-TO-DATE! <<<\n");
  } else {
    printf(">>> WARNING: Hardware may be OLD version! <<<\n");
  }
#else
  printf("STREAM_MULTDIV_BASE not defined!\n");
#endif

  // 0. Quick Read/Write Check
  printf("Performing simple R/W check...\n");
  unsigned int magic = 0x0;
  for (int i = 0; i != DATA_SIZE; ++i) {
    IOWR(DEST_ADDR_BASE, i, magic + i);
  }
  for (int i = 0; i != DATA_SIZE; ++i) {
    unsigned int v = IORD(DEST_ADDR_BASE, i);
    if (v != magic + i) {
      printf("Error: Mismatch at index %d: expected %x, got %x\n", i, magic + i,
             v);
      break;
    }
  }

  // 1. run_custom_instruction_test();

  // 2. DMA vs CPU Source Copy Speed Test
  compare_transfer_speed(); // Skip for now

  // 3. Bypass Mode Test (Critical for debugging)
  printf("\n=== BYPASS MODE TEST ===\n");
  printf("Testing if pipeline works at all...\n");
  IOWR(STREAM_MULTDIV_BASE, 1, 1); // Enable bypass
  run_stream_processor_test(400);  // Coeff doesn't matter in bypass mode

  // 4. Multiplication Mode Test
  printf("\n=== MULTIPLICATION MODE TEST ===\n");
  IOWR(STREAM_MULTDIV_BASE, 1, 0); // Disable bypass
  run_stream_processor_test(400);  // Test with coeff 800

  return 0;
}
