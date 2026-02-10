# Nios II 및 하드웨어 시스템 통합 가이드

[⬅️ 메인 README로 돌아가기](../README.md) | [🇰🇷 한글 메인](./README_kor.md)

## 소프트웨어 제어 (CSR 활용)

DMA 컨트롤러 하드웨어가 완성되면 Nios II 소프트웨어에서 이를 제어해야 합니다. `burst_master`는 CSR(Control Status Register) 인터페이스를 통해 제어됩니다.

### CSR 레지스터 맵
- `0x0`: Control (bit 0: Start, bit 1: Stop)
- `0x1`: Status (bit 0: Busy, bit 1: Done)
- `0x2`: Source Address
- `0x3`: Destination Address
- `0x4`: Length
- `0x5`: Processing Coefficient (burst_master_3 이상)

### C 코드 예제

```c
#include <io.h>
#include "system.h"

// DMA 시작 함수 예시
void start_dma_transfer(void* src, void* dst, int len, int coeff) {
    // 1. 설정값 입력 (기본 Base Address: BURST_MASTER_BASE)
    IOWR_32DIRECT(BURST_MASTER_BASE, 20, coeff);    // Offset 0x14 = Addr 0x5
    IOWR_32DIRECT(BURST_MASTER_BASE, 8,  src);      // Offset 0x08 = Addr 0x2
    IOWR_32DIRECT(BURST_MASTER_BASE, 12, dst);      // Offset 0x0C = Addr 0x3
    IOWR_32DIRECT(BURST_MASTER_BASE, 16, len);      // Offset 0x10 = Addr 0x4
    
    // 2. Start 명령 전송
    IOWR_32DIRECT(BURST_MASTER_BASE, 0, 1);         // Offset 0x00 = Addr 0x0
}

// 완료 대기
void wait_dma_done() {
    while(IORD_32DIRECT(BURST_MASTER_BASE, 4) & 0x1); // Status Busy 체크
}
```

---

## 실전 활용: HPS DDR 활용 및 부트 로더

### DE10-Nano와 DDR 메모리

DE10-Nano 보드는 FPGA 전용 DDR 칩이 없습니다. 대신 **HPS(Hard Processor System, ARM Core)**에 연결된 1GB DDR3 메모리를 FPGA가 **"빌려"** 사용해야 합니다.

### 1. HPS DDR 연결 (FPGA-to-SDRAM Bridge)

**Platform Designer (Qsys)에서의 연결**:
1. **Hard Processor System (HPS)** 컴포넌트 추가
2. **FPGA-to-HPS SDRAM Interface** 활성화
   - `f2h_sdram0_data` 등의 포트가 생성됨
3. **Nios II Master**를 HPS of `f2h_sdram0_data` Slaves에 연결

**주소 매핑 예시**:
- HPS DDR 시작 주소: `0xC000_0000` (Nios II 관점)
- 또는 Bridge 설정을 통해 `0x0000_0000`으로 매핑 가능

### 2. 부트 시퀀스 (Boot Sequence)의 중요성

DDR 메모리는 전원이 켜지자마자 바로 사용할 수 없습니다. **DDR 컨트롤러 초기화(Training)** 과정이 필수적입니다.

**순서**:
1. FPGA 전원 ON → FPGA Config 완료
2. **HPS 부팅 시작** (Preloader / SPL)
3. Preloader가 **DDR 컨트롤러를 초기화** ← **이 과정이 끝나야 DDR 사용 가능!**
4. Nios II가 DDR에 접근하여 프로그램 실행

> [!IMPORTANT]
> HPS가 DDR을 초기화하기 전에 Nios II가 DDR에서 코드를 읽으려고 하면 CPU가 가동을 멈추거나 에러가 발생합니다.

### 3. 부트 로더 (Bootloader)의 역할

프로그램 크기가 커서 DDR에서 실행해야 한다면, 다음과 같은 구조를 가집니다.

#### 구조:
- **On-Chip RAM**: 아주 작은 부트 로더 코드 저장 (Reset Vector)
- **DDR3 RAM**: 실제 큰 어플리케이션 코드 저장

#### 동작 순서:
1. Nios II가 **On-Chip RAM**의 부트 로더에서 시작
2. 부트 로더는 HPS가 DDR 초기화를 마쳤는지 확인 (Handshake)
3. Flash 또는 외부 SD 카드에서 코드를 읽어 **DDR로 복사**
4. 복사가 끝나면 **DDR 주소로 Jump** 하여 메인 프로그램 실행

### 4. 실전 팁: Preloader 활용

일반적으로 입문 단계에서는 **Preloader**가 DDR 초기화를 다 해준 뒤, Nios II를 Reset에서 해제하도록 설정합니다.

