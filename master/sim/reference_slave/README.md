# Slave simulation reference

`i2c_slave.v` and `i2c_regs.v` are unmodified copies of the user's reference files:
`C:/Users/kccistc/Downloads/slave`, provided on 2026-11-03.

They are used only in simulation so Master changes are tested against the actual
Slave protocol, including its register pointer, repeated START, ACK handling,
register snapshots, status flags, and USER register writes.
They are not synthesized into the Master bitstream. Original Downloads files are unchanged.
