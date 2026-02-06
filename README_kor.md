# Nios II 커스텀 인스트럭션 & DMA 가속 프로젝트

이 프로젝트는 **커스텀 인스트럭션(Custom Instruction)**과 **Scatter-Gather DMA (SG-DMA)**를 사용하여 FPGA 기반 Nios II 시스템의 성능을 최적화하는 방법을 보여줍니다.

고속 연산을 위한 하드웨어 가속 유닛을 구현하고, 메모리 간 데이터 전송을 DMA가 전담하게 하여 CPU의 부하를 획기적으로 줄였습니다.

## 프로젝트 여정 (문서)
설계 의도, 타이밍 분석, 파이프라인 로직 등 상세한 구현 과정은 아래 문서를 참고하세요:
*   [🇺🇸 **English: Implementation Journey**](./history.md)
*   [🇰🇷 **Korean: FPGA 프로젝트 검증 (한글)**](./history_kor.md)

## 프로젝트 개요

### 주요 기능
1.  **커스텀 인스트럭션 유닛 (Custom Instruction Unit)**:
    *   특정 산술 연산(`(A * B) / 400`)에 최적화된 하드웨어 로직.
    *   **Timing Optimization**: 느린 하드웨어 제산기 대신 Shift-Add 연산(`(A * 1311) >> 19`)을 사용하여 Setup Time Violation 문제 해결.
    *   소프트웨어 구현 대비 획기적인 사이클 감소 달성.

2.  **커스텀 Avalon-MM 슬레이브**:
    *   내부 저장소로 듀얼 포트 RAM(DPRAM) 통합.
    *   Nios II와 DMA 양쪽에서 고속 데이터 접근 지원.

3.  **DMA 컨트롤러 (SG-DMA)**:
    *   On-Chip Memory와 커스텀 슬레이브 간의 고대역폭 데이터 전송 처리.
    *   메모리 복사 작업에서 CPU 오버헤드 제거.

## 디렉토리 구조

```text
d:/quartus_project/
├── RTL/                    # Verilog HDL 소스 파일
│   ├── my_multi_calc.v     # 커스텀 인스트럭션 로직 (Shift-Add)
│   ├── my_slave.v          # DPRAM이 내장된 커스텀 Avalon-MM 슬레이브
│   └── top_module.v        # 최상위 통합 모듈
├── software/
│   ├── cust_inst_app/      # Nios II 애플리케이션 코드
│   │   └── main.c          # 성능 벤치마킹 및 테스트 앱
│   └── cust_inst/          # Board Support Package (BSP) - *git 제외됨*
├── images/                 # 문서용 이미지
├── history_kor.md          # 구현 여정 (한글 상세 문서)
└── custom_inst_qsys.qsys   # Platform Designer (Qsys) 시스템 파일
```

## 시스템 아키텍처

Nios II 프로세서가 메인 컨트롤러로서 다음을 지휘합니다:
*   **커스텀 인스트럭션**: Nios II 데이터 경로에 직접 연결되어 제로 레이턴시(혹은 멀티사이클) 실행.
*   **DMA 엔진**: `main.c` 애플리케이션을 통해 설정되며, 메인 메모리의 데이터 청크(예: 1KB 블록)를 하드웨어 가속기 버퍼로 이동시킴.

## 소프트웨어 구현

소프트웨어(`main.c`)는 두 가지 주요 벤치마크를 수행합니다:

1.  **데이터 복사 속도**:
    *   `CPU memcpy` 루프 vs `SG-DMA 비동기 전송` 비교.
    *   정확한 하드웨어 측정을 위해 캐시 플러시 오버헤드와 Busy-wait 폴링 시간을 포함.

2.  **연산 속도**:
    *   `C 소프트웨어 나눗셈` vs `하드웨어 커스텀 인스트럭션` 비교.
    *   정확한 사이클 측정을 위해 고해상도 하드웨어 타이머(`alt_timestamp`) 사용.

## 스트리밍 가속 통합 (New)

데이터 처리(`(Data * A) / 400`)를 데이터 이동 중에 실시간으로 수행하기 위해 `stream_processor`를 사용하며, Qsys 시스템을 **Modular SGDMA**로 재구성해야 합니다.

### Platform Designer (Qsys) 설정
1.  **컴포넌트 추가**: `RTL/stream_processor.v`를 새 컴포넌트로 가져옵니다.
    *   인터페이스: `asi` (Sink), `aso` (Source), `avs` (Control Slave).
2.  **Modular SGDMA 아키텍처**:
    *   표준 SGDMA를 3개의 개별 모듈로 교체:
        *   **mSGDMA Dispatcher**: Nios II에 연결.
        *   **mSGDMA Read Master**: 메모리에서 읽음 -> 스트림으로 보냄.
        *   **mSGDMA Write Master**: 스트림에서 받음 -> 메모리에 씀.
3.  **연결 (Connections)**:
    *   `Read Master (Source)` -> `Stream Processor (Sink)`
    *   `Stream Processor (Source)` -> `Write Master (Sink)`
    *   `Nios II (Data Master)` -> `Stream Processor (avs)` (계수 A 설정용).

### 주소 맵 (Address Map)
*   **Stream Processor CSR**: 베이스 주소 (예: `0x0008_1000`)
    *   오프셋 `0x0`: Coefficient A (RW)

### 파이프라인 흐름 제어 (Valid-Ready Handshake)
`stream_processor`는 표준 Avalon-ST `valid`와 `ready` 신호를 사용하여 강력한 **백프레셔(Backpressure)** 메커니즘을 구현합니다.
*   재귀적 인에이블 로직 사용: `enable[i] = (!valid[i]) || enable[i+1]`
*   다운스트림이 준비되면 100% 처리량을 보장하고, 백프레셔 발생 시 데이터 손실 없이 일시 정지합니다.

## 성능 결과

벤치마킹 결과는 상당한 성능 향상을 보여줍니다:

![Performance Result](./images/image_nios_result.png)

*   **연산**: 하드웨어 커스텀 인스트럭션은 소프트웨어 에뮬레이션 나눗셈보다 **약 5-10배 빠릅니다** (최적화 옵션에 따라 다름).
*   **데이터 전송**: DMA는 CPU 부하를 제거하여 이론적인 병렬 처리를 가능하게 합니다 (단, 1KB 같은 소량 데이터에서는 설정 오버헤드가 보일 수 있음).

## 빌드 및 실행 방법

1.  **하드웨어 생성**:
    *   Quartus Prime에서 `custom_inst.qpf` 열기.
    *   Platform Designer (`.qsys`) 열기 및 HDL 생성.
    *   Quartus 프로젝트를 컴파일하여 `.sof` 파일 생성.
    *   FPGA 프로그래밍.

2.  **소프트웨어 컴파일 (Nios II SBT)**:
    *   BSP 생성: `nios2-bsp-generate-files --settings=software/cust_inst/settings.bsp --bsp-dir=software/cust_inst`
    *   애플리케이션 빌드: `make -C software/cust_inst_app`
    *   하드웨어에서 실행: `nios2-download -g software/cust_inst_app/main.elf && nios2-terminal`

*참고: `software/cust_inst` BSP 폴더는 git에서 제외되어 있습니다. `.sopcinfo` 파일을 사용하여 다시 생성해야 합니다.*

## 라이선스
MIT License
