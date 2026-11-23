/* Include after xiic.h: every XIic_Send / XIic_Recv in the including file goes through iic_safe.c (timeouts, retries). */
#ifndef IIC_SAFE_H
#define IIC_SAFE_H
#include "xil_types.h"
#include "xiic_l.h"

unsigned IicSafeSend(UINTPTR BaseAddress, u8 Address, u8 *Buffer, unsigned ByteCount, u8 Option);
unsigned IicSafeRecv(UINTPTR BaseAddress, u8 Address, u8 *Buffer, unsigned ByteCount, u8 Option);
extern u32 IicErrors;

#define XIic_Send IicSafeSend
#define XIic_Recv IicSafeRecv
#endif
