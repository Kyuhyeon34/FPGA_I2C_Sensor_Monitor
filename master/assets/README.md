# OLED 애니메이션 검증 데이터

`D:/project/fpga/ai2/i2c_driver/assets`의 현재 사용 중인 야돈 애니메이션을 가져왔습니다.

- `slowpoke-frames.hex`: 32×32 흑백 4프레임, SSD1306 page 형식의 512바이트. `tb_oled.sv`가 실제 출력과 비교하는 기준 데이터입니다.
- `slowpoke-frames.png`: 4프레임 미리보기.

합성용 ROM은 `../src/ssd1306_oled.v`에 내장되어 있으므로 보드 실행 중 외부 파일이 필요하지 않습니다.
원본의 이미지 생성 자료와 사용하지 않는 이전 캐릭터 파일은 포함하지 않았습니다.
