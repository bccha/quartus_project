# 1. 50MHz 클럭 정의 (주기 20ns)
create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]

# 2. 클럭 불확실성(Jitter 등) 계산 포함
derive_clock_uncertainty

# 3. (혹시 PLL 쓴다면) PLL 클럭 자동 생성
derive_pll_clocks