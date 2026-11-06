# I2C Slave 보드 (Basys3) — 담당 : 이규현

DHT11 · HC-SR04 측정값을 스냅샷 레지스터에 저장하고 I2C 주소 0x42로 응답하는 Slave 보드 (Vivado 2020.2)

## Master 담당자용 프로토콜 요약
- Slave 주소: **7'h42** (쓰기 바이트 0x84, 읽기 바이트 0x85)
- SCL 100kHz, clock stretching 없음
- Master는 SDA를 SCL이 low인 구간에서만 바꿔야 함 (SCL 하강 후 약 1us 이상 지나서 변경 권장)
- 쓰기: `S | 0x84 | reg | data... | P`
- 읽기: `S | 0x84 | reg | Sr | 0x85 | data(ACK) ... 마지막 data(NACK) | P`
- 레지스터 포인터는 바이트마다 자동 증가

| Reg | 내용 | R/W |
|---|---|---|
| 0x00 | WHO_AM_I = 0xA5 (PASS/FAIL 판정용) | R |
| 0x01 | 습도 정수 | R |
| 0x02 | 습도 소수 | R |
| 0x03 | 온도 정수 | R |
| 0x04 | 온도 소수 | R |
| 0x05 | 거리 상위 바이트 (cm) | R |
| 0x06 | 거리 하위 바이트 | R |
| 0x07 | bit0: DHT11 OK, bit1: 초음파 OK | R |
| 0x10 | USER (Slave의 led[7:0]에 표시) | R/W |

0x01~0x07은 START 순간 값을 고정(snapshot)하므로, 한 번에 burst read하면 값이 서로 어긋나지 않음.

## 배선
| 신호 | Slave 핀 | 연결 |
|---|---|---|
| SDA | JA1 (J1) | Master JA1, 4.7kΩ 풀업을 3.3V에 |
| SCL | JA2 (L2) | Master JA2, 4.7kΩ 풀업을 3.3V에 |
| GND | JA5 | Master JA5 |
| DHT11 DATA | JB1 (A14) | |
| HC-SR04 Trig | JB2 (A16) | |
| HC-SR04 Echo | JB3 (B15) | 5V이므로 1k/2k 분압 |

## Slave 보드 조작 / 표시
- btnC: reset, btnU: FND 표시 전환 (HH.TT ↔ 거리 cm)
- UART 9600 8N1, 1초마다 `H=45.0 T=23.1 D=0123`
- led[7:0] 수신값, led[8] write 토글, led[9] read 토글, led[10] DHT OK, led[11] 초음파 OK, led[15] START~STOP

## 파일
- `src/` : top_slave, i2c_slave, i2c_regs, dht11_ctrl, hcsr04_ctrl, fnd_ctrl, uart_tx
- `constr/Basys3_slave.xdc`
- `sim/tb_i2c_slave.v` : I2C master 모델로 18개 항목 검증
- `sim/tb_sensors.v` : DHT11 / HC-SR04 모델 검증

## 실행
- 프로젝트 새로 만들기 : Vivado Tcl Console 에서 `source slave/create_project.tcl` → `slave/vivado/i2c_slave.xpr`
- 바로 보드에 올리기 : `bitstream/top_slave.bit`

## 결과
- 시뮬레이션 : `tb_i2c_slave` 18개 check 모두 PASS, `tb_sensors` 3개 PASS (DHT11 정상 / checksum 오류 거부, HC-SR04 100cm)
- 합성/구현 : LUT 578, FF 475, WNS +3.126 ns, WHS +0.090 ns (`reports/`)