- **방법**: HPS의 GPIO나 특정 레지스터를 통해 Nios II의 `reset_n` 신호를 제어합니다.
- ARM 코어(HPS)가 부팅을 마치고 "DDR 준비 완료!"가 되면 Nios II를 깨우는 방식입니다.

### 5. 부트 동기화 방식 비교: Reset 제어 vs. Bootloader Polling

질문하신 것처럼 Nios II가 On-Chip RAM에서 돌면서 DDR이 준비됐는지 체크하는 것도 가능합니다. 두 방식의 차이는 다음과 같습니다.

| 구분 | Reset 제어 방식 (하드웨어) | Bootloader Polling 방식 (소프트웨어) |
| :--- | :--- | :--- |
| **개념** | Preloader가 Reset을 직접 품 | Nios는 돌면서 공유 변수/PIO 감시 |
| **안전성** | 매우 높음 (실수 방지) | 중간 (DDR 미준비 시 Bus Hang 위험) |
| **복잡도** | 단순 (Qsys 설정 중심) | 약간 높음 (Handshake 로직 필요) |
| **특징** | 가장 일반적인 방식 | Booting 애니메이션 등 조기 동작 필요 시 사용 |

#### Polling 방식 선택 시 주의사항:
1. **Bridge 활성화**: HPS가 `FPGA-to-SDRAM Bridge`를 열어주기 전에는 Nios가 DDR 주소에 접근하는 것만으로도 시스템이 멈출(Hang) 수 있습니다.
2. **Handshake용 Register**: HPS와 공유하는 PIO 레지스터나 특정 메모리 공간(On-Chip RAM 일부)을 "Ready Flag"로 정의해야 합니다.
3. **Wait Logic**: Nios II Bootloader에서 해당 Flag가 `1`이 될 때까지 무한 루프를 돌며 기다린 후, 코드를 복사하고 Jump 해야 합니다.

### 6. Preloader가 Nios II Bootloader 역할도 해주나?

**네, 하지만 역할 분담이 있습니다.**

엄밀히 말하면 **Preloader(SPL)**는 ARM 코어(HPS)를 위한 1단계 부트로더이지만, 시스템 전체의 "관리자"로서 Nios II를 도와줄 수 있습니다.

#### Preloader가 해주는 일 (ARM 관점):
1. **DDR3 초기화**: FPGA와 공유할 메모리 공간을 사용할 수 있게 만듭니다.
2. **Bridge 초기화**: `FPGA-to-SDRAM Bridge`를 활성화하여 FPGA가 DDR을 볼 수 있게 문을 엽니다.
3. **Nios II 코드 로딩 (선택 사항)**: SD 카드나 Flash에 있는 Nios II 바이너리(`.bin`)를 DDR 메모리의 특정 주소로 미리 복사해둘 수 있습니다.

#### Nios II에게 여전히 필요한 것:
Preloader가 DDR에 코드를 다 갖다 놓았더라도, Nios II는 **"어디서부터 실행해야 하는지"** 알아야 합니다.

1. **Reset Vector**: Nios II의 Reset Vector는 여전히 **On-Chip RAM**이나 DDR의 시작 지점을 가리키고 있어야 합니다.
2. **Reset 상태 유지**: Preloader가 코드를 DDR에 다 복사하기 전까지 Nios II가 깨어나면 안 됩니다. 그래서 Preloader가 마지막에 Nios II의 Reset 신호를 풀어주는 하드웨어 설계가 동반되어야 합니다.

**요약**:
- **Preloader**: 메모리(DDR) 준비 + 문(Bridge) 열기 + 코드 복사(선택)
- **Nios II**: 하드웨어 리셋 해제 후 정해진 주소(DDR 또는 On-Chip의 Jump 코드)에서 실행 시작

### 7. 아키텍처 고민: ARM(HPS) 의존성 문제

"ARM의 Preloader에 의존성이 너무 크지 않나?"라는 생각은 매우 중요한 설계적 관점입니다. FPGA의 독립성을 중요하게 생각한다면 이 의존성이 부담스러울 수 있습니다. 이를 해결하기 위한 관점과 대안은 다음과 같습니다.

#### 1) 왜 의존성이 생기는가? (하드웨어적 한계)
DE10-Nano (Cyclone V SoC)의 구조 때문입니다.
- **HPS DDR**: DDR3 컨트롤러가 ARM 하드웨어(HPS) 내부에 물리적으로 박혀 있습니다.
- **FPGA 자원**: FPGA 단독으로 DDR을 제어하려면 외부 DDR 칩이 FPGA 전용 핀에 연결되어 있어야 하는데, DE10-Nano는 모든 DDR3 핀이 HPS에 몰려 있습니다.
- **결론**: 이 보드에서 DDR을 쓰려면 ARM(HPS)의 도움(초기화)이 무조건 필요합니다.

