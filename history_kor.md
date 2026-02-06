# FPGA 프로젝트 검증: 커스텀 슬레이브부터 하드웨어 가속기까지

**날짜:** 2026-02-06
**프로젝트 경로:** `d:/quartus_project`

---

## 소개 (Introduction)
이 문서는 인텔 FPGA 상에서 Nios II 기반 SoC를 구축하는 개발 과정을 기록한 것입니다. 이 프로젝트는 메모리 맵(Memory-Mapped) 커스텀 슬레이브 인터페이스와 산술 연산 가속을 위한 고성능 커스텀 인스트럭션(Custom Instruction) 유닛이라는 두 가지 핵심 하드웨어 컴포넌트에 초점을 맞추고 있습니다. 단순한 변경 이력(Changelog)이 아닌, **왜** 이렇게 설계했는지에 대한 심층적인 기술 기록입니다.

---

## 챕터 1: 커스텀 슬레이브 인터페이스 (Avalon-MM)

### 도전 과제: "Structural Net Expression" 에러
듀얼 포트 RAM(DPRAM)을 슬레이브 모듈 내부에 통합하는 과정에서, 흔한 Verilog 에러인 *"Output port must be connected to a structural net expression"* 문제에 직면했습니다.
이 에러는 `readdata` 출력 포트를 `reg` 타입으로 선언해 놓고, 내부적으로 인스턴스화된 `dpram` 모듈의 출력에 직접 연결하려 했기 때문에 발생했습니다. Verilog에서 모듈 인스턴스는 레지스터(reg)가 아닌 와이어(wire)를 구동해야 합니다.

### 해결책: Wire 변환 및 Valid 로직 추가
이 문제를 해결하기 위해 `readdata`를 `wire` 타입으로 변경하여 직접 연결할 수 있게 했습니다. 또한, Avalon-MM 프로토콜은 명시적인 읽기 지연(Latency) 관리를 요구합니다. 우리가 사용하는 블록 RAM(BlockRAM) 읽기는 1 클럭 사이클이 소요되므로, 읽기 요청 후 정확히 1 사이클 뒤에 `1`이 되는 동기식 `readdatavalid` 신호를 구현했습니다.

**구현 코드 (`RTL/my_slave.v`):**
```verilog
module my_custom_slave (
    // ... ports ...
    output wire [31:0] readdata,   // reg에서 wire로 변경
    output reg         readdatavalid // Avalon-MM 지연 처리를 위해 추가
);
    
    // DPRAM 인스턴스에 직접 연결
    dpram dpram_inst (
        .clock(clk),        
        .rdaddress(address),
        // ...
        .q(readdata) // dpram이 이 wire를 직접 구동함
    );
   
    // 동기식 Valid 생성 (1 사이클 지연)
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin            
            readdatavalid <= 1'b0;
        end else begin           
            readdatavalid <= read; // 1 사이클 딜레이를 두고 전달
        end
    end
endmodule
```

### 내부 구조: 내장 메모리 (DPRAM)
커스텀 슬레이브에 실질적인 기능을 부여하기 위해 **듀얼 포트 RAM(DPRAM)**을 내장했습니다. 플립플롭 기반의 레지스터와 달리, DPRAM은 FPGA의 전용 메모리 블록(M10K/M9K)을 사용하여 고밀도 저장 공간을 효율적으로 제공합니다.

*   **왜 듀얼 포트인가?**
    서로 다른 두 포트에서 동시에 접근이 가능하기 때문입니다. 더 복잡한 시나리오에서는, 한 포트는 (이 Avalon 슬레이브를 통해) Nios II 프로세서와 연결되고, 다른 한 포트는 센서나 하드웨어 로직으로부터 고속 데이터를 독립적으로 수집할 수 있습니다.
*   **"Structural" 연결 주의사항:**
    앞서 언급한 에러 해결 과정처럼, `dpram` 모듈은 구조적(structural) 엔티티입니다. `q` (출력) 포트는 와이어를 구동하며, 이 와이어는 Avalon 인터페이스의 `readdata` 버스로 바로 연결됩니다. **중요: `q` 출력에 레지스터(`reg`)를 다시 달면 안 됩니다.** `dpram` 인스턴스가 이미 구조적으로 신호를 드라이브하고 있는데, 이를 또다시 같은 모듈 내의 `reg` 블록에 래치하려고 하면 컴파일 에러가 발생합니다.

