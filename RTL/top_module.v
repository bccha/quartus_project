module top_module (
    input wire CLOCK_50,   // 보드에 있는 50MHz 오실레이터 핀
	 input wire RST
    // 리셋 버튼이 없다면 생략 가능 (JTAG으로 리셋 가능)
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

		.mmio_exp_address       (w_address),       // .address
		.mmio_exp_write         (w_write),         // .write
		.mmio_exp_read          (w_read),          // .read
		.mmio_exp_writedata     (w_writedata),     // .writedata
		.mmio_exp_readdata      (w_readdata),      // .readdata
		
		.mmio_exp_waitrequest   (1'b0),            // .waitrequest
		.mmio_exp_readdatavalid (w_readdatavalid), // .readdatavalid (my_slave에서 나옴)
		.mmio_exp_burstcount    (),    // .burstcount
		.mmio_exp_byteenable    (),    // .byteenable
		.mmio_exp_debugaccess   ()    // .debugaccess
		
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

     // [삭제] 기존 top_module에 있던 Valid 로직 제거됨

endmodule