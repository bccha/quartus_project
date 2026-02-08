# Nios II 커스텀 인스트럭션 & DMA 가속 프로젝트

이 프로젝트는 **커스텀 인스트럭션(Custom Instruction)**과 **Scatter-Gather DMA (SG-DMA)**를 사용하여 FPGA 기반 Nios II 시스템의 성능을 최적화하는 방법을 보여줍니다.

고속 연산을 위한 하드웨어 가속 유닛을 구현하고, 메모리 간 데이터 전송을 DMA가 전담하게 하여 CPU의 부하를 획기적으로 줄였습니다.

## 설계 과정 (상세 문서)
설계 배경, 성능 분석, 파이프라인 로직 등 상세 구현 과정은 다음 문서를 참조하세요:
*   [🇰🇷 **한글: FPGA 프로젝트 검증 (상세 기록)**](./history_kor.md)
*   [🇺🇸 **English: Implementation Journey**](./history.md)

### 다른 언어로 읽기
*   [🇺🇸 **English (영어)**](./README.md)

## 프로젝트 개요

### 주요 특징
1.  **커스텀 인스트럭션 유닛 (Custom Instruction Unit)**:
    *   특정 산술 연산(`(A * B) / 400`)을 위해 최적화된 하드웨어 로직.
    *   **타이밍 최적화**: 느린 하드웨어 나눗셈기를 대신하여 Shift-Add 연산(`(A * 5243) >> 21`)을 적용, Setup Time Violation을 해결.
    *   소프트웨어 구현 대비 극적인 사이클 단축 달성.

2.  **스트리밍 가속기 (Stream Processor)**:
    *   **N-Stage 파이프라인**: 고주파수 안정성을 위해 파라미터화 가능한 3단 파이프라인 구조로 설계.
    *   **백프레셔(Backpressure) 지원**: Avalon-ST 표준 Valid-Ready 핸드셰이크 (`pipe_valid`/`pipe_ready` 체인) 구현.
    *   **엔디안 역전 보정**: Nios II 메모리 구조에 맞게 실시간 Byte-Swap 처리.
    *   **재사용 템플릿**: 다른 프로젝트에도 활용 가능한 [pipe_template.v](./RTL/pipe_template.v) 포함.

3.  **Modular SGDMA 통합**:
    *   DMA 전송 도중에 실시간으로 연산을 수행하여 CPU 부하 제로 달성.
    *   분리된 mSGDMA Dispatcher, Read Master, Write Master 구조 사용.

## 디렉토리 구조

```text
c:/Workspace/quartus_project/
├── RTL/                    # Verilog HDL 소스 파일
│   ├── stream_processor.v  # 3단 파이프라인 가속기
│   ├── pipe_template.v     # 재사용 가능한 N단 템플릿
│   ├── my_multi_calc.v     # 커스텀 인스트럭션 로직
│   └── top_module.v        # 최상위 시스템 통합
├── software/
│   ├── cust_inst_app/      # Nios II 애플리케이션 코드
│   │   └── main.c          # 벤치마킹 및 테스트 앱 (HW v0x110)
│   └── cust_inst/          # BSP - *git 제외*
├── history_kor.md          # 상세 개발 기록 (한글)
├── history.md              # 상세 개발 기록 (영어)
└── custom_inst_qsys.qsys   # Platform Designer 시스템 파일
```

## 성능 측정 결과

Nios II (50MHz) 기반 최종 테스트 결과, 다음과 같은 성능 향상을 확인했습니다:

- **바이패스 모드 (단순 복사)**: CPU 메모리 복사 루프 대비 **7.59배** 빠름.
- **연산 가속 모드**: 순수 소프트웨어 나눗셈 연산 대비 **86.14배** 빠름.

---

## 라이선스
MIT License
