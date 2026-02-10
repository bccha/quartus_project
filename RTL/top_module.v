module top_module (
    input wire CLOCK_50,   // 보드에 있는 50MHz 오실레이터 핀
	 input wire RST,
 
    // === 2. HPS DDR3 Memory (HPS가 쓰는 전용 핀) ===
    output wire [14:0] HPS_DDR3_ADDR,
    output wire [2:0]  HPS_DDR3_BA,
    output wire        HPS_DDR3_CAS_N,
    output wire        HPS_DDR3_CKE,
    output wire        HPS_DDR3_CK_N,
    output wire        HPS_DDR3_CK_P,
    output wire        HPS_DDR3_CS_N,
    output wire [3:0]  HPS_DDR3_DM,
    inout  wire [31:0] HPS_DDR3_DQ,
    inout  wire [3:0]  HPS_DDR3_DQS_N,
    inout  wire [3:0]  HPS_DDR3_DQS_P,
    output wire        HPS_DDR3_ODT,
    output wire        HPS_DDR3_RAS_N,
    output wire        HPS_DDR3_RESET_N,
    output wire        HPS_DDR3_WE_N,
    input  wire        HPS_DDR3_RZQ,

    // === 3. HPS Peripherals (이더넷, SD, USB, UART, I2C) ===
    output wire        HPS_ENET_GTX_CLK,
    inout  wire        HPS_ENET_MDIO,
    output wire        HPS_ENET_MDC,
    input  wire        HPS_ENET_RX_CLK,
    input  wire        HPS_ENET_RX_DV,
    input  wire [3:0]  HPS_ENET_RX_DATA,
    output wire        HPS_ENET_TX_EN,
    output wire [3:0]  HPS_ENET_TX_DATA,

    inout  wire        HPS_SD_CMD,
    inout  wire        HPS_SD_CLK,
    inout  wire [3:0]  HPS_SD_DATA,

    input  wire        HPS_UART_RX,
    output wire        HPS_UART_TX,

    inout  wire        HPS_USB_CLKOUT,
    inout  wire [7:0]  HPS_USB_DATA,
    input  wire        HPS_USB_DIR,
    input  wire        HPS_USB_NXT,
    output wire        HPS_USB_STP,

    inout  wire        HPS_SPIM_CLK,
    inout  wire        HPS_SPIM_MISO,
    inout  wire        HPS_SPIM_MOSI,
    inout  wire        HPS_SPIM_SS,

    inout  wire        HPS_I2C0_SCLK,
    inout  wire        HPS_I2C0_SDAT,
    inout  wire        HPS_I2C1_SCLK,
    inout  wire        HPS_I2C1_SDAT,
	 // GPIO (필요하면 연결, 안 쓰면 비워둠)
	 inout  wire        HPS_CONV_USB_N,   // GPIO09
    inout  wire        HPS_ENET_INT_N,   // GPIO35
    inout  wire        HPS_LTC_GPIO,     // GPIO40
    inout  wire        HPS_LED,          // GPIO53
    inout  wire        HPS_KEY,          // GPIO54
    inout  wire        HPS_GSENSOR_INT   // GPIO61
);

	wire [7:0]  w_address;       // 주소
	wire        w_read;          // 읽기 신호
	wire        w_write;         // 쓰기 신호
	wire [31:0] w_writedata;     // 쓸 데이터
	wire [31:0] w_readdata;      // 읽은 데이터 (내 모듈 -> Qsys) 
	wire        w_readdatavalid; // [추가] 읽은 데이터 유효 신호 

    // Qsys에서 만든 시스템 인스턴스화
    // (Generate HDL 후 나오는 .v 파일 열어서 복사해오세요)
	custom_inst_qsys u0 (
		.clk_clk       (CLOCK_50),       //   clk.clk
		.reset_reset_n (RST),  // reset.reset_n		

		// 2. HPS DDR3 Memory (이름 매칭)
        .memory_mem_a                       (HPS_DDR3_ADDR),
        .memory_mem_ba                      (HPS_DDR3_BA),
        .memory_mem_ck                      (HPS_DDR3_CK_P),
        .memory_mem_ck_n                    (HPS_DDR3_CK_N),
        .memory_mem_cke                     (HPS_DDR3_CKE),
        .memory_mem_cs_n                    (HPS_DDR3_CS_N),
        .memory_mem_ras_n                   (HPS_DDR3_RAS_N),
        .memory_mem_cas_n                   (HPS_DDR3_CAS_N),
        .memory_mem_we_n                    (HPS_DDR3_WE_N),
        .memory_mem_reset_n                 (HPS_DDR3_RESET_N),
        .memory_mem_dq                      (HPS_DDR3_DQ),
        .memory_mem_dqs                     (HPS_DDR3_DQS_P),
        .memory_mem_dqs_n                   (HPS_DDR3_DQS_N),
        .memory_mem_odt                     (HPS_DDR3_ODT),
        .memory_mem_dm                      (HPS_DDR3_DM),
        .memory_oct_rzqin                   (HPS_DDR3_RZQ),

        // 3. HPS Peripherals (이름 매칭)
        // Ethernet
        .hps_io_hps_io_emac1_inst_TX_CLK    (HPS_ENET_GTX_CLK),
        .hps_io_hps_io_emac1_inst_TXD0      (HPS_ENET_TX_DATA[0]),
        .hps_io_hps_io_emac1_inst_TXD1      (HPS_ENET_TX_DATA[1]),
        .hps_io_hps_io_emac1_inst_TXD2      (HPS_ENET_TX_DATA[2]),
        .hps_io_hps_io_emac1_inst_TXD3      (HPS_ENET_TX_DATA[3]),
        .hps_io_hps_io_emac1_inst_RXD0      (HPS_ENET_RX_DATA[0]),
        .hps_io_hps_io_emac1_inst_MDIO      (HPS_ENET_MDIO),
        .hps_io_hps_io_emac1_inst_MDC       (HPS_ENET_MDC),
        .hps_io_hps_io_emac1_inst_RX_CTL    (HPS_ENET_RX_DV),
        .hps_io_hps_io_emac1_inst_TX_CTL    (HPS_ENET_TX_EN),
        .hps_io_hps_io_emac1_inst_RX_CLK    (HPS_ENET_RX_CLK),
        .hps_io_hps_io_emac1_inst_RXD1      (HPS_ENET_RX_DATA[1]),
        .hps_io_hps_io_emac1_inst_RXD2      (HPS_ENET_RX_DATA[2]),
        .hps_io_hps_io_emac1_inst_RXD3      (HPS_ENET_RX_DATA[3]),

        // SD Card
        .hps_io_hps_io_sdio_inst_CMD        (HPS_SD_CMD),
        .hps_io_hps_io_sdio_inst_D0         (HPS_SD_DATA[0]),
        .hps_io_hps_io_sdio_inst_D1         (HPS_SD_DATA[1]),
        .hps_io_hps_io_sdio_inst_CLK        (HPS_SD_CLK),
        .hps_io_hps_io_sdio_inst_D2         (HPS_SD_DATA[2]),
        .hps_io_hps_io_sdio_inst_D3         (HPS_SD_DATA[3]),

        // USB
        .hps_io_hps_io_usb1_inst_D0         (HPS_USB_DATA[0]),
        .hps_io_hps_io_usb1_inst_D1         (HPS_USB_DATA[1]),
        .hps_io_hps_io_usb1_inst_D2         (HPS_USB_DATA[2]),
        .hps_io_hps_io_usb1_inst_D3         (HPS_USB_DATA[3]),
        .hps_io_hps_io_usb1_inst_D4         (HPS_USB_DATA[4]),
        .hps_io_hps_io_usb1_inst_D5         (HPS_USB_DATA[5]),
        .hps_io_hps_io_usb1_inst_D6         (HPS_USB_DATA[6]),
        .hps_io_hps_io_usb1_inst_D7         (HPS_USB_DATA[7]),
        .hps_io_hps_io_usb1_inst_CLK        (HPS_USB_CLKOUT),
        .hps_io_hps_io_usb1_inst_STP        (HPS_USB_STP),
        .hps_io_hps_io_usb1_inst_DIR        (HPS_USB_DIR),
        .hps_io_hps_io_usb1_inst_NXT        (HPS_USB_NXT),

        // SPI
        .hps_io_hps_io_spim1_inst_CLK       (HPS_SPIM_CLK),
        .hps_io_hps_io_spim1_inst_MOSI      (HPS_SPIM_MOSI),
        .hps_io_hps_io_spim1_inst_MISO      (HPS_SPIM_MISO),
        .hps_io_hps_io_spim1_inst_SS0       (HPS_SPIM_SS),

        // UART
        .hps_io_hps_io_uart0_inst_RX        (HPS_UART_RX),
        .hps_io_hps_io_uart0_inst_TX        (HPS_UART_TX),

        // I2C
        .hps_io_hps_io_i2c0_inst_SDA        (HPS_I2C0_SDAT),
        .hps_io_hps_io_i2c0_inst_SCL        (HPS_I2C0_SCLK),
        .hps_io_hps_io_i2c1_inst_SDA        (HPS_I2C1_SDAT),
        .hps_io_hps_io_i2c1_inst_SCL        (HPS_I2C1_SCLK),

        // GPIO (비워둠)

        .hps_io_hps_io_gpio_inst_GPIO09     (HPS_CONV_USB_N),   // USB PHY Reset
        .hps_io_hps_io_gpio_inst_GPIO35     (HPS_ENET_INT_N),   // Ethernet Interrupt
        .hps_io_hps_io_gpio_inst_GPIO40     (HPS_LTC_GPIO),     // LTC Connector
        .hps_io_hps_io_gpio_inst_GPIO53     (HPS_LED),          // HPS User LED
        .hps_io_hps_io_gpio_inst_GPIO54     (HPS_KEY),          // HPS User Button
        .hps_io_hps_io_gpio_inst_GPIO61     (HPS_GSENSOR_INT),   // G-Sensor Interrupt
		  
		.mmio_exp_address       (w_address),       // .address
		.mmio_exp_write         (w_write),         // .write
		.mmio_exp_read          (w_read),          // .read
		.mmio_exp_writedata     (w_writedata),     // .writedata
		.mmio_exp_readdata      (w_readdata)      // .readdata		
	);

	my_custom_slave s1 (
		.clk(CLOCK_50),
		.reset_n(RST),
		.address(w_address),
		.read(w_read),
		.write(w_write),
		.writedata(w_writedata),
		.readdata(w_readdata),
		.readdatavalid(w_readdatavalid)
	);

endmodule