![DPRAM 내부 아키텍처](./images/image_dpram.png)
*(그림: DPRAM이 통합된 커스텀 슬레이브의 내부 구조)*

### 주소 정렬 (Address Alignment): Byte vs. Word
구현 시 자주 간과되는 중요한 디테일은 CPU의 주소와 RAM의 주소를 어떻게 맞추느냐 하는 것입니다.

*   **충돌 포인트**:
    *   **Nios II (Master)**: **바이트 주소 지정(Byte Addressing)**을 사용합니다. 연속된 32비트 정수를 읽을 때 주소는 `0x00`, `0x04`, `0x08`, `0x0C`로 증가합니다.
    *   **DPRAM (Internal)**: **워드 인덱싱(Word Indexing)**을 사용합니다. 0번 슬롯, 1번 슬롯 순서이며 `0`, `1`, `2`, `3`을 기대합니다.
*   **해결책 (Qsys 설정)**:
    Platform Designer에서 Avalon-MM Pipeline Slave 설정을 **Address Units: WORDS**로 선택했습니다.
    *   **동작 원리**: 시스템 인터커넥트(Interconnect)가 마스터의 바이트 주소를 자동으로 2비트 우측 시프트(`Address >> 2`)한 후 모듈의 `address` 입력으로 전달합니다.
    *   **결과**: CPU가 `0x04` (바이트 주소 4)를 읽으려 할 때, `my_slave.v`는 `address` 입력으로 `1`을 받게 됩니다. 따라서 Verilog 코드 내에서 별도의 비트 슬라이싱(예: `address[9:2]`) 없이 입력 `address`를 DPRAM의 `rdaddress` 포트에 **직접** 연결할 수 있습니다.

---

## 챕터 2: 하드웨어 가속 (Custom Instruction)

### 목표: 고속 나눗셈
표준 Nios II 프로세서는 기본적으로 하드웨어 부동소수점 유닛이 없으며, 정수 나눗셈은 연산 비용이 매우 높습니다(많은 사이클 소요). 우리는 두 수를 곱한 뒤 400으로 나누는 특정 산술 연산을 극도로 빠르게 처리할 방법이 필요했습니다.

### 최적화: 나눗셈 대신 Shift-Add 사용
하드웨어 제산기(Divider)는 많은 로직 리소스와 타이밍을 잡아먹습니다. 생(Raw) 제산기를 쓰는 대신, **비트 시프트와 덧셈(Shift-Add)**을 이용한 수학적 근사법을 채택했습니다.

**수학적 원리:**
우리는 $result = (A \times B) / 400$을 계산하고자 합니다.
400으로 나누는 것은 0.0025를 곱하는 것과 비슷합니다.
우리는 1311을 곱하고 19비트 오른쪽으로 시프트하는 것이 매우 정밀한 근사값을 준다는 것을 발견했습니다:

$$ \frac{1311}{2^{19}} = \frac{1311}{524288} \approx 0.00250053 $$

이 방식의 오차는 **0.02%**에 불과하며, 우리 애플리케이션에서는 허용 가능한 수준입니다.
일반 곱셈기를 피하기 위해 1311이라는 숫자를 2의 거듭제곱의 합과 차로 구성했습니다:

$$
1311 = 1024 + 256 + 32 - 1 = (2^{10} + 2^8 + 2^5 - 2^0)
$$

**구현 코드 (`RTL/my_multi_calc.v`):**
```verilog
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            mult_stage <= 0;
            result <= 0;
        end 
        else if (clk_en) begin
            // [Cycle 1] 하드웨어 곱셈
            mult_stage <= 64'd1 * dataa * datab;
            
            // [Cycle 2] 최적화: 제산기 대신 Shift-Add 사용
            // 로직: (val * 1311) >> 19
            result <= ((mult_stage << 10) + (mult_stage << 8) + (mult_stage << 5) - mult_stage) >> 19;      
        end
    end
```

---

## 챕터 3: 시스템 통합

### 최상위 모듈 연결 (Top-Level Wiring)
마지막으로, 이 모듈들은 최상위 엔티티에서 하나로 합쳐집니다. Platform Designer가 생성한 `custom_inst_qsys` 시스템이 두뇌 역할을 하고, 우리의 커스텀 HDL 모듈들이 근육 역할을 수행합니다.

