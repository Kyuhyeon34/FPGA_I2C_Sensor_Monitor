# I2C Master 보드 (담당 : 박수민)

`master` 브랜치에 올라갈 예정입니다. 올린 뒤 `main`에 합칩니다.

권장 구성 (slave/ 와 같은 형태)
```
master/
  src/        top, i2c_master, button_pulse, binary_to_bcd16, OLED / FND / UART
  sim/        tb_i2c_master, tb_top, tb_oled
  constr/     Basys3_master.xdc
  create_project.tcl
  bitstream/  top.bit
  reports/    timing_summary.txt, utilization.txt
```