#### 2) 의존성을 줄이는 대안 (FPGA 독립성 확보)

만약 ARM 없이 Nios II가 독자적으로 돌아가게 하고 싶다면 다음과 같은 선택지가 있습니다.

- **방법 A: On-Chip RAM만 사용**
  - 프로그램 크기를 줄여서 내장 RAM에서만 실행합니다.
  - HPS가 죽어있어도 FPGA 전원만 들어오면 Nios II가 즉시 실행됩니다. (의존성 0%)
- **방법 B: Serial Flash (EPCQ)에서 직접 실행 (XIP)**
  - 코드를 Flash에 두고 거기서 직접 읽어 실행합니다.
  - 속도가 DDR보다 훨씬 느리지만, ARM 도움 없이 독자 부팅이 가능합니다.
- **방법 C: 전용 DDR 칩이 있는 보드 사용**
  - Arria 10이나 Stratix 등 상위 보드는 FPGA 전용 DDR 슬롯이 따로 있어 ARM 없이도 광활한 메모리를 쓸 수 있습니다.

#### 3) 실무적 관점: "도구로서의 ARM"
하지만 SoC FPGA(Cyclone V 등) 시스템에서는 **"ARM을 FPGA의 초기화 비서"**로 활용하는 것이 표준입니다.
- ARM이 복잡한 DDR, SD 카드, 이더넷 초기화를 다 해주고,
- FPGA(Nios II)는 그 환경이 준비되면 "고성능 연산"에만 집중하는 구조입니다.

### 8. Altera(Intel) 권장 표준 설정 (Best Practice)

대용량 데이터를 다루는 SoC FPGA 시스템에서 Intel이 권장하는 가장 안정적인 부팅 및 메모리 설정 방법은 다음과 같습니다.

#### 1) Platform Designer (Qsys) 하드웨어 설정
- **Nios II Reset Vector**: `On-Chip RAM` (작은 크기, 4~8KB)으로 지정합니다.
- **Nios II Exception Vector**: `HPS DDR` 주소 공간으로 지정합니다.
- **Reset 제어 회로**: HPS의 전용 Reset Manager 출력이나, HPS에서 제어하는 PIO 출력을 Nios II의 `reset_n` 핀에 연결합니다.
- **DDR Bridge**: HPS의 `FPGA-to-SDRAM` 브릿지를 활성화하고 Nios II Master를 연결합니다.

#### 2) ARM 소프트웨어 설정 (Preloader/U-Boot)
- **DDR 초기화**: Preloader가 실행되면서 가장 먼저 DDR 컨트롤러를 Training 합니다.
- **Bridge 활성화**: HPS의 F2S(FPGA-to-SDRAM) 브릿지를 엽니다. 이 시점부터 FPGA가 DDR에 접근 가능합니다.
- **Nios II 이미지 복사**: U-Boot 단계에서 SD 카드의 Nios II 바이너리(`.bin`)를 DDR 시작 주소(예: `0x0100_0000`)로 로딩합니다.
- **Nios II 깨우기**: 모든 준비가 끝나면 ARM이 PIO를 조작하여 Nios II의 Reset을 해제합니다.

#### 3) Nios II 소프트웨어 설정 (BSP)
- **Reset Handler**: On-Chip RAM에서 시작하지만, 실제로는 `jump 0x0100_0000` (DDR 주소) 명령만 수행하는 아주 작은 코드입니다.
- **Main Code (.text)**: Linker Script에서 모든 코드를 `DDR` 영역에 배치합니다.
- **Stack/Heap**: 역시 `DDR` 영역에 배치하여 메모리를 넉넉하게 사용합니다.

#### 이 방식의 장점
1. **신뢰성**: ARM이 모든 하드웨어(DDR, Bridge)를 완벽히 세팅한 후 Nios II를 깨우므로 부팅 실패가 없습니다.
2. **속도**: Nios II가 On-chip에서 DDR로 소프트웨어적으로 복사할 필요가 없어 부팅 속도가 매우 빠릅니다.
3. **유연성**: Nios II 코드가 수정되어도 HPS의 SD 카드 안에 파일만 바꾸면 되므로 FPGA를 다시 컴파일할 필요가 없습니다.

> [!TIP]
> **FPGA 단독 부팅이 필요한 경우**에는 `방법 B(Flash 실행)`를 선택해야 하지만, 상용 장비나 고속 처리가 필요한 시스템에서는 위와 같은 **ARM-coordinated Boot**가 산업 표준(Standard)입니다.