**핵심 통합 코드 (`RTL/top_module.v`):**
```verilog
    // Qsys 시스템 인스턴스화
	custom_inst_qsys u0 (
		.clk_clk       (CLOCK_50),
		.reset_reset_n (RST),  
        // ... Avalon-MM 신호 연결 ...
		.mmio_exp_readdata      (w_readdata),
		.mmio_exp_readdatavalid (w_readdatavalid), // 우리 슬레이브와 연결됨
        // ...
	);

    // 커스텀 슬레이브 인스턴스화
	my_custom_slave s1 (
		.clk(CLOCK_50),
		.readdata(w_readdata), // Qsys로 피드백
		.readdatavalid(w_readdatavalid)
        // ...
	);
```

---

## 부록: Platform Designer 설정 가이드

가속기(`my_multi_calc.v`)를 Nios II 시스템에 통합하기 위해 Platform Designer에서 다음 단계를 따르십시오.

**1단계: 새 컴포넌트 생성**
*   새 컴포넌트를 생성하고 블록 심볼을 확인합니다.
    ![블록 심볼](./images/image_block.png)

**2단계: 파일 추가**
*   `RTL/my_multi_calc.v`를 추가하고 합성 파일 분석(Analyze Synthesis Files)을 실행합니다.
    ![파일 탭 설정](./images/image_files.png)

**3단계 & 4단계: 인터페이스 및 타이밍 설정**
*   **인터페이스 타입**: **Custom Instruction Slave**를 선택합니다.
*   **타이밍**: 파이프라인 깊이를 고려하여 **Multicycle** (2 또는 3 사이클)을 명시적으로 설정합니다. Combinatorial(조합회로)을 사용하면 안 됩니다.
    *   *참고: 하드웨어 로직이 2단계이므로 2 또는 3이 적절합니다.*

*(아래 이미지의 오른쪽 설정을 참조하세요)*

![신호 및 파이미터 설정](./images/image_signals.png)

**5단계: 완료**
1.  **Finish**를 클릭하여 컴포넌트(`cust_cal`)를 저장합니다.
2.  Qsys 시스템에 새 컴포넌트를 추가합니다.

---

## 챕터 4: 고속 데이터 이동 (DMA)

### 병목 현상: CPU 복사
Nios II 프로세서가 다재다능하긴 하지만, 대용량 버퍼 데이터를 복사하는 데(예: 메인 메모리에서 하드웨어 가속기로) 사용하는 것은 비효율적입니다. `ldw` / `stw` 명령어 하나하나마다 CPU 사이클을 소모하며 병목을 유발합니다.

### 해결책: Scatter-Gather DMA (SG-DMA)
이를 해결하기 위해 **Altera Scatter-Gather DMA Controller**를 Qsys 시스템에 통합했습니다. 이를 통해 하드웨어가 독립적으로 대량의 데이터 전송을 처리하게 하여 CPU는 다른 작업을 할 수 있게 됩니다.

### 아키텍처 및 데이터 흐름
이 시스템은 처리 데이터를 매끄럽게 이동시키도록 설계되었습니다:

1.  **소스 (On-Chip Memory)**:
    *   원시 입력 데이터(예: 계산을 위한 피연산자 배열)를 보유합니다.
    *   Qsys에서 슬레이브로 매핑됩니다.
2.  **전송 엔진 (SG-DMA)**:
    *   **Memory-to-Memory** 모드로 동작합니다.
    *   On-Chip Memory에서 읽어 커스텀 슬레이브로 씁니다.
    *   디스크립터(Descriptor)를 통한 "Scatter-Gather"를 지원하여, 필요시 불연속적인 메모리 블록도 한 번에 처리할 수 있습니다.
3.  **목적지 (Custom Slave / DPRAM)**:
    *   Avalon-MM Slave 인터페이스를 통해 데이터 스트림을 받습니다.
    *   내부 DPRAM에 저장하여 커스텀 로직이나 다른 마스터가 접근할 수 있게 합니다.

![Qsys 시스템 통합](./images/image_qsys.png)
*(그림: Nios II, On-Chip Memory, SG-DMA, 커스텀 슬레이브 간의 연결을 보여주는 Qsys 시스템 뷰)*

---

## 챕터 5: 임베디드 소프트웨어 구현

하드웨어는 그것을 구동하는 소프트웨어만큼만 훌륭할 수 있습니다. 우리는 DMA를 제어하고 커스텀 가속기의 성능을 벤치마킹하기 위해 C 애플리케이션(`main.c`)을 구현했습니다.

### 1. How-To: 주소 처리 및 레지스터 접근 (Address Handling)
복잡한 DMA로 넘어가기 전에, C 코드가 어떻게 우리의 커스텀 슬레이브 하드웨어와 "대화"하는지 이해하는 것이 필수적입니다.

#### 단계 A: 시스템 맵 (`system.h`)
Qsys에서 하드웨어를 컴파일하고 BSP(Board Support Package)를 생성하면, Quartus는 `system.h` 파일을 생성합니다. 이 파일은 모든 모듈의 베이스 주소를 담고 있습니다.
*   **타겟**: `MMIO_0_BASE` (우리의 "my_custom_slave" 컴포넌트 베이스 주소).

#### 단계 B: 읽기/쓰기 매크로 (`io.h`)
하드웨어 레지스터에 접근하려면 Altera HAL이 제공하는 특정 매크로를 사용해야 합니다. 잘못된 매크로를 선택하면 세그멘테이션 폴트나 정렬 에러가 발생할 수 있습니다.

| 매크로 | 인자 | 설명 | 주소 지정 모드 |
| :--- | :--- | :--- | :--- |
| **`IOWR`** | `(BASE, REG_NUM, DATA)` | 레지스터에 32비트 데이터를 씁니다. | **워드 오프셋** (`BASE + REG_NUM * 4`) |
| **`IORD`** | `(BASE, REG_NUM)` | 레지스터에서 32비트 데이터를 읽습니다. | **워드 오프셋** (`BASE + REG_NUM * 4`) |
| `IOWR_32DIRECT` | `(BASE, OFFSET, DATA)` | 특정 *바이트* 주소에 32비트 데이터를 씁니다. | **바이트 오프셋** (`BASE + OFFSET`) |
| `IORD_32DIRECT` | `(BASE, OFFSET)` | 특정 *바이트* 주소에서 32비트 데이터를 읽습니다. | **바이트 오프셋** (`BASE + OFFSET`) |
| `IOWR_16DIRECT` | `(BASE, OFFSET, DATA)` | 16비트 데이터를 씁니다. | **바이트 오프셋** (`BASE + OFFSET`) |
| `IOWR_8DIRECT` | `(BASE, OFFSET, DATA)` | 8비트 데이터를 씁니다. | **바이트 오프셋** (`BASE + OFFSET`) |

**`IOWR` vs `IOWR_32DIRECT` 무엇을 써야 할까?**
*   **`IOWR` 사용** (권장): 우리 프로젝트처럼 컴포넌트가 슬레이브 주소 정렬을 "Word" 단위로 사용할 때. *인덱스*(0, 1, 2...)를 넘기면 매크로가 자동으로 4를 곱해줍니다.
*   **`IOWR_32DIRECT` 사용**: Raw 메모리에 접근하거나, "Byte" 주소 정렬을 사용하는 컴포넌트에 접근할 때 바이트 주소(예: `0`, `4`, `8`...)를 명시적으로 제어해야 하는 경우 사용합니다.

#### 단계 C: 인덱싱의 "마법"
하드웨어가 **Word Alignment**로 설정되어 있기 때문에, Nios II 소프트웨어의 인덱스 `i`는 DPRAM의 `i`번째 행(Row)과 완벽하게 일치합니다.
1.  **소프트웨어**: `IOWR(MMIO_0_BASE, 5, val)` -> CPU는 바이트 주소 `Base + 20` (0x14)를 출력.
2.  **인터커넥트**: "Word Aligned" 슬레이브임을 감지하고 주소를 시프트. `20 >> 2` = `5`.
3.  **하드웨어**: 슬레이브는 주소 `5`를 받음. DPRAM은 5번째 슬롯에 데이터를 씀.

**코드 예제 (`main.c`):**
```c
#include "io.h"
#include "system.h"

// 간단한 R/W 테스트
for (int i = 0; i != 256; ++i) {
    // 쓰기: 인덱스 'i'는 DPRAM 주소 'i'와 1:1 매핑됨
    IOWR(MMIO_0_BASE, i, 0x1000 + i); 
}

for (int i = 0; i != 256; ++i) {
    // 읽기: 데이터 검증
    int read_val = IORD(MMIO_0_BASE, i);
    // ...
}
```

### 2. DMA 제어: 캐시 건너뛰기
Nios II DMA 시스템에서 흔히 겪는 함정은 **데이터 캐시 일관성(Data Cache Coherency)** 문제입니다. CPU는 데이터 캐시를 가지고 있지만, DMA 엔진은 물리 메모리(RAM)를 직접 읽습니다.
만약 우리가 `src_data[i] = ...` 처럼 데이터를 쓰고 바로 DMA를 시작하면, 데이터는 RAM이 아니라 아직 CPU 캐시 안에 머물러 있을 수 있습니다. 그러면 DMA는 RAM에 있는 이전의 쓰레기 값을 복사하게 됩니다.
**해결책:** 전송을 시작하기 전에 반드시 명시적으로 데이터 캐시를 플러시(Flush)하여 RAM에 써넣어야 합니다.

```c
#include <sys/alt_cache.h> 

void start_dma_transfer() {
    // 1. 데이터 준비
    for(int i=0; i<256; i++) src_data[i] = i * 400;

    // [필수] 캐시를 RAM으로 플러시하여 DMA가 올바른 데이터를 보게 함
    alt_dcache_flush(src_data, sizeof(src_data));

    alt_msgdma_dev *dma_dev = alt_msgdma_open(DMA_ONCHIP_DP_CSR_NAME);

    // 2. 디스크립터 생성
    alt_msgdma_standard_descriptor descriptor;
    alt_msgdma_construct_standard_mm_to_mm_descriptor(
        dma_dev,
        &descriptor,
        (alt_u32 *)src_data,        // 소스 (RAM에 있는 배열)
        (alt_u32 *)MMIO_0_BASE,     // 목적지 (커스텀 슬레이브 베이스 주소)
        sizeof(src_data),           // 길이
        0
    );

    // 3. DMA 시작 (비동기)
    alt_msgdma_standard_descriptor_async_transfer(dma_dev, &descriptor);
}
```

### 3. 벤치마킹: 하드웨어 vs. 소프트웨어
커스텀 인스트럭션의 가치를 입증하기 위해, 고해상도 타임스탬프 타이머를 사용하여 하드웨어 가속기와 순수 소프트웨어 구현의 실행 시간을 측정했습니다.

**측정 코드:**
```c
#include "system.h"
#include "sys/alt_timestamp.h"

// ... inside main() ...

  if (alt_timestamp_start() < 0) {
      printf("Error: Timestamp timer not defined in BSP.\n");
      return -1;
  }

  // 하드웨어 측정 (Custom Instruction)
  time_start = alt_timestamp();
  for (int i = 990; i != 1024; ++i) {
      for (int j = 390; j != 400; ++j) {
          // 새 명령어: 멀티사이클 곱셈 & 나눗셈
          result = (int)ALT_CI_CUST_CAL_0(i, j); 
          sum += result;
      }
  }
  time_hw = alt_timestamp() - time_start;
  
  // 소프트웨어 측정 (표준 연산자)
  time_start = alt_timestamp();
  for (int i = 990; i != 1024; ++i) {
      for (int j = 390; j != 400; ++j) {
          result = i * j / 400; // 소프트웨어 나눗셈은 느림
          sum += result;
      }
  }
  time_sw = alt_timestamp() - time_start;

  printf("HW Cycles: %llu\n", time_hw);
  printf("SW Cycles: %llu\n", time_sw);
  if (time_sw > 0) {
      printf("Speedup: %.2fx faster!\n", (float)time_sw / (float)time_hw);
  }
```

이 셋업은 무거운 산술 연산을 로직으로 옮김으로써 얻을 수 있는 속도 향상에 대한 확실한 데이터를 제공합니다.

### 4. 성능 측정 결과

실제 하드웨어에서 테스트를 수행한 결과는 다음과 같습니다:

![Nios II 성능 측정 결과](./images/image_nios_result.png)
*(그림: Nios II 콘솔 출력 화면 - HW 사이클이 SW 사이클보다 현저히 적음을 볼 수 있음)*

위 결과 이미지에서 볼 수 있듯이, 동일한 연산에 대해 Custom Instruction을 사용한 하드웨어 연산(HW Cycles)이 소프트웨어 연산(SW Cycles)보다 훨씬 적은 사이클을 소모하며, 이를 통해 확실한 가속 효과를 입증했습니다.